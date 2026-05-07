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

    enum CodingKeys: String, CodingKey {
        case id
        case label
        case content
        case associationIDs
        case createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        content = try container.decode(String.self, forKey: .content)
        associationIDs = try container.decodeIfPresent([UUID].self, forKey: .associationIDs) ?? []
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(label, forKey: .label)
        try container.encode(content, forKey: .content)
        try container.encode(associationIDs, forKey: .associationIDs)
        try container.encodeIfPresent(createdAt, forKey: .createdAt)
    }

    init(id: UUID, label: String, content: String, associationIDs: [UUID], createdAt: Date?) {
        self.id = id
        self.label = label
        self.content = content
        self.associationIDs = associationIDs
        self.createdAt = createdAt
    }
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
        range: Range<Int>, depth: Int, sortOrder: SortOrder,
        continuation: AsyncStream<Result<SearchResult<Memory>, MemoryError>>.Continuation
    )
    private typealias AssocEntry = (
        range: Range<Int>, depth: Int,
        continuation: AsyncStream<Result<[Memory], MemoryError>>.Continuation
    )
    private typealias SearchEntry = (
        keywords: [String], range: Range<Int>, depth: Int, sortOrder: SortOrder,
        continuation: AsyncStream<Result<SearchResult<Memory>, MemoryError>>.Continuation
    )

    private var nodeStreams: [UUID: [UUID: NodeEntry]] = [:]
    private var contentStreams: [UUID: [UUID: ContentEntry]] = [:]
    private var allNodesStreams: [UUID: ListEntry] = [:]
    private var searchStreams: [UUID: SearchEntry] = [:]
    private var orphanStreams: [UUID: ListEntry] = [:]
    private var assocStreams: [UUID: [UUID: AssocEntry]] = [:]

    public init() {}

    private func buildNode(
        _ stored: StoredNode, depth: Int, path: Set<UUID>
    ) -> Memory {
        let nodePath = path.union([stored.id])

        if depth < 0 {
            return Memory(
                id: stored.id, label: stored.label, content: stored.content,
                associations: [])
        }

        let childIds = associations[stored.id] ?? []
        let children = childIds.compactMap { childId -> Memory? in
            guard let child = store[childId] else { return nil }
            if nodePath.contains(childId) { return nil }
            if depth == 0 {
                return Memory(
                    id: child.id, label: child.label, content: "", associations: [])
            }
            return buildNode(child, depth: depth - 1, path: nodePath)
        }
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
        if range.lowerBound >= array.count {
            return array
        }
        let upper = min(range.upperBound, array.count)
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

    private func notifyAll(affectedIDs: Set<UUID>) {
        let hasAllSubscribers = !allNodesStreams.isEmpty
        let hasSearchSubscribers = !searchStreams.isEmpty
        let hasOrphanSubscribers = !orphanStreams.isEmpty

        for id in affectedIDs {
            nodeStreams[id]?.values.forEach { entry in
                let value = store[id].map { buildNode($0, depth: entry.depth, path: []) }
                entry.continuation.yield(.success([value]))
            }
            contentStreams[id]?.values.forEach { continuation in
                continuation.yield(.success([store[id]?.content]))
            }
            assocStreams[id]?.values.forEach { entry in
                guard let stored = store[id] else { return }
                let nodes = associations[stored.id]?.compactMap { store[$0] } ?? []
                let paged = paginate(nodes, range: entry.range).map {
                    buildNode($0, depth: entry.depth, path: [])
                }
                entry.continuation.yield(.success(paged))
            }
        }

        if hasAllSubscribers {
            let all = Array(store.values)
            allNodesStreams.values.forEach { entry in
                let sorted = sorted(all, by: entry.sortOrder)
                let paged = paginate(sorted, range: entry.range)
                entry.continuation.yield(
                    .success(
                        SearchResult(
                            items: paged.map { buildNode($0, depth: 0, path: []) },
                            totalCount: sorted.count)))
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
                let sorted = sorted(matched, by: entry.sortOrder, keywords: entry.keywords)
                let paged = paginate(sorted, range: entry.range)
                entry.continuation.yield(
                    .success(
                        SearchResult(
                            items: paged.map { buildNode($0, depth: 0, path: []) },
                            totalCount: sorted.count)))
            }
        }

        if hasOrphanSubscribers {
            let orphans = currentOrphans()
            orphanStreams.values.forEach { entry in
                let sorted = sorted(orphans, by: entry.sortOrder)
                let paged = paginate(sorted, range: entry.range)
                entry.continuation.yield(
                    .success(
                        SearchResult(
                            items: paged.map { buildNode($0, depth: 0, path: []) },
                            totalCount: sorted.count)))
            }
        }
    }

    public func memorize(_ memories: [Memory]) -> Result<[UUID], MemoryError> {
        var affectedIDs: Set<UUID> = []
        queue.sync {
            for memory in memories {
                store[memory.id] = StoredNode(
                    id: memory.id, label: memory.label, content: memory.content, createdAt: Date.now
                )
            }

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

            if !affectedIDs.isEmpty {
                invalidateReferencedCache()
                notifyAll(affectedIDs: affectedIDs)
            } else {
                allNodesStreams.values.forEach { entry in
                    let sorted = sortedStore(by: entry.sortOrder)
                    let paged = paginate(sorted, range: entry.range)
                    entry.continuation.yield(
                        .success(
                            SearchResult(
                                items: paged.map { buildNode($0, depth: 0, path: []) },
                                totalCount: sorted.count)))
                }
                searchStreams.values.forEach { entry in
                    let matched = store.values.filter { storedNode in
                        entry.keywords.contains { keyword in
                            storedNode.label.lowercased().contains(keyword.lowercased())
                                || storedNode.content.lowercased().contains(keyword.lowercased())
                        }
                    }
                    let sorted = sorted(matched, by: entry.sortOrder, keywords: entry.keywords)
                    let paged = paginate(sorted, range: entry.range)
                    entry.continuation.yield(
                        .success(
                            SearchResult(
                                items: paged.map { buildNode($0, depth: 0, path: []) },
                                totalCount: sorted.count)))
                }
                orphanStreams.values.forEach { entry in
                    let orphans = currentOrphans()
                    let sorted = sorted(orphans, by: entry.sortOrder)
                    let paged = paginate(sorted, range: entry.range)
                    entry.continuation.yield(
                        .success(
                            SearchResult(
                                items: paged.map { buildNode($0, depth: 0, path: []) },
                                totalCount: sorted.count)))
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
                var allMemories: [Memory?] = []

                for id in ids {
                    if let stored = store[id] {
                        var visited: Set<UUID> = [stored.id]
                        expandNodeToFlatArray(
                            stored, depth: depth, into: &allMemories, path: [stored.id],
                            visited: &visited)
                    } else {
                        allMemories.append(nil)
                    }
                }

                continuation.yield(.success(allMemories))

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

    private func expandNodeToFlatArray(
        _ stored: StoredNode, depth: Int, into memories: inout [Memory?],
        path: Set<UUID>, visited: inout Set<UUID>
    ) {
        let nodePath = path.union([stored.id])
        let assocIds: [UUID] = Array(associations[stored.id] ?? [])

        let mem = Memory(
            id: stored.id, label: stored.label, content: stored.content,
            associations: assocIds)
        memories.append(mem)
        visited.insert(stored.id)

        if depth > 0 {
            for childId in assocIds {
                if nodePath.contains(childId) { continue }
                if visited.contains(childId) { continue }
                if let child = store[childId] {
                    expandNodeToFlatArray(
                        child, depth: depth - 1, into: &memories,
                        path: nodePath, visited: &visited)
                }
            }
        }
    }

    public func buildSummaryNode(ids: [UUID], depth: Int, sortOrder: SortOrder) -> AsyncStream<
        Result<[MemorySummaryNode?], MemoryError>
    > {
        return AsyncStream { continuation in
            var snapshot: [UUID: MemorySummaryNode] = [:]
            queue.sync {
                for id in ids {
                    snapshot[id] =
                        store[id].map { stored in
                            MemorySummaryNode(
                                id: stored.id, label: stored.label, depth: 0, associations: [])
                        } ?? MemorySummaryNode(id: id, label: "", depth: 0, associations: [])
                }
            }

            var results: [MemorySummaryNode?] = Array(repeating: nil, count: ids.count)
            for (index, id) in ids.enumerated() {
                if let node = snapshot[id] {
                    var visited: Set<UUID> = [id]
                    let children = buildSummaryChildrenSync(
                        for: id, depth: depth, path: [], visited: &visited)
                    results[index] = MemorySummaryNode(
                        id: node.id, label: node.label, depth: 0, associations: children)
                }
            }
            continuation.yield(.success(results))
        }
    }

    private func buildSummaryChildrenSync(
        for id: UUID, depth: Int, path: Set<UUID>, visited: inout Set<UUID>
    ) -> [MemorySummaryNode] {
        let childIds = associations[id] ?? []
        let nodePath = path.union([id])

        var children: [MemorySummaryNode] = []
        for childId in childIds {
            if visited.contains(childId) { continue }
            if let childNode = buildSummaryChildSync(
                for: childId, depth: depth + 1, path: nodePath, visited: &visited
            ) {
                children.append(childNode)
            }
        }
        return children
    }

    private func buildSummaryChildSync(
        for id: UUID, depth: Int, path: Set<UUID>, visited: inout Set<UUID>
    ) -> MemorySummaryNode? {
        guard let stored = store[id] else { return nil }
        if path.contains(id) { return nil }
        if visited.contains(id) { return nil }
        visited.insert(id)

        let childIds = associations[id] ?? []
        if depth <= 0 || childIds.isEmpty {
            return MemorySummaryNode(
                id: stored.id, label: stored.label, depth: depth, associations: [])
        }

        var childAssociations: [MemorySummaryNode] = []
        let childPath = path.union([id])
        for childId in childIds {
            if let childNode = buildSummaryChildSync(
                for: childId, depth: depth - 1, path: childPath, visited: &visited
            ) {
                childAssociations.append(childNode)
            }
        }
        return MemorySummaryNode(
            id: stored.id, label: stored.label, depth: depth, associations: childAssociations)
    }

    private func buildSummaryChildren(
        for id: UUID, depth: Int, path: Set<UUID>, visited: inout Set<UUID>
    ) async -> [MemorySummaryNode] {
        let childIds = associations[id] ?? []
        let nodePath = path.union([id])

        // Local copy of visited to avoid inout capture by escaping closure
        let taskVisited = visited
        return await withTaskGroup(
            of: MemorySummaryNode?.self, returning: [MemorySummaryNode].self
        ) { group in
            for childId in childIds {
                group.addTask { [self, taskVisited] in
                    guard let child = self.store[childId] else { return nil }
                    if nodePath.contains(childId) { return nil }

                    var childVisited = taskVisited
                    let children =
                        depth > 0
                        ? await self.buildSummaryChildren(
                            for: childId, depth: depth - 1, path: nodePath, visited: &childVisited)
                        : []
                    return MemorySummaryNode(
                        id: child.id, label: child.label, associations: children)
                }
            }

            var results: [MemorySummaryNode] = []
            for await node in group {
                if let node = node { results.append(node) }
            }
            return results
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

    public func search(keywords: [String], in range: Range<Int>, depth: Int, sortOrder: SortOrder)
        -> AsyncStream<Result<SearchResult<Memory>, MemoryError>>
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
                let sorted = sorted(matched, by: sortOrder, keywords: keywords)
                let paged = paginate(sorted, range: range)
                continuation.yield(
                    .success(
                        SearchResult(
                            items: paged.map { buildNode($0, depth: depth, path: []) },
                            totalCount: sorted.count)))
                searchStreams[streamID] = (
                    keywords: keywords, range: range, depth: depth, sortOrder: sortOrder,
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

    public func allMemories(in range: Range<Int>, depth: Int, sortOrder: SortOrder) -> AsyncStream<
        Result<SearchResult<Memory>, MemoryError>
    > {
        let streamID = UUID()
        return AsyncStream { continuation in
            queue.sync {
                let sorted = sorted(Array(store.values), by: sortOrder)
                let paged = paginate(sorted, range: range)
                continuation.yield(
                    .success(
                        SearchResult(
                            items: paged.map { buildNode($0, depth: depth, path: []) },
                            totalCount: sorted.count)))
                allNodesStreams[streamID] = (
                    range: range, depth: depth, sortOrder: sortOrder, continuation: continuation
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
                    buildNode($0, depth: depth, path: [])
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

    public func adrift(in range: Range<Int>, depth: Int, sortOrder: SortOrder) -> AsyncStream<
        Result<SearchResult<Memory>, MemoryError>
    > {
        let streamID = UUID()
        return AsyncStream { continuation in
            queue.sync {
                let orphans = currentOrphans()
                let sorted = sorted(orphans, by: sortOrder)
                let paged = paginate(sorted, range: range)
                continuation.yield(
                    .success(
                        SearchResult(
                            items: paged.map { buildNode($0, depth: depth, path: []) },
                            totalCount: sorted.count)))
                orphanStreams[streamID] = (
                    range: range, depth: depth, sortOrder: sortOrder, continuation: continuation
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

                let validTargets = relatedIds.filter { $0 != id && store[$0] != nil }
                for i in validTargets.indices {
                    for j in validTargets.indices {
                        if i != j {
                            let from = validTargets[i]
                            let to = validTargets[j]
                            let inserted = associations[from, default: []].insert(to).inserted
                            if inserted {
                                affectedIDs.insert(from)
                            }
                        }
                    }
                }

                if !missingIDs.isEmpty || !selfIDs.isEmpty {
                    // fall through to error return
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
            return .failure(.associationFailed("Self-association is not allowed"))
        }
        if !missingIDs.isEmpty {
            let idsList = missingIDs.map { $0.uuidString }.joined(separator: ", ")
            return .failure(.associationFailed("Memory not found: \(idsList)"))
        }
        if didAssociate {
            recordHistory(
                type: .associate, affectedIds: [id] + Array(affectedIDs).filter { $0 != id })
        }
        return didAssociate ? .success(()) : .failure(.memoryNotFound(errorID ?? id))
    }

    public func dissociate(_ id: UUID, from relatedIds: [UUID]) -> Result<Void, MemoryError> {
        var errorID: UUID?
        var didDissociate = false
        var missingIDs: [UUID] = []
        var affectedIDs: Set<UUID> = [id]
        queue.sync {
            if store[id] != nil {
                for relatedId in relatedIds {
                    if store[relatedId] != nil {
                        associations[id]?.remove(relatedId)
                        associations[relatedId]?.remove(id)
                        affectedIDs.insert(relatedId)
                    } else {
                        missingIDs.append(relatedId)
                    }
                }
                if !affectedIDs.isEmpty {
                    invalidateReferencedCache()
                    notifyAll(affectedIDs: affectedIDs)
                }
                if missingIDs.isEmpty {
                    didDissociate = true
                }
            } else {
                errorID = id
            }
        }
        if !missingIDs.isEmpty {
            let idsList = missingIDs.map { $0.uuidString }.joined(separator: ", ")
            return .failure(.associationFailed("Memory not found: \(idsList)"))
        }
        if didDissociate { recordHistory(type: .dissociate, affectedIds: [id] + relatedIds) }
        return didDissociate ? .success(()) : .failure(.memoryNotFound(errorID ?? id))
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
                let existingIDs = Set(store.keys)
                let isFirstImport = existingIDs.isEmpty
                for record in records {
                    if existingIDs.contains(record.id) {
                        idMapping[record.id] = record.id
                    } else if isFirstImport {
                        idMapping[record.id] = record.id
                        store[record.id] = StoredNode(
                            id: record.id, label: record.label, content: record.content,
                            createdAt: record.createdAt ?? Date.now)
                    } else {
                        let newID = UUID()
                        idMapping[record.id] = newID
                        store[newID] = StoredNode(
                            id: newID, label: record.label, content: record.content,
                            createdAt: record.createdAt ?? Date.now)
                    }
                }

                let importedIDs = Set(idMapping.values)

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
