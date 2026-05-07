import Foundation
import Hummingbird
import NIOCore
import core

struct AssociationHandlers {
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

    private func serverErrorResponse(_ error: Error) -> Response {
        Response(
            status: .internalServerError,
            body: .init(
                byteBuffer: ByteBuffer(
                    string: "{\"error\":\"\(error.localizedDescription)\"}"
                )
            )
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

    func handleAssociate(request: Request, context: some RequestContext) async throws -> Response {
        let identifierString = String(context.parameters["id"] ?? "")
        guard let id = UUID(uuidString: identifierString) else {
            return Response(
                status: .notFound,
                body: .init(
                    byteBuffer: ByteBuffer(
                        string: "{\"error\":\"Invalid UUID: \(identifierString)\"}"
                    )
                )
            )
        }

        do {
            let body = try await request.body.collect(upTo: .max)
            let ids = try JSONDecoder().decode(
                [UUID].self,
                from: Data(body.readableBytesView)
            )
            switch graph.associate(id, with: ids) {
            case .success:
                return successResponse()
            case .failure(let error):
                return serverErrorResponse(error)
            }
        } catch {
            return badRequestResponse(error)
        }
    }

    func handleDissociate(request: Request, context: some RequestContext) async throws -> Response {
        let identifierString = String(context.parameters["id"] ?? "")
        guard let id = UUID(uuidString: identifierString) else {
            return Response(
                status: .notFound,
                body: .init(
                    byteBuffer: ByteBuffer(
                        string: "{\"error\":\"Invalid UUID: \(identifierString)\"}"
                    )
                )
            )
        }

        do {
            let body = try await request.body.collect(upTo: .max)
            let ids = try JSONDecoder().decode(
                [UUID].self,
                from: Data(body.readableBytesView)
            )
            switch graph.dissociate(id, from: ids) {
            case .success:
                return successResponse()
            case .failure(let error):
                return serverErrorResponse(error)
            }
        } catch {
            return badRequestResponse(error)
        }
    }
}
