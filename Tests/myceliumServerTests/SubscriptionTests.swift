import Foundation
import Testing

@testable import websocket_observer

@Suite("Subscription matching")
struct SubscriptionTests {

    @Test("all subscription equality, hashing, and set deduplication")
    func allSubscriptionEqualityAndSetBehavior() {
        let sub: Subscription = .all
        #expect(sub == .all)
        #expect(sub.hashValue == Subscription.all.hashValue)

        // Set deduplication
        var subs: Set<Subscription> = []
        subs.insert(sub)
        subs.insert(.all)
        #expect(subs.count == 1)
    }

    @Test("memory subscription matches all event types with target ID")
    func memorySubscriptionMatchesAllEventTypes() {
        let targetID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let sub = Subscription.memory(targetID)

        #expect(MemoryEvent.memorized(ids: [targetID]).matches(subscription: sub))
        #expect(MemoryEvent.memorized(ids: [targetID, UUID()]).matches(subscription: sub))
        #expect(MemoryEvent.forgotten(ids: [targetID]).matches(subscription: sub))
        #expect(MemoryEvent.forgotten(ids: [targetID, UUID()]).matches(subscription: sub))
        #expect(MemoryEvent.associated(id: targetID, with: [UUID()]).matches(subscription: sub))
        #expect(MemoryEvent.dissociated(id: targetID, from: [UUID()]).matches(subscription: sub))
        // Non-matching event types
        #expect(!MemoryEvent.imported.matches(subscription: sub))
        #expect(!MemoryEvent.graphState(nodes: [], associations: []).matches(subscription: sub))
    }

    @Test("memory subscription rejects unrelated and non-matching events")
    func memorySubscriptionRejectsUnrelatedAndNonMatchingEvents() {
        let targetID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let otherID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let sub = Subscription.memory(targetID)

        #expect(!MemoryEvent.memorized(ids: [otherID]).matches(subscription: sub))
        #expect(!MemoryEvent.forgotten(ids: [otherID]).matches(subscription: sub))
        #expect(!MemoryEvent.associated(id: otherID, with: [UUID()]).matches(subscription: sub))
        #expect(!MemoryEvent.dissociated(id: otherID, from: [UUID()]).matches(subscription: sub))
    }

    @Test("search subscription matches exact keywords in order")
    func searchSubscriptionMatchesExactKeywords() {
        let sub = Subscription.search(keywords: ["swift", "testing"])

        #expect(
            MemoryEvent.searchUpdated(keywords: ["swift", "testing"]).matches(subscription: sub))
        #expect(!MemoryEvent.searchUpdated(keywords: []).matches(subscription: sub))
        #expect(!MemoryEvent.searchUpdated(keywords: ["swift"]).matches(subscription: sub))
        #expect(
            !MemoryEvent.searchUpdated(keywords: ["swift", "testing", "extra"]).matches(
                subscription: sub))
        #expect(
            !MemoryEvent.searchUpdated(keywords: ["testing", "swift"]).matches(subscription: sub))

        // Empty keyword subscription
        let emptySub = Subscription.search(keywords: [])
        #expect(MemoryEvent.searchUpdated(keywords: []).matches(subscription: emptySub))
        #expect(!MemoryEvent.searchUpdated(keywords: ["test"]).matches(subscription: emptySub))
    }

    @Test("different subscription types are never equal")
    func differentSubTypesNeverEqual() {
        let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let allSub: Subscription = .all
        let memorySub = Subscription.memory(id)
        let searchSub = Subscription.search(keywords: ["test"])

        #expect(allSub != memorySub)
        #expect(allSub != searchSub)
        #expect(memorySub != searchSub)

        // Same types with different values are distinct in sets
        var subs: Set<Subscription> = []
        subs.insert(allSub)
        subs.insert(memorySub)
        subs.insert(searchSub)
        #expect(subs.count == 3)
    }
}
