import Foundation
import Hummingbird
import HummingbirdWebSocket
import core

struct WebSocketHandler {
    static func handleConnection(
        _ inbound: WebSocketInboundStream,
        outbound: WebSocketOutboundWriter,
        wsManager: WebSocketManager,
        graph: MemoryGraphBox
    ) async {
        let connectionId = UUID()
        await wsManager.register(outbound: outbound, id: connectionId)

        await broadcastInitialGraphState(wsManager: wsManager, graph: graph)

        await readMessages(inbound, connectionId: connectionId, wsManager: wsManager, graph: graph)
        await wsManager.unregister(connectionId)
    }

    private static func broadcastInitialGraphState(
        wsManager: WebSocketManager, graph: MemoryGraphBox
    ) async {
        var nodes: [GraphNode] = []
        var assocList: [(from: UUID, to: UUID)] = []

        let result = await graph.allMemories(in: 0..<10000, depth: 0, sortOrder: .chronological)
            .firstResult()
        if case .success(let memories) = result {
            nodes = memories.items.map { memory in
                GraphNode(
                    id: memory.id, label: memory.label, content: memory.content,
                    createdAt: Date.now, associationCount: memory.associations.count)
            }
            let nodeIds = Set(memories.items.map { $0.id })
            for memory in memories.items {
                for assocId in memory.associations {
                    if nodeIds.contains(assocId) {
                        assocList.append((from: memory.id, to: assocId))
                    }
                }
            }
        }

        await wsManager.broadcast(.graphState(nodes: nodes, associations: assocList))
    }

    private static func readMessages(
        _ inbound: WebSocketInboundStream,
        connectionId: UUID,
        wsManager: WebSocketManager,
        graph: MemoryGraphBox
    ) async {
        do {
            for try await frame in inbound {
                guard frame.opcode == .text,
                    let string = frame.data.getString(
                        at: frame.data.readerIndex, length: frame.data.readableBytes)
                else {
                    continue
                }
                await handleMessage(
                    string, connectionId: connectionId, wsManager: wsManager, graph: graph)
            }
        } catch {
            await wsManager.unregister(connectionId)
        }
    }

    private static func handleMessage(
        _ message: String, connectionId: WebSocketManager.Connection.ID,
        wsManager: WebSocketManager,
        graph: MemoryGraphBox
    ) async {
        guard let data = message.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return
        }

        if let subscribe = json["subscribe"] as? String {
            handleSubscribe(
                subscribe, connectionId: connectionId, params: json, wsManager: wsManager)
        } else if let unsubscribe = json["unsubscribe"] as? String {
            handleUnsubscribe(unsubscribe, connectionId: connectionId, wsManager: wsManager)
        } else if let command = json["command"] as? String {
            await handleCommand(
                command, params: json, connectionId: connectionId, wsManager: wsManager,
                graph: graph)
        }
    }

    private static func handleSubscribe(
        _ type: String, connectionId: WebSocketManager.Connection.ID, params: [String: Any],
        wsManager: WebSocketManager
    ) {
        let identifierString = params["id"] as? String
        let keywords = params["keywords"] as? [String]
        Task {
            switch type {
            case "all":
                await wsManager.subscribe(connectionId, to: .all)
            case "memory":
                if let identifierString = identifierString,
                    let id = UUID(uuidString: identifierString)
                {
                    await wsManager.subscribe(connectionId, to: .memory(id))
                }
            case "search":
                if let keywords = keywords {
                    await wsManager.subscribe(connectionId, to: .search(keywords: keywords))
                }
            default:
                break
            }
        }
    }

    private static func handleUnsubscribe(
        _ type: String, connectionId: WebSocketManager.Connection.ID, wsManager: WebSocketManager
    ) {
        Task {
            switch type {
            case "all":
                await wsManager.unsubscribeAll(connectionId)
            default:
                break
            }
        }
    }

    private static func handleCommand(
        _ command: String,
        params: [String: Any],
        connectionId: WebSocketManager.Connection.ID,
        wsManager: WebSocketManager,
        graph: MemoryGraphBox
    ) async {
        // Wrap in Sendable struct to satisfy strict concurrency
        struct CommandCapture: @unchecked Sendable {
            let command: String
            let params: [String: Any]
            let connectionId: WebSocketManager.Connection.ID
            let wsManager: WebSocketManager
            let graph: MemoryGraphBox
        }
        let capture = CommandCapture(
            command: command,
            params: params,
            connectionId: connectionId,
            wsManager: wsManager,
            graph: graph
        )
        Task { @Sendable in
            switch capture.command {
            case "memorize":
                await handleMemorize(
                    params: capture.params, connectionId: capture.connectionId,
                    wsManager: capture.wsManager, graph: capture.graph)
            case "recall":
                await handleRecall(
                    params: capture.params, connectionId: capture.connectionId,
                    wsManager: capture.wsManager, graph: capture.graph)
            case "recallFully":
                await handleRecallFully(
                    params: capture.params, connectionId: capture.connectionId,
                    wsManager: capture.wsManager, graph: capture.graph)
            case "search":
                await handleSearch(
                    params: capture.params, connectionId: capture.connectionId,
                    wsManager: capture.wsManager, graph: capture.graph)
            case "allMemories":
                await handleAllMemories(
                    params: capture.params, connectionId: capture.connectionId,
                    wsManager: capture.wsManager, graph: capture.graph)
            case "adrift":
                await handleAdrift(
                    params: capture.params, connectionId: capture.connectionId,
                    wsManager: capture.wsManager, graph: capture.graph)
            case "forget":
                await handleForget(
                    params: capture.params, connectionId: capture.connectionId,
                    wsManager: capture.wsManager, graph: capture.graph)
            case "associate":
                await handleAssociate(
                    params: capture.params, connectionId: capture.connectionId,
                    wsManager: capture.wsManager, graph: capture.graph)
            case "dissociate":
                await handleDissociate(
                    params: capture.params, connectionId: capture.connectionId,
                    wsManager: capture.wsManager, graph: capture.graph)
            case "import":
                await handleImport(
                    params: capture.params, connectionId: capture.connectionId,
                    wsManager: capture.wsManager, graph: capture.graph)
            case "export":
                await handleExport(
                    params: capture.params, connectionId: capture.connectionId,
                    wsManager: capture.wsManager, graph: capture.graph)
            default:
                break
            }
        }
    }

    private static func handleMemorize(
        params: [String: Any], connectionId: WebSocketManager.Connection.ID,
        wsManager: WebSocketManager, graph: MemoryGraphBox
    ) async {
        guard let label = params["label"] as? String else {
            await wsManager.send(
                connectionId, .commandError(message: "Missing required field: label"))
            return
        }
        guard let content = params["content"] as? String else {
            await wsManager.send(
                connectionId, .commandError(message: "Missing required field: content"))
            return
        }
        let associations =
            (params["associations"] as? [String])?.compactMap { UUID(uuidString: $0) } ?? []
        let memory = Memory(id: UUID(), label: label, content: content, associations: associations)
        switch graph.memorize([memory]) {
        case .success(let ids):
            await wsManager.send(connectionId, .commandResult(.ids(ids.map { $0.uuidString })))
        case .failure(let error):
            await wsManager.send(connectionId, .commandError(message: error.localizedDescription))
        }
    }

    private static func handleRecall(
        params: [String: Any], connectionId: WebSocketManager.Connection.ID,
        wsManager: WebSocketManager, graph: MemoryGraphBox
    ) async {
        guard let idsStr = params["ids"] as? [String] else {
            await wsManager.send(
                connectionId, .commandError(message: "Missing required field: ids"))
            return
        }
        let ids = idsStr.compactMap { UUID(uuidString: $0) }
        let depth = params["depth"] as? Int ?? 0
        let sort =
            (params["sort"] as? String).flatMap { QueryParser.parseSortOrderStrict($0) }
            ?? .chronological
        switch await graph.recall(ids: ids, depth: depth, sortOrder: sort).firstResult() {
        case .success(let memories):
            let valid = memories.compactMap { $0 }
            await wsManager.send(connectionId, .commandResult(.memories(valid)))
        case .failure(let error):
            await wsManager.send(
                connectionId, .commandError(message: error.localizedDescription))
        }
    }

    private static func handleRecallFully(
        params: [String: Any], connectionId: WebSocketManager.Connection.ID,
        wsManager: WebSocketManager, graph: MemoryGraphBox
    ) async {
        guard let idsStr = params["ids"] as? [String] else {
            await wsManager.send(
                connectionId, .commandError(message: "Missing required field: ids"))
            return
        }
        let ids = idsStr.compactMap { UUID(uuidString: $0) }
        switch await graph.recallFully(ids: ids, sortOrder: .chronological).firstResult() {
        case .success(let contents):
            let valid = contents.compactMap { $0 }
            await wsManager.send(connectionId, .commandResult(.contents(valid)))
        case .failure(let error):
            await wsManager.send(
                connectionId, .commandError(message: error.localizedDescription))
        }
    }

    private static func handleSearch(
        params: [String: Any], connectionId: WebSocketManager.Connection.ID,
        wsManager: WebSocketManager, graph: MemoryGraphBox
    ) async {
        guard let keywords = params["keywords"] as? [String] else {
            await wsManager.send(
                connectionId, .commandError(message: "Missing required field: keywords"))
            return
        }
        let range = (params["range"] as? String).flatMap { QueryParser.parseRange($0) } ?? (0..<50)
        let depth = (params["depth"] as? Int) ?? 0
        let sort =
            (params["sort"] as? String).flatMap { QueryParser.parseSortOrderStrict($0) }
            ?? .chronological
        switch await graph.search(keywords: keywords, in: range, depth: depth, sortOrder: sort)
            .firstResult()
        {
        case .success(let searchResult):
            await wsManager.send(connectionId, .commandResult(.nodes(searchResult.items)))
        case .failure(let error):
            await wsManager.send(
                connectionId, .commandError(message: error.localizedDescription))
        }
    }

    private static func handleAllMemories(
        params: [String: Any], connectionId: WebSocketManager.Connection.ID,
        wsManager: WebSocketManager, graph: MemoryGraphBox
    ) async {
        let range = (params["range"] as? String).flatMap { QueryParser.parseRange($0) } ?? (0..<50)
        let depth = (params["depth"] as? Int) ?? 0
        let sort =
            (params["sortOrder"] as? String).flatMap { QueryParser.parseSortOrderStrict($0) }
            ?? .chronological
        switch await graph.allMemories(in: range, depth: depth, sortOrder: sort).firstResult() {
        case .success(let searchResult):
            await wsManager.send(connectionId, .commandResult(.nodes(searchResult.items)))
        case .failure(let error):
            await wsManager.send(
                connectionId, .commandError(message: error.localizedDescription))
        }
    }

    private static func handleAdrift(
        params: [String: Any], connectionId: WebSocketManager.Connection.ID,
        wsManager: WebSocketManager, graph: MemoryGraphBox
    ) async {
        let range = (params["range"] as? String).flatMap { QueryParser.parseRange($0) } ?? (0..<50)
        let depth = (params["depth"] as? Int) ?? 0
        let sort =
            (params["sort"] as? String).flatMap { QueryParser.parseSortOrderStrict($0) }
            ?? .chronological
        switch await graph.adrift(in: range, depth: depth, sortOrder: sort).firstResult() {
        case .success(let searchResult):
            await wsManager.send(connectionId, .commandResult(.nodes(searchResult.items)))
        case .failure(let error):
            await wsManager.send(
                connectionId, .commandError(message: error.localizedDescription))
        }
    }

    private static func handleForget(
        params: [String: Any], connectionId: WebSocketManager.Connection.ID,
        wsManager: WebSocketManager, graph: MemoryGraphBox
    ) async {
        guard let idsStr = params["ids"] as? [String] else {
            await wsManager.send(
                connectionId, .commandError(message: "Missing required field: ids"))
            return
        }
        let ids = idsStr.compactMap { UUID(uuidString: $0) }
        guard !ids.isEmpty else {
            await wsManager.send(connectionId, .commandError(message: "No IDs provided"))
            return
        }
        switch graph.forget(ids) {
        case .success:
            await wsManager.send(connectionId, .commandResult(.ok(true)))
        case .failure(let error):
            await wsManager.send(connectionId, .commandError(message: error.localizedDescription))
        }
    }

    private static func handleAssociate(
        params: [String: Any], connectionId: WebSocketManager.Connection.ID,
        wsManager: WebSocketManager, graph: MemoryGraphBox
    ) async {
        guard let idStr = params["id"] as? String else {
            await wsManager.send(connectionId, .commandError(message: "Missing required field: id"))
            return
        }
        guard let id = UUID(uuidString: idStr) else {
            await wsManager.send(connectionId, .commandError(message: "Invalid UUID: \(idStr)"))
            return
        }
        guard let withStr = params["with"] as? [String] else {
            await wsManager.send(
                connectionId, .commandError(message: "Missing required field: with"))
            return
        }
        let withIds = withStr.compactMap { UUID(uuidString: $0) }
        switch graph.associate(id, with: withIds) {
        case .success:
            await wsManager.send(connectionId, .commandResult(.ok(true)))
        case .failure(let error):
            await wsManager.send(connectionId, .commandError(message: error.localizedDescription))
        }
    }

    private static func handleDissociate(
        params: [String: Any], connectionId: WebSocketManager.Connection.ID,
        wsManager: WebSocketManager, graph: MemoryGraphBox
    ) async {
        guard let idStr = params["id"] as? String else {
            await wsManager.send(connectionId, .commandError(message: "Missing required field: id"))
            return
        }
        guard let id = UUID(uuidString: idStr) else {
            await wsManager.send(connectionId, .commandError(message: "Invalid UUID: \(idStr)"))
            return
        }
        guard let fromStr = params["from"] as? [String] else {
            await wsManager.send(
                connectionId, .commandError(message: "Missing required field: from"))
            return
        }
        let fromIds = fromStr.compactMap { UUID(uuidString: $0) }
        switch graph.dissociate(id, from: fromIds) {
        case .success:
            await wsManager.send(connectionId, .commandResult(.ok(true)))
        case .failure(let error):
            await wsManager.send(connectionId, .commandError(message: error.localizedDescription))
        }
    }

    private static func handleImport(
        params: [String: Any], connectionId: WebSocketManager.Connection.ID,
        wsManager: WebSocketManager, graph: MemoryGraphBox
    ) async {
        guard let jsonStr = params["json"] as? String else {
            await wsManager.send(
                connectionId, .commandError(message: "Missing required field: json"))
            return
        }
        switch graph.importMemory(json: jsonStr) {
        case .success:
            await wsManager.send(connectionId, .commandResult(.ok(true)))
        case .failure(let error):
            await wsManager.send(connectionId, .commandError(message: error.localizedDescription))
        }
    }

    private static func handleExport(
        params: [String: Any], connectionId: WebSocketManager.Connection.ID,
        wsManager: WebSocketManager, graph: MemoryGraphBox
    ) async {
        switch graph.exportMemoryJSON() {
        case .success(let jsonStr):
            await wsManager.send(connectionId, .commandResult(.exportedJson(jsonStr)))
        case .failure(let error):
            await wsManager.send(connectionId, .commandError(message: error.localizedDescription))
        }
    }
}
