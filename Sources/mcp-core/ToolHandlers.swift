import Foundation
import MCP
import core

/// Depth description used across tool definitions and handlers.
public let depthDescription = """
    -1 = no associations loaded
    0 = direct associations only
    1+ = recursive association expansion
    """

/// Typed tool names to replace raw string matching.
private enum ToolName: String {
    case memorize
    case recall
    case recallFully
    case search
    case allMemories
    case adrift
    case associate
    case dissociate
    case forget
}

public func handleTool(
    graph: MemoryGraphBox,
    parameters: CallTool.Parameters
) async -> CallTool.Result {
    guard let tool = ToolName(rawValue: parameters.name) else {
        return .error("Unknown tool: \(parameters.name)")
    }

    switch tool {
    case .memorize: return await handleMemorize(graph, parameters)
    case .recall: return await handleRecall(graph, parameters)
    case .recallFully: return await handleRecallFully(graph, parameters)
    case .search: return await handleSearch(graph, parameters)
    case .allMemories: return await handleAllMemories(graph, parameters)
    case .adrift: return await handleOrphans(graph, parameters)
    case .associate: return await handleAssociate(graph, parameters)
    case .dissociate: return await handleDissociate(graph, parameters)
    case .forget: return handleForget(graph, parameters)
    }
}

extension CallTool.Result {
    fileprivate static func error(_ message: String) -> CallTool.Result {
        .init(
            content: [.text(text: message, annotations: nil, _meta: nil)],
            isError: true)
    }

    fileprivate static func text(_ text: String) -> CallTool.Result {
        .init(
            content: [.text(text: text, annotations: nil, _meta: nil)],
            isError: false)
    }

    fileprivate static let okResponse: CallTool.Result = .init(
        content: [.text(text: "{\"ok\": true}", annotations: nil, _meta: nil)],
        isError: false)

    fileprivate static let nullResponse: CallTool.Result = .init(
        content: [.text(text: "null", annotations: nil, _meta: nil)],
        isError: false)
}

private func handleMemorize(_ graph: MemoryGraphBox, _ parameters: CallTool.Parameters) async
    -> CallTool.Result
{
    guard let label = parameters.arguments?["label"]?.stringValue else {
        return .error("Missing required argument: label")
    }
    let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedLabel.isEmpty else {
        return .error("Invalid input: Label must not be empty or whitespace-only")
    }
    guard let content = parameters.arguments?["content"]?.stringValue else {
        return .error("Missing required argument: content")
    }

    let associations = (parameters.arguments?["associations"]?.arrayValue ?? [])
        .compactMap { $0.stringValue }
        .compactMap { UUID(uuidString: $0) }

    let memory = Memory(
        id: UUID(), label: trimmedLabel, content: content, associations: associations)
    switch graph.memorize([memory]) {
    case .success(let ids):
        let idStrings = ids.map { $0.uuidString }
        return .text("{\"ids\": [\(idStrings.map { "\"\($0)\"" }.joined(separator: ", "))]}")
    case .failure(let error):
        return .error("Error: \(error.localizedDescription)")
    }
}

private func handleRecall(_ graph: MemoryGraphBox, _ parameters: CallTool.Parameters) async
    -> CallTool.Result
{
    guard let ids = extractIDs(named: "ids", from: parameters.arguments) else {
        return .error("Missing required argument: ids")
    }
    let depth = parameters.arguments?["depth"]?.intValue ?? 0
    let sort =
        QueryParser.parseSortOrderStrict(parameters.arguments?["sort"]?.stringValue)
        ?? .chronological

    switch await graph.buildSummaryNode(ids: ids, depth: depth, sortOrder: sort).firstResult() {
    case .success(let nodes):
        guard let summaryNode = nodes.first, summaryNode != nil else {
            return .nullResponse
        }
        return .text(MemoryMarkdown.formatSummaryNode(summaryNode))
    case .failure(let error):
        return .error("Error: \(error.localizedDescription)")
    }
}

private func handleRecallFully(_ graph: MemoryGraphBox, _ parameters: CallTool.Parameters) async
    -> CallTool.Result
{
    guard let ids = extractIDs(named: "ids", from: parameters.arguments) else {
        return .error("Missing required argument: ids")
    }
    let sort =
        QueryParser.parseSortOrderStrict(parameters.arguments?["sort"]?.stringValue)
        ?? .chronological

    switch await graph.recallFully(ids: ids, sortOrder: sort).firstResult() {
    case .success(let contents):
        if ids.count == 1 && contents[0] == nil {
            return .nullResponse
        }
        return .text(MemoryMarkdown.formatContents(contents))
    case .failure(let error):
        return .error("Error: \(error.localizedDescription)")
    }
}

private func handleSearch(_ graph: MemoryGraphBox, _ parameters: CallTool.Parameters) async
    -> CallTool.Result
{
    guard let keywords = extractKeywords(from: parameters.arguments) else {
        return .error("Missing required argument: keywords")
    }
    let range = QueryParser.parseRange(parameters.arguments?["range"]?.stringValue) ?? (0..<50)
    let depth = parameters.arguments?["depth"]?.intValue ?? 0
    let sort =
        QueryParser.parseSortOrderStrict(parameters.arguments?["sort"]?.stringValue)
        ?? .chronological

    return formatSearchResult(
        await graph.search(keywords: keywords, in: range, depth: depth, sortOrder: sort)
            .firstResult(),
        offset: range.lowerBound
    )
}

private func handleAllMemories(_ graph: MemoryGraphBox, _ parameters: CallTool.Parameters) async
    -> CallTool.Result
{
    let range = QueryParser.parseRange(parameters.arguments?["range"]?.stringValue) ?? (0..<50)
    let depth = parameters.arguments?["depth"]?.intValue ?? 0
    let sort =
        QueryParser.parseSortOrderStrict(parameters.arguments?["sort"]?.stringValue)
        ?? .chronological

    return formatSearchResult(
        await graph.allMemories(in: range, depth: depth, sortOrder: sort).firstResult(),
        offset: range.lowerBound
    )
}

private func handleOrphans(_ graph: MemoryGraphBox, _ parameters: CallTool.Parameters) async
    -> CallTool.Result
{
    let range = QueryParser.parseRange(parameters.arguments?["range"]?.stringValue) ?? (0..<50)
    let depth = parameters.arguments?["depth"]?.intValue ?? 0
    let sort =
        QueryParser.parseSortOrderStrict(parameters.arguments?["sort"]?.stringValue)
        ?? .chronological

    return formatSearchResult(
        await graph.adrift(in: range, depth: depth, sortOrder: sort).firstResult(),
        offset: range.lowerBound
    )
}

private func handleAssociate(_ graph: MemoryGraphBox, _ parameters: CallTool.Parameters) async
    -> CallTool.Result
{
    guard let id = extractID(named: "id", from: parameters.arguments) else {
        return .error("Missing required argument: id")
    }
    guard let withValue = parameters.arguments?["with"]?.arrayValue else {
        return .error("Missing required argument: with")
    }
    let withIds = withValue.compactMap { $0.stringValue }.compactMap { UUID(uuidString: $0) }

    return executeWithFailureCheck(graph.associate(id, with: withIds))
}

private func handleDissociate(_ graph: MemoryGraphBox, _ parameters: CallTool.Parameters) async
    -> CallTool.Result
{
    guard let id = extractID(named: "id", from: parameters.arguments) else {
        return .error("Missing required argument: id")
    }
    guard let fromValue = parameters.arguments?["from"]?.arrayValue else {
        return .error("Missing required argument: from")
    }
    let fromIds = fromValue.compactMap { $0.stringValue }.compactMap { UUID(uuidString: $0) }

    return executeWithFailureCheck(graph.dissociate(id, from: fromIds))
}

private func handleForget(_ graph: MemoryGraphBox, _ parameters: CallTool.Parameters)
    -> CallTool.Result
{
    let idsToForget =
        extractIDs(named: "ids", from: parameters.arguments)
        ?? extractIDs(named: "id", from: parameters.arguments)
        ?? []

    guard !idsToForget.isEmpty else {
        return .error("Missing required argument: ids")
    }

    return executeWithFailureCheck(graph.forget(idsToForget))
}

private func formatSearchResult(
    _ result: Result<SearchResult<Memory>, MemoryError>,
    offset: Int
) -> CallTool.Result {
    switch result {
    case .success(let searchResult):
        let memories = searchResult.items
        let totalFound = searchResult.totalCount
        let labelMap = memories.reduce(into: [:]) { $0[$1.id] = $1.label }
        return .text(
            MemoryMarkdown.formatSearchResults(
                memories, totalFound: totalFound,
                offset: offset, labelMap: labelMap))
    case .failure(let error):
        return .error("Error: \(error.localizedDescription)")
    }
}

private func executeWithFailureCheck(_ result: Result<Void, MemoryError>) -> CallTool.Result {
    switch result {
    case .success:
        return .okResponse
    case .failure(let error):
        return .error("Error: \(error.localizedDescription)")
    }
}

private func extractIDs(named key: String, from arguments: [String: Value]?) -> [UUID]? {
    guard let arrayValue = arguments?[key]?.arrayValue else { return nil }
    return arrayValue.compactMap(\.stringValue).compactMap { UUID(uuidString: $0) }
}

private func extractKeywords(from arguments: [String: Value]?) -> [String]? {
    guard let arrayValue = arguments?["keywords"]?.arrayValue else { return nil }
    return arrayValue.compactMap(\.stringValue)
}

private func extractID(named name: String, from arguments: [String: Value]?) -> UUID? {
    guard let value = arguments?[name] else { return nil }
    guard let identifierString = value.stringValue else { return nil }
    return UUID(uuidString: identifierString)
}
