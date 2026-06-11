import Foundation
import HTTPTypes
import Hummingbird
import Logging
import core

struct ServerHelpers {
    static let logger = Logger(label: "com.nxoim.mycelium.server")

    static func jsonResponse(_ data: Data) -> Response {
        return Response(status: .ok, body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }

    static func jsonResponse(_ json: [String: Any]) -> Response {
        let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        return jsonResponse(data)
    }

    static func errorResponse(_ message: String, status: HTTPResponse.Status = .internalServerError)
        -> Response
    {
        let json = ["error": message]
        let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        return Response(status: status, body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }

    static func parseAPIRange(_ query: String?) -> Range<Int> {
        return QueryParser.parseRange(query) ?? (0..<50)
    }

    static func parseAPISort(_ query: String?) -> core.SortOrder {
        guard let query = query, let sortStr = parseAPIQueryParam(query, "sort") else {
            return .chronological
        }
        return QueryParser.parseSortOrder(sortStr)
    }

    static func parseAPIQueryArray(_ query: String?, _ key: String) -> [String] {
        return QueryParser.parseQueryArray(query, key)
    }

    static func parseAPIQueryParam(_ query: String?, _ key: String) -> String? {
        return QueryParser.parseQueryParam(query, key)
    }

    static func handleGetNodes(
        request: Request, context: some Hummingbird.RequestContext, graph: MemoryGraphBox
    ) async -> Response {
        let range = parseAPIRange(request.uri.query)
        let depthStr = parseAPIQueryArray(request.uri.query, "depth").first
        let depth: Int = {
            guard let d = depthStr, let value = Int(d) else { return 0 }
            return value
        }()
        let sort = parseAPISort(request.uri.query)

        switch await graph.allMemories(in: range, depth: depth, sortOrder: sort).firstResult() {
        case .success(let searchResult):
            let summaries: [[String: Any]] = searchResult.items.map { memory in
                [
                    "id": memory.id.uuidString,
                    "label": memory.label,
                    "content": "",
                    "createdAt": "",
                    "associationCount": memory.associations.count,
                ]
            }
            let data = (try? JSONSerialization.data(withJSONObject: summaries)) ?? Data()
            return jsonResponse(data)
        case .failure(let error):
            return errorResponse(error.localizedDescription)
        }
    }

    static func handleGetNodeDetail(
        request: Request, context: some Hummingbird.RequestContext, graph: MemoryGraphBox
    ) async -> Response {
        let identifierString = String(context.parameters["id"] ?? "")
        guard let id = UUID(uuidString: identifierString) else {
            return errorResponse("Invalid UUID: \(identifierString)", status: .badRequest)
        }

        switch await graph.recall(
            ids: [id], depth: 0, sortOrder: parseAPISort(request.uri.query)
        ).firstResult() {
        case .success(let nodes):
            guard let memory = nodes.first, let memory = memory else {
                return errorResponse("Memory not found", status: .notFound)
            }
            let json: [String: Any] = [
                "id": memory.id.uuidString,
                "label": memory.label,
                "content": memory.content,
                "associations": memory.associations.map { $0.uuidString },
            ]
            let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
            return jsonResponse(data)
        case .failure(let error):
            return errorResponse(error.localizedDescription)
        }
    }

    static func handleGetNodeAssociations(
        request: Request, context: some Hummingbird.RequestContext, graph: MemoryGraphBox
    ) async -> Response {
        let identifierString = String(context.parameters["id"] ?? "")
        guard let id = UUID(uuidString: identifierString) else {
            return errorResponse("Invalid UUID: \(identifierString)", status: .badRequest)
        }

        let depthString = parseAPIQueryArray(request.uri.query, "depth").first
        let depth: Int = {
            guard let d = depthString, let value = Int(d) else { return 0 }
            return value
        }()

        switch await graph.buildSummaryNode(
            ids: [id], depth: depth, sortOrder: .chronological
        ).firstResult() {
        case .success(let nodes):
            guard let node = nodes.first, let node = node else {
                return errorResponse("Memory not found", status: .notFound)
            }
            let summaryJSON = summaryNodeToJSON(node)
            let data = (try? JSONSerialization.data(withJSONObject: summaryJSON)) ?? Data()
            return jsonResponse(data)
        case .failure(let error):
            return errorResponse(error.localizedDescription)
        }
    }

    static func summaryNodeToJSON(_ node: MemorySummaryNode) -> [String: Any] {
        let json: [String: Any] = [
            "id": node.id.uuidString,
            "label": node.label,
            "depth": node.depth,
            "associations": node.associations.map { summaryNodeToJSON($0) },
        ]
        return json
    }

    static func handleGetSearch(
        request: Request, context: some Hummingbird.RequestContext, graph: MemoryGraphBox
    ) async -> Response {
        let keywords = parseAPIQueryArray(request.uri.query, "keywords")
        let range = parseAPIRange(request.uri.query)
        let depthStr = parseAPIQueryArray(request.uri.query, "depth").first
        let depth: Int = {
            guard let d = depthStr, let value = Int(d) else { return 0 }
            return value
        }()
        let sort = parseAPISort(request.uri.query)

        switch await graph.search(keywords: keywords, in: range, depth: depth, sortOrder: sort)
            .firstResult()
        {
        case .success(let searchResult):
            let summaries: [[String: Any]] = searchResult.items.map { memory in
                [
                    "id": memory.id.uuidString,
                    "label": memory.label,
                    "content": "",
                    "createdAt": "",
                    "associationCount": memory.associations.count,
                ]
            }
            let data = (try? JSONSerialization.data(withJSONObject: summaries)) ?? Data()
            return jsonResponse(data)
        case .failure(let error):
            return errorResponse(error.localizedDescription)
        }
    }

    static func handleGetAdrift(
        request: Request, context: some Hummingbird.RequestContext, graph: MemoryGraphBox
    ) async -> Response {
        let range = parseAPIRange(request.uri.query)
        let depthStr = parseAPIQueryArray(request.uri.query, "depth").first
        let depth: Int = {
            guard let d = depthStr, let value = Int(d) else { return 0 }
            return value
        }()
        let sort = parseAPISort(request.uri.query)

        switch await graph.adrift(in: range, depth: depth, sortOrder: sort).firstResult() {
        case .success(let searchResult):
            let summaries: [[String: Any]] = searchResult.items.map { memory in
                [
                    "id": memory.id.uuidString,
                    "label": memory.label,
                    "content": "",
                    "createdAt": "",
                    "associationCount": memory.associations.count,
                ]
            }
            let data = (try? JSONSerialization.data(withJSONObject: summaries)) ?? Data()
            return jsonResponse(data)
        case .failure(let error):
            return errorResponse(error.localizedDescription)
        }
    }

    static func handleGetGraphState(
        request: Request, context: some Hummingbird.RequestContext, graph: MemoryGraphBox
    ) async -> Response {
        let range = parseAPIRange(request.uri.query)

        var nodes: [[String: Any]] = []
        var associations: [[String: String]] = []

        switch await graph.allMemories(in: range, depth: 0, sortOrder: .chronological).firstResult()
        {
        case .success(let searchResult):
            nodes = searchResult.items.map { memory in
                [
                    "id": memory.id.uuidString,
                    "label": memory.label,
                    "content": memory.content,
                    "createdAt": ISO8601DateFormatter().string(from: Date.now),
                    "associationCount": memory.associations.count,
                ]
            }

            let nodeIds = Set(searchResult.items.map { $0.id })
            for memory in searchResult.items {
                for assocId in memory.associations {
                    if nodeIds.contains(assocId) {
                        associations.append([
                            "from": memory.id.uuidString,
                            "to": assocId.uuidString,
                        ])
                    }
                }
            }
        case .failure(let error):
            return errorResponse(error.localizedDescription)
        }

        let json: [String: Any] = [
            "nodes": nodes,
            "associations": associations,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        return jsonResponse(data)
    }
}
