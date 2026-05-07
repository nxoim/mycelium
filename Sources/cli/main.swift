import ArgumentParser
import Darwin
import Foundation
import core

@main
struct CLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cli",
        subcommands: [
            MemorizeCommand.self,
            RecallCommand.self,
            RecallContentCommand.self,
            SearchCommand.self,
            AllMemoriesCommand.self,
            AdriftCommand.self,
            AssociateCommand.self,
            DissociateCommand.self,
            ForgetCommand.self,
            ImportMemoryCommand.self,
            ExportMemoryCommand.self,
        ],
        defaultSubcommand: .none,
        helpNames: [.short, .long]
    )
}

struct MemorizeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "memorize",
        abstract: "Store one or more memories."
    )

    @Flag(help: "Use in-memory storage instead of persistent SQLite database")
    var ramOnly = false

    @Option(help: "Path to the SQLite database directory (default: executable directory)")
    var db: String = ""

    @Option(help: "Label for the memory")
    var label: String

    @Option(help: "Content for the memory")
    var content: String

    @Option(parsing: .upToNextOption, help: "UUIDs of memories to associate with")
    var with: [String] = []

    func run() throws {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLabel.isEmpty else {
            if label.isEmpty {
                fputs("Error: Label must not be empty. An empty label is not allowed.\n", stderr)
            } else {
                fputs(
                    "Error: Label contains only whitespace. Whitespace-only labels are not allowed.\n",
                    stderr
                )
            }
            Darwin.exit(1)
        }
        let config = MyceliumConfig(dbPath: db.isEmpty ? nil : db, ramOnly: ramOnly)
        let graph = try makeGraph(config: config)
        let memory = Memory(
            id: UUID(),
            label: trimmedLabel,
            content: content,
            associations: with.compactMap { UUID(uuidString: $0) }
        )
        switch graph.memorize([memory]) {
        case .success(let ids):
            for id in ids {
                print(id.uuidString)
            }
        case .failure(let error):
            print("Error: \(error.localizedDescription)")
            Darwin.exit(1)
        }
    }
}

struct RecallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "recall",
        abstract: "Recall memory summaries by ID."
    )

    @Flag(help: "Use in-memory storage instead of persistent SQLite database")
    var ramOnly = false

    @Argument(help: "UUIDs of memories to recall")
    var ids: [String]

    @Option(help: "Path to the SQLite database directory (default: executable directory)")
    var db: String = ""

    @Option(
        name: .customLong("depth"),
        parsing: .unconditional,
        help:
            "Depth of association recursion (default: 0). Use -1 or 'no-associations' to load nodes without their associations."
    )
    var depthString: String = "0"

    @Option(help: "Sort order: chronological, reverseChronological (default: chronological)")
    var sort: String = "chronological"

    func run() async throws {
        let uuids = ids.compactMap { UUID(uuidString: $0) }
        guard uuids.count == ids.count else {
            print("Error: Invalid UUID provided")
            Darwin.exit(1)
        }
        guard let sortOrder = QueryParser.parseSortOrderStrict(sort) else {
            print("Error: Invalid sort order '\(sort)'")
            Darwin.exit(1)
        }
        let depth = QueryParser.parseDepth(depthString)
        let config = MyceliumConfig(dbPath: db.isEmpty ? nil : db, ramOnly: ramOnly)
        let graph = try makeGraph(config: config)
        switch await graph.buildSummaryNode(ids: uuids, depth: depth, sortOrder: sortOrder)
            .firstResult()
        {
        case .success(let nodes):
            print(MemoryMarkdown.formatSummaryNodesTree(nodes))
        case .failure(let error):
            print("Error: \(error.localizedDescription)")
            Darwin.exit(1)
        }
    }
}

struct RecallContentCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "recall-fully",
        abstract: "Recall full memory content by ID."
    )

    @Flag(help: "Use in-memory storage instead of persistent SQLite database")
    var ramOnly = false

    @Argument(help: "UUIDs of memories to recall")
    var ids: [String]

    @Option(help: "Path to the SQLite database directory (default: executable directory)")
    var db: String = ""

    func run() async throws {
        let uuids = ids.compactMap { UUID(uuidString: $0) }
        guard uuids.count == ids.count else {
            print("Error: Invalid UUID provided")
            Darwin.exit(1)
        }
        let config = MyceliumConfig(dbPath: db.isEmpty ? nil : db, ramOnly: ramOnly)
        let graph = try makeGraph(config: config)
        switch await graph.recallFully(ids: uuids, sortOrder: .chronological).firstResult() {
        case .success(let contents):
            for content in contents {
                if let c = content {
                    print(c)
                } else {
                    print("null")
                }
            }
        case .failure(let error):
            print("Error: \(error.localizedDescription)")
            Darwin.exit(1)
        }
    }
}

struct SearchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search memory nodes by keywords."
    )

    @Flag(help: "Use in-memory storage instead of persistent SQLite database")
    var ramOnly = false

    @Argument(help: "Keywords to search for")
    var keywords: [String]

    @Option(
        name: .shortAndLong,
        help: "Pagination range in format lowerBound:upperBound (default 0:50)"
    )
    var range: String = "0:50"

    @Option(
        name: .shortAndLong,
        help: "Sort order: chronological, reverseChronological, relevance (default: chronological)"
    )
    var sort: String = "chronological"

    @Option(help: "Path to the SQLite database directory (default: executable directory)")
    var db: String = ""

    @Option(
        name: .customLong("depth"),
        parsing: .unconditional,
        help:
            "Depth of association recursion (default: 0). Use -1 or 'no-associations' to load nodes without their associations."
    )
    var depthString: String = "0"

    func run() async throws {
        let range = QueryParser.parseRange(range) ?? (0..<50)
        guard let sortOrder = QueryParser.parseSortOrderStrict(sort) else {
            throw ValidationError("invalid --sort '\(sort)'")
        }
        let config = MyceliumConfig(dbPath: db.isEmpty ? nil : db, ramOnly: ramOnly)
        let graph = try makeGraph(config: config)
        switch await graph.search(
            keywords: keywords, in: range, depth: 0, sortOrder: sortOrder
        )
        .firstResult()
        {
        case .success(let searchResult):
            let memories = searchResult.items
            let labelMap = memories.reduce(into: [:]) { $0[$1.id] = $1.label }
            print(
                MemoryMarkdown.formatSearchResults(
                    memories, totalFound: searchResult.totalCount,
                    offset: range.lowerBound, labelMap: labelMap))
        case .failure(let error):
            print("Error: \(error.localizedDescription)")
        }
    }
}

struct AllMemoriesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "all-memories",
        abstract: "List all memory nodes."
    )

    @Flag(help: "Use in-memory storage instead of persistent SQLite database")
    var ramOnly = false

    @Option(
        name: .shortAndLong,
        help: "Pagination range in format lowerBound:upperBound (default 0:50)"
    )
    var range: String = "0:50"

    @Option(
        name: .shortAndLong,
        help: "Sort order: chronological, reverseChronological, relevance (default: chronological)"
    )
    var sort: String = "chronological"

    @Option(help: "Path to the SQLite database directory (default: executable directory)")
    var db: String = ""

    @Option(
        name: .customLong("depth"),
        parsing: .unconditional,
        help:
            "Depth of association recursion (default: 0). Use -1 or 'no-associations' to load nodes without their associations."
    )
    var depthString: String = "0"

    func run() async throws {
        let range = QueryParser.parseRange(range) ?? (0..<50)
        guard let sortOrder = QueryParser.parseSortOrderStrict(sort) else {
            throw ValidationError("invalid --sort '\(sort)'")
        }
        let config = MyceliumConfig(dbPath: db.isEmpty ? nil : db, ramOnly: ramOnly)
        let graph = try makeGraph(config: config)
        switch await graph.allMemories(in: range, depth: 0, sortOrder: sortOrder).firstResult() {
        case .success(let searchResult):
            let memories = searchResult.items
            let labelMap = memories.reduce(into: [:]) { $0[$1.id] = $1.label }
            print(
                MemoryMarkdown.formatSearchResults(
                    memories, totalFound: searchResult.totalCount,
                    offset: range.lowerBound, labelMap: labelMap))
        case .failure(let error):
            print("Error: \(error.localizedDescription)")
        }
    }
}

struct AdriftCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "adrift",
        abstract: "Find orphaned memory nodes with no incoming associations."
    )

    @Flag(help: "Use in-memory storage instead of persistent SQLite database")
    var ramOnly = false

    @Option(
        name: .shortAndLong,
        help: "Pagination range in format lowerBound:upperBound (default 0:50)"
    )
    var range: String = "0:50"

    @Option(
        name: .shortAndLong,
        help: "Sort order: chronological, reverseChronological"
    )
    var sort: String = "chronological"

    @Option(help: "Path to the SQLite database directory (default: executable directory)")
    var db: String = ""

    @Option(
        name: .customLong("depth"),
        parsing: .unconditional,
        help:
            "Depth of association recursion (default: 0). Use -1 or 'no-associations' to load nodes without their associations."
    )
    var depthString: String = "0"

    func run() async throws {
        let range = QueryParser.parseRange(range) ?? (0..<50)
        guard let sortOrder = QueryParser.parseSortOrderStrict(sort) else {
            throw ValidationError("invalid --sort '\(sort)'")
        }
        let config = MyceliumConfig(dbPath: db.isEmpty ? nil : db, ramOnly: ramOnly)
        let graph = try makeGraph(config: config)
        switch await graph.adrift(in: range, depth: 0, sortOrder: sortOrder).firstResult() {
        case .success(let searchResult):
            let memories = searchResult.items
            let labelMap = memories.reduce(into: [:]) { $0[$1.id] = $1.label }
            print(
                MemoryMarkdown.formatSearchResults(
                    memories, totalFound: searchResult.totalCount,
                    offset: range.lowerBound, labelMap: labelMap))
        case .failure(let error):
            print("Error: \(error.localizedDescription)")
        }
    }
}

struct AssociateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "associate",
        abstract: "Link two memories together."
    )

    @Flag(help: "Use in-memory storage instead of persistent SQLite database")
    var ramOnly = false

    @Argument(help: "UUID of the first memory")
    var id: String

    @Option(name: .shortAndLong, help: "UUIDs to associate with (can be repeated)")
    var with: [String] = []

    @Option(help: "Path to the SQLite database directory (default: executable directory)")
    var db: String = ""

    func run() throws {
        guard let uuid = UUID(uuidString: id) else { throw ValidationError("invalid UUID") }
        let relatedIds = with.compactMap { UUID(uuidString: $0) }
        guard relatedIds.count == with.count else {
            throw ValidationError("invalid UUID in --with")
        }
        let config = MyceliumConfig(dbPath: db.isEmpty ? nil : db, ramOnly: ramOnly)
        let graph = try makeGraph(config: config)
        switch graph.associate(uuid, with: relatedIds) {
        case .success:
            print("OK")
        case .failure(let error):
            print("Error: \(error.localizedDescription)")
        }
    }
}

struct DissociateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dissociate",
        abstract: "Remove a link between memories."
    )

    @Flag(help: "Use in-memory storage instead of persistent SQLite database")
    var ramOnly = false

    @Argument(help: "UUID of the memory")
    var id: String

    @Option(name: .shortAndLong, help: "UUIDs to dissociate from (can be repeated)")
    var from: [String] = []

    @Option(help: "Path to the SQLite database directory (default: executable directory)")
    var db: String = ""

    func run() throws {
        guard let uuid = UUID(uuidString: id) else { throw ValidationError("invalid UUID") }
        let fromIds = from.compactMap { UUID(uuidString: $0) }
        guard fromIds.count == from.count else {
            throw ValidationError("invalid UUID in --from")
        }
        let config = MyceliumConfig(dbPath: db.isEmpty ? nil : db, ramOnly: ramOnly)
        let graph = try makeGraph(config: config)
        switch graph.dissociate(uuid, from: fromIds) {
        case .success:
            print("OK")
        case .failure(let error):
            print("Error: \(error.localizedDescription)")
        }
    }
}

struct ForgetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "forget",
        abstract: "Delete memory nodes."
    )

    @Flag(help: "Use in-memory storage instead of persistent SQLite database")
    var ramOnly = false

    @Argument(help: "UUID of a single node to delete")
    var id: String?

    @Option(name: .shortAndLong, help: "Multiple UUIDs to delete (can be repeated)")
    var ids: [String] = []

    @Option(help: "Path to the SQLite database directory (default: executable directory)")
    var db: String = ""

    func run() throws {
        let config = MyceliumConfig(dbPath: db.isEmpty ? nil : db, ramOnly: ramOnly)
        let graph = try makeGraph(config: config)
        if let id = id {
            guard let uuid = UUID(uuidString: id) else { throw ValidationError("invalid UUID") }
            switch graph.forget([uuid]) {
            case .success:
                print("Memory \(uuid) forgotten.")
            case .failure(let error):
                throw ValidationError("Failed to forget memory: \(error.localizedDescription)")
            }
        } else if !ids.isEmpty {
            let uuids = ids.compactMap { UUID(uuidString: $0) }
            guard uuids.count == ids.count else {
                throw ValidationError("invalid UUID in --ids")
            }
            switch graph.forget(uuids) {
            case .success:
                print("\(uuids.count) memory(s) forgotten.")
            case .failure(let error):
                throw ValidationError("Failed to forget memories: \(error.localizedDescription)")
            }
        } else {
            throw ValidationError("provide an <id> or --ids")
        }
    }
}

struct ImportMemoryCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import-memory",
        abstract:
            "Import memory data from JSON. UUIDs are regenerated to avoid collisions.",
        discussion:
            """
            Expected JSON structure:
            [
              {"id": "uuid", "label": "Memory label", "content": "Memory content", "associationIDs": ["uuid1", "uuid2"]}
            ]

            Note: Original UUIDs are NOT preserved. New UUIDs are generated for all imported memories
            to avoid ID collisions with existing data. The import returns a mapping of old IDs to new IDs.
            """
    )

    @Flag(help: "Use in-memory storage instead of persistent SQLite database")
    var ramOnly = false

    @Option(name: .shortAndLong, help: "Path to a JSON file to import")
    var file: String?

    @Option(name: .shortAndLong, help: "Raw JSON string to import")
    var json: String?

    @Option(help: "Path to the SQLite database directory (default: executable directory)")
    var db: String = ""

    func run() throws {
        let config = MyceliumConfig(dbPath: db.isEmpty ? nil : db, ramOnly: ramOnly)
        let graph = try makeGraph(config: config)
        if let file = file {
            switch graph.importMemory(from: URL(fileURLWithPath: file)) {
            case .success(let mapping):
                if mapping.isEmpty {
                    print("OK (no memories imported — file may be empty or invalid)")
                } else {
                    print("OK (imported \(mapping.count) memories)")
                    print("Remapped IDs:")
                    for (oldId, newId) in mapping {
                        print("\(oldId.uuidString) → \(newId.uuidString)")
                    }
                }
            case .failure(let error):
                print("Error: \(error.localizedDescription)")
            }
        } else if let json = json {
            switch graph.importMemory(json: json) {
            case .success(let mapping):
                if mapping.isEmpty {
                    print("OK (no memories imported — JSON may be empty or invalid)")
                } else {
                    print("OK (imported \(mapping.count) memories)")
                    print("Remapped IDs:")
                    for (oldId, newId) in mapping {
                        print("\(oldId.uuidString) → \(newId.uuidString)")
                    }
                }
            case .failure(let error):
                print("Error: \(error.localizedDescription)")
            }
        } else {
            throw ValidationError("provide either --file or --json")
        }
    }
}

struct ExportMemoryCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export-memory",
        abstract: "Export memory data."
    )

    @Flag(help: "Use in-memory storage instead of persistent SQLite database")
    var ramOnly = false

    @Option(name: .shortAndLong, help: "Path to write the exported JSON file")
    var file: String?

    @Flag(name: .shortAndLong, help: "Print exported JSON to stdout")
    var json = false

    @Option(help: "Path to the SQLite database directory (default: executable directory)")
    var db: String = ""

    func run() throws {
        let config = MyceliumConfig(dbPath: db.isEmpty ? nil : db, ramOnly: ramOnly)
        let graph = try makeGraph(config: config)
        switch graph.exportMemoryJSON() {
        case .success(let jsonStr):
            if let file = file {
                switch graph.exportMemory(to: URL(fileURLWithPath: file)) {
                case .success:
                    print("OK")
                case .failure(let error):
                    print("Error: \(error.localizedDescription)")
                }
            } else if json {
                print(jsonStr)
            } else {
                print("OK")
            }
        case .failure(let error):
            print("Error: \(error.localizedDescription)")
        }
    }
}

func makeGraph(config: MyceliumConfig = MyceliumConfig()) throws -> MemoryGraphBox {
    if config.ramOnly {
        return MemoryGraphBox(InMemoryMemoryGraph())
    }
    let graph = try LocalMemoryGraph(directory: config.databaseDirectory)
    return MemoryGraphBox(graph)
}
