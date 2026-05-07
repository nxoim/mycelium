import Foundation
import Testing

@testable import core

enum CLIArg {
    static let label = "--label"
    static let content = "--content"
    static let db = "--db"
    static let depth = "--depth"
    static let assocWith = "--with"
    static let assocFrom = "--from"
    static let jsonFlag = "--json"
    static let fileFlag = "--file"
    static let range = "--range"
    static let sort = "--sort"
    static let observe = "--observe"
    static let ramOnly = "--ram-only"
    static let port = "--port"

    enum Depth: String {
        case all = "-1"
        case noAssociations = "no-associations"
    }
}

enum OutputPattern {
    static let found = "#### "
    static let memoriesOfFound = "memories of"
    static let associatedWithNothing = "Associated with nothing"
    static let null = "null"
    static let ok = "OK"
    static let imported = "imported"
    static let remappedIDs = "Remapped IDs:"
    static let arrow = "→"
}

enum HTTPPath {
    static let memories = "/memories"
    static let apiGraphState = "/api/graph/state"
    static let apiNodes = "/api/nodes"

    static func nodeAssociations(_ id: String) -> String {
        "\(HTTPPath.apiNodes)/\(id)/associations"
    }

    static func associate(_ id: String) -> String {
        "\(HTTPPath.memories)/\(id)/associate"
    }
}

enum TestResult {
    private static let uuidRegex: NSRegularExpression = {
        try! NSRegularExpression(
            pattern:
                "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
        )
    }()

    static func extractUUIDs(from text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        let matches = uuidRegex.matches(in: text, range: range)
        return matches.compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    static func firstUUID(from result: CLIResult) -> String? {
        extractUUIDs(from: result.stdout).first
    }

    static func allUUIDs(from result: CLIResult) -> [String] {
        extractUUIDs(from: result.stdout)
    }

    static func parseJSON(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }

    static func parseJSONRPCResponse(_ line: String, expectedID: Int) -> (
        isError: Bool, text: String
    )? {
        guard let data = line.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let id = json["id"] as? Int
        guard id == expectedID else { return nil }

        if let error = json["error"] as? [String: Any], !error.isEmpty {
            let message = error["message"] as? String ?? "Unknown error"
            return (isError: true, text: message)
        }

        if let result = json["result"] as? [String: Any],
            let content = result["content"] as? [[String: Any]],
            let first = content.first,
            let text = first["text"] as? String
        {
            return (isError: false, text: text)
        }

        return (isError: false, text: line)
    }
}

private final class _BundleClass {}

struct CLIResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

enum ProcessHelper {
    private static let cliPath: String = {
        let root = projectRoot()
        return root.appendingPathComponent("debug/cli").path
    }()

    static let mcpStdioPath: String = {
        let root = projectRoot()
        return root.appendingPathComponent("debug/mcp-stdio").path
    }()

    static func projectRoot() -> URL {
        let bundleURL = Bundle(for: _BundleClass.self).bundleURL
        var current = bundleURL
        for _ in 0..<10 {
            current = current.deletingLastPathComponent()
            if current.lastPathComponent == ".build" {
                break
            }
        }
        return current
    }

    static func run(_ args: [String], timeout: TimeInterval = 30.0) -> CLIResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = args
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let semaphore = DispatchSemaphore(value: 0)
        var result: (exitCode: Int32, stdout: Data, stderr: Data) = (-1, Data(), Data())
        let resultLock = NSLock()

        let thread = Thread {
            process.launch()
            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let exitCode = process.terminationStatus
            resultLock.lock()
            result = (exitCode, stdoutData, stderrData)
            resultLock.unlock()
            semaphore.signal()
        }
        thread.start()

        _ = semaphore.wait(timeout: .now() + timeout)

        resultLock.lock()
        let finalResult = result
        resultLock.unlock()

        return CLIResult(
            exitCode: finalResult.exitCode,
            stdout: String(data: finalResult.stdout, encoding: .utf8) ?? "",
            stderr: String(data: finalResult.stderr, encoding: .utf8) ?? ""
        )
    }

    static func runMCP(messages: [String], extraArgs: [String] = [], timeout: TimeInterval = 10.0)
        -> [String]
    {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: mcpStdioPath)
        process.arguments = extraArgs

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        process.launch()

        let responsesLock = NSLock()
        var responses: [String] = []
        let done = DispatchSemaphore(value: 0)

        let stdoutObserver = stdoutPipe.fileHandleForReading
        let thread = Thread {
            while true {
                guard let line = stdoutObserver.readLine() else { break }
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    responsesLock.lock()
                    responses.append(trimmed)
                    responsesLock.unlock()
                }
            }
            done.signal()
        }
        thread.start()

        for message in messages {
            let data = (message + "\n").data(using: .utf8)
            stdinPipe.fileHandleForWriting.write(data!)
        }

        Thread.sleep(forTimeInterval: timeout)

        process.terminate()
        process.waitUntilExit()
        thread.cancel()

        return responses
    }
}

extension FileHandle {
    func readLine() -> String? {
        let availableData = self.availableData
        if let line = String(data: availableData, encoding: .utf8),
            line.contains("\n")
        {
            let endIndex = line.index(line.lastIndex(of: "\n")!, offsetBy: 1)
            return String(line[..<endIndex])
        }
        return nil
    }
}

enum HTTPClient {
    struct Response {
        let statusCode: Int
        let body: String
        let jsonData: [String: Any]?

        init(statusCode: Int, body: String) {
            self.statusCode = statusCode
            self.body = body
            self.jsonData =
                try? JSONSerialization.jsonObject(
                    with: body.data(using: .utf8) ?? Data()) as? [String: Any]
        }
    }

    static func get(url: URL, timeout: TimeInterval = 10.0) -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        let (data, response) = URLSession.shared.synchronousData(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = String(data: data, encoding: .utf8) ?? ""
        return Response(statusCode: statusCode, body: body)
    }

    static func postJSON(url: URL, body: [String: Any], timeout: TimeInterval = 10.0) -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bodyData = try? JSONSerialization.data(withJSONObject: body) {
            request.httpBody = bodyData
        }
        let (responseData, response) = URLSession.shared.synchronousData(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        let bodyStr = String(data: responseData, encoding: .utf8) ?? ""
        return Response(statusCode: statusCode, body: bodyStr)
    }

    static func delete(
        url: URL, queryParams: [String: String], timeout: TimeInterval = 10.0
    ) -> Response {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = queryParams.map {
            URLQueryItem(name: $0.key, value: $0.value)
        }
        guard let targetURL = components?.url else {
            return Response(statusCode: 0, body: "Invalid URL")
        }
        var request = URLRequest(url: targetURL)
        request.httpMethod = "DELETE"
        request.timeoutInterval = timeout
        let (responseData, response) = URLSession.shared.synchronousData(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        let bodyStr = String(data: responseData, encoding: .utf8) ?? ""
        return Response(statusCode: statusCode, body: bodyStr)
    }

    static func postRaw(
        url: URL, body: String, contentType: String = "application/json",
        timeout: TimeInterval = 10.0
    ) -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = body.data(using: .utf8)
        let (responseData, response) = URLSession.shared.synchronousData(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        let bodyStr = String(data: responseData, encoding: .utf8) ?? ""
        return Response(statusCode: statusCode, body: bodyStr)
    }
}

enum WSCommand {
    static func memorize(label: String, content: String, id: Int) -> String {
        let obj: [String: Any] = [
            "command": "memorize",
            "label": label,
            "content": content,
            "associations": [] as [[String: Any]],
            "id": id as NSNumber,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
            let str = String(data: data, encoding: .utf8)
        else { return "" }
        return str
    }

    static func parseCommandResult(from text: String) -> String? {
        guard text.contains("\"event\":\"commandResult\"") else { return nil }
        let json = TestResult.parseJSON(text)
        let payload = json?["payload"] as? [String: Any]
        let ids = payload?["ids"] as? [String] ?? []
        return ids.first
    }
}

final class TestServer: @unchecked Sendable {
    private var process: Process?
    private let port: Int
    private let dbPath: String?
    private let ramOnly: Bool
    private let lock = NSLock()

    init(port: Int, dbPath: String? = nil, ramOnly: Bool = true) {
        self.port = port
        self.dbPath = dbPath
        self.ramOnly = ramOnly
    }

    func start() async throws {
        let observerPath = {
            let root = ProcessHelper.projectRoot()
            return root.appendingPathComponent("debug/websocket-observer").path
        }()

        process = Process()
        process!.executableURL = URL(fileURLWithPath: observerPath)

        var args: [String] = [CLIArg.port, "\(port)", CLIArg.observe]
        if ramOnly {
            args.append(CLIArg.ramOnly)
        }
        if let dbPath {
            args += [CLIArg.db, dbPath]
        }
        process!.arguments = args
        process!.standardOutput = FileHandle.nullDevice
        process!.standardError = FileHandle.nullDevice

        process!.launch()

        let maxWait: TimeInterval = 15.0
        let startTime = Date()
        var ready = false

        while Date().timeIntervalSince(startTime) < maxWait {
            let url = URL(string: "http://127.0.0.1:\(port)\(HTTPPath.apiGraphState)")!
            let request = URLRequest(url: url, timeoutInterval: 1.0)
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if (response as? HTTPURLResponse)?.statusCode == 200 {
                    ready = true
                    break
                }
            } catch {
                // Server not ready yet
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }

        if !ready {
            process!.terminate()
            process!.waitUntilExit()
            self.process = nil
            throw TestServerError.startFailed("Server did not become ready within \(maxWait)s")
        }
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard let process = process else { return }
        process.terminate()
        process.waitUntilExit()
        self.process = nil
    }

    var baseURL: URL {
        URL(string: "http://127.0.0.1:\(port)")!
    }

    var wsURL: URL {
        URL(string: "ws://127.0.0.1:\(port)/ws")!
    }

    enum TestServerError: Error, CustomStringConvertible {
        case startFailed(String)

        var description: String {
            switch self {
            case .startFailed(let msg): return "Start failed: \(msg)"
            }
        }
    }
}

final class TempDirectory: @unchecked Sendable {
    private var _path: String
    private let lock = NSLock()

    init() {
        let base = FileManager.default.temporaryDirectory
        _path = base.appendingPathComponent("mycelium-e2e-\(UUID().uuidString)").path
        try? FileManager.default.createDirectory(atPath: _path, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: _path)
    }

    var path: String {
        lock.withLock { _path }
    }
}

final class PortAllocator: @unchecked Sendable {
    private static let state = PortAllocatorState()

    static func allocate() -> Int {
        state.lock.lock()
        defer { state.lock.unlock() }
        let port = state.nextPort
        state.nextPort += 1
        return port
    }
}

private final class PortAllocatorState: @unchecked Sendable {
    var nextPort: Int = 9000
    let lock = NSLock()
}

enum MCPClient {
    struct CallResult {
        let isError: Bool
        let text: String
    }

    static func call(
        toolName: String,
        arguments: [String: Any] = [:],
        extraArgs: [String] = [],
        timeout: TimeInterval = 10.0
    ) -> CallResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessHelper.mcpStdioPath)
        process.arguments = extraArgs

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        process.launch()

        let responsesLock = NSLock()
        var responses: [String] = []
        let done = DispatchSemaphore(value: 0)

        let stdoutObserver = stdoutPipe.fileHandleForReading
        let readerThread = Thread {
            while true {
                guard let line = stdoutObserver.readLine() else { break }
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    responsesLock.lock()
                    responses.append(trimmed)
                    responsesLock.unlock()
                }
            }
            done.signal()
        }
        readerThread.start()

        let initReq = jsonRPCRequest(
            id: 1, method: "initialize",
            params: [
                "protocolVersion": "2024-11-05",
                "capabilities": [:],
                "clientInfo": ["name": "mycelium-e2e", "version": "0.0.1"],
            ])
        writeLine(process: process, stdinPipe: stdinPipe, text: initReq)

        let initNotif = jsonRPCNotification(method: "notifications/initialized")
        writeLine(process: process, stdinPipe: stdinPipe, text: initNotif)

        let callID = 2
        let toolReq = jsonRPCRequest(
            id: callID,
            method: "tools/call",
            params: ["name": toolName, "arguments": arguments]
        )
        writeLine(process: process, stdinPipe: stdinPipe, text: toolReq)

        _ = done.wait(timeout: .now() + timeout)

        process.terminate()
        process.waitUntilExit()

        for response in responses {
            if let parsed = TestResult.parseJSONRPCResponse(response, expectedID: callID) {
                return MCPClient.CallResult(isError: parsed.isError, text: parsed.text)
            }
        }

        return CallResult(isError: true, text: "No response received")
    }
}

private func writeLine(process: Process, stdinPipe: Pipe, text: String) {
    let data = (text + "\n").data(using: .utf8)
    stdinPipe.fileHandleForWriting.write(data!)
}

extension URLSession {
    fileprivate func synchronousData(for request: URLRequest) -> (Data, URLResponse) {
        let semaphore = DispatchSemaphore(value: 0)
        var result: (Data, URLResponse)? = nil

        let task = dataTask(with: request) { data, response, error in
            if let error = error {
                fatalError("HTTP request failed: \(error.localizedDescription)")
            }
            result = (data ?? Data(), response!)
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()

        guard let r = result else {
            fatalError("No result from synchronous request")
        }
        return r
    }
}
