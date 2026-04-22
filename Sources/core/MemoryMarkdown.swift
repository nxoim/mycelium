import Foundation

@available(macOS 12.0, *)
public enum MemoryMarkdown {

    public static func formatSummaryNode(_ node: MemorySummaryNode?) -> String {
        guard let node else {
            return "no data"
        }
        var output = "# \(node.label)\n"
        output += "## Associated with:\n"
        output += formatNodeTree(node.associations, indent: 0)
        output += "id: \(node.id.uuidString)\n"
        return output
    }

    /// Format a list of summary nodes, separated by blank lines.
    public static func formatSummaryNodes(_ nodes: [MemorySummaryNode?]) -> String {
        nodes.map { formatSummaryNode($0) }.joined(separator: "\n")
    }

    public static func formatMemory(_ memory: Memory) -> String {
        formatMemory(memory, labelMap: [:])
    }

    public static func formatMemory(_ memory: Memory, labelMap: [UUID: String]) -> String {
        var output = "# \(memory.label)\n"
        output += "\n\(memory.content)\n"
        output += "## Associated with:\n"
        if memory.associations.isEmpty {
            output += "no associations for \"\(memory.label)\"\n"
        } else {
            output += formatFlatAssociations(memory.associations, labelMap: labelMap, indent: 0)
        }
        output += "id: \(memory.id.uuidString)\n"
        return output
    }

    /// Format a list of Memories with content, separated by blank lines.
    public static func formatMemories(_ memories: [Memory]) -> String {
        formatMemories(memories, labelMap: [:])
    }

    /// Format a list of Memories with content using a label map, separated by blank lines.
    public static func formatMemories(_ memories: [Memory], labelMap: [UUID: String]) -> String {
        memories.map { formatMemory($0, labelMap: labelMap) }.joined(separator: "\n")
    }

    public static func formatSummary(_ memory: Memory) -> String {
        formatSummary(memory, labelMap: [:])
    }

    public static func formatSummary(_ memory: Memory, labelMap: [UUID: String]) -> String {
        var output = "# \(memory.label)\n"
        output += "## Associated with:\n"
        if memory.associations.isEmpty {
            output += "no associations for \"\(memory.label)\"\n"
        } else {
            output += formatFlatAssociations(memory.associations, labelMap: labelMap, indent: 0)
        }
        output += "id: \(memory.id.uuidString)\n"
        return output
    }

    /// Format a list of summaries (no content), separated by blank lines.
    public static func formatSummaries(_ memories: [Memory]) -> String {
        formatSummaries(memories, labelMap: [:])
    }

    /// Format a list of summaries with a label map for resolving association IDs.
    public static func formatSummaries(_ memories: [Memory], labelMap: [UUID: String]) -> String {
        memories.map { formatSummary($0, labelMap: labelMap) }.joined(separator: "\n")
    }

    public static func formatMemoriesWithCount(_ memories: [Memory], labelMap: [UUID: String] = [:])
        -> String
    {
        var output = "## Found \(memories.count) memory(s)\n\n"
        output += memories.map { formatMemoryWithId($0, labelMap: labelMap) }.joined(
            separator: "\n---\n\n")
        return output
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

    public static func formatContent(_ content: String?) -> String {
        content ?? "no content"
    }

    /// Format full contents for multiple memories — raw plaintext, no formatting.
    public static func formatContents(_ contents: [String?]) -> String {
        contents.map { $0 ?? "no content" }.joined(separator: "\n")
    }

    private static func formatNodeTree(_ nodes: [MemorySummaryNode], indent: Int) -> String {
        guard !nodes.isEmpty else {
            return "no associations\n"
        }
        let prefix = String(repeating: "-", count: indent + 1)
        return nodes.map { node in
            "\(prefix) **\(node.label)** (id: \(node.id.uuidString))\n"
                + formatNodeTree(node.associations, indent: indent + 1)
        }.joined()
    }

    private static func formatMemoryWithId(
        _ memory: Memory, labelMap: [UUID: String]
    ) -> String {
        var output = "# \(memory.label)\n"
        output += "\n\(memory.content)\n"
        output += "## Associated with:\n"
        if memory.associations.isEmpty {
            output += "no associations for \"\(memory.label)\"\n"
        } else {
            output += formatFlatAssociations(memory.associations, labelMap: labelMap, indent: 0)
        }
        output += "id: \(memory.id.uuidString)\n"
        return output
    }

    private static func formatSummaryWithId(
        _ memory: Memory, labelMap: [UUID: String]
    ) -> String {
        var output = "# \(memory.label)\n"
        output += "## Associated with:\n"
        if memory.associations.isEmpty {
            output += "no associations for \"\(memory.label)\"\n"
        } else {
            output += formatFlatAssociations(memory.associations, labelMap: labelMap, indent: 0)
        }
        output += "id: \(memory.id.uuidString)\n"
        return output
    }

    private static func formatFlatAssociations(
        _ associationIds: [UUID], labelMap: [UUID: String], indent: Int
    ) -> String {
        guard !associationIds.isEmpty else {
            return "no associations\n"
        }
        let prefix = String(repeating: "-", count: indent + 1)
        return associationIds.map { id in
            if let label = labelMap[id] {
                "\(prefix) **\(label)** (id: \(id.uuidString))\n"
            } else {
                "\(prefix) \(id.uuidString)\n"
            }
        }.joined()
    }
}
