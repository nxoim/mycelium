import Foundation
import Hummingbird
import NIOCore
import core

struct AssociationHandlers {
    private let graph: MemoryGraphBox

    init(graph: MemoryGraphBox) {
        self.graph = graph
    }

    func handleAssociate(request: Request, context: some RequestContext) async throws -> Response {
        let identifierString = String(context.parameters["id"] ?? "")
        guard let id = UUID(uuidString: identifierString) else {
            return Response(
                status: .notFound,
                body: .init(
                    byteBuffer: ByteBuffer(
                        string: "{\"error\":\"Invalid UUID: \(identifierString)\"}")))
        }
        do {
            let body = try await request.body.collect(upTo: .max)
            let data = Data(body.readableBytesView)
            let ids = try JSONDecoder().decode([UUID].self, from: data)
            switch graph.associate(id, with: ids) {
            case .success:
                return Response(
                    status: .ok, body: .init(byteBuffer: ByteBuffer(string: "{\"ok\":true}")))
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

    func handleDissociate(request: Request, context: some RequestContext) async throws -> Response {
        let identifierString = String(context.parameters["id"] ?? "")
        guard let id = UUID(uuidString: identifierString) else {
            return Response(
                status: .notFound,
                body: .init(
                    byteBuffer: ByteBuffer(
                        string: "{\"error\":\"Invalid UUID: \(identifierString)\"}")))
        }
        do {
            let body = try await request.body.collect(upTo: .max)
            let data = Data(body.readableBytesView)
            let ids = try JSONDecoder().decode([UUID].self, from: data)
            switch graph.dissociate(id, from: ids) {
            case .success:
                return Response(
                    status: .ok, body: .init(byteBuffer: ByteBuffer(string: "{\"ok\":true}")))
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
}
