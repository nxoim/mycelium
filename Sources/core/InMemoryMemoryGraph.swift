import Foundation

private struct StoredNode {
    let id: UUID
    let label: String
    let content: String
    let createdAt: Date
}

private struct PersistedNode: Codable {
    let id: UUID
    let label: String
    let content: String
    let associationIDs: [UUID]
    let createdAt: Date?
}

/// In-memory `MemoryGraph` implementation. Uses a serial DispatchQueue for all state access,
/// allowing `@unchecked Sendable` conformance despite holding `AsyncStream.Continuation` references.
@available(macOS 12.0, *)
public final class InMemoryMemoryGraph: MemoryGraph, @unchecked Sendable {

    private var store: [UUID: StoredNode] = [:]
    private var associations: [UUID: Set<UUID>] = [:]
    private var historyLog: [HistoryEntry] = []
    private let maxHistoryEntries = 10000
    private let queue = DispatchQueue(label: "com.nxoim.mycelium.inmemory")

    private typealias NodeEntry = (
        depth: Int, continuation: AsyncStream<Result<[Memory?], MemoryError>>.Continuation
    )
    private typealias ContentEntry = AsyncStream<Result<[String?], MemoryError>>.Continuation
    private typealias ListEntry = (
        range: Range<Int>, sortOrder: SortOrder,
        continuation: AsyncStream<Result<[Memory], MemoryError>>.Continuation
    )
    private typealias AssocEntry = (
        range: Range<Int>, depth: Int,
        continuation: AsyncStream<Result<[Memory], MemoryError>>.Continuation
    )
    private typealias SearchEntry = (
        keywords: [String], range: Range<Int>, sortOrder: SortOrder,
        continuation: AsyncStream<Result<[Memory], MemoryError>>.Continuation
    )

    private var nodeStreams: [UUID: [UUID: NodeEntry]] = [:]
    private var contentStreams: [UUID: [UUID: ContentEntry]] = [:]
    private var allNodesStreams: [UUID: ListEntry] = [:]
    private var searchStreams: [UUID: SearchEntry] = [:]
    private var orphanStreams: [UUID: ListEntry] = [:]
    private var assocStreams: [UUID: [UUID: AssocEntry]] = [:]

    public init() {}

    private func buildNode(_ stored: StoredNode, depth: Int) -> Memory {
        if depth == 0 {
            return Memory(
                id: stored.id, label: stored.label, content: stored.content,
                associations: Array(associations[stored.id] ?? []))
        }
        if depth < 0 {
            return Memory(
                id: stored.id, label: stored.label, content: stored.content, associations: [])
        }
        let children =
            associations[stored.id]?.compactMap { store[$0] }.map { child in
                depth > 0
                    ? buildNode(child, depth: depth - 1)
                    : Memory(id: child.id, label: child.label, content: "", associations: [])
            } ?? []
        return Memory(
            id: stored.id, label: stored.label, content: stored.content,
            associations: children.map { $0.id })
    }

    private func sorted(_ nodes: [StoredNode], by order: SortOrder, keywords: [String] = [])
        -> [StoredNode]
    {
        switch order {
        case .chronological: return nodes.sorted { $0.createdAt < $1.createdAt }
        case .reverseChronological: return nodes.sorted { $0.createdAt > $1.createdAt }
        case .relevance: return nodes.sorted { score($0, keywords) > score($1, keywords) }
        }
    }

    private func sortedStore(by order: SortOrder, keywords: [String] = []) -> [StoredNode] {
        let values = Array(store.values)
        switch order {
        case .chronological: return values.sorted { $0.createdAt < $1.createdAt }
        case .reverseChronological: return values.sorted { $0.createdAt > $1.createdAt }
        case .relevance: return values.sorted { score($0, keywords) > score($1, keywords) }
        }
    }

    private func score(_ node: StoredNode, _ keywords: [String]) -> Int {
        var score = 0
        for keyword in keywords {
            let k = keyword.lowercased()
            if node.label.lowercased().contains(k) { score += 2 }
            if node.content.lowercased().contains(k) { score += 1 }
        }
        return score
    }

    private func paginate<T>(_ array: [T], range: Range<Int>) -> [T] {
        // If specified range exceeds total amount of items to paginate, load all items
        if range.lowerBound >= array.count {
            return array
        }
        let upper = min(range.upperBound, array.count)
        if range.lowerBound == 0 && upper == array.count {
            return array
        }
        return Array(array[range.lowerBound..<upper])
    }

    private func currentOrphans() -> [StoredNode] {
        let referenced = referencedCache
        return store.values.filter { !referenced.contains($0.id) }
    }

    private var _referencedCache: Set<UUID> = []
    private var _referencedCacheValid = false

    private func invalidateReferencedCache() {
        _referencedCacheValid = false
    }

    private var referencedCache: Set<UUID> {
        if _referencedCacheValid { return _referencedCache }
        _referencedCache = Set(associations.values.flatMap { $0 })
        _referencedCacheValid = true
        return _referencedCache
    }

    private func invalidateAllCaches() {
        invalidateReferencedCache()
    }

    // Called from within queue — notifies all active streams of current state
    private func notifyAll(affectedIDs: Set<UUID>) {
        let hasAllSubscribers = !allNodesStreams.isEmpty
        let hasSearchSubscribers = !searchStreams.isEmpty
        let hasOrphanSubscribers = !orphanStreams.isEmpty

        // Node-specific streams
        for id in affectedIDs {
            nodeStreams[id]?.values.forEach { entry in
                let value = store[id].map { buildNode($0, depth: entry.depth) }
                entry.continuation.yield(.success([value]))
            }
            contentStreams[id]?.values.forEach { continuation in
                continuation.yield(.success([store[id]?.content]))
            }
            assocStreams[id]?.values.forEach { entry in
                guard let stored = store[id] else { return }
                let nodes = associations[stored.id]?.compactMap { store[$0] } ?? []
                let paged = paginate(nodes, range: entry.range).map {
                    buildNode($0, depth: entry.depth)
                }
                entry.continuation.yield(.success(paged))
            }
        }

        // Global streams — only rebuild if there are subscribers
        if hasAllSubscribers {
            let all = Array(store.values)
            allNodesStreams.values.forEach { entry in
                let paged = paginate(sorted(all, by: entry.sortOrder), range: entry.range)
                entry.continuation.yield(.success(paged.map { buildNode($0, depth: 0) }))
            }
        }

        if hasSearchSubscribers {
            let all = Array(store.values)
            searchStreams.values.forEach { entry in
                let matched = all.filter { storedNode in
                    entry.keywords.contains { keyword in
                        storedNode.label.lowercased().contains(keyword.lowercased())
                            || storedNode.content.lowercased().contains(keyword.lowercased())
                    }
                }
                let paged = paginate(
                    sorted(matched, by: entry.sortOrder, keywords: entry.keywords),
                    range: entry.range)
                entry.continuation.yield(.success(paged.map { buildNode($0, depth: 0) }))
            }
        }

        if hasOrphanSubscribers {
            let orphans = currentOrphans()
            orphanStreams.values.forEach { entry in
                let paged = paginate(sorted(orphans, by: entry.sortOrder), range: entry.range)
                entry.continuation.yield(.success(paged.map { buildNode($0, depth: 0) }))
            }
        }
    }

    public func memorize(_ memories: [Memory]) -> Result<[UUID], MemoryError> {
        // Use provided IDs (not generate new ones) and create bidirectional associations
        var affectedIDs: Set<UUID> = []
        queue.sync {
            // Pass 1: Store all nodes first
            for memory in memories {
                store[memory.id] = StoredNode(
                    id: memory.id, label: memory.label, content: memory.content, createdAt: Date.now
                )
            }

            // Pass 2: Create bidirectional associations (all nodes now exist)
            // Link new memory to each declared target (bidirectional)
            // Then link all targets to each other (omni-directional)
            for memory in memories {
                for relatedId in memory.associations {
                    if store[relatedId] != nil {
                        associations[memory.id, default: []].insert(relatedId)
                        associations[relatedId, default: []].insert(memory.id)
                        affectedIDs.insert(memory.id)
                        affectedIDs.insert(relatedId)
                    }
                }
            }
            // Pass 3: Create omni-directional links among declared targets
            for memory in memories {
                let validTargets = memory.associations.filter { store[$0] != nil }
                for i in validTargets.indices {
                    for j in validTargets.indices {
                        if i != j {
                            let from = validTargets[i]
                            let to = validTargets[j]
                            associations[from, default: []].insert(to)
                            associations[to, default: []].insert(from)
                            affectedIDs.insert(from)
                            affectedIDs.insert(to)
                        }
                    }
                }
            }

            // Always notify global streams about new nodes, and node-specific streams about new associations
            if !affectedIDs.isEmpty {
                invalidateReferencedCache()
                notifyAll(affectedIDs: affectedIDs)
            } else {
                allNodesStreams.values.forEach { entry in
                    let paged = paginate(sortedStore(by: entry.sortOrder), range: entry.range)
                    entry.continuation.yield(.success(paged.map { buildNode($0, depth: 0) }))
                }
                searchStreams.values.forEach { entry in
                    let matched = store.values.filter { storedNode in
                        entry.keywords.contains { keyword in
                            storedNode.label.lowercased().contains(keyword.lowercased())
                                || storedNode.content.lowercased().contains(keyword.lowercased())
                        }
                    }
                    let paged = paginate(
                        sorted(matched, by: entry.sortOrder, keywords: entry.keywords),
                        range: entry.range)
                    entry.continuation.yield(.success(paged.map { buildNode($0, depth: 0) }))
                }
                orphanStreams.values.forEach { entry in
                    let paged = paginate(
                        sorted(currentOrphans(), by: entry.sortOrder), range: entry.range)
                    entry.continuation.yield(.success(paged.map { buildNode($0, depth: 0) }))
                }
            }
        }
        recordHistory(type: .memorize, affectedIds: memories.map { $0.id })
        return .success(memories.map { $0.id })
    }

    public func recall(ids: [UUID], depth: Int, sortOrder: SortOrder) -> AsyncStream<
        Result<[Memory?], MemoryError>
    > {
        let streamID = UUID()
        return AsyncStream { continuation in
            queue.sync {
                let results = ids.map { id in store[id].map { buildNode($0, depth: depth) } }
                continuation.yield(.success(results))
                for id in ids where store[id] != nil {
                    nodeStreams[id, default: [:]][streamID] = (
                        depth: depth, continuation: continuation
                    )
                }
            }
            continuation.onTermination = { [queue] _ in
                queue.async { [weak self] in
                    for id in ids {
                        self?.nodeStreams[id]?.removeValue(forKey: streamID)
                    }
                }
            }
        }
    }

    public func buildSummaryNode(ids: [UUID], depth: Int, sortOrder: SortOrder) -> AsyncStream<
        Result<[MemorySummaryNode?], MemoryError>
    > {
        return AsyncStream { continuation in
            queue.sync {
                let results = ids.map { id in
                    store[id].map { stored in
                        MemorySummaryNode(
                            id: stored.id, label: stored.label,
                            associations: buildSummaryChildren(for: stored.id, depth: depth))
                    }
                }
                continuation.yield(.success(results))
            }
        }
    }

    private func buildSummaryChildren(for id: UUID, depth: Int) -> [MemorySummaryNode] {
        guard let childIds = associations[id], !childIds.isEmpty else { return [] }
        return childIds.compactMap { childId in
            store[childId].map { child in
                MemorySummaryNode(
                    id: child.id, label: child.label,
                    associations: depth > 0
                        ? buildSummaryChildren(for: child.id, depth: depth - 1) : [])
            }
        }
    }

    public func recallFully(ids: [UUID], sortOrder: SortOrder) -> AsyncStream<
        Result<[String?], MemoryError>
    > {
        let streamID = UUID()
        return AsyncStream { continuation in
            queue.sync {
                let results = ids.map { id in store[id]?.content }
                continuation.yield(.success(results))
                for id in ids where store[id] != nil {
                    contentStreams[id, default: [:]][streamID] = continuation
                }
            }
            continuation.onTermination = { [queue] _ in
                queue.async { [weak self] in
                    for id in ids {
                        self?.nodeStreams[id]?.removeValue(forKey: streamID)
                    }
                }
            }
        }
    }

    public func search(keywords: [String], in range: Range<Int>, sortOrder: SortOrder)
        -> AsyncStream<Result<[Memory], MemoryError>>
    {
        let streamID = UUID()
        return AsyncStream { continuation in
            queue.sync {
                let matched = store.values.filter { storedNode in
                    keywords.contains { keyword in
                        storedNode.label.lowercased().contains(keyword.lowercased())
                            || storedNode.content.lowercased().contains(keyword.lowercased())
                    }
                }
                let paged = paginate(
                    sorted(matched, by: sortOrder, keywords: keywords), range: range)
                continuation.yield(.success(paged.map { buildNode($0, depth: 0) }))
                searchStreams[streamID] = (
                    keywords: keywords, range: range, sortOrder: sortOrder,
                    continuation: continuation
                )
            }
            continuation.onTermination = { [queue] _ in
                queue.async { [weak self] in
                    self?.searchStreams.removeValue(forKey: streamID)
                }
            }
        }
    }

    public func allMemories(in range: Range<Int>, sortOrder: SortOrder) -> AsyncStream<
        Result<[Memory], MemoryError>
    > {
        let streamID = UUID()
        return AsyncStream { continuation in
            queue.sync {
                let paged = paginate(sorted(Array(store.values), by: sortOrder), range: range)
                continuation.yield(.success(paged.map { buildNode($0, depth: 0) }))
                allNodesStreams[streamID] = (
                    range: range, sortOrder: sortOrder, continuation: continuation
                )
            }
            continuation.onTermination = { [queue] _ in
                queue.async { [weak self] in
                    self?.allNodesStreams.removeValue(forKey: streamID)
                }
            }
        }
    }

    public func related(to id: UUID, in range: Range<Int>, depth: Int, sortOrder: SortOrder)
        -> AsyncStream<
            Result<[Memory], MemoryError>
        >
    {
        let streamID = UUID()
        return AsyncStream { continuation in
            queue.sync {
                guard store[id] != nil else {
                    continuation.yield(.failure(.memoryNotFound(id)))
                    return
                }
                let childIds = associations[id]?.map { $0 } ?? []
                let paged = paginate(childIds, range: range).compactMap { store[$0] }.map {
                    buildNode($0, depth: depth)
                }
                continuation.yield(.success(paged))
                assocStreams[id, default: [:]][streamID] = (
                    range: range, depth: depth, continuation: continuation
                )
            }
            continuation.onTermination = { [queue] _ in
                queue.async { [weak self] in
                    self?.assocStreams[id]?.removeValue(forKey: streamID)
                }
            }
        }
    }

    public func adrift(in range: Range<Int>, sortOrder: SortOrder) -> AsyncStream<
        Result<[Memory], MemoryError>
    > {
        let streamID = UUID()
        return AsyncStream { continuation in
            queue.sync {
                let orphans = currentOrphans()
                let paged = paginate(sorted(orphans, by: sortOrder), range: range)
                continuation.yield(.success(paged.map { buildNode($0, depth: 0) }))
                orphanStreams[streamID] = (
                    range: range, sortOrder: sortOrder, continuation: continuation
                )
            }
            continuation.onTermination = { [queue] _ in
                queue.async { [weak self] in
                    self?.orphanStreams.removeValue(forKey: streamID)
                }
            }
        }
    }

    public func associate(_ id: UUID, with relatedIds: [UUID]) -> Result<Void, MemoryError> {
        var errorID: UUID?
        var didAssociate = false
        var affectedIDs: Set<UUID> = [id]
        var missingIDs: [UUID] = []
        var selfIDs: [UUID] = []
        queue.sync {
            if store[id] != nil {
                for relatedId in relatedIds {
                    if relatedId == id {
                        selfIDs.append(relatedId)
                        continue
                    }
                    if store[relatedId] != nil {
                        let inserted1 = associations[id, default: []].insert(relatedId)
                        let inserted2 = associations[relatedId, default: []].insert(id)
                        if inserted1.inserted || inserted2.inserted {
                            affectedIDs.insert(relatedId)
                        }
                    } else {
                        missingIDs.append(relatedId)
                    }
                }
                if !missingIDs.isEmpty || !selfIDs.isEmpty {
                    // still mark as done so we return the error below
                } else {
                    invalidateReferencedCache()
                    notifyAll(affectedIDs: affectedIDs)
                    didAssociate = true
                }
            } else {
                errorID = id
            }
        }
        if !selfIDs.isEmpty {
            let idsList = selfIDs.map { $0.uuidString }.joined(separator: ", ")
            return .failure(
                .associationFailed(
                    "Association failed because memory(\(idsList)) is the same as the target. Self-association is not allowed."
                ))
        }
        if !missingIDs.isEmpty {
            let idsList = missingIDs.map { $0.uuidString }.joined(separator: ", ")
            return .failure(
                .associationFailed(
                    "Association failed because memory(\(idsList)) did not exist. Create a new memory with full contents indicating there is no knowledge about the memory."
                ))
        }
        if didAssociate {
            recordHistory(
                type: .associate, affectedIds: [id] + Array(affectedIDs).filter { $0 != id })
        }
        return didAssociate ? .success(()) : .failure(.memoryNotFound(errorID!))
    }

    public func dissociate(_ id: UUID, from relatedIds: [UUID]) -> Result<Void, MemoryError> {
        var errorID: UUID?
        var didDissociate = false
        var missingIDs: [UUID] = []
        queue.sync {
            if store[id] != nil {
                for relatedId in relatedIds {
                    if store[relatedId] != nil {
                        associations[id]?.remove(relatedId)
                        associations[relatedId]?.remove(id)
                    } else {
                        missingIDs.append(relatedId)
                    }
                }
                if missingIDs.isEmpty {
                    invalidateReferencedCache()
                    notifyAll(affectedIDs: Set([id] + relatedIds))
                    didDissociate = true
                }
            } else {
                errorID = id
            }
        }
        if !missingIDs.isEmpty {
            let idsList = missingIDs.map { $0.uuidString }.joined(separator: ", ")
            return .failure(
                .associationFailed(
                    "Dissociation failed because memory(\(idsList)) did not exist."
                ))
        }
        if didDissociate { recordHistory(type: .dissociate, affectedIds: [id] + relatedIds) }
        return didDissociate ? .success(()) : .failure(.memoryNotFound(errorID!))
    }

    public func forget(_ ids: [UUID]) -> Result<Void, MemoryError> {
        let idSet = Set(ids)
        var foundIDs: [UUID] = []
        var affectedIDs: Set<UUID> = []
        var missingIDs: [UUID] = []
        queue.sync {
            for id in ids {
                if store[id] != nil {
                    foundIDs.append(id)
                    store.removeValue(forKey: id)
                    associations.removeValue(forKey: id)
                } else {
                    missingIDs.append(id)
                }
            }
            // Remove deleted IDs from all other memories' associations
            for key in Array(associations.keys) {
                if var set = associations[key] {
                    let oldCount = set.count
                    set.subtract(idSet)
                    if set.isEmpty {
                        associations[key] = nil
                    } else if set.count != oldCount {
                        associations[key] = set
                        affectedIDs.insert(key)
                    }
                }
            }
            invalidateReferencedCache()
            if !affectedIDs.isEmpty {
                notifyAll(affectedIDs: affectedIDs)
            }
        }
        if !missingIDs.isEmpty {
            let idsList = missingIDs.map { $0.uuidString }.joined(separator: ", ")
            return .failure(
                .associationFailed(
                    "Memory did not exist when forgetting: \(idsList)"))
        }
        if !foundIDs.isEmpty { recordHistory(type: .forget, affectedIds: foundIDs) }
        return foundIDs.isEmpty ? .failure(.memoryNotFound(ids.first ?? UUID())) : .success(())
    }

    public func importMemory(from url: URL) -> Result<[UUID: UUID], MemoryError> {
        do {
            let data = try Data(contentsOf: url)
            return decode(data)
        } catch {
            return .failure(.importFailed(error.localizedDescription))
        }
    }

    public func importMemory(json: String) -> Result<[UUID: UUID], MemoryError> {
        guard let data = json.data(using: .utf8) else {
            return .failure(.importFailed("Invalid UTF-8"))
        }
        return decode(data)
    }

    private func decode(_ data: Data) -> Result<[UUID: UUID], MemoryError> {
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let records = try decoder.decode([PersistedNode].self, from: data)

            var idMapping: [UUID: UUID] = [:]
            queue.sync {
                // Map old IDs — reuse existing nodes or create new ones
                let existingIDs = Set(store.keys)
                for record in records {
                    if existingIDs.contains(record.id) {
                        idMapping[record.id] = record.id
                    } else {
                        let newID = UUID()
                        idMapping[record.id] = newID
                        store[newID] = StoredNode(
                            id: newID, label: record.label, content: record.content,
                            createdAt: record.createdAt ?? Date.now)
                    }
                }

                let importedIDs = Set(idMapping.values)

                // Restore bidirectional associations using remapped IDs
                var affectedIDs: Set<UUID> = []
                for record in records {
                    guard let newID = idMapping[record.id] else { continue }
                    for relatedId in record.associationIDs {
                        let newRelatedID = idMapping[relatedId] ?? relatedId
                        guard
                            existingIDs.contains(newRelatedID) || importedIDs.contains(newRelatedID)
                        else { continue }
                        associations[newID, default: []].insert(newRelatedID)
                        associations[newRelatedID, default: []].insert(newID)
                        affectedIDs.insert(newID)
                        affectedIDs.insert(newRelatedID)
                    }
                }

                if !affectedIDs.isEmpty {
                    invalidateReferencedCache()
                    notifyAll(affectedIDs: affectedIDs)
                }
            }
            return .success(idMapping)
        } catch {
            return .failure(.importFailed(error.localizedDescription))
        }
    }

    public func exportMemory(to url: URL) -> Result<Void, MemoryError> {
        exportMemoryJSON().flatMap { json in
            do {
                try json.write(to: url, atomically: true, encoding: .utf8)
                return .success(())
            } catch {
                return .failure(.exportFailed(error.localizedDescription))
            }
        }
    }

    public func exportMemoryJSON() -> Result<String, MemoryError> {
        var records: [PersistedNode] = []
        queue.sync {
            records = store.values.map { stored in
                PersistedNode(
                    id: stored.id, label: stored.label, content: stored.content,
                    associationIDs: Array(associations[stored.id] ?? []),
                    createdAt: stored.createdAt)
            }
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(records)
            guard let json = String(data: data, encoding: .utf8) else {
                return .failure(.exportFailed("Failed to encode JSON"))
            }
            return .success(json)
        } catch {
            return .failure(.exportFailed(error.localizedDescription))
        }
    }

    public func history(in range: Range<Int>, sortOrder: SortOrder) -> AsyncStream<
        Result<[HistoryEntry], MemoryError>
    > {
        return AsyncStream { continuation in
            queue.sync {
                let entries = sortedHistory(by: sortOrder)
                let paged = paginate(entries, range: range)
                continuation.yield(.success(paged))
            }
        }
    }

    private func sortedHistory(by order: SortOrder) -> [HistoryEntry] {
        switch order {
        case .chronological: return historyLog.sorted { $0.timestamp < $1.timestamp }
        case .reverseChronological: return historyLog.sorted { $0.timestamp > $1.timestamp }
        case .relevance: return historyLog
        }
    }

    private func recordHistory(type: MutationType, affectedIds: [UUID]) {
        let entry = HistoryEntry(timestamp: .now, type: type, affectedIds: affectedIds)
        historyLog.append(entry)
        if historyLog.count > maxHistoryEntries {
            historyLog.removeFirst(historyLog.count - maxHistoryEntries)
        }
    }
}
