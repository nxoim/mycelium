import Foundation

/// A Sendable box that holds any `MemoryGraph` implementation.
///
/// Concurrency Invariant:
/// `MemoryGraphBox` wraps a concrete `MemoryGraph` (either `LocalMemoryGraph` or
/// `InMemoryMemoryGraph`) by capturing its methods into `@Sendable` closures. Both
/// underlying implementations are internally thread-safe: `LocalMemoryGraph` uses GRDB's
/// checked `Sendable` `DatabaseQueue`, and `InMemoryMemoryGraph` serializes all access through
/// a `DispatchQueue`. Since the closures themselves capture no non-Sendable state and the
/// underlying graphs guarantee their own invariants, the existential wrapper is safe to share
/// across concurrency domains.
///
/// - Note: `@unchecked Sendable` is required because the closure types contain generic
///   parameters that are not Sendable-aware at the type level, even though their captured
///   state is safe. The invariant above guarantees correctness.
@available(macOS 12.0, *)
public final class MemoryGraphBox: @unchecked Sendable {
    private let _memorize: ([Memory]) -> Result<[UUID], MemoryError>
    private let _recall: ([UUID], Int, SortOrder) -> AsyncStream<Result<[Memory?], MemoryError>>
    private let _recallFully: ([UUID], SortOrder) -> AsyncStream<Result<[String?], MemoryError>>
    private let _search:
        ([String], Range<Int>, SortOrder) -> AsyncStream<Result<[Memory], MemoryError>>
    private let _allMemories: (Range<Int>, SortOrder) -> AsyncStream<Result<[Memory], MemoryError>>
    private let _adrift: (Range<Int>, SortOrder) -> AsyncStream<Result<[Memory], MemoryError>>
    private let _associate: (UUID, [UUID]) -> Result<Void, MemoryError>
    private let _dissociate: (UUID, [UUID]) -> Result<Void, MemoryError>
    private let _forget: ([UUID]) -> Result<Void, MemoryError>
    private let _importFromURL: (URL) -> Result<[UUID: UUID], MemoryError>
    private let _importJSON: (String) -> Result<[UUID: UUID], MemoryError>
    private let _exportToURL: (URL) -> Result<Void, MemoryError>
    private let _exportJSON: () -> Result<String, MemoryError>
    private let _history:
        (Range<Int>, SortOrder) -> AsyncStream<Result<[HistoryEntry], MemoryError>>
    private let _buildSummaryNode:
        ([UUID], Int, SortOrder) -> AsyncStream<Result<[MemorySummaryNode?], MemoryError>>

    public var onMemorized: ([UUID]) -> Void = { _ in }
    public var onForgotten: ([UUID]) -> Void = { _ in }
    public var onAssociated: (UUID, [UUID]) -> Void = { _, _ in }
    public var onDissociated: (UUID, [UUID]) -> Void = { _, _ in }
    public var onImported: () -> Void = {}

    public init<G: MemoryGraph>(_ graph: G) {
        _memorize = { memories in graph.memorize(memories) }
        _recall = { ids, depth, sortOrder in
            graph.recall(ids: ids, depth: depth, sortOrder: sortOrder)
        }
        _recallFully = { ids, sortOrder in graph.recallFully(ids: ids, sortOrder: sortOrder) }
        _search = { keywords, range, sortOrder in
            graph.search(keywords: keywords, in: range, sortOrder: sortOrder)
        }
        _allMemories = { range, sortOrder in graph.allMemories(in: range, sortOrder: sortOrder) }
        _adrift = { range, sortOrder in graph.adrift(in: range, sortOrder: sortOrder) }
        _associate = { id, withIds in graph.associate(id, with: withIds) }
        _dissociate = { id, fromIds in graph.dissociate(id, from: fromIds) }
        _forget = { ids in graph.forget(ids) }
        _importFromURL = { url in graph.importMemory(from: url) }
        _importJSON = { json in graph.importMemory(json: json) }
        _exportToURL = { url in graph.exportMemory(to: url) }
        _exportJSON = { graph.exportMemoryJSON() }
        _history = { range, sortOrder in graph.history(in: range, sortOrder: sortOrder) }
        _buildSummaryNode = { ids, depth, sortOrder in
            graph.buildSummaryNode(ids: ids, depth: depth, sortOrder: sortOrder)
        }
    }

    public func memorize(_ memories: [Memory]) -> Result<[UUID], MemoryError> {
        let result = _memorize(memories)
        switch result {
        case .success(let ids):
            onMemorized(ids)
        case .failure:
            break
        }
        return result
    }

    public func recall(ids: [UUID], depth: Int, sortOrder: SortOrder) -> AsyncStream<
        Result<[Memory?], MemoryError>
    > {
        _recall(ids, depth, sortOrder)
    }

    public func recallFully(ids: [UUID], sortOrder: SortOrder) -> AsyncStream<
        Result<[String?], MemoryError>
    > {
        _recallFully(ids, sortOrder)
    }

    public func search(keywords: [String], in range: Range<Int>, sortOrder: SortOrder)
        -> AsyncStream<Result<[Memory], MemoryError>>
    {
        _search(keywords, range, sortOrder)
    }

    public func allMemories(in range: Range<Int>, sortOrder: SortOrder) -> AsyncStream<
        Result<[Memory], MemoryError>
    > {
        _allMemories(range, sortOrder)
    }

    public func adrift(in range: Range<Int>, sortOrder: SortOrder) -> AsyncStream<
        Result<[Memory], MemoryError>
    > {
        _adrift(range, sortOrder)
    }

    public func associate(_ id: UUID, with relatedIds: [UUID]) -> Result<Void, MemoryError> {
        let result = _associate(id, relatedIds)
        switch result {
        case .success:
            onAssociated(id, relatedIds)
        case .failure:
            break
        }
        return result
    }

    public func dissociate(_ id: UUID, from relatedIds: [UUID]) -> Result<Void, MemoryError> {
        let result = _dissociate(id, relatedIds)
        switch result {
        case .success:
            onDissociated(id, relatedIds)
        case .failure:
            break
        }
        return result
    }

    public func forget(_ ids: [UUID]) -> Result<Void, MemoryError> {
        let result = _forget(ids)
        switch result {
        case .success:
            onForgotten(ids)
        case .failure:
            break
        }
        return result
    }

    public func importMemory(from url: URL) -> Result<[UUID: UUID], MemoryError> {
        let result = _importFromURL(url)
        if case .success = result {
            onImported()
        }
        return result
    }

    public func importMemory(json: String) -> Result<[UUID: UUID], MemoryError> {
        let result = _importJSON(json)
        if case .success = result {
            onImported()
        }
        return result
    }

    public func buildSummaryNode(ids: [UUID], depth: Int, sortOrder: SortOrder) -> AsyncStream<
        Result<[MemorySummaryNode?], MemoryError>
    > {
        _buildSummaryNode(ids, depth, sortOrder)
    }

    public func exportMemory(to url: URL) -> Result<Void, MemoryError> {
        _exportToURL(url)
    }

    public func exportMemoryJSON() -> Result<String, MemoryError> {
        _exportJSON()
    }

    public func history(in range: Range<Int>, sortOrder: SortOrder) -> AsyncStream<
        Result<[HistoryEntry], MemoryError>
    > {
        _history(range, sortOrder)
    }
}
