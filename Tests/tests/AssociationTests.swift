import Foundation
import Testing

@testable import core

@Suite
struct AssociationTests {

    @Test("Bidirectional association")
    func test_associate_bidirectional() async throws {
        let db = TempDirectory()
        var uuids: [String] = []

        let resultA = ProcessHelper.run([
            "memorize", "--label", "Alpha", "--content", "Memory A",
            "--db", db.path,
        ])
        uuids.append(resultA.stdout.trimmingCharacters(in: .whitespacesAndNewlines))

        let resultB = ProcessHelper.run([
            "memorize", "--label", "Beta", "--content", "Memory B",
            "--db", db.path,
        ])
        uuids.append(resultB.stdout.trimmingCharacters(in: .whitespacesAndNewlines))

        let assocResult = ProcessHelper.run([
            "associate", uuids[1], CLIArg.assocWith, uuids[0], CLIArg.db, db.path,
        ])
        #expect(assocResult.exitCode == 0)

        let recallA = ProcessHelper.run([
            "recall", uuids[0], CLIArg.depth, "1", CLIArg.db, db.path,
        ])
        #expect(recallA.exitCode == 0)
        #expect(recallA.stdout.contains("Alpha"))
        #expect(recallA.stdout.contains("- **Beta**"))

        let recallB = ProcessHelper.run([
            "recall", uuids[1], CLIArg.depth, "1", CLIArg.db, db.path,
        ])
        #expect(recallB.exitCode == 0)
        #expect(recallB.stdout.contains("Beta"))
        #expect(recallB.stdout.contains("- **Alpha**"))
        #expect(recallB.stdout.contains("id:"))

        // B1: Create a cycle (Alpha→Beta, Beta→Gamma, Gamma→Alpha) and verify no duplicates
        let resultC = ProcessHelper.run([
            "memorize", "--label", "Gamma", "--content", "Memory C",
            "--db", db.path,
        ])
        let uuidC = resultC.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        // Create cycle: Alpha→Beta (already exists), Beta→Gamma, Gamma→Alpha
        _ = ProcessHelper.run([
            "associate", uuids[1], CLIArg.assocWith, uuidC, CLIArg.db, db.path,
        ])
        _ = ProcessHelper.run([
            "associate", uuidC, CLIArg.assocWith, uuids[0], CLIArg.db, db.path,
        ])

        let recallCycle = ProcessHelper.run([
            "recall", uuids[0], CLIArg.depth, "10", CLIArg.db, db.path,
        ])
        #expect(recallCycle.exitCode == 0)

        let cycleUUIDs = TestResult.allUUIDs(from: recallCycle)
        let uniqueCycleUUIDs = Set(cycleUUIDs)
        #expect(
            cycleUUIDs.count == uniqueCycleUUIDs.count,
            "No duplicate nodes with cycle detection. Total: \(cycleUUIDs.count), Unique: \(uniqueCycleUUIDs.count)"
        )
    }

    @Test("Multiple target associations")
    func test_associate_multiple_targets() async throws {
        let db = TempDirectory()
        var uuids: [String] = []

        for label in ["Alpha", "Beta", "Gamma"] {
            let result = ProcessHelper.run([
                "memorize", CLIArg.label, label, CLIArg.content, "Content for \(label)",
                CLIArg.db, db.path,
            ])
            uuids.append(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let assocResult1 = ProcessHelper.run([
            "associate", uuids[0], CLIArg.assocWith, uuids[1], CLIArg.db, db.path,
        ])
        #expect(assocResult1.exitCode == 0)

        let assocResult2 = ProcessHelper.run([
            "associate", uuids[0], CLIArg.assocWith, uuids[2], CLIArg.db, db.path,
        ])
        #expect(assocResult2.exitCode == 0)

        let recallA = ProcessHelper.run([
            "recall", uuids[0], CLIArg.depth, "1", CLIArg.db, db.path,
        ])
        #expect(recallA.exitCode == 0)
        #expect(recallA.stdout.contains("Alpha"))
        #expect(recallA.stdout.contains("- **Beta**"))
        #expect(recallA.stdout.contains("- **Gamma**"))
        #expect(recallA.stdout.contains("id:"))

        let recallB = ProcessHelper.run([
            "recall", uuids[1], CLIArg.depth, "1", CLIArg.db, db.path,
        ])
        #expect(recallB.exitCode == 0)
        #expect(recallB.stdout.contains("Beta"))
        #expect(recallB.stdout.contains("- **Alpha**"))
        #expect(recallB.stdout.contains("id:"))

        let recallC = ProcessHelper.run([
            "recall", uuids[2], CLIArg.depth, "1", CLIArg.db, db.path,
        ])
        #expect(recallC.exitCode == 0)
        #expect(recallC.stdout.contains("Gamma"))
        #expect(recallC.stdout.contains("- **Alpha**"))
        #expect(recallC.stdout.contains("id:"))
    }

    @Test("Dissociate removes bidirectional link")
    func test_dissociate_removes_bidirectional() async throws {
        let db = TempDirectory()
        var uuids: [String] = []

        for label in ["Alpha", "Beta"] {
            let result = ProcessHelper.run([
                "memorize", CLIArg.label, label, CLIArg.content, "Content for \(label)",
                CLIArg.db, db.path,
            ])
            uuids.append(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let assocResult = ProcessHelper.run([
            "associate", uuids[0], CLIArg.assocWith, uuids[1], CLIArg.db, db.path,
        ])
        #expect(assocResult.exitCode == 0)

        let dissociateResult = ProcessHelper.run([
            "dissociate", uuids[0], CLIArg.assocFrom, uuids[1], CLIArg.db, db.path,
        ])
        #expect(dissociateResult.exitCode == 0)

        let recallA = ProcessHelper.run([
            "recall", uuids[0], CLIArg.depth, "0", CLIArg.db, db.path,
        ])
        #expect(recallA.exitCode == 0)
        #expect(recallA.stdout.contains(OutputPattern.associatedWithNothing))

        let recallB = ProcessHelper.run([
            "recall", uuids[1], CLIArg.depth, "0", CLIArg.db, db.path,
        ])
        #expect(recallB.exitCode == 0)
        #expect(recallB.stdout.contains(OutputPattern.associatedWithNothing))
    }

    @Test("MCP create with HTTP read-back")
    func test_associate_via_mcp_creates_graph_state() async throws {
        let server = TestServer(port: PortAllocator.allocate())
        try await server.start()
        defer { server.stop() }

        let mem1 = HTTPClient.postRaw(
            url: URL(string: "\(server.baseURL)\(HTTPPath.memories)")!,
            body:
                "[{\"id\":\"\(UUID())\",\"label\":\"MCPLabel1\",\"content\":\"MCP content 1\",\"associations\":[]}]"
        )
        #expect(mem1.statusCode == 200)
        let mem1JSON = TestResult.parseJSON(mem1.body)
        let mem1UUIDs = mem1JSON?["ids"] as? [String] ?? []
        #expect(mem1UUIDs.count == 1)

        let mem2 = HTTPClient.postRaw(
            url: URL(string: "\(server.baseURL)\(HTTPPath.memories)")!,
            body:
                "[{\"id\":\"\(UUID())\",\"label\":\"MCPLabel2\",\"content\":\"MCP content 2\",\"associations\":[]}]"
        )
        #expect(mem2.statusCode == 200)
        let mem2JSON = TestResult.parseJSON(mem2.body)
        let mem2UUIDs = mem2JSON?["ids"] as? [String] ?? []
        #expect(mem2UUIDs.count == 1)

        let assoc = HTTPClient.postRaw(
            url: URL(string: "\(server.baseURL)\(HTTPPath.associate(mem1UUIDs[0]))")!,
            body: "[\"\(mem2UUIDs[0])\"]"
        )
        #expect(assoc.statusCode == 200)

        let recallA = HTTPClient.get(
            url: URL(string: "\(server.baseURL)\(HTTPPath.memories)/\(mem1UUIDs[0])")!)
        #expect(recallA.statusCode == 200)
        let recallAJSON = recallA.jsonData
        #expect((recallAJSON?["label"] as? String) == "MCPLabel1")
        #expect((recallAJSON?["content"] as? String) == "MCP content 1")

        let recallB = HTTPClient.get(
            url: URL(string: "\(server.baseURL)\(HTTPPath.memories)/\(mem2UUIDs[0])")!)
        #expect(recallB.statusCode == 200)
        let recallBJSON = recallB.jsonData
        #expect((recallBJSON?["label"] as? String) == "MCPLabel2")
        #expect((recallBJSON?["content"] as? String) == "MCP content 2")
    }
}
