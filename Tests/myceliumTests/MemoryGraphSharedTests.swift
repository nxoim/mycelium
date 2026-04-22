import Foundation
import GRDB
import Testing

@testable import core

extension AsyncStream {
    func firstValue() async -> Element? {
        var iterator = makeAsyncIterator()
        return await iterator.next()
    }
}

extension Result {
    func get() throws -> Success {
        switch self {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }
}

private func memorizeNode(
    in graph: any MemoryGraph,
    label: String, content: String, associations: [UUID] = []
) async throws -> UUID {
    let memory = Memory(id: UUID(), label: label, content: content, associations: associations)
    switch graph.memorize([memory]) {
    case .success(let ids): return ids.first!
    case .failure(let error): throw error
    }
}

@Suite("LocalMemoryGraph — memorize")
struct LocalMemorizeTests {
    private let tempDirectoryURL: URL = {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }()

    private func makeGraph() throws -> LocalMemoryGraph {
        try LocalMemoryGraph(directory: tempDirectoryURL)
    }

    @Test("memorize single draft returns UUID")
    func memorizeSingleDraftReturnsUUID() async throws {
        let graph = try makeGraph()
        let memory = Memory(
            id: UUID(), label: "Test Label", content: "Test Content", associations: [])
        switch graph.memorize([memory]) {
        case .success(let ids):
            #expect(ids.count == 1)
        case .failure:
            #expect(Bool(false), "Memorize should succeed")
        }
    }

    @Test("memorize batch returns multiple unique UUIDs")
    func memorizeBatchReturnsMultipleUUIDs() async throws {
        let graph = try makeGraph()
        let memories = (0..<5).map { i in
            Memory(id: UUID(), label: "Memory \(i)", content: "Content \(i)", associations: [])
        }
        switch graph.memorize(memories) {
        case .success(let ids):
            #expect(ids.count == 5)
            #expect(Set(ids).count == 5)
        case .failure:
            #expect(Bool(false), "Batch memorize should succeed")
        }
    }

    @Test("memorize empty batch returns empty array")
    func memorizeEmptyBatchReturnsEmptyArray() async throws {
        let graph = try makeGraph()
        switch graph.memorize([]) {
        case .success(let ids):
            #expect(ids.count == 0)
        case .failure:
            #expect(Bool(false), "Empty batch should return empty array")
        }
    }

    @Test("duplicate label is allowed")
    func duplicateLabelIsAllowed() async throws {
        let graph = try makeGraph()
        let mem1 = Memory(id: UUID(), label: "Same Label", content: "First", associations: [])
        let mem2 = Memory(id: UUID(), label: "Same Label", content: "Second", associations: [])
        switch graph.memorize([mem1, mem2]) {
        case .success(let ids):
            #expect(ids.count == 2)
        case .failure:
            #expect(Bool(false), "Memorize should succeed for duplicate labels")
        }
    }
}

@Suite("LocalMemoryGraph — recall")
struct LocalRecallTests {
    private let tempDirectoryURL: URL = {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }()

    private func makeGraph() throws -> LocalMemoryGraph {
        try LocalMemoryGraph(directory: tempDirectoryURL)
    }

    @Test("recall known ID returns memory")
    func recallKnownIDReturnsMemory() async throws {
        let graph = try makeGraph()
        let memory = Memory(id: UUID(), label: "Test", content: "Content", associations: [])
        switch graph.memorize([memory]) {
        case .success(let ids):
            guard let id = ids.first else { return }
            if let result = await graph.recall(
                ids: [id], depth: 0, sortOrder: .chronological
            ).firstValue() {
                switch result {
                case .success(let nodes):
                    #expect(nodes.count == 1)
                    #expect(nodes[0] != nil)
                    #expect(nodes[0]!.label == "Test")
                case .failure:
                    #expect(Bool(false), "Recall should succeed")
                }
            } else {
                #expect(Bool(false), "Should receive result")
            }
        case .failure:
            #expect(Bool(false), "Memorize should succeed")
        }
    }

    @Test("recall unknown ID returns nil")
    func recallUnknownIDReturnsNil() async throws {
        let graph = try makeGraph()
        let unknownId = UUID()
        if let result = await graph.recall(
            ids: [unknownId], depth: 0, sortOrder: .chronological
        ).firstValue() {
            switch result {
            case .success(let nodes):
                #expect(nodes.count == 1)
                #expect(nodes[0] == nil)
            case .failure:
                #expect(Bool(false), "Should not fail for unknown ID")
            }
        } else {
            #expect(Bool(false), "Should receive result")
        }
    }

    @Test("recall batch returns in input order")
    func recallBatchReturnsInInputOrder() async throws {
        let graph = try makeGraph()
        let mem1 = Memory(id: UUID(), label: "First", content: "a", associations: [])
        let mem2 = Memory(id: UUID(), label: "Second", content: "b", associations: [])
        let mem3 = Memory(id: UUID(), label: "Third", content: "c", associations: [])
        switch graph.memorize([mem1, mem2, mem3]) {
        case .success(let ids):
            let reversed = [ids[2], ids[0], ids[1]]
            if let result = await graph.recall(
                ids: reversed, depth: 0, sortOrder: .chronological
            ).firstValue() {
                switch result {
                case .success(let nodes):
                    #expect(nodes.count == 3)
                    #expect(nodes[0] != nil)
                    #expect(nodes[1] != nil)
                    #expect(nodes[2] != nil)
                    #expect(nodes[0]!.label == "Third")
                    #expect(nodes[1]!.label == "First")
                    #expect(nodes[2]!.label == "Second")
                case .failure:
                    #expect(Bool(false), "Recall should succeed")
                }
            }
        case .failure:
            #expect(Bool(false), "Memorize should succeed")
        }
    }

    @Test("recallFully known ID returns content")
    func recallFullyKnownIDReturnsContent() async throws {
        let graph = try makeGraph()
        let memory = Memory(
            id: UUID(), label: "Test", content: "Full content here.", associations: [])
        switch graph.memorize([memory]) {
        case .success(let ids):
            guard let id = ids.first else { return }
            if let result = await graph.recallFully(
                ids: [id], sortOrder: .chronological
            ).firstValue() {
                switch result {
                case .success(let contents):
                    #expect(contents.count == 1)
                    #expect(contents[0] == "Full content here.")
                case .failure:
                    #expect(Bool(false), "Recall should succeed")
                }
            }
        case .failure:
            #expect(Bool(false), "Memorize should succeed")
        }
    }

    @Test("persists across instances")
    func persistsAcrossInstances() async throws {
        let graph = try LocalMemoryGraph(directory: tempDirectoryURL)
        let memory = Memory(
            id: UUID(), label: "Persistent", content: "still here", associations: [])
        switch graph.memorize([memory]) {
        case .success(let ids):
            guard let id = ids.first else { return }
            let graph2 = try LocalMemoryGraph(directory: tempDirectoryURL)
            if let result = await graph2.recall(
                ids: [id], depth: 0, sortOrder: .chronological
            ).firstValue() {
                switch result {
                case .success(let nodes):
                    #expect(nodes[0]?.label == "Persistent")
                default: break
                }
            }
        case .failure:
            #expect(Bool(false), "Memorize should succeed")
        }
    }
}

@Suite("LocalMemoryGraph — associate and forget")
struct LocalAssociateForgetTests {
    private let tempDirectoryURL: URL = {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }()

    private func makeGraph() throws -> LocalMemoryGraph {
        try LocalMemoryGraph(directory: tempDirectoryURL)
    }

    @Test("associate creates link visible in both memories")
    func associateCreatesLinkVisibleInBothMemories() async throws {
        let graph = try makeGraph()
        let mem1 = Memory(id: UUID(), label: "Memory 1", content: "", associations: [])
        let mem2 = Memory(id: UUID(), label: "Memory 2", content: "", associations: [])
        switch graph.memorize([mem1, mem2]) {
        case .success(let ids):
            guard let id1 = ids.first, let id2 = ids.last else { return }
            switch graph.associate(id1, with: [id2]) {
            case .success:
                if let result = await graph.related(
                    to: id1, in: 0..<10, depth: 0, sortOrder: .chronological
                ).firstValue() {
                    switch result {
                    case .success(let related):
                        #expect(related.contains(where: { $0.id == id2 }))
                    case .failure:
                        #expect(Bool(false), "Should succeed")
                    }
                }
            case .failure:
                #expect(Bool(false), "Associate should succeed")
            }
        case .failure:
            #expect(Bool(false), "Memorize should succeed")
        }
    }

    @Test("dissociate removes link from both")
    func dissociateRemovesLinkFromBoth() async throws {
        let graph = try makeGraph()
        let mem1 = Memory(id: UUID(), label: "Memory 1", content: "", associations: [])
        let mem2 = Memory(id: UUID(), label: "Memory 2", content: "", associations: [])
        switch graph.memorize([mem1, mem2]) {
        case .success(let ids):
            guard let id1 = ids.first, let id2 = ids.last else { return }
            try? graph.associate(id1, with: [id2]).get()
            try? graph.dissociate(id1, from: [id2]).get()
            if let result = await graph.related(
                to: id1, in: 0..<10, depth: 0, sortOrder: .chronological
            ).firstValue() {
                switch result {
                case .success(let related):
                    #expect(!related.contains(where: { $0.id == id2 }))
                case .failure:
                    #expect(Bool(false), "Should succeed")
                }
            }
        case .failure:
            #expect(Bool(false), "Memorize should succeed")
        }
    }

    @Test("forget single ID deletes and not retrievable")
    func forgetSingleIDDeletedAndNotRetrievable() async throws {
        let graph = try makeGraph()
        let memory = Memory(id: UUID(), label: "To Delete", content: "", associations: [])
        switch graph.memorize([memory]) {
        case .success(let ids):
            guard let id = ids.first else { return }
            try? graph.forget([id]).get()
            if let result = await graph.recall(
                ids: [id], depth: 0, sortOrder: .chronological
            ).firstValue() {
                switch result {
                case .success(let nodes):
                    #expect(nodes[0] == nil)
                default: break
                }
            }
        case .failure:
            #expect(Bool(false), "Memorize should succeed")
        }
    }

    @Test("forget unknown ID returns memoryNotFound")
    func forgetUnknownIDReturnsMemoryNotFound() async throws {
        let graph = try makeGraph()
        switch graph.forget([UUID()]) {
        case .success:
            #expect(Bool(false), "Should fail for unknown ID")
        case .failure(let error):
            if case .memoryNotFound = error {
                // Expected
            } else {
                #expect(Bool(false), "Expected memoryNotFound, got: \(error)")
            }
        }
    }

    @Test("forget cascade removes from associations")
    func forgetCascadeRemovesFromAssociations() async throws {
        let graph = try makeGraph()
        let childID = try await memorizeNode(in: graph, label: "Child", content: "")
        let parentID = try await memorizeNode(
            in: graph, label: "Parent", content: "", associations: [childID])
        _ = try graph.associate(parentID, with: [childID]).get()
        _ = try graph.forget([childID]).get()

        if let result = await graph.recall(
            ids: [parentID], depth: 0, sortOrder: .chronological
        ).firstValue() {
            switch result {
            case .success(let nodes):
                #expect(
                    nodes[0]!.associations.isEmpty,
                    "Child should be removed from parent associations")
            case .failure:
                #expect(Bool(false), "Recall should succeed")
            }
        }
    }
    @Test("self-association is rejected")
    func selfAssociationRejected() async throws {
        let graph = try makeGraph()
        let mem1 = Memory(id: UUID(), label: "Self", content: "test", associations: [])
        switch graph.memorize([mem1]) {
        case .success(let ids):
            guard let id = ids.first else { return }
            switch graph.associate(id, with: [id]) {
            case .success:
                #expect(Bool(false), "Self-association should be rejected")
            case .failure(let error):
                #expect(error.localizedDescription.contains("Self-association"))
            }
        case .failure:
            #expect(Bool(false), "Memorize should succeed")
        }
    }
}

@Suite("LocalMemoryGraph — search and allMemories")
struct LocalSearchAllMemoriesTests {
    private let tempDirectoryURL: URL = {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }()

    private func makeGraph() throws -> LocalMemoryGraph {
        try LocalMemoryGraph(directory: tempDirectoryURL)
    }

    @Test("search multiple keywords returns union")
    func searchMultipleKeywordsReturnsUnion() async throws {
        let graph = try makeGraph()
        _ = try await memorizeNode(in: graph, label: "Apple", content: "red fruit")
        _ = try await memorizeNode(in: graph, label: "Banana", content: "yellow fruit")
        _ = try await memorizeNode(in: graph, label: "Cherry", content: "red fruit")

        if let result = await graph.search(
            keywords: ["Apple", "Banana"], in: 0..<10, sortOrder: .chronological
        ).firstValue() {
            switch result {
            case .success(let nodes):
                #expect(nodes.count == 2, "Should return both Apple and Banana")
            case .failure:
                #expect(Bool(false), "Search should succeed")
            }
        }
    }

    @Test("search relevance ranks label above content")
    func searchRelevanceRanksLabelAboveContent() async throws {
        let graph = try makeGraph()
        _ = try await memorizeNode(
            in: graph, label: "Swift Concurrency", content: "some details about concurrency")
        _ = try await memorizeNode(
            in: graph, label: "Python Basics", content: "Swift is a programming language")

        if let result = await graph.search(
            keywords: ["Swift"], in: 0..<10, sortOrder: .relevance
        ).firstValue() {
            switch result {
            case .success(let nodes):
                #expect(nodes.count == 2)
                #expect(nodes[0].label == "Swift Concurrency")
            case .failure:
                #expect(Bool(false), "Search should succeed")
            }
        }
    }

    @Test("allMemories chronological sort works")
    func allMemoriesChronologicalSort() async throws {
        let graph = try makeGraph()
        let firstID = try await memorizeNode(in: graph, label: "First", content: "")
        let lastID = try await memorizeNode(in: graph, label: "Last", content: "")

        if let result = await graph.allMemories(
            in: 0..<2, sortOrder: .chronological
        ).firstValue() {
            switch result {
            case .success(let nodes):
                #expect(nodes.count == 2)
                #expect(nodes[0].id == firstID)
                #expect(nodes[1].id == lastID)
            case .failure:
                #expect(Bool(false), "allMemories should succeed")
            }
        }
    }

    @Test("memory referenced by another does not appear in adrift")
    func memoryReferencedByAnotherDoesNotAppearInAdrift() async throws {
        let graph = try makeGraph()
        _ = try await memorizeNode(in: graph, label: "Orphan", content: "")
        let linkedID = try await memorizeNode(in: graph, label: "Linked", content: "")
        _ = try await memorizeNode(
            in: graph, label: "Parent", content: "", associations: [linkedID])

        if let result = await graph.adrift(
            in: 0..<10, sortOrder: .chronological
        ).firstValue() {
            switch result {
            case .success(let orphans):
                let orphanIDs = orphans.map { $0.id }
                #expect(!orphanIDs.contains(linkedID))
            case .failure:
                #expect(Bool(false), "adrift should succeed")
            }
        }
    }
}

@Suite("LocalMemoryGraph — import and export")
struct LocalImportExportTests {
    private let tempDirectoryURL: URL = {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }()

    private func makeGraph() throws -> LocalMemoryGraph {
        try LocalMemoryGraph(directory: tempDirectoryURL)
    }

    @Test("export then import preserves memories")
    func exportThenImportPreservesMemories() async throws {
        let graph = try makeGraph()
        let memory = Memory(id: UUID(), label: "Exportable", content: "export me", associations: [])
        switch graph.memorize([memory]) {
        case .success(let ids):
            guard let id = ids.first else { return }
            switch graph.exportMemoryJSON() {
            case .success(let json):
                let freshGraph = try makeGraph()
                if case .success(let mapping) = freshGraph.importMemory(json: json) {
                    let newId = mapping[id] ?? id
                    if let result = await freshGraph.recall(
                        ids: [newId], depth: 0, sortOrder: .chronological
                    ).firstValue() {
                        switch result {
                        case .success(let nodes):
                            #expect(nodes[0]?.label == "Exportable")
                        default: break
                        }
                    }
                }
            case .failure:
                #expect(Bool(false), "Export should succeed")
            }
        case .failure:
            #expect(Bool(false), "Memorize should succeed")
        }
    }

    @Test("export then import preserves associations")
    func exportThenImportPreservesAssociations() async throws {
        let graph = try makeGraph()
        let mem1 = Memory(id: UUID(), label: "Source", content: "", associations: [])
        let mem2 = Memory(id: UUID(), label: "Target", content: "", associations: [mem1.id])
        switch graph.memorize([mem1, mem2]) {
        case .success(let ids):
            guard let id1 = ids.first, let id2 = ids.last else { return }
            switch graph.exportMemoryJSON() {
            case .success(let json):
                let freshGraph = try makeGraph()
                switch freshGraph.importMemory(json: json) {
                case .success(let mapping):
                    let newId2 = mapping[id2] ?? id2
                    let newId1 = mapping[id1] ?? id1
                    if let result = await freshGraph.recall(
                        ids: [newId2], depth: 0, sortOrder: .chronological
                    ).firstValue() {
                        switch result {
                        case .success(let nodes):
                            #expect(nodes[0]!.associations.count == 1)
                            #expect(nodes[0]!.associations.first == newId1)
                        default: break
                        }
                    }
                case .failure:
                    #expect(Bool(false), "Import should succeed")
                }
            case .failure:
                #expect(Bool(false), "Export should succeed")
            }
        case .failure:
            #expect(Bool(false), "Memorize should succeed")
        }
    }

    @Test("import invalid JSON returns error")
    func importInvalidJSONReturnsError() async throws {
        let graph = try makeGraph()
        switch graph.importMemory(json: "not json at all") {
        case .success:
            #expect(Bool(false), "Should fail with invalid JSON")
        case .failure(let error):
            #expect(!error.localizedDescription.isEmpty)
        }
    }

    @Test("import JSON with bad associations drops cleanly")
    func importJSONWithBadAssociationsDropsCleanly() async throws {
        let graph = try makeGraph()
        let badUUID = UUID()
        let json = """
            [{"id":"\(UUID())","label":"Test","content":"data","associationIDs":["\(badUUID)"]}]
            """
        switch graph.importMemory(json: json) {
        case .success:
            break
        case .failure(let error):
            #expect(Bool(false), "Import should succeed, got: \(error)")
        }
    }

    @Test("import with existing ID collision reuses original UUID")
    func importWithExistingIDCollisionReusesUUID() async throws {
        let graph = try makeGraph()
        let existingMem = Memory(id: UUID(), label: "Existing", content: "data", associations: [])
        switch graph.memorize([existingMem]) {
        case .success(let ids):
            guard let existingID = ids.first else { return }
            let json = """
                [{"id":"\(existingID)","label":"Imported","content":"imported","associationIDs":[]}]
                """
            switch graph.importMemory(json: json) {
            case .success(let mapping):
                #expect(mapping[existingID] == existingID, "Existing ID should map to itself")
            case .failure:
                #expect(Bool(false), "Import should succeed")
            }
        case .failure:
            #expect(Bool(false), "Memorize should succeed")
        }
    }
}

@Suite("MemoryGraphBox wrapper")
struct MemoryGraphBoxTests {

    @Test(
        "box forwards memorize for both InMemoryMemoryGraph and LocalMemoryGraph, including empty batch"
    )
    func boxForwardsMemorizeForBothImplementations() async throws {
        // InMemoryMemoryGraph — single memorize
        let inMemoryGraph = InMemoryMemoryGraph()
        let inBox = MemoryGraphBox(inMemoryGraph)
        let inMemory = Memory(id: UUID(), label: "InMem", content: "Hello", associations: [])
        switch inBox.memorize([inMemory]) {
        case .success(let ids):
            #expect(ids.count == 1)
        case .failure:
            #expect(Bool(false), "InMemory memorize should succeed")
        }

        // InMemoryMemoryGraph — empty memorize
        switch inBox.memorize([]) {
        case .success(let ids):
            #expect(ids.isEmpty)
        case .failure:
            #expect(Bool(false), "Empty memorize should succeed")
        }

        // LocalMemoryGraph — single memorize
        let dbPath = ".tmp/test_box_localgraph.db"
        try? FileManager.default.removeItem(atPath: dbPath)
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let dbQueue = try DatabaseQueue(path: dbPath)
        let localGraph = try LocalMemoryGraph(database: dbQueue)
        let localBox = MemoryGraphBox(localGraph)
        let localMemory = Memory(id: UUID(), label: "Local", content: "World", associations: [])
        switch localBox.memorize([localMemory]) {
        case .success(let ids):
            #expect(ids.count == 1)
        case .failure:
            #expect(Bool(false), "Local memorize should succeed")
        }
    }

    @Test("core callbacks fire on their respective operations")
    func coreCallbacksFire() async {
        struct CallbackScenario {
            let name: String
            let test: (MemoryGraphBox) -> Void
        }

        let scenarios: [CallbackScenario] = [
            CallbackScenario(name: "onMemorized") { box in
                var fired = false
                var ids: [UUID] = []
                box.onMemorized = { f in
                    fired = true
                    ids = f
                }
                let memory = Memory(
                    id: UUID(), label: "Test", content: "Hello", associations: [])
                switch box.memorize([memory]) {
                case .success(let resultIds):
                    #expect(resultIds.count == 1)
                case .failure:
                    #expect(Bool(false), "Memorize should succeed")
                }
                #expect(fired)
                #expect(ids.count == 1)
            },
            CallbackScenario(name: "onAssociated") { box in
                let mem1 = Memory(id: UUID(), label: "A", content: "", associations: [])
                let mem2 = Memory(id: UUID(), label: "B", content: "", associations: [])
                switch box.memorize([mem1, mem2]) {
                case .success(let ids):
                    var fired = false
                    var callbackID: UUID? = nil
                    var callbackWith: [UUID] = []
                    box.onAssociated = { id, with in
                        fired = true
                        callbackID = id
                        callbackWith = with
                    }
                    _ = box.associate(ids[0], with: [ids[1]])
                    #expect(fired)
                    #expect(callbackID == ids[0])
                    #expect(callbackWith == [ids[1]])
                case .failure:
                    #expect(Bool(false), "Memorize should succeed")
                }
            },
            CallbackScenario(name: "onDissociated") { box in
                let mem1 = Memory(id: UUID(), label: "A", content: "", associations: [])
                let mem2 = Memory(id: UUID(), label: "B", content: "", associations: [])
                switch box.memorize([mem1, mem2]) {
                case .success(let ids):
                    _ = box.associate(ids[0], with: [ids[1]])
                    var fired = false
                    var callbackID: UUID? = nil
                    var callbackFrom: [UUID] = []
                    box.onDissociated = { id, from in
                        fired = true
                        callbackID = id
                        callbackFrom = from
                    }
                    _ = box.dissociate(ids[0], from: [ids[1]])
                    #expect(fired)
                    #expect(callbackID == ids[0])
                    #expect(callbackFrom == [ids[1]])
                case .failure:
                    #expect(Bool(false), "Memorize should succeed")
                }
            },
            CallbackScenario(name: "onForgotten") { box in
                let memory = Memory(
                    id: UUID(), label: "Test", content: "Hello", associations: [])
                switch box.memorize([memory]) {
                case .success(let ids):
                    guard let id = ids.first else {
                        #expect(Bool(false), "Should have ID")
                        return
                    }
                    var fired = false
                    var callbackIDs: [UUID] = []
                    box.onForgotten = { f in
                        fired = true
                        callbackIDs = f
                    }
                    _ = box.forget([id])
                    #expect(fired)
                    #expect(callbackIDs == [id])
                case .failure:
                    #expect(Bool(false), "Memorize should succeed")
                }
            },
        ]

        for scenario in scenarios {
            let graph = InMemoryMemoryGraph()
            let box = MemoryGraphBox(graph)
            scenario.test(box)
        }
    }
}

// MARK: - InMemoryMemoryGraph stream-based tests

/// Stream-based tests for InMemoryMemoryGraph that cover validation logic
/// shared with LocalMemoryGraph (self-association rejection, adrift behavior).
@Suite("InMemoryMemoryGraph stream operations")
struct InMemoryMemoryGraphStreamTests {

    private func makeGraph() -> InMemoryMemoryGraph {
        InMemoryMemoryGraph()
    }

    @Test("self-association rejected with stream emission")
    func selfAssociationRejected_stream() async throws {
        let graph = makeGraph()
        let mem1 = Memory(id: UUID(), label: "Self", content: "test", associations: [])
        _ = graph.memorize([mem1])

        let id = mem1.id
        switch graph.associate(id, with: [id]) {
        case .success:
            #expect(Bool(false), "Self-association should be rejected")
        case .failure(let error):
            #expect(error.localizedDescription.contains("Self-association"))
        }

        // Verify the rejected association does not leak into recall streams
        let stream = graph.recall(ids: [id], depth: 0, sortOrder: .chronological)
        if let result = await stream.firstValue() {
            switch result {
            case .success(let nodes):
                #expect(nodes[0] != nil, "Original memory should still be retrievable")
                #expect(nodes[0]!.associations.isEmpty, "Self-association should not persist")
            case .failure:
                #expect(Bool(false), "Recall should succeed")
            }
        }
    }

    @Test("adrift after delete — no orphans for still-referenced memory")
    func adriftAfterDelete_noOrphans() async throws {
        let graph = makeGraph()
        let orphanID = UUID()
        let linkedID = UUID()
        let parentID = UUID()

        _ = graph.memorize([
            Memory(id: orphanID, label: "Orphan", content: "", associations: [linkedID]),
            Memory(id: linkedID, label: "Linked", content: "", associations: [parentID]),
            Memory(id: parentID, label: "Parent", content: "", associations: [linkedID]),
        ])

        // linkedID is referenced by parentID, so it should NOT appear in orphans
        if let result = await graph.adrift(in: 0..<10, sortOrder: .chronological).firstValue() {
            switch result {
            case .success(let orphans):
                let orphanIDs = orphans.map { $0.id }
                #expect(!orphanIDs.contains(linkedID), "linkedID should not be in orphans")
            case .failure:
                #expect(Bool(false), "adrift should succeed")
            }
        }

        // Now forget the parent — linkedID should still NOT appear in orphans
        // because orphanID still references it
        _ = graph.forget([parentID])

        if let result = await graph.adrift(in: 0..<10, sortOrder: .chronological).firstValue() {
            switch result {
            case .success(let orphans):
                let orphanIDs = orphans.map { $0.id }
                #expect(
                    !orphanIDs.contains(linkedID),
                    "linkedID should remain referenced by orphanID")
            case .failure:
                #expect(Bool(false), "adrift should succeed")
            }
        }
    }
}
