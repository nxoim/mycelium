import Foundation

@available(macOS 12.0, *)
public enum MemoryMarkdown {

    public static func formatSummaryNode(_ node: MemorySummaryNode?, atRoot: Bool = true) -> String
    {
        guard let node else {
            return "null"
        }
        var output = "# \(node.label)\n"
        if atRoot && node.associations.isEmpty {
            output += "## Associated with nothing\n"
        } else if !node.associations.isEmpty {
            output += "## Associated with:\n"
            output += formatNodeTree(node.associations, indent: 0)
        }
        output += "id: \(node.id.uuidString)\n"
        return output
    }

    public static func formatSummaryNodes(_ nodes: [MemorySummaryNode?]) -> String {
        nodes.map { formatSummaryNode($0) }.joined(separator: "\n")
    }

    public static func formatSummaryNodesWithCount(
        _ nodes: [MemorySummaryNode?]
    ) -> String {
        var output = "## Found \(nodes.count) memory(s)\n\n"
        output += nodes.map { formatSummaryNode($0, atRoot: true) }.joined(separator: "\n\n---\n\n")
        return output
    }

    public static func formatSummaryNodesTree(_ nodes: [MemorySummaryNode?]) -> String {
        nodes.map { formatSummaryNode($0, atRoot: true) }.joined(separator: "\n\n")
    }

    /// Format a list of summaries (no content), with a count header, and ID footer on each.
    public static func formatSummariesWithCount(
        _ memories: [Memory], labelMap: [UUID: String] = [:]
    )
        -> String
    {
        var output = "## Found \(memories.count) memory(s)\n\n"
        output += memories.map { formatSummaryWithId($0, labelMap: labelMap) }.joined(
            separator: "\n---\n\n")
        return output
    }

    /// Format a list of memories with count header — the single source of truth for all
    /// search/list results (both CLI and MCP).
    public static func formatSearchResults(
        _ memories: [Memory],
        totalFound: Int,
        offset: Int = 0,
        labelMap: [UUID: String] = [:]
    ) -> String {
        var output =
            "#### \(memories.count) memories of \(totalFound) found, starting from \(offset)\n"

        if !memories.isEmpty {
            output +=
                "\n"
                + memories.map(
                    { formatSummaryWithId($0, labelMap: labelMap) }
                ).joined(separator: "\n---\n")
        }

        return output
    }

    public static func formatContent(_ content: String?) -> String {
        content ?? "no content"
    }

    public static func formatContents(_ contents: [String?]) -> String {
        contents.map { $0 ?? "no content" }.joined(separator: "\n")
    }

    private static func formatNodeTree(_ nodes: [MemorySummaryNode], indent: Int) -> String {
        guard !nodes.isEmpty else {
            return ""
        }
        let prefix = String(repeating: "-", count: indent + 1)
        return nodes.map { node in
            "\(prefix) **\(node.label)** (id: \(node.id.uuidString))\n"
                + formatNodeTree(node.associations, indent: indent + 1)
        }.joined()
    }

    private static func formatSummaryWithId(
        _ memory: Memory, labelMap: [UUID: String]
    ) -> String {
        var output = "# \(memory.label)\n"
        if memory.associations.isEmpty {
            output += "## Associated with nothing\n"
        } else {
            output += "## Associated with:\n"
            output += formatFlatAssociations(memory.associations, labelMap: labelMap, indent: 0)
        }
        output += "id: \(memory.id.uuidString)\n"
        return output
    }

    private static func formatFlatAssociations(
        _ associationIds: [UUID], labelMap: [UUID: String], indent: Int
    ) -> String {
        guard !associationIds.isEmpty else {
            return "Associated with nothing\n"
        }
        let prefix = String(repeating: "-", count: indent + 1)
        return associationIds.map { id in
            if let label = labelMap[id] {
                "\(prefix) **\(label)** (id: \(id.uuidString))\n"
            } else {
                "\(prefix) **\(id.uuidString)** (id: \(id.uuidString))\n"
            }
        }.joined()
    }
}
