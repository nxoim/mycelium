import Foundation
@preconcurrency import GRDB

private struct NodeRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "nodes"
    let id: UUID
    let label: String
    let content: String
    let createdAt: Date
}

private struct AssociationRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "associations"
    let parentId: UUID
    let childId: UUID
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

@available(macOS 12.0, *)
public final class LocalMemoryGraph: MemoryGraph, Sendable {

    private let databaseQueue: DatabaseQueue
    private let databaseURL: URL?

    public init(database: DatabaseQueue) throws {
        self.databaseURL = nil
        self.databaseQueue = database
        try setupDatabase(databaseQueue)
    }

    public init(directory: URL? = nil) throws {
        let dir =
            directory
            ?? URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()

        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        databaseURL = dir.appendingPathComponent(DatabaseConfig.defaultFileName)
        guard let dbPath = databaseURL?.path else {
            fatalError("Failed to create database URL")
        }
        databaseQueue = try DatabaseQueue(path: dbPath)
        try setupDatabase(databaseQueue)
    }

    private func setupDatabase(_ queue: DatabaseQueue) throws {
        try queue.write { database in
            try database.create(table: NodeRecord.databaseTableName, ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("label", .text).notNull()
                t.column("content", .text).notNull()
                t.column("createdAt", .text).notNull()
            }
            try database.create(table: AssociationRecord.databaseTableName, ifNotExists: true) {
                t in
                t.column("parentId", .text).notNull().references(
                    NodeRecord.databaseTableName, onDelete: .cascade)
                t.column("childId", .text).notNull().references(
                    NodeRecord.databaseTableName, onDelete: .cascade)
                t.primaryKey(["parentId", "childId"])
            }
            try database.create(table: "history", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("timestamp", .text).notNull()
                t.column("type", .text).notNull()
                t.column("affectedIds", .text).notNull()
            }
        }
    }

    private func buildNode(
        database: Database, id: UUID, depth: Int, path: Set<UUID>
    ) throws -> Memory? {
        guard let record = try NodeRecord.fetchOne(database, key: id) else {
            return nil
        }

        let nodePath = path.union([record.id])

        if depth < 0 {
            return Memory(
                id: record.id, label: record.label, content: record.content, associations: [])
        }

        let childIds =
            try AssociationRecord
            .filter(Column("parentId") == id)
            .fetchAll(database)
            .map { $0.childId }

        let children = try childIds.compactMap { childId -> Memory? in
            if nodePath.contains(childId) { return nil }
            guard let childRecord = try NodeRecord.fetchOne(database, key: childId) else {
                return nil
            }
            if depth == 0 {
                return Memory(
                    id: childRecord.id, label: childRecord.label, content: "", associations: [])
            }
            return try buildNode(
                database: database, id: childId, depth: depth - 1, path: nodePath)
        }

        return Memory(
            id: record.id, label: record.label, content: record.content,
            associations: children.compactMap { $0.id })
    }

    private func sorted(_ nodes: [NodeRecord], by order: SortOrder, keywords: [String] = [])
        -> [NodeRecord]
    {
        switch order {
        case .chronological: return nodes.sorted { $0.createdAt < $1.createdAt }
        case .reverseChronological: return nodes.sorted { $0.createdAt > $1.createdAt }
        case .relevance: return nodes.sorted { score($0, keywords) > score($1, keywords) }
        }
    }

    private func score(_ node: NodeRecord, _ keywords: [String]) -> Int {
        keywords.reduce(0) { acc, kw in
            let k = kw.lowercased()
            return acc
                + (node.label.lowercased().contains(k) ? 2 : 0)
                + (node.content.lowercased().contains(k) ? 1 : 0)
        }
    }

    private func paginate<T>(_ array: [T], range: Range<Int>) -> [T] {
        if range.lowerBound >= array.count {
            return array
        }
        let upper = min(range.upperBound, array.count)
        return Array(array[range.lowerBound..<upper])
    }

    public func memorize(_ memories: [Memory]) -> Result<[UUID], MemoryError> {
        do {
            try databaseQueue.write { database in
                for memory in memories {
                    let node = NodeRecord(
                        id: memory.id, label: memory.label, content: memory.content,
                        createdAt: Date.now)
                    try node.insert(database, onConflict: .ignore)
                }

                for memory in memories {
                    for relatedId in memory.associations {
                        guard (try NodeRecord.fetchOne(database, key: relatedId)) != nil else {
                            continue
                        }
                        let parentAssoc = AssociationRecord(parentId: memory.id, childId: relatedId)
                        try parentAssoc.insert(database, onConflict: .ignore)
                        let childAssoc = AssociationRecord(parentId: relatedId, childId: memory.id)
                        try childAssoc.insert(database, onConflict: .ignore)
                    }
                }

                for memory in memories {
                    let validRelatedIds = memory.associations.filter { relatedId in
                        (try? NodeRecord.fetchOne(database, key: relatedId)) != nil
                    }
                    for i in 0..<validRelatedIds.count {
                        for j in (i + 1)..<validRelatedIds.count {
                            let a = validRelatedIds[i]
                            let b = validRelatedIds[j]
                            let ab = AssociationRecord(parentId: a, childId: b)
                            try ab.insert(database, onConflict: .ignore)
                            let ba = AssociationRecord(parentId: b, childId: a)
                            try ba.insert(database, onConflict: .ignore)
                        }
                    }
                }
            }
            recordHistory(type: .memorize, affectedIds: memories.map { $0.id })
            return .success(memories.map { $0.id })
        } catch {
            return .failure(.storageFailed(error.localizedDescription))
        }
    }

    public func recall(ids: [UUID], depth: Int, sortOrder: SortOrder) -> AsyncStream<
        Result<[Memory?], MemoryError>
    > {
        return AsyncStream { continuation in
            do {
                var allMemories: [Memory?] = []

                try databaseQueue.read { database in
                    for id in ids {
                        guard try NodeRecord.fetchOne(database, key: id) != nil else {
                            allMemories.append(nil)
                            continue
                        }
                        var visited: Set<UUID> = [id]
                        try expandNodeToFlatArray(
                            database: database, id: id, depth: depth,
                            into: &allMemories, path: [id],
                            visited: &visited)
                    }
                }
                continuation.yield(.success(allMemories))
            } catch {
                continuation.yield(.failure(.storageFailed(error.localizedDescription)))
            }
        }
    }

    private func expandNodeToFlatArray(
        database: Database, id: UUID, depth: Int, into memories: inout [Memory?],
        path: Set<UUID>, visited: inout Set<UUID>
    ) throws {
        guard let record = try NodeRecord.fetchOne(database, key: id) else { return }

        let nodePath = path.union([record.id])

        let assocIds: [UUID] =
            try AssociationRecord
            .filter(Column("parentId") == id)
            .fetchAll(database)
            .map { $0.childId }

        let mem = Memory(
            id: record.id, label: record.label, content: record.content,
            associations: assocIds)
        memories.append(mem)
        visited.insert(id)

        if depth > 0 {
            for childId in assocIds {
                if nodePath.contains(childId) { continue }
                if visited.contains(childId) { continue }
                if try NodeRecord.fetchOne(database, key: childId) != nil {
                    try expandNodeToFlatArray(
                        database: database, id: childId, depth: depth - 1,
                        into: &memories, path: nodePath,
                        visited: &visited)
                }
            }
        }
    }

    public func buildSummaryNode(ids: [UUID], depth: Int, sortOrder: SortOrder) -> AsyncStream<
        Result<[MemorySummaryNode?], MemoryError>
    > {
        return AsyncStream { continuation in
            do {
                var snapshot: [(UUID, String)] = []
                try databaseQueue.read { database in
                    for id in ids {
                        if let record = try NodeRecord.fetchOne(database, key: id) {
                            snapshot.append((record.id, record.label))
                        }
                    }
                }

                var results: [MemorySummaryNode?] = Array(repeating: nil, count: ids.count)
                for (index, id) in ids.enumerated() {
                    guard let (uuid, label) = snapshot.first(where: { $0.0 == id }) else {
                        continue
                    }
                    var visited: Set<UUID> = [uuid]
                    let children = try buildSummaryChildrenSync(
                        databaseQueue: databaseQueue, id: uuid,
                        depth: depth, path: [], visited: &visited)
                    results[index] = MemorySummaryNode(
                        id: uuid, label: label, depth: 0, associations: children)
                }
                continuation.yield(.success(results))
            } catch {
                continuation.yield(.failure(.storageFailed(error.localizedDescription)))
            }
        }
    }

    private func buildSummaryChildrenSync(
        databaseQueue: DatabaseQueue, id: UUID, depth: Int, path: Set<UUID>,
        visited: inout Set<UUID>
    ) throws -> [MemorySummaryNode] {
        let childIds = try databaseQueue.read { db in
            try AssociationRecord
                .filter(Column("parentId") == id)
                .fetchAll(db)
                .map { $0.childId }
        }
        let nodePath = path.union([id])

        var children: [MemorySummaryNode] = []
        for childId in childIds {
            if visited.contains(childId) { continue }
            if let childNode = try buildSummaryChildSync(
                databaseQueue: databaseQueue, id: childId, depth: depth + 1,
                path: nodePath, visited: &visited
            ) {
                children.append(childNode)
            }
        }
        return children
    }

    private func buildSummaryChildSync(
        databaseQueue: DatabaseQueue, id: UUID, depth: Int, path: Set<UUID>,
        visited: inout Set<UUID>
    ) throws -> MemorySummaryNode? {
        guard let record = try databaseQueue.read({ try NodeRecord.fetchOne($0, key: id) }) else {
            return nil
        }
        if path.contains(id) { return nil }
        if visited.contains(id) { return nil }
        visited.insert(id)

        let childIds = try databaseQueue.read { db in
            try AssociationRecord
                .filter(Column("parentId") == id)
                .fetchAll(db)
                .map { $0.childId }
        }

        if depth <= 0 || childIds.isEmpty {
            return MemorySummaryNode(
                id: record.id, label: record.label, depth: depth, associations: [])
        }

        var childAssociations: [MemorySummaryNode] = []
        let childPath = path.union([id])
        for childId in childIds {
            if let childNode = try buildSummaryChildSync(
                databaseQueue: databaseQueue, id: childId, depth: depth - 1,
                path: childPath, visited: &visited
            ) {
                childAssociations.append(childNode)
            }
        }
        return MemorySummaryNode(
            id: record.id, label: record.label, depth: depth, associations: childAssociations)
    }

    private func buildSummaryChildren(
        databaseQueue: DatabaseQueue, id: UUID, depth: Int, path: Set<UUID>,
        visited: inout Set<UUID>
    )
        async throws -> [MemorySummaryNode]
    {
        let childIds = try await databaseQueue.read { db in
            try AssociationRecord
                .filter(Column("parentId") == id)
                .fetchAll(db)
                .map { $0.childId }
        }

        let nodePath = path.union([id])

        let dbPath = databaseURL?.path ?? ""

        // Local copy of visited to avoid inout capture by escaping closure
        let taskVisited = visited
        return await withTaskGroup(
            of: MemorySummaryNode?.self, returning: [MemorySummaryNode].self
        ) { group in
            for childId in childIds {
                group.addTask { [dbPath, taskVisited] in
                    do {
                        let dbQueue = try DatabaseQueue(path: dbPath)
                        let record = try await dbQueue.read { db in
                            try NodeRecord.fetchOne(db, key: childId)
                        }
                        guard let record = record else { return nil }
                        if nodePath.contains(childId) { return nil }
                        var childVisited = taskVisited
                        let children: [MemorySummaryNode] =
                            depth > 0
                            ? (try? await self.buildSummaryChildren(
                                databaseQueue: dbQueue, id: childId, depth: depth - 1,
                                path: nodePath, visited: &childVisited))
                                ?? []
                            : []
                        return MemorySummaryNode(
                            id: record.id, label: record.label, associations: children)
                    } catch {
                        return nil
                    }
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
        return AsyncStream { continuation in
            do {
                var results: [String?] = Array(repeating: nil, count: ids.count)
                try databaseQueue.read { database in
                    for (index, id) in ids.enumerated() {
                        results[index] = try NodeRecord.fetchOne(database, key: id)?.content
                    }
                }
                continuation.yield(.success(results))
            } catch {
                continuation.yield(.failure(.storageFailed(error.localizedDescription)))
            }
        }
    }

    public func search(keywords: [String], in range: Range<Int>, depth: Int, sortOrder: SortOrder)
        -> AsyncStream<Result<[Memory], MemoryError>>
    {
        return AsyncStream { continuation in
            do {
                let allNodes = try databaseQueue.read { database -> [NodeRecord] in
                    try NodeRecord.fetchAll(database)
                }
                let matched = allNodes.filter { n in
                    keywords.contains { kw in
                        n.label.lowercased().contains(kw.lowercased())
                            || n.content.lowercased().contains(kw.lowercased())
                    }
                }
                let paged = self.paginate(
                    self.sorted(matched, by: sortOrder, keywords: keywords), range: range)
                if paged.isEmpty {
                    continuation.yield(.success([]))
                } else {
                    let memories = try databaseQueue.read { database -> [Memory] in
                        try paged.compactMap {
                            try self.buildNode(
                                database: database, id: $0.id, depth: depth, path: [])
                        }.compactMap { $0 }
                    }
                    continuation.yield(.success(memories))
                }
            } catch {
                continuation.yield(.failure(.storageFailed(error.localizedDescription)))
            }
        }

    }

    public func allMemories(in range: Range<Int>, depth: Int, sortOrder: SortOrder) -> AsyncStream<
        Result<[Memory], MemoryError>
    > {
        return AsyncStream { continuation in
            do {
                let allNodes = try databaseQueue.read { database -> [NodeRecord] in
                    try NodeRecord.fetchAll(database)
                }
                let paged = self.paginate(self.sorted(allNodes, by: sortOrder), range: range)
                if paged.isEmpty {
                    continuation.yield(.success([]))
                } else {
                    let memories = try databaseQueue.read { database -> [Memory] in
                        try paged.compactMap {
                            try self.buildNode(
                                database: database, id: $0.id, depth: depth, path: [])
                        }.compactMap { $0 }
                    }
                    continuation.yield(.success(memories))
                }
            } catch {
                continuation.yield(.failure(.storageFailed(error.localizedDescription)))
            }
        }
    }

    public func related(to id: UUID, in range: Range<Int>, depth: Int, sortOrder: SortOrder)
        -> AsyncStream<Result<[Memory], MemoryError>>
    {
        return AsyncStream { continuation in
            do {
                let found = try databaseQueue.read { database -> Bool in
                    (try NodeRecord.fetchOne(database, key: id)) != nil
                }
                guard found else {
                    continuation.yield(.failure(.memoryNotFound(id)))
                    return
                }

                let childIds = try databaseQueue.read { database in
                    try AssociationRecord.filter(Column("parentId") == id).fetchAll(database).map {
                        $0.childId
                    }
                }
                let paged = self.paginate(childIds, range: range)
                let memories = try databaseQueue.read { database -> [Memory] in
                    try paged.compactMap { childId -> Memory? in
                        if depth == 0 {
                            guard let record = try NodeRecord.fetchOne(database, key: childId)
                            else { return nil }
                            return Memory(
                                id: record.id, label: record.label, content: "", associations: [])
                        }
                        return try buildNode(
                            database: database, id: childId, depth: depth, path: [])
                    }.compactMap { $0 }
                }
                continuation.yield(.success(memories))
            } catch {
                continuation.yield(.failure(.storageFailed(error.localizedDescription)))
            }
        }
    }

    public func adrift(in range: Range<Int>, depth: Int, sortOrder: SortOrder) -> AsyncStream<
        Result<[Memory], MemoryError>
    > {
        return AsyncStream { continuation in
            do {
                let orphans = try databaseQueue.read { database -> [NodeRecord] in
                    let request = NodeRecord.filter(
                        sql: "id NOT IN (SELECT childId FROM associations)")
                    return try request.fetchAll(database)
                }
                let paged = self.paginate(orphans, range: range)
                if paged.isEmpty {
                    continuation.yield(.success([]))
                } else {
                    let memories = try databaseQueue.read { database -> [Memory] in
                        try paged.compactMap {
                            try self.buildNode(
                                database: database, id: $0.id, depth: depth, path: [])
                        }.compactMap { $0 }
                    }
                    continuation.yield(.success(memories))
                }
            } catch {
                continuation.yield(.failure(.storageFailed(error.localizedDescription)))
            }
        }
    }

    public func associate(_ id: UUID, with relatedIds: [UUID]) -> Result<Void, MemoryError> {
        do {
            var missingIDs: [UUID] = []
            var selfIDs: [UUID] = []
            try databaseQueue.write { database in
                guard (try NodeRecord.fetchOne(database, key: id)) != nil else {
                    throw MemoryError.memoryNotFound(id)
                }

                for relatedId in relatedIds {
                    if relatedId == id {
                        selfIDs.append(relatedId)
                        continue
                    }
                    guard (try NodeRecord.fetchOne(database, key: relatedId)) != nil else {
                        missingIDs.append(relatedId)
                        continue
                    }
                    let parentAssoc = AssociationRecord(parentId: id, childId: relatedId)
                    try parentAssoc.insert(database, onConflict: .ignore)
                    let childAssoc = AssociationRecord(parentId: relatedId, childId: id)
                    try childAssoc.insert(database, onConflict: .ignore)
                }

                let validTargets = relatedIds.filter { relatedId in
                    relatedId != id && (try? NodeRecord.fetchOne(database, key: relatedId)) != nil
                }
                for i in 0..<validTargets.count {
                    for j in (i + 1)..<validTargets.count {
                        let a = validTargets[i]
                        let b = validTargets[j]
                        let ab = AssociationRecord(parentId: a, childId: b)
                        try ab.insert(database, onConflict: .ignore)
                        let ba = AssociationRecord(parentId: b, childId: a)
                        try ba.insert(database, onConflict: .ignore)
                    }
                }

                if !missingIDs.isEmpty {
                    let idsList = missingIDs.map { $0.uuidString }.joined(separator: ", ")
                    throw MemoryError.associationFailed("Memory not found: \(idsList)")
                }
                if !selfIDs.isEmpty {
                    throw MemoryError.associationFailed("Self-association is not allowed")
                }
            }
            let validRelatedIds = relatedIds.filter { $0 != id }
            recordHistory(type: .associate, affectedIds: [id] + validRelatedIds)
            return .success(())
        } catch {
            if let memError = error as? MemoryError {
                return .failure(memError)
            }
            return .failure(.storageFailed(error.localizedDescription))
        }
    }

    public func dissociate(_ id: UUID, from relatedIds: [UUID]) -> Result<Void, MemoryError> {
        do {
            try databaseQueue.write { database in
                guard (try NodeRecord.fetchOne(database, key: id)) != nil else {
                    throw MemoryError.memoryNotFound(id)
                }

                for relatedId in relatedIds {
                    let parentAssoc = AssociationRecord.filter(
                        Column("parentId") == id && Column("childId") == relatedId)
                    try parentAssoc.deleteAll(database)

                    let childAssoc = AssociationRecord.filter(
                        Column("parentId") == relatedId && Column("childId") == id)
                    try childAssoc.deleteAll(database)
                }
            }
            recordHistory(type: .dissociate, affectedIds: [id] + relatedIds)
            return .success(())
        } catch {
            if let memError = error as? MemoryError {
                return .failure(memError)
            }
            return .failure(.storageFailed(error.localizedDescription))
        }
    }

    public func forget(_ ids: [UUID]) -> Result<Void, MemoryError> {
        var foundAny = false
        do {
            try databaseQueue.write { database in
                for id in ids {
                    if try NodeRecord.deleteOne(database, key: id) {
                        foundAny = true
                    }
                }
                if !ids.isEmpty {
                    let placeholders = ids.map { _ in "?" }.joined(separator: ",")
                    try database.execute(
                        sql: "DELETE FROM associations WHERE parentId IN (\(placeholders))",
                        arguments: StatementArguments(ids.map { $0.uuidString }))
                    try database.execute(
                        sql: "DELETE FROM associations WHERE childId IN (\(placeholders))",
                        arguments: StatementArguments(ids.map { $0.uuidString }))
                }
            }
            if foundAny { recordHistory(type: .forget, affectedIds: ids) }
            return foundAny ? .success(()) : .failure(.memoryNotFound(ids.first ?? UUID()))
        } catch {
            return .failure(.storageFailed(error.localizedDescription))
        }
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
            let existingIDs = try databaseQueue.read { database in
                try NodeRecord.fetchAll(database).map(\.id)
            }

            try databaseQueue.write { database in
                for record in records {
                    if existingIDs.contains(record.id) {
                        idMapping[record.id] = record.id
                    } else {
                        let newID = UUID()
                        idMapping[record.id] = newID
                        let createdAt = record.createdAt ?? Date.now
                        try NodeRecord(
                            id: newID, label: record.label, content: record.content,
                            createdAt: createdAt
                        ).insert(database, onConflict: .ignore)
                    }
                }

                let importedIDs = Set(idMapping.values)

                for record in records {
                    guard let newID = idMapping[record.id] else { continue }
                    for relatedId in record.associationIDs {
                        let newRelatedID = idMapping[relatedId] ?? relatedId
                        guard
                            existingIDs.contains(newRelatedID) || importedIDs.contains(newRelatedID)
                        else { continue }
                        try AssociationRecord(parentId: newID, childId: newRelatedID).insert(
                            database, onConflict: .ignore)
                        try AssociationRecord(parentId: newRelatedID, childId: newID).insert(
                            database, onConflict: .ignore)
                    }
                }

                try database.execute(
                    sql: "DELETE FROM associations WHERE childId NOT IN (SELECT id FROM nodes)")
                try database.execute(
                    sql: "DELETE FROM associations WHERE parentId NOT IN (SELECT id FROM nodes)")
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
        do {
            let persistedNodes = try databaseQueue.read { database -> [PersistedNode] in
                let nodes = try NodeRecord.fetchAll(database)
                let allAssocs = try AssociationRecord.fetchAll(database)
                let assocMap = Dictionary(grouping: allAssocs, by: \.parentId)
                return nodes.map { n in
                    let childIds = assocMap[n.id]?.map { $0.childId } ?? []
                    return PersistedNode(
                        id: n.id, label: n.label, content: n.content, associationIDs: childIds,
                        createdAt: n.createdAt)
                }
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(persistedNodes)
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
            var entries: [HistoryEntry] = []
            do {
                try databaseQueue.read { database -> Void in
                    let rows = try SQLRequest(
                        "SELECT id, timestamp, type, affectedIds FROM history ORDER BY rowid ASC"
                    ).fetchAll(database)
                    for row in rows {
                        let entry = HistoryEntry(
                            id: UUID(uuidString: row["id"] as? String ?? "") ?? UUID(),
                            timestamp: ISO8601DateFormatter().date(
                                from: row["timestamp"] as? String ?? "") ?? .now,
                            type: MutationType(rawValue: row["type"] as? String ?? "") ?? .memorize,
                            affectedIds: (row["affectedIds"] as? String ?? "[]").components(
                                separatedBy: ","
                            ).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) }
                                .compactMap { UUID(uuidString: $0) }
                        )
                        entries.append(entry)
                    }
                }

                let sorted: [HistoryEntry]
                switch sortOrder {
                case .chronological: sorted = entries.sorted { $0.timestamp < $1.timestamp }
                case .reverseChronological: sorted = entries.sorted { $0.timestamp > $1.timestamp }
                case .relevance: sorted = entries
                }

                let paged = self.paginate(sorted, range: range)
                continuation.yield(.success(paged))
            } catch {
                continuation.yield(.failure(.storageFailed(error.localizedDescription)))
            }
        }
    }

    private func recordHistory(type: MutationType, affectedIds: [UUID]) {
        do {
            try databaseQueue.write { database in
                let id = UUID().uuidString
                let timestamp = ISO8601DateFormatter().string(from: Date.now)
                let affectedIdsJSON =
                    "[\(affectedIds.map { "\"\($0.uuidString)\"" }.joined(separator: ", "))]"

                try database.execute(
                    sql:
                        "INSERT INTO history (id, timestamp, type, affectedIds) VALUES (?, ?, ?, ?)",
                    arguments: [id, timestamp, type.rawValue, affectedIdsJSON])
                try database.execute(
                    sql:
                        "DELETE FROM history WHERE rowid NOT IN (SELECT rowid FROM history ORDER BY rowid DESC LIMIT 10000)"
                )
            }
        } catch {
            // Best-effort — failures are silent
        }
    }
}
