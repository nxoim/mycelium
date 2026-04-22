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
}

@available(macOS 12.0, *)
public final class LocalMemoryGraph: MemoryGraph, Sendable {

    private let databaseQueue: DatabaseQueue
    private let databaseURL: URL?

    public init(database: DatabaseQueue) throws {
        self.databaseURL = nil
        self.databaseQueue = database
        try databaseQueue.write { database in
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

    public init(directory: URL? = nil) throws {
        let dir =
            directory
            ?? URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()

        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        databaseURL = dir.appendingPathComponent("mycelium.sqlite")
        databaseQueue = try DatabaseQueue(path: databaseURL!.path)

        try databaseQueue.write { database in
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

    private func buildNode(database: Database, id: UUID, depth: Int) throws -> Memory? {
        guard let record = try NodeRecord.fetchOne(database, key: id) else {
            return nil
        }

        if depth < 0 {
            return Memory(
                id: record.id, label: record.label, content: record.content, associations: [])
        }

        if depth == 0 {
            let childIds =
                try AssociationRecord
                .filter(Column("parentId") == id)
                .fetchAll(database)
                .map { $0.childId }
            return Memory(
                id: record.id, label: record.label, content: record.content, associations: childIds)
        }

        let childIds =
            try AssociationRecord
            .filter(Column("parentId") == id)
            .fetchAll(database)
            .map { $0.childId }

        let children = try childIds.compactMap { childId -> Memory? in
            if depth > 0 {
                return try buildNode(database: database, id: childId, depth: depth - 1)
            } else {
                guard let childRecord = try NodeRecord.fetchOne(database, key: childId) else {
                    return nil
                }
                return Memory(
                    id: childRecord.id, label: childRecord.label, content: "", associations: [])
            }
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
        // If specified range exceeds total amount of items to paginate, load all items
        if range.lowerBound >= array.count {
            return array
        }
        let upper = min(range.upperBound, array.count)
        return Array(array[range.lowerBound..<upper])
    }

    public func memorize(_ memories: [Memory]) -> Result<[UUID], MemoryError> {
        do {
            try databaseQueue.write { database in
                // Use a single transaction with individual inserts
                for memory in memories {
                    let node = NodeRecord(
                        id: memory.id, label: memory.label, content: memory.content,
                        createdAt: Date.now)
                    try node.insert(database, onConflict: .ignore)
                }

                // Batch associations using SQL INSERT OR IGNORE
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

                // Omni-directional associations: link all declared targets to each other
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
                var results: [Memory?] = Array(repeating: nil, count: ids.count)
                try databaseQueue.read { database in
                    for (index, id) in ids.enumerated() {
                        guard let record = try NodeRecord.fetchOne(database, key: id) else {
                            continue
                        }

                        if depth == 0 {
                            let childIds =
                                try AssociationRecord
                                .filter(Column("parentId") == id)
                                .fetchAll(database)
                                .map { $0.childId }
                            results[index] = Memory(
                                id: record.id, label: record.label, content: record.content,
                                associations: childIds)
                        } else {
                            let childIds =
                                try AssociationRecord
                                .filter(Column("parentId") == id)
                                .fetchAll(database)
                                .map { $0.childId }

                            var children: [Memory] = []
                            for childId in childIds {
                                if depth > 1 {
                                    if let child = try buildNode(
                                        database: database, id: childId, depth: depth - 1)
                                    {
                                        children.append(child)
                                    }
                                } else {
                                    guard
                                        let childRecord = try NodeRecord.fetchOne(
                                            database, key: childId)
                                    else { continue }
                                    children.append(
                                        Memory(
                                            id: childRecord.id, label: childRecord.label,
                                            content: "", associations: []))
                                }
                            }
                            results[index] = Memory(
                                id: record.id, label: record.label, content: record.content,
                                associations: children.map { $0.id })
                        }
                    }
                }
                continuation.yield(.success(results))
            } catch {
                continuation.yield(.failure(.storageFailed(error.localizedDescription)))
            }
        }
    }

    public func buildSummaryNode(ids: [UUID], depth: Int, sortOrder: SortOrder) -> AsyncStream<
        Result<[MemorySummaryNode?], MemoryError>
    > {
        return AsyncStream { continuation in
            do {
                var results: [MemorySummaryNode?] = Array(repeating: nil, count: ids.count)
                try databaseQueue.read { database in
                    for (index, id) in ids.enumerated() {
                        guard let record = try NodeRecord.fetchOne(database, key: id) else {
                            return
                        }
                        let children = try buildSummaryChildren(
                            database: database, id: id, depth: depth)
                        results[index] = MemorySummaryNode(
                            id: record.id, label: record.label, associations: children)
                    }
                }
                continuation.yield(.success(results))
            } catch {
                continuation.yield(.failure(.storageFailed(error.localizedDescription)))
            }
        }
    }

    private func buildSummaryChildren(database: Database, id: UUID, depth: Int) throws
        -> [MemorySummaryNode]
    {
        let childIds =
            try AssociationRecord
            .filter(Column("parentId") == id)
            .fetchAll(database)
            .map { $0.childId }
        return try childIds.compactMap { childId -> MemorySummaryNode? in
            guard let record = try NodeRecord.fetchOne(database, key: childId) else { return nil }
            let children =
                depth > 0
                ? try buildSummaryChildren(database: database, id: childId, depth: depth - 1) : []
            return MemorySummaryNode(id: record.id, label: record.label, associations: children)
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

    public func search(keywords: [String], in range: Range<Int>, sortOrder: SortOrder)
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
                            try self.buildNode(database: database, id: $0.id, depth: 0)
                        }.compactMap { $0 }
                    }
                    continuation.yield(.success(memories))
                }
            } catch {
                continuation.yield(.failure(.storageFailed(error.localizedDescription)))
            }
        }
    }

    public func allMemories(in range: Range<Int>, sortOrder: SortOrder) -> AsyncStream<
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
                            try self.buildNode(database: database, id: $0.id, depth: 0)
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
                        return try buildNode(database: database, id: childId, depth: depth)
                    }.compactMap { $0 }
                }
                continuation.yield(.success(memories))
            } catch {
                continuation.yield(.failure(.storageFailed(error.localizedDescription)))
            }
        }
    }

    public func adrift(in range: Range<Int>, sortOrder: SortOrder) -> AsyncStream<
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
                            try self.buildNode(database: database, id: $0.id, depth: 0)
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

                if !missingIDs.isEmpty {
                    let idsList = missingIDs.map { $0.uuidString }.joined(separator: ", ")
                    throw MemoryError.associationFailed(
                        "Association failed because memory(\(idsList)) did not exist. Create a new memory with full contents indicating there is no knowledge about the memory."
                    )
                }
                if !selfIDs.isEmpty {
                    let idsList = selfIDs.map { $0.uuidString }.joined(separator: ", ")
                    throw MemoryError.associationFailed(
                        "Association failed because memory(\(idsList)) is the same as the target. Self-association is not allowed."
                    )
                }
            }
            recordHistory(type: .associate, affectedIds: [id] + relatedIds)
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
                    // Remove both directions of association
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
                // Clean up orphaned associations
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
                // Pass 1: map old IDs — reuse existing nodes or create new ones
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

                // Pass 2: restore associations using remapped IDs
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
                // Batch fetch all associations in one query
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
            // History recording is best-effort — failures are silent
        }
    }
}
