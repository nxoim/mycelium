import Foundation
import Hummingbird
import NIOCore
import core

struct ImportExportHandlers {
    private let graph: MemoryGraphBox

    init(graph: MemoryGraphBox) {
        self.graph = graph
    }

    func handleImport(request: Request, context: some RequestContext) async throws -> Response {
        do {
            let body = try await request.body.collect(upTo: .max)
            let data = Data(body.readableBytesView)
            let jsonString = String(decoding: data, as: UTF8.self)
            switch graph.importMemory(json: jsonString) {
            case .success:
                return Response(
                    status: .ok, body: .init(byteBuffer: ByteBuffer(string: "{\"ok\":true}")))
            case .failure(let error):
                return Response(
                    status: .badRequest,
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

    func handleExport(request: Request, context: some RequestContext) async throws -> Response {
        switch graph.exportMemoryJSON() {
        case .success(let jsonString):
            return Response(
                status: .ok, body: .init(byteBuffer: ByteBuffer(string: jsonString)))
        case .failure(let error):
            return Response(
                status: .internalServerError,
                body: .init(
                    byteBuffer: ByteBuffer(string: "{\"error\":\"\(error.localizedDescription)\"}"))
            )
        }
    }
}
