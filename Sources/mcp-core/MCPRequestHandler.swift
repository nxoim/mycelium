import Foundation
import HTTPTypes
import Hummingbird
import MCP
import core

/// Handles an incoming MCP HTTP request by routing it through the transport layer.
public func handleMCPRequest(
    graphBox: MemoryGraphBox,
    transport: StatelessHTTPServerTransport,
    request: Request
) async throws -> Response {
    let normalizedPath = request.uri.path.replacingOccurrences(of: "/$", with: "")
    let httpRequest = try await HTTPTransportAdapter.toMCPRequest(request, path: normalizedPath)

    if let bodyData = httpRequest.body,
        let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
        let method = json["method"] as? String
    {
        if method == "initialize" {
            return HTTPTransportAdapter.makeInitializeResponse(forID: json["id"])
        }

        if method == "notifications/initialized" {
            var headers = HTTPFields()
            if let name = HTTPField.Name("content-type") {
                headers.append(HTTPField(name: name, value: "application/json"))
            }
            return Response(status: .accepted, headers: headers)
        }
    }

    let httpResponse = await transport.handleRequest(httpRequest)

    return HTTPTransportAdapter.toHBResponse(httpResponse)
}
