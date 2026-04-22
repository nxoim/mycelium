import Foundation
import Testing

@testable import core
@testable import websocket_observer

@Suite("Data types, serialization, and MemoryEvent encoding")
struct DataTypesAndEventsTests {

    // MARK: - Core domain types

    @Test("Memory codable round-trip preserves all fields")
    func memoryCodableRoundTrip() {
        let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let memory = Memory(
            id: id, label: "Test", content: "Hello\nWorld", associations: [UUID()])

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try? encoder.encode(memory)
        #expect(data != nil)

        let decoder = JSONDecoder()
        let decoded = try? decoder.decode(Memory.self, from: data!)
        #expect(decoded != nil)
        #expect(decoded?.id == id)
        #expect(decoded?.label == "Test")
        #expect(decoded?.content == "Hello\nWorld")
    }

    @Test("MemorySummary codable round-trip preserves fields")
    func memorySummaryCodableRoundTrip() {
        let id = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let summary = MemorySummary(
            id: id, label: "Summary Test", associations: [UUID()])

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try? encoder.encode(summary)
        #expect(data != nil)

        let decoder = JSONDecoder()
        let decoded = try? decoder.decode(MemorySummary.self, from: data!)
        #expect(decoded != nil)
        #expect(decoded?.id == id)
        #expect(decoded?.label == "Summary Test")
    }

    @Test("MemorySummary from Memory preserves fields")
    func memorySummaryFromMemoryInit() {
        let id = UUID()
        let mem = Memory(id: id, label: "Test", content: "Hello", associations: [UUID()])
        let summary = MemorySummary(from: mem)

        #expect(summary.id == id)
        #expect(summary.label == "Test")
        #expect(summary.associations.count == mem.associations.count)
    }

    // MARK: - CommandPayload

    @Test("CommandPayload.ids encodes valid JSON")
    func commandPayloadIdsEncodes() {
        let payload = CommandPayload.ids([
            "11111111-1111-1111-1111-111111111111",
            "22222222-2222-2222-2222-222222222222",
        ])
        #expect(payload.json.contains("\"ids\""))
        #expect(payload.json.contains("11111111-1111-1111-1111-111111111111"))
        #expect(payload.json.contains("22222222-2222-2222-2222-222222222222"))

        let data = payload.json.data(using: .utf8)!
        #expect(throws: Never.self) {
            try JSONSerialization.jsonObject(with: data)
        }
    }

    @Test("CommandPayload.ok encodes correct JSON")
    func commandPayloadOkTrue() {
        let payload = CommandPayload.ok(true)
        #expect(payload.json.contains("\"ok\":true"))

        let data = payload.json.data(using: .utf8)!
        #expect(throws: Never.self) {
            if let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let ok = dict["ok"] as? Bool
            {
                #expect(ok == true)
            } else {
                Issue.record("Failed to decode ok field")
            }
        }
    }

    @Test("CommandPayload.exportedJson returns raw json unchanged")
    func commandPayloadExportedJson() {
        let rawJson = "{\"custom\":42,\"nested\":{\"key\":\"value\"}}"
        let payload = CommandPayload.exportedJson(rawJson)
        #expect(payload.json == rawJson)
    }

    @Test("CommandPayload.memories encodes Memory array")
    func commandPayloadMemories() {
        let mem1 = Memory(id: UUID(), label: "Test1", content: "Content1", associations: [])
        let mem2 = Memory(id: UUID(), label: "Test2", content: "Content2", associations: [UUID()])
        let payload = CommandPayload.memories([mem1, mem2])
        #expect(payload.json.contains("\"label\":\"Test1\""))
        #expect(payload.json.contains("\"label\":\"Test2\""))
        #expect(payload.json.contains("\"content\":\"Content1\""))

        let data = payload.json.data(using: .utf8)!
        #expect(throws: Never.self) {
            try JSONSerialization.jsonObject(with: data)
        }
    }

    // MARK: - MemoryEvent JSON encoding (parametrized)

    private static func validateJSON(_ json: String) {
        let data = json.data(using: .utf8)!
        #expect(throws: Never.self) {
            try JSONSerialization.jsonObject(with: data)
        }
    }

    @Test(
        "all MemoryEvent variants encode valid JSON",
        arguments: [
            (
                "memorized",
                MemoryEvent.memorized(ids: [
                    UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                    UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                ]).encodeToJSON()
            ),
            (
                "forgotten",
                MemoryEvent.forgotten(ids: [
                    UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
                ]).encodeToJSON()
            ),
            (
                "associated",
                {
                    let id = UUID()
                    return MemoryEvent.associated(id: id, with: [UUID()]).encodeToJSON()
                }()
            ),
            (
                "dissociated",
                {
                    let id = UUID()
                    return MemoryEvent.dissociated(id: id, from: [UUID()]).encodeToJSON()
                }()
            ),
            (
                "searchUpdated",
                MemoryEvent.searchUpdated(keywords: ["test", "keyword"]).encodeToJSON()
            ),
            ("imported", MemoryEvent.imported.encodeToJSON()),
            (
                "graphState",
                {
                    let node = GraphNode(
                        id: UUID(),
                        label: "Test",
                        content: "line1\nline2\r\nline3\ttab",
                        createdAt: Date(),
                        associationCount: 3
                    )
                    return MemoryEvent.graphState(nodes: [node], associations: []).encodeToJSON()
                }()
            ),
            (
                "commandResult.ids",
                MemoryEvent.commandResult(
                    .ids([
                        "33333333-3333-3333-3333-333333333333"
                    ])
                ).encodeToJSON()
            ),
            (
                "commandResult.exportedJson",
                {
                    let mem = Memory(id: UUID(), label: "test", content: "data", associations: [])
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.sortedKeys]
                    let jsonStr = String(data: try! encoder.encode([mem]), encoding: .utf8)!
                    return MemoryEvent.commandResult(.exportedJson(jsonStr)).encodeToJSON()
                }()
            ),
            (
                "commandError.simple",
                MemoryEvent.commandError(message: "Invalid UUID: abc").encodeToJSON()
            ),
            ("commandError.unicode", MemoryEvent.commandError(message: "错误: 无效的输入").encodeToJSON()),
        ])
    func eventEncodesValidJSON(name: String, json: String) {
        #expect(!json.isEmpty)
        Self.validateJSON(json)
    }

    @Test("memorized event encodes event type and IDs")
    func memorizedEventEncodesTypeAndIDs() {
        let id1 = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let id2 = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let event = MemoryEvent.memorized(ids: [id1, id2])
        let json = event.encodeToJSON()

        #expect(json.contains("\"event\":\"memorized\""))
        #expect(json.contains("11111111-1111-1111-1111-111111111111"))
        #expect(json.contains("22222222-2222-2222-2222-222222222222"))
        #expect(json.contains("\"ids\""))
    }

    @Test("graphState event escapes special characters in content")
    func graphStateEventEscapesContent() {
        let node = GraphNode(
            id: UUID(),
            label: "Test",
            content: "line1\nline2\r\nline3\ttab",
            createdAt: Date(),
            associationCount: 3
        )
        let event = MemoryEvent.graphState(nodes: [node], associations: [])
        let json = event.encodeToJSON()

        #expect(json.contains("\"event\":\"graphState\""))
        #expect(json.contains("line1\\nline2\\r\\nline3\\ttab"))
        #expect(json.contains("\"associationCount\":3"))
    }

    @Test("commandResult event with ids encodes event type and payload")
    func commandResultEventWithIdsEncodes() {
        let event = MemoryEvent.commandResult(
            .ids(["33333333-3333-3333-3333-333333333333"]))
        let json = event.encodeToJSON()

        #expect(json.contains("\"event\":\"commandResult\""))
        #expect(json.contains("\"ids\""))
        #expect(json.contains("33333333-3333-3333-3333-333333333333"))
    }

    @Test("commandError event encodes unicode message")
    func commandErrorEventEncodesUnicodeMessage() {
        let event = MemoryEvent.commandError(message: "错误: 无效的输入")
        let json = event.encodeToJSON()

        #expect(json.contains("\"event\":\"commandError\""))
        #expect(json.contains("错误"))
    }

    // MARK: - MemoryEvent.matches

    @Test("matches returns true when event ID is in subscription target")
    func matchesReturnsTrueWhenIDMatches() {
        let targetID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let event = MemoryEvent.memorized(ids: [targetID, UUID()])
        let sub = Subscription.memory(targetID)
        #expect(event.matches(subscription: sub))
    }

    @Test("matches returns false when event ID is unrelated to subscription")
    func matchesReturnsFalseWhenIDIsUnrelated() {
        let targetID = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        let otherID = UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!
        let event = MemoryEvent.memorized(ids: [otherID])
        let sub = Subscription.memory(targetID)
        #expect(!event.matches(subscription: sub))
    }

    @Test("imported event does not match memory subscription")
    func importedDoesNotMatchMemorySub() {
        let event = MemoryEvent.imported
        let sub = Subscription.memory(UUID())
        #expect(!event.matches(subscription: sub))
    }

    @Test("forgotten event does not match memory subscription")
    func forgottenDoesNotMatchMemorySub() {
        let targetID = UUID()
        let event = MemoryEvent.forgotten(ids: [targetID])
        let sub = Subscription.memory(UUID())
        #expect(!event.matches(subscription: sub))
    }
}
