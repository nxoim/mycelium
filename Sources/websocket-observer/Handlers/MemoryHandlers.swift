import Foundation
import Hummingbird
import NIOCore
import core

struct MemoryHandlers {
    private let graph: MemoryGraphBox

    init(graph: MemoryGraphBox) {
        self.graph = graph
    }

    func handleAllMemories(request: Request, context: some RequestContext) async throws -> Response
    {
        let rangeStr = QueryParser.parseQueryParam(request.uri.query, "range")
        let range = QueryParser.parseRange(rangeStr) ?? (0..<20)
        let depthStr = QueryParser.parseQueryParam(request.uri.query, "depth")
        let depth = depthStr.flatMap { Int($0) } ?? 0
        let sortStr = QueryParser.parseQueryParam(request.uri.query, "sort")
        let sort = QueryParser.parseSortOrderStrict(sortStr) ?? .chronological
        return await handleAllMemoriesAsync(range: range, depth: depth, sort: sort)
    }

    private func handleAllMemoriesAsync(range: Range<Int>, depth: Int, sort: core.SortOrder) async
        -> Response
    {
        do {
            let result = await graph.allMemories(in: range, depth: depth, sortOrder: sort)
                .firstResult()
            switch result {
            case .success(let nodes):
                let data = try JSONEncoder().encode(nodes)
                return Response(status: .ok, body: .init(byteBuffer: ByteBuffer(data: data)))
            case .failure(let error):
                return Response(
                    status: .internalServerError,
                    body: .init(
                        byteBuffer: ByteBuffer(
                            string: "{\"error\":\"\(error.localizedDescription)\"}")))
            }
        } catch {
            return Response(
                status: .internalServerError,
                body: .init(
                    byteBuffer: ByteBuffer(string: "{\"error\":\"\(error.localizedDescription)\"}"))
            )
        }
    }

    func handleSearch(request: Request, context: some RequestContext) async throws -> Response {
        let keywords = QueryParser.parseQueryArray(request.uri.query, "keywords")
        let rangeStr = QueryParser.parseQueryParam(request.uri.query, "range")
        let range = QueryParser.parseRange(rangeStr) ?? (0..<20)
        let depthStr = QueryParser.parseQueryParam(request.uri.query, "depth")
        let depth = depthStr.flatMap { Int($0) } ?? 0
        let sortStr = QueryParser.parseQueryParam(request.uri.query, "sort")
        let sort = QueryParser.parseSortOrderStrict(sortStr) ?? .chronological
        return await handleSearchAsync(keywords: keywords, range: range, depth: depth, sort: sort)
    }

    private func handleSearchAsync(
        keywords: [String], range: Range<Int>, depth: Int, sort: core.SortOrder
    )
        async -> Response
    {
        do {
            let result = await graph.search(
                keywords: keywords, in: range, depth: depth, sortOrder: sort
            )
            .firstResult()
            switch result {
            case .success(let nodes):
                let data = try JSONEncoder().encode(nodes)
                return Response(status: .ok, body: .init(byteBuffer: ByteBuffer(data: data)))
            case .failure(let error):
                return Response(
                    status: .internalServerError,
                    body: .init(
                        byteBuffer: ByteBuffer(
                            string: "{\"error\":\"\(error.localizedDescription)\"}")))
            }
        } catch {
            return Response(
                status: .internalServerError,
                body: .init(
                    byteBuffer: ByteBuffer(string: "{\"error\":\"\(error.localizedDescription)\"}"))
            )
        }
    }

    func handleAdrift(request: Request, context: some RequestContext) async throws -> Response {
        let rangeStr = QueryParser.parseQueryParam(request.uri.query, "range")
        let range = QueryParser.parseRange(rangeStr) ?? (0..<20)
        let depthStr = QueryParser.parseQueryParam(request.uri.query, "depth")
        let depth = depthStr.flatMap { Int($0) } ?? 0
        let sortStr = QueryParser.parseQueryParam(request.uri.query, "sort")
        let sort = QueryParser.parseSortOrderStrict(sortStr) ?? .chronological
        return await handleAdriftAsync(range: range, depth: depth, sort: sort)
    }

    private func handleAdriftAsync(range: Range<Int>, depth: Int, sort: core.SortOrder) async
        -> Response
    {
        do {
            let result = await graph.adrift(in: range, depth: depth, sortOrder: sort).firstResult()
            switch result {
            case .success(let nodes):
                let data = try JSONEncoder().encode(nodes)
                return Response(status: .ok, body: .init(byteBuffer: ByteBuffer(data: data)))
            case .failure(let error):
                return Response(
                    status: .internalServerError,
                    body: .init(
                        byteBuffer: ByteBuffer(
                            string: "{\"error\":\"\(error.localizedDescription)\"}")))
            }
        } catch {
            return Response(
                status: .internalServerError,
                body: .init(
                    byteBuffer: ByteBuffer(string: "{\"error\":\"\(error.localizedDescription)\"}"))
            )
        }
    }

    func handleRecall(request: Request, context: some RequestContext) async throws -> Response {
        let identifierString = String(context.parameters["id"] ?? "")
        guard let id = UUID(uuidString: identifierString) else {
            return Response(
                status: .notFound,
                body: .init(
                    byteBuffer: ByteBuffer(
                        string: "{\"error\":\"Invalid UUID: \(identifierString)\"}")))
        }
        let depth =
            QueryParser.parseQueryParam(request.uri.query, "depth")
            .flatMap { Int($0) } ?? 0
        return await handleRecallAsync(id: id, depth: depth)
    }

    private func handleRecallAsync(id: UUID, depth: Int) async -> Response {
        do {
            let result = await graph.recall(ids: [id], depth: depth, sortOrder: .chronological)
                .firstResult()
            switch result {
            case .success(let nodes):
                guard let node = nodes.first, let memory = node else {
                    return Response(
                        status: .notFound,
                        body: .init(
                            byteBuffer: ByteBuffer(string: "{\"error\":\"Memory not found\"}")))
                }
                let data = try JSONEncoder().encode(memory)
                return Response(status: .ok, body: .init(byteBuffer: ByteBuffer(data: data)))
            case .failure(let error):
                return Response(
                    status: .internalServerError,
                    body: .init(
                        byteBuffer: ByteBuffer(
                            string: "{\"error\":\"\(error.localizedDescription)\"}")))
            }
        } catch {
            return Response(
                status: .internalServerError,
                body: .init(
                    byteBuffer: ByteBuffer(string: "{\"error\":\"\(error.localizedDescription)\"}"))
            )
        }
    }

    func handleRecallContent(request: Request, context: some RequestContext) async throws
        -> Response
    {
        let identifierString = String(context.parameters["id"] ?? "")
        guard let id = UUID(uuidString: identifierString) else {
            return Response(
                status: .notFound,
                body: .init(
                    byteBuffer: ByteBuffer(
                        string: "{\"error\":\"Invalid UUID: \(identifierString)\"}")))
        }
        return await handleRecallContentAsync(id: id)
    }

    private func handleRecallContentAsync(id: UUID) async -> Response {
        do {
            let result = await graph.recallFully(ids: [id], sortOrder: .chronological)
                .firstResult()
            switch result {
            case .success(let contents):
                guard let content = contents.first else {
                    return Response(
                        status: .notFound,
                        body: .init(
                            byteBuffer: ByteBuffer(string: "{\"error\":\"Memory not found\"}")))
                }
                let data = try JSONEncoder().encode(content)
                return Response(status: .ok, body: .init(byteBuffer: ByteBuffer(data: data)))
            case .failure(let error):
                return Response(
                    status: .internalServerError,
                    body: .init(
                        byteBuffer: ByteBuffer(
                            string: "{\"error\":\"\(error.localizedDescription)\"}")))
            }
        } catch {
            return Response(
                status: .internalServerError,
                body: .init(
                    byteBuffer: ByteBuffer(string: "{\"error\":\"\(error.localizedDescription)\"}"))
            )
        }
    }

    func handleMemorize(request: Request, context: some RequestContext) async throws -> Response {
        do {
            let body = try await request.body.collect(upTo: .max)
            let data = Data(body.readableBytesView)
            let memories = try JSONDecoder().decode([Memory].self, from: data)
            guard !memories.isEmpty else {
                return Response(
                    status: .ok, body: .init(byteBuffer: ByteBuffer(string: "{\"ids\":[]}")))
            }
            switch graph.memorize(memories) {
            case .success(let ids):
                let idsJSON = ids.map { "\"\($0.uuidString)\"" }.joined(separator: ", ")
                return Response(
                    status: .ok,
                    body: .init(byteBuffer: ByteBuffer(string: "{\"ids\":[\(idsJSON)]}")))
            case .failure(let error):
                return Response(
                    status: .internalServerError,
                    body: .init(
                        byteBuffer: ByteBuffer(
                            string: "{\"error\":\"\(error.localizedDescription)\"}")))
            }
        } catch {
            return Response(
                status: .badRequest,
                body: .init(
                    byteBuffer: ByteBuffer(string: "{\"error\":\"\(error.localizedDescription)\"}"))
            )
        }
    }

    func handleForget(request: Request, context: some RequestContext) async throws -> Response {
        let ids = QueryParser.parseQueryArray(request.uri.query, "ids").compactMap {
            UUID(uuidString: $0)
        }
        return await handleForgetAsync(ids: ids)
    }

    private func handleForgetAsync(ids: [UUID]) async -> Response {
        switch graph.forget(ids) {
        case .success:
            return Response(
                status: .ok, body: .init(byteBuffer: ByteBuffer(string: "{\"ok\":true}")))
        case .failure(let error):
            return Response(
                status: .internalServerError,
                body: .init(
                    byteBuffer: ByteBuffer(string: "{\"error\":\"\(error.localizedDescription)\"}"))
            )
        }
    }
}
