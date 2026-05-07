import Foundation

/// Encodes a dictionary to JSON string.
internal func jsonString(_ obj: [String: Any]) -> String {
    if let data = try? JSONSerialization.data(withJSONObject: obj),
        let str = String(data: data, encoding: .utf8)
    {
        return str
    }
    return "{}"
}

/// Builds a JSON-RPC request string.
internal func jsonRPCRequest(id: Int, method: String, params: [String: Any] = [:]) -> String {
    let obj: [String: Any] = [
        "jsonrpc": "2.0",
        "id": id,
        "method": method,
        "params": params,
    ]
    return jsonString(obj)
}

/// Builds a JSON-RPC notification string.
internal func jsonRPCNotification(method: String) -> String {
    let obj: [String: Any] = [
        "jsonrpc": "2.0",
        "method": method,
    ]
    return jsonString(obj)
}

/// Parses a JSON-RPC response line for a given expected ID.
internal func parseJSONRPCResponse(_ line: String, expectedID: Int) -> (
    isError: Bool, text: String
)? {
    guard let data = line.data(using: .utf8),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }

    let id = json["id"] as? Int
    if id != expectedID { return nil }

    if let error = json["error"] as? [String: Any], !error.isEmpty {
        let message = error["message"] as? String ?? "Unknown error"
        return (isError: true, text: message)
    }

    if let result = json["result"] as? [String: Any],
        let content = result["content"] as? [[String: Any]],
        let first = content.first,
        let text = first["text"] as? String
    {
        return (isError: false, text: text)
    }

    return (isError: false, text: line)
}
