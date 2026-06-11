import ArgumentParser
import Foundation
import GRDB
import HTTPTypes
import Hummingbird
import HummingbirdWebSocket
import core

#if os(macOS)
    import Darwin
#else
    import Glibc
#endif

@main
struct Observer: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "websocket-observer",
        abstract: "Start the Mycelium observation server with WebSocket support.",
        helpNames: [.short, .long]
    )

    @Flag(name: .long, help: "Enable observation server (HTTP + WebSocket)")
    var observe = false

    @Option(
        name: .customLong("http-host"),
        help: "Host and port to bind for HTTP (format: host:port, default: 127.0.0.1:8080)"
    )
    var httpHost: String = "127.0.0.1:8080"

    @Flag(help: "Use in-memory storage instead of persistent SQLite database")
    var ramOnly = false

    @Option(
        name: .long,
        help: "Path to the SQLite database directory (default: executable directory)")
    var db: String?

    func run() async throws {
        let graph: MemoryGraphBox
        let dbQueue: DatabaseQueue?
        do {
            if ramOnly {
                graph = MemoryGraphBox(InMemoryMemoryGraph())
                dbQueue = nil
            } else {
                let dbPathArg: String
                if let dbPathArgFromOpt = db {
                    dbPathArg = dbPathArgFromOpt
                } else {
                    let executableDir = URL(fileURLWithPath: CommandLine.arguments[0])
                        .deletingLastPathComponent()
                    let fm = FileManager.default
                    if !fm.fileExists(atPath: executableDir.path) {
                        try fm.createDirectory(
                            at: executableDir, withIntermediateDirectories: true)
                    }
                    dbPathArg = executableDir.appendingPathComponent("mycelium.sqlite").path
                }
                let fm = FileManager.default
                if fm.fileExists(atPath: dbPathArg) {
                    var isDir = ObjCBool(false)
                    fm.fileExists(atPath: dbPathArg, isDirectory: &isDir)
                    if isDir.boolValue {
                        let dbFile = URL(fileURLWithPath: dbPathArg).appendingPathComponent(
                            "mycelium.sqlite"
                        ).path
                        dbQueue = try DatabaseQueue(path: dbFile)
                    } else {
                        dbQueue = try DatabaseQueue(path: dbPathArg)
                    }
                } else {
                    dbQueue = try DatabaseQueue(path: dbPathArg)
                }
                graph = try MemoryGraphBox(LocalMemoryGraph(database: dbQueue!))
            }
        } catch {
            fatalError("Failed to initialize database: \(error)")
        }

        let wsManager = WebSocketManager()

        if !ramOnly, let dbQueue = dbQueue {
            let observationDriver = ObservationDriver(dbQueue: dbQueue, wsManager: wsManager)

            graph.onMemorized = { [weak observationDriver] ids in
                Task { await observationDriver?.recordMemorized(ids: ids) }
            }
            graph.onForgotten = { [weak observationDriver] ids in
                Task { await observationDriver?.recordForgotten(ids: ids) }
            }
            graph.onAssociated = { [weak observationDriver] id, with in
                Task { await observationDriver?.recordAssociated(id: id, with: with) }
            }
            graph.onDissociated = { [weak observationDriver] id, from in
                Task { await observationDriver?.recordDissociated(id: id, from: from) }
            }
            graph.onImported = { [weak observationDriver] in
                Task { await observationDriver?.recordImported() }
            }

            await observationDriver.start()
        }

        if observe {
            let memoryHandlers = MemoryHandlers(graph: graph)
            let assocHandlers = AssociationHandlers(graph: graph)
            let importExportHandlers = ImportExportHandlers(graph: graph)

            let router = Router(context: BasicWebSocketRequestContext.self)

            router.get("health") { _, _ in
                Response(status: .ok)
            }
            router.on("memories", method: .get, use: memoryHandlers.handleAllMemories)
            router.on("memories/search", method: .get, use: memoryHandlers.handleSearch)
            router.on("memories/adrift", method: .get, use: memoryHandlers.handleAdrift)
            router.on("memories/:id", method: .get, use: memoryHandlers.handleRecall)
            router.on("memories/:id/content", method: .get, use: memoryHandlers.handleRecallContent)
            router.on("memories", method: .post, use: memoryHandlers.handleMemorize)
            router.on("memories", method: .delete, use: memoryHandlers.handleForget)
            router.on("memories/:id/associate", method: .post, use: assocHandlers.handleAssociate)
            router.on("memories/:id/dissociate", method: .post, use: assocHandlers.handleDissociate)
            router.on("memories/import", method: .post, use: importExportHandlers.handleImport)
            router.on("memories/export", method: .get, use: importExportHandlers.handleExport)

            router.get("api/nodes") { request, context in
                await ServerHelpers.handleGetNodes(request: request, context: context, graph: graph)
            }
            router.get("api/nodes/:id") { request, context in
                await ServerHelpers.handleGetNodeDetail(
                    request: request, context: context, graph: graph)
            }
            router.get("api/nodes/:id/associations") { request, context in
                await ServerHelpers.handleGetNodeAssociations(
                    request: request, context: context, graph: graph)
            }
            router.get("api/search") { request, context in
                await ServerHelpers.handleGetSearch(
                    request: request, context: context, graph: graph)
            }
            router.get("api/adrift") { request, context in
                await ServerHelpers.handleGetAdrift(
                    request: request, context: context, graph: graph)
            }
            router.get("api/graph/state") { request, context in
                await ServerHelpers.handleGetGraphState(
                    request: request, context: context, graph: graph)
            }

            // Register /ws route for WebSocket connections
            router.ws("/ws") { @Sendable inbound, outbound, wsContext in
                await WebSocketHandler.handleConnection(
                    inbound, outbound: outbound, wsManager: wsManager, graph: graph)
            }

            let host = httpHost.split(separator: ":").first.map(String.init) ?? "127.0.0.1"
            let port = httpHost.split(separator: ":").last.flatMap { Int($0) } ?? 8080
            let app = Application(
                router: router,
                server: .http1WebSocketUpgrade(webSocketRouter: router, configuration: .init()),
                configuration: .init(address: .hostname(host, port: port)),
                onServerRunning: { channel in
                    ServerHelpers.logger.info(
                        "Observation server running on \(host):\(port)\(ramOnly ? " (in-memory mode)" : "")"
                    )
                }
            )

            print(
                "Observation server starting on \(host):\(port)\(ramOnly ? " (in-memory mode)" : "")"
            )
            try await app.run()
        } else {
            if ramOnly {
                print(
                    "Observer ready (in-memory mode). Use --observe to start the observation server."
                )
            } else {
                print("Observer ready. Use --observe to start the observation server.")
            }
        }
    }
}
