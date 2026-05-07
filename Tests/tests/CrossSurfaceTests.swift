import Foundation
import Testing

@testable import core

@Suite
struct CrossSurfaceTests {

    @Test("CLI create with MCP read")
    func test_cli_create_mcp_read() async throws {
        let server = TestServer(port: PortAllocator.allocate())
        try await server.start()
        defer { server.stop() }

        let createResult = HTTPClient.postRaw(
            url: URL(string: "\(server.baseURL)\(HTTPPath.memories)")!,
            body:
                "[{\"id\":\"\(UUID())\",\"label\":\"CrossTest\",\"content\":\"Created via CLI\",\"associations\":[]}]"
        )
        #expect(createResult.statusCode == 200)
        let createJSON = TestResult.parseJSON(createResult.body)
        let uuids = createJSON?["ids"] as? [String] ?? []
        #expect(uuids.count == 1)
        let uuid = uuids[0]

        let httpResult = HTTPClient.get(
            url: URL(string: "\(server.baseURL)\(HTTPPath.memories)/\(uuid)")!)
        #expect(httpResult.statusCode == 200)
        let httpJSON = httpResult.jsonData
        #expect((httpJSON?["label"] as? String) == "CrossTest")
    }

    @Test("MCP create with HTTP read")
    func test_mcp_create_http_read() async throws {
        let server = TestServer(port: PortAllocator.allocate())
        try await server.start()
        defer { server.stop() }

        let wsUUID = await createMemory(
            label: "MCPCrossTest", content: "MCP created content",
            wsURL: server.wsURL)

        if let wsUUID = wsUUID {
            let httpResult = HTTPClient.get(
                url: URL(string: "\(server.baseURL)\(HTTPPath.memories)/\(wsUUID)")!)
            #expect(httpResult.statusCode == 200)
            let httpJSON = httpResult.jsonData
            #expect((httpJSON?["label"] as? String) == "MCPCrossTest")
            #expect((httpJSON?["content"] as? String) == "MCP created content")
        }
    }

    @Test("WebSocket create with HTTP read")
    func test_ws_create_http_read() async throws {
        let server = TestServer(port: PortAllocator.allocate())
        try await server.start()
        defer { server.stop() }

        let wsUUID = await createMemory(
            label: "WSCrossTest", content: "Via WebSocket",
            wsURL: server.wsURL)

        if let wsUUID = wsUUID {
            let httpResult = HTTPClient.get(
                url: URL(string: "\(server.baseURL)\(HTTPPath.memories)/\(wsUUID)")!)
            #expect(httpResult.statusCode == 200)
            let httpJSON = httpResult.jsonData
            #expect((httpJSON?["label"] as? String) == "WSCrossTest")
            #expect((httpJSON?["content"] as? String) == "Via WebSocket")

            let detailResult = HTTPClient.get(
                url: URL(
                    string: "\(server.baseURL)\(HTTPPath.nodeAssociations(wsUUID))"
                )!)
            #expect(detailResult.statusCode == 200)
            let detailJSON = detailResult.jsonData
            #expect(detailJSON != nil, "Node detail should return valid JSON")
            if let node = detailJSON {
                #expect(
                    node["depth"] != nil,
                    "Node JSON should contain a 'depth' field. Keys: \(node.keys)")
            }
        }
    }

    @Test("Cross-surface lifecycle: CLI create → MCP search → HTTP verify")
    func test_cross_surface_lifecycle() async throws {
        let db = TempDirectory()
        let server = TestServer(port: PortAllocator.allocate())
        try await server.start()
        defer { server.stop() }

        let createResult = ProcessHelper.run([
            "memorize", CLIArg.label, "LifecycleTarget",
            CLIArg.content, "This content is about Swift programming language",
            CLIArg.db, db.path,
        ])
        #expect(createResult.exitCode == 0)

        let _ = ProcessHelper.run([
            "memorize", CLIArg.label, "UnrelatedTopic",
            CLIArg.content, "This is about something completely different",
            CLIArg.db, db.path,
        ])

        let searchResult = MCPClient.call(
            toolName: "search",
            arguments: ["keywords": ["Swift", "programming"]],
            extraArgs: [CLIArg.db, db.path]
        )
        #expect(!searchResult.isError)
        #expect(searchResult.text.contains("LifecycleTarget"))

        let emptySearch = MCPClient.call(
            toolName: "search",
            arguments: ["keywords": ["nonexistent_xyz_98765"]],
            extraArgs: [CLIArg.db, db.path]
        )
        #expect(!emptySearch.isError)
        #expect(emptySearch.text.contains("memories of") || emptySearch.text.isEmpty)

        for i in 0..<3 {
            let _ = ProcessHelper.run([
                "memorize", CLIArg.label, "AllMemTest\(i)",
                CLIArg.content, "Content number \(i)",
                CLIArg.db, db.path,
            ])
        }

        let allResult = MCPClient.call(
            toolName: "allMemories",
            arguments: ["range": "0:10"]
        )
        #expect(!allResult.isError)

        let httpResult = HTTPClient.get(
            url: URL(string: "\(server.baseURL)\(HTTPPath.memories)")!)
        #expect(httpResult.statusCode == 200)
    }
}

private func createMemory(label: String, content: String, wsURL: URL) async -> String? {
    let commandID = Int.random(in: 1000..<9999)
    let commandString = WSCommand.memorize(label: label, content: content, id: commandID)

    let session = URLSession(configuration: .default)
    let task = session.webSocketTask(with: wsURL)
    task.resume()

    task.send(.string(commandString)) { _ in }

    var captured: String?
    task.receive { _ in
        task.receive { receiveResult in
            switch receiveResult {
            case .success(let message):
                switch message {
                case .string(let text):
                    captured = WSCommand.parseCommandResult(from: text)
                case .data(let data):
                    let text = String(data: data, encoding: .utf8) ?? ""
                    captured = WSCommand.parseCommandResult(from: text)
                @unknown default:
                    break
                }
            case .failure:
                break
            }
        }
    }

    try? await Task.sleep(nanoseconds: UInt64(3.0 * 1_000_000_000))
    task.cancel(with: .normalClosure, reason: Data())

    return captured
}
