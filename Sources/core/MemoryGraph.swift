import Foundation

public struct Memory: Sendable, Codable {
    public let id: UUID
    public let label: String
    public let content: String
    public let associations: [UUID]

    public init(id: UUID, label: String, content: String, associations: [UUID]) {
        self.id = id
        self.label = label
        self.content = content
        self.associations = associations
    }
}

/// Structured view of a memory — id, label, associations only. Never includes content.
public struct MemorySummary: Sendable, Codable {
    public let id: UUID
    public let label: String
    public let associations: [UUID]

    public init(id: UUID, label: String, associations: [UUID]) {
        self.id = id
        self.label = label
        self.associations = associations
    }

    public init(from memory: Memory) {
        self.id = memory.id
        self.label = memory.label
        self.associations = memory.associations
    }
}

/// Paginated search result with totalCount metadata.
public struct SearchResult<T: Sendable & Encodable>: Sendable, Encodable {
    public let items: [T]
    public let totalCount: Int

    public init(items: [T], totalCount: Int) {
        self.items = items
        self.totalCount = totalCount
    }
}

/// Nested memory summary for recall with depth — associations are recursive MemorySummaryNodes.
///
/// The `depth` field tracks the node's position in the association tree (root = 0, children = 1, etc.).
/// It is primarily used for JSON serialization / API output where the depth is meaningful.
/// The `formatNodeTree` function uses its `indent` parameter for tree rendering instead, because
/// tree indentation is computed dynamically during formatting rather than stored in the model.
public struct MemorySummaryNode: Sendable, Codable {
    public let id: UUID
    public let label: String
    public let depth: Int
    public let associations: [MemorySummaryNode]

    public init(id: UUID, label: String, depth: Int = 0, associations: [MemorySummaryNode] = []) {
        self.id = id
        self.label = label
        self.depth = depth
        self.associations = associations
    }
}

public enum SortOrder {
    case chronological
    case reverseChronological
    case relevance
}

public enum MemoryError: Sendable, Error, LocalizedError {
    case memoryNotFound(UUID)
    case associationFailed(String)
    case importFailed(String)
    case exportFailed(String)
    case storageFailed(String)
    case invalidInput(String)

    public var errorDescription: String? {
        switch self {
        case .memoryNotFound(let id):
            "Memory not found: \(id.uuidString)"
        case .associationFailed(let reason):
            reason
        case .importFailed(let reason):
            "Import failed: \(reason)"
        case .exportFailed(let reason):
            "Export failed: \(reason)"
        case .storageFailed(let reason):
            "Storage failed: \(reason)"
        case .invalidInput(let reason):
            "Invalid input: \(reason)"
        }
    }
}

public enum MutationType: Sendable, Codable, CaseIterable, RawRepresentable {
    public typealias RawValue = String

    case memorize
    case associate
    case dissociate
    case forget

    public var rawValue: String {
        switch self {
        case .memorize: "memorize"
        case .associate: "associate"
        case .dissociate: "dissociate"
        case .forget: "forget"
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "memorize": self = .memorize
        case "associate": self = .associate
        case "dissociate": self = .dissociate
        case "forget": self = .forget
        default: return nil
        }
    }
}

public struct HistoryEntry: Sendable, Codable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let type: MutationType
    public let affectedIds: [UUID]

    public init(id: UUID = UUID(), timestamp: Date = .now, type: MutationType, affectedIds: [UUID])
    {
        self.id = id
        self.timestamp = timestamp
        self.type = type
        self.affectedIds = affectedIds
    }
}

@available(macOS 12.0, *)
public protocol MemoryGraph: Sendable {
    /// Store one or more memories, returns generated IDs in order on success
    func memorize(_ memories: [Memory]) -> Result<[UUID], MemoryError>

    /// Retrieve memories by ID with optional association depth (default 0 = direct associations only)
    /// Returns array matching input ID order; nil for any ID not found
    func recall(ids: [UUID], depth: Int, sortOrder: SortOrder) -> AsyncStream<
        Result<[Memory?], MemoryError>
    >

    /// Retrieve full content strings for the given IDs
    /// Returns array matching input ID order; nil for any ID not found
    func recallFully(ids: [UUID], sortOrder: SortOrder) -> AsyncStream<
        Result<[String?], MemoryError>
    >

    /// Build a MemorySummaryNode tree for the given IDs with the specified depth.
    /// Returns array matching input ID order; nil for any ID not found.
    func buildSummaryNode(ids: [UUID], depth: Int, sortOrder: SortOrder) -> AsyncStream<
        Result<[MemorySummaryNode?], MemoryError>
    >

    /// Search memories by keywords, paginated and sorted with optional association depth.
    /// Returns a SearchResult wrapper with totalCount metadata for the result header.
    func search(keywords: [String], in range: Range<Int>, depth: Int, sortOrder: SortOrder)
        -> AsyncStream<
            Result<SearchResult<Memory>, MemoryError>
        >

    /// Retrieve all memories, paginated and sorted with optional association depth.
    /// Returns a SearchResult wrapper with totalCount metadata for the result header.
    func allMemories(in range: Range<Int>, depth: Int, sortOrder: SortOrder) -> AsyncStream<
        Result<SearchResult<Memory>, MemoryError>
    >

    /// Find memories associated with a given memory, traversing up to the specified depth
    func related(to id: UUID, in range: Range<Int>, depth: Int, sortOrder: SortOrder)
        -> AsyncStream<Result<[Memory], MemoryError>>

    /// Find memories with no incoming associations (orphans/adrift) with optional association depth.
    /// Returns a SearchResult wrapper with totalCount metadata for the result header.
    func adrift(in range: Range<Int>, depth: Int, sortOrder: SortOrder) -> AsyncStream<
        Result<SearchResult<Memory>, MemoryError>
    >

    /// Create mutual associations between a memory and others
    func associate(_ id: UUID, with: [UUID]) -> Result<Void, MemoryError>

    /// Remove mutual associations between a memory and others
    func dissociate(_ id: UUID, from: [UUID]) -> Result<Void, MemoryError>

    /// Delete one or more memories (cascade removes them from other memories' associations)
    func forget(_ ids: [UUID]) -> Result<Void, MemoryError>

    /// Import memory database from a local file URL.
    /// Returns id mapping (oldId → newId) for imported memories.
    func importMemory(from url: URL) -> Result<[UUID: UUID], MemoryError>

    /// Import memory database from a raw JSON string.
    /// Returns id mapping (oldId → newId) for imported memories.
    func importMemory(json: String) -> Result<[UUID: UUID], MemoryError>

    /// Export memory database to a local file URL
    func exportMemory(to url: URL) -> Result<Void, MemoryError>

    /// Export memory database as a raw JSON string
    func exportMemoryJSON() -> Result<String, MemoryError>

    /// Retrieve change history — mutations to the memory graph
    func history(in range: Range<Int>, sortOrder: SortOrder) -> AsyncStream<
        Result<[HistoryEntry], MemoryError>
    >
}
