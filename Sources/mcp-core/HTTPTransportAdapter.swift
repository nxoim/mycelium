import Foundation
import HTTPTypes
import Hummingbird
import MCP

public actor HTTPTransportAdapter {

    /// Convert a Hummingbird `Request` to an MCP `HTTPRequest`.
    public static func toMCPRequest(_ request: Request, path: String) async throws
        -> MCP.HTTPRequest
    {
        let body = try await request.body.collect(upTo: .max)
        var headers: [String: String] = [:]
        for field in request.headers {
            headers[field.name.rawName] = field.value
        }
        if headers["accept"] == nil {
            headers["accept"] = "application/json"
        }
        let data =
            body.readableBytesView.withContiguousStorageIfAvailable { Data($0) }
            ?? Data(body.readableBytesView)

        return MCP.HTTPRequest(
            method: request.method.rawValue,
            headers: headers,
            body: data.isEmpty ? nil : data,
            path: path
        )
    }

    /// Convert an MCP `HTTPResponse` to a Hummingbird `Response`.
    public static func toHBResponse(_ response: MCP.HTTPResponse) -> Response {
        var hbHeaders = HTTPFields()
        for (key, value) in response.headers {
            if let name = HTTPField.Name(key) {
                hbHeaders.append(HTTPField(name: name, value: value))
            }
        }
        let status = HTTPResponse.Status(code: response.statusCode)

        if case .stream(let sseStream, _) = response {
            return Response(
                status: status,
                headers: hbHeaders,
                body: .init(asyncSequence: sseStream.map { ByteBuffer(bytes: $0) })
            )
        }

        if let data = response.bodyData {
            return Response(
                status: status,
                headers: hbHeaders,
                body: .init(byteBuffer: ByteBuffer(bytes: data))
            )
        }

        return Response(status: status, headers: hbHeaders)
    }

    /// Build a standard MCP initialize response as a Hummingbird `Response`.
    public static func makeInitializeResponse(forID requestID: Any?) -> Response {
        let serverInfo: [String: Any] = [
            "name": "mycelium-mcp",
            "version": "1.0.0",
        ]

        let capabilities: [String: Any] = [
            "tools": ["listChanged": true]
        ]

        let result: [String: Any] = [
            "protocolVersion": "2024-11-05",
            "capabilities": capabilities,
            "serverInfo": serverInfo,
        ]

        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "result": result,
            "id": requestID ?? NSNull(),
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: response) else {
            return Response(
                status: .internalServerError,
                headers: HTTPTransportAdapter.jsonHeaders,
                body: .init(byteBuffer: ByteBuffer(string: "Failed to encode initialize response"))
            )
        }

        return Response(
            status: .ok,
            headers: HTTPTransportAdapter.jsonHeaders,
            body: .init(byteBuffer: ByteBuffer(bytes: data))
        )
    }

    public static let jsonHeaders: HTTPFields = {
        var headers = HTTPFields()
        if let name = HTTPField.Name("content-type") {
            headers.append(HTTPField(name: name, value: "application/json"))
        }
        return headers
    }()
}
