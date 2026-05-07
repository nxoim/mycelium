import Foundation
import core

enum MemoryEvent: Sendable {
    case memorized(ids: [UUID])
    case forgotten(ids: [UUID])
    case associated(id: UUID, with: [UUID])
    case dissociated(id: UUID, from: [UUID])
    case searchUpdated(keywords: [String])
    case imported
    case graphState(nodes: [GraphNode], associations: [(from: UUID, to: UUID)])
    case commandResult(CommandPayload)
    case commandError(message: String)

    func encodeToJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        switch self {
        case .memorized(let ids):
            let wrapper = EncodedMemorized(ids: ids)
            return String(data: (try? encoder.encode(wrapper)) ?? Data(), encoding: .utf8) ?? ""
        case .forgotten(let ids):
            let wrapper = EncodedForgotten(ids: ids)
            return String(data: (try? encoder.encode(wrapper)) ?? Data(), encoding: .utf8) ?? ""
        case .associated(let id, let with):
            let wrapper = EncodedAssociated(id: id, with: with)
            return String(data: (try? encoder.encode(wrapper)) ?? Data(), encoding: .utf8) ?? ""
        case .dissociated(let id, let from):
            let wrapper = EncodedDissociated(id: id, from: from)
            return String(data: (try? encoder.encode(wrapper)) ?? Data(), encoding: .utf8) ?? ""
        case .searchUpdated(let keywords):
            let wrapper = EncodedSearchUpdated(keywords: keywords)
            return String(data: (try? encoder.encode(wrapper)) ?? Data(), encoding: .utf8) ?? ""
        case .imported:
            let wrapper = EncodedImported()
            return String(data: (try? encoder.encode(wrapper)) ?? Data(), encoding: .utf8) ?? ""
        case .graphState(let nodes, let associations):
            let encodedAssocs = associations.map { EncodedAssociation(from: $0.from, to: $0.to) }
            let wrapper = EncodedGraphState(nodes: nodes, associations: encodedAssocs)
            return String(data: (try? encoder.encode(wrapper)) ?? Data(), encoding: .utf8) ?? ""
        case .commandResult(let payload):
            guard
                let jsonObject = try? JSONSerialization.jsonObject(
                    with: Data(payload.json.utf8), options: []
                )
            else {
                return "{\"event\":\"commandResult\",\"payload\":null}"
            }
            let outer = ["event": "commandResult", "payload": jsonObject]
            guard let data = try? JSONSerialization.data(withJSONObject: outer) else {
                return ""
            }
            return String(data: data, encoding: .utf8) ?? ""
        case .commandError(let message):
            let wrapper = EncodedCommandError(message: message)
            return String(data: (try? encoder.encode(wrapper)) ?? Data(), encoding: .utf8) ?? ""
        }
    }

    private struct EncodedMemorized: Encodable {
        let event: String = "memorized"
        let ids: [UUID]
    }

    private struct EncodedForgotten: Encodable {
        let event: String = "forgotten"
        let ids: [UUID]
    }

    private struct EncodedAssociated: Encodable {
        let event: String = "associated"
        let id: UUID
        let with: [UUID]
    }

    private struct EncodedDissociated: Encodable {
        let event: String = "dissociated"
        let id: UUID
        let from: [UUID]
    }

    private struct EncodedSearchUpdated: Encodable {
        let event: String = "searchUpdated"
        let keywords: [String]
    }

    private struct EncodedImported: Encodable {
        let event: String = "imported"
    }

    private struct EncodedGraphState: Encodable {
        let event: String = "graphState"
        let nodes: [GraphNode]
        let associations: [EncodedAssociation]
    }

    private struct EncodedAssociation: Encodable {
        let from: UUID
        let to: UUID
    }

    private struct EncodedCommandError: Encodable {
        let event: String = "commandError"
        let message: String
    }

}

public enum CommandPayload: Sendable {

    case ids([String])
    case memories([Memory])
    case contents([String])
    case nodes([Memory])
    case ok(Bool)
    case exportedJson(String)

    var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        switch self {
        case .ids(let ids):
            return String(data: (try? encoder.encode(["ids": ids])) ?? Data(), encoding: .utf8)
                ?? "null"
        case .memories(let memories):
            return String(data: (try? encoder.encode(memories)) ?? Data(), encoding: .utf8)
                ?? "null"
        case .contents(let contents):
            return String(data: (try? encoder.encode(contents)) ?? Data(), encoding: .utf8)
                ?? "null"
        case .nodes(let nodes):
            return String(data: (try? encoder.encode(nodes)) ?? Data(), encoding: .utf8) ?? "null"
        case .ok(let ok):
            return String(data: (try? encoder.encode(["ok": ok])) ?? Data(), encoding: .utf8)
                ?? "null"
        case .exportedJson(let json):
            return json
        }
    }
}

struct GraphNode: Encodable, Sendable {
    let id: UUID
    let label: String
    let content: String
    let createdAt: Date
    let associationCount: Int

    enum CodingKeys: String, CodingKey {
        case id, label, content, createdAt, associationCount
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(label, forKey: .label)
        try container.encode(content, forKey: .content)
        try container.encode(createdAt.iso8601(), forKey: .createdAt)
        try container.encode(associationCount, forKey: .associationCount)
    }
}

extension Date {
    func iso8601() -> String {
        ISO8601DateFormatter().string(from: self)
    }
}
