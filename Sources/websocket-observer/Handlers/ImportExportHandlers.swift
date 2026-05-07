import Foundation
import Hummingbird
import NIOCore
import core

struct ImportExportHandlers {
    private let graph: MemoryGraphBox

    init(graph: MemoryGraphBox) {
        self.graph = graph
    }

    private func successResponse() -> Response {
        Response(
            status: .ok,
            body: .init(byteBuffer: ByteBuffer(string: "{\"ok\":true}"))
        )
    }

    private func badRequestResponse(_ error: Error) -> Response {
        Response(
            status: .badRequest,
            body: .init(
                byteBuffer: ByteBuffer(string: "{\"error\":\"\(error.localizedDescription)\"}")
            )
        )
    }

    private func internalErrorResponse(_ error: Error) -> Response {
        Response(
            status: .internalServerError,
            body: .init(
                byteBuffer: ByteBuffer(string: "{\"error\":\"\(error.localizedDescription)\"}")
            )
        )
    }

    func handleImport(request: Request, context: some RequestContext) async throws -> Response {
        let body = try await request.body.collect(upTo: .max)
        guard let jsonStr = String(data: Data(body.readableBytesView), encoding: .utf8),
            !jsonStr.isEmpty
        else {
            throw NSError(
                domain: "ImportError", code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Missing required field: json"])
        }

        switch graph.importMemory(json: jsonStr) {
        case .success:
            return successResponse()
        case .failure(let error):
            throw error
        }
    }

    func handleExport(request: Request, context: some RequestContext) async throws -> Response {
        switch graph.exportMemoryJSON() {
        case .success(let jsonStr):
            return Response(
                status: .ok,
                body: .init(byteBuffer: ByteBuffer(string: jsonStr))
            )
        case .failure(let error):
            throw error
        }
    }
}
