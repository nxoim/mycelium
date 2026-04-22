import Foundation
import MCP
import core

public func handleTool(
    graph: MemoryGraphBox,
    parameters: CallTool.Parameters
) async -> CallTool.Result {
    switch parameters.name {
    case "memorize": return await handleMemorize(graph, parameters)
    case "recall": return await handleRecall(graph, parameters)
    case "recallFully": return await handleRecallFully(graph, parameters)
    case "search": return await handleSearch(graph, parameters)
    case "allMemories": return await handleAllMemories(graph, parameters)
    case "adrift": return await handleOrphans(graph, parameters)
    case "associate": return await handleAssociate(graph, parameters)
    case "dissociate": return await handleDissociate(graph, parameters)
    case "forget": return handleForget(graph, parameters)
    default:
        return .init(
            content: [
                .text(text: "Unknown tool: \(parameters.name)", annotations: nil, _meta: nil)
            ], isError: true)
    }
}

private func handleMemorize(_ graph: MemoryGraphBox, _ parameters: CallTool.Parameters) async
    -> CallTool.Result
{
    guard let label = parameters.arguments?["label"]?.stringValue else {
        return .init(
            content: [
                .text(text: "Missing required argument: label", annotations: nil, _meta: nil)
            ], isError: true)
    }
    guard let content = parameters.arguments?["content"]?.stringValue else {
        return .init(
            content: [
                .text(text: "Missing required argument: content", annotations: nil, _meta: nil)
            ], isError: true)
    }

    let associations = (parameters.arguments?["associations"]?.arrayValue ?? []).compactMap {
        $0.stringValue
    }
    .compactMap { UUID(uuidString: $0) }

    let memory = Memory(id: UUID(), label: label, content: content, associations: associations)
    switch graph.memorize([memory]) {
    case .success(let ids):
        // Return Stage 10 format: {"ids": ["uuid1", "uuid2"]}
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let idStrings = ids.map { $0.uuidString }
        let json = "{\"ids\": [\(idStrings.map { "\"\($0)\"" }.joined(separator: ", "))]}"
        return .init(content: [.text(text: json, annotations: nil, _meta: nil)], isError: false)
    case .failure(let error):
        return .init(
            content: [
                .text(text: "Error: \(error.localizedDescription)", annotations: nil, _meta: nil)
            ], isError: true)
    }
}

private func handleRecall(_ graph: MemoryGraphBox, _ parameters: CallTool.Parameters) async
    -> CallTool.Result
{
    guard let idsValue = parameters.arguments?["ids"]?.arrayValue else {
        return .init(
            content: [.text(text: "Missing required argument: ids", annotations: nil, _meta: nil)],
            isError: true)
    }
    let ids = idsValue.compactMap { $0.stringValue }.compactMap { UUID(uuidString: $0) }
    let depth = parameters.arguments?["depth"]?.intValue ?? 0
    let sort =
        QueryParser.parseSortOrderStrict(parameters.arguments?["sort"]?.stringValue)
        ?? .chronological

    guard
        let result = await graph.buildSummaryNode(ids: ids, depth: depth, sortOrder: sort)
            .firstElement()
    else {
        return .init(
            content: [.text(text: "No result returned", annotations: nil, _meta: nil)],
            isError: true)
    }

    switch result {
    case .success(let nodes):
        guard let node = nodes.first else {
            return .init(
                content: [.text(text: "null", annotations: nil, _meta: nil)], isError: false)
        }
        guard let summaryNode = node else {
            return .init(
                content: [.text(text: "null", annotations: nil, _meta: nil)], isError: false)
        }

        return .init(
            content: [
                .text(
                    text: MemoryMarkdown.formatSummaryNode(summaryNode), annotations: nil,
                    _meta: nil)
            ], isError: false)
    case .failure(let error):
        return .init(
            content: [
                .text(text: "Error: \(error.localizedDescription)", annotations: nil, _meta: nil)
            ], isError: true)
    }
}

private func handleRecallFully(_ graph: MemoryGraphBox, _ parameters: CallTool.Parameters) async
    -> CallTool.Result
{
    guard let idsValue = parameters.arguments?["ids"]?.arrayValue else {
        return .init(
            content: [.text(text: "Missing required argument: ids", annotations: nil, _meta: nil)],
            isError: true)
    }
    let ids = idsValue.compactMap { $0.stringValue }.compactMap { UUID(uuidString: $0) }
    let sort =
        QueryParser.parseSortOrderStrict(parameters.arguments?["sort"]?.stringValue)
        ?? .chronological

    guard let result = await graph.recallFully(ids: ids, sortOrder: sort).firstElement() else {
        return .init(
            content: [.text(text: "No result returned", annotations: nil, _meta: nil)],
            isError: true)
    }

    switch result {
    case .success(let contents):
        // If only one ID was requested and it was not found, return null
        if ids.count == 1 && contents[0] == nil {
            return .init(
                content: [.text(text: "null", annotations: nil, _meta: nil)], isError: false)
        }

        return .init(
            content: [
                .text(text: MemoryMarkdown.formatContents(contents), annotations: nil, _meta: nil)
            ], isError: false)
    case .failure(let error):
        return .init(
            content: [
                .text(text: "Error: \(error.localizedDescription)", annotations: nil, _meta: nil)
            ], isError: true)
    }
}

private func handleSearch(_ graph: MemoryGraphBox, _ parameters: CallTool.Parameters) async
    -> CallTool.Result
{
    guard let keywordsValue = parameters.arguments?["keywords"]?.arrayValue else {
        return .init(
            content: [
                .text(text: "Missing required argument: keywords", annotations: nil, _meta: nil)
            ], isError: true)
    }
    let keywords = keywordsValue.compactMap { $0.stringValue }
    let range = QueryParser.parseRange(parameters.arguments?["range"]?.stringValue) ?? (0..<50)
    let sort =
        QueryParser.parseSortOrderStrict(parameters.arguments?["sort"]?.stringValue)
        ?? .chronological

    guard
        let result = await graph.search(keywords: keywords, in: range, sortOrder: sort)
            .firstElement()
    else {
        return .init(
            content: [.text(text: "No result returned", annotations: nil, _meta: nil)],
            isError: true)
    }

    switch result {
    case .success(let nodes):
        let labelMap = nodes.reduce(into: [:]) { $0[$1.id] = $1.label }
        return .init(
            content: [
                .text(
                    text: MemoryMarkdown.formatSummariesWithCount(nodes, labelMap: labelMap),
                    annotations: nil, _meta: nil)
            ], isError: false)
    case .failure(let error):
        return .init(
            content: [
                .text(text: "Error: \(error.localizedDescription)", annotations: nil, _meta: nil)
            ], isError: true)
    }
}

private func handleAllMemories(_ graph: MemoryGraphBox, _ parameters: CallTool.Parameters) async
    -> CallTool.Result
{
    let range = QueryParser.parseRange(parameters.arguments?["range"]?.stringValue) ?? (0..<50)
    let sort =
        QueryParser.parseSortOrderStrict(parameters.arguments?["sortOrder"]?.stringValue)
        ?? .chronological

    guard let result = await graph.allMemories(in: range, sortOrder: sort).firstElement() else {
        return .init(
            content: [.text(text: "No result returned", annotations: nil, _meta: nil)],
            isError: true)
    }

    switch result {
    case .success(let nodes):
        let labelMap = nodes.reduce(into: [:]) { $0[$1.id] = $1.label }
        return .init(
            content: [
                .text(
                    text: MemoryMarkdown.formatSummariesWithCount(nodes, labelMap: labelMap),
                    annotations: nil, _meta: nil)
            ], isError: false)
    case .failure(let error):
        return .init(
            content: [
                .text(text: "Error: \(error.localizedDescription)", annotations: nil, _meta: nil)
            ], isError: true)
    }
}

private func handleOrphans(_ graph: MemoryGraphBox, _ parameters: CallTool.Parameters) async
    -> CallTool.Result
{
    let range = QueryParser.parseRange(parameters.arguments?["range"]?.stringValue) ?? (0..<50)
    let sort =
        QueryParser.parseSortOrderStrict(parameters.arguments?["sortOrder"]?.stringValue)
        ?? .chronological

    guard let result = await graph.adrift(in: range, sortOrder: sort).firstElement() else {
        return .init(
            content: [.text(text: "No result returned", annotations: nil, _meta: nil)],
            isError: true)
    }

    switch result {
    case .success(let nodes):
        let labelMap = nodes.reduce(into: [:]) { $0[$1.id] = $1.label }
        return .init(
            content: [
                .text(
                    text: MemoryMarkdown.formatSummariesWithCount(nodes, labelMap: labelMap),
                    annotations: nil, _meta: nil)
            ], isError: false)
    case .failure(let error):
        return .init(
            content: [
                .text(text: "Error: \(error.localizedDescription)", annotations: nil, _meta: nil)
            ], isError: true)
    }
}

private func handleAssociate(_ graph: MemoryGraphBox, _ parameters: CallTool.Parameters) async
    -> CallTool.Result
{
    guard let identifierString = parameters.arguments?["id"]?.stringValue else {
        return .init(
            content: [.text(text: "Missing required argument: id", annotations: nil, _meta: nil)],
            isError: true)
    }
    guard let id = UUID(uuidString: identifierString) else {
        return .init(
            content: [
                .text(text: "Invalid UUID: \(identifierString)", annotations: nil, _meta: nil)
            ], isError: true)
    }

    guard let withValue = parameters.arguments?["with"]?.arrayValue else {
        return .init(
            content: [.text(text: "Missing required argument: with", annotations: nil, _meta: nil)],
            isError: true)
    }
    let withIds = withValue.compactMap { $0.stringValue }.compactMap { UUID(uuidString: $0) }

    switch graph.associate(id, with: withIds) {
    case .success:
        return .init(
            content: [.text(text: "{\"ok\": true}", annotations: nil, _meta: nil)], isError: false)
    case .failure(let error):
        return .init(
            content: [
                .text(text: "Error: \(error.localizedDescription)", annotations: nil, _meta: nil)
            ], isError: true)
    }
}

private func handleDissociate(_ graph: MemoryGraphBox, _ parameters: CallTool.Parameters) async
    -> CallTool.Result
{
    guard let identifierString = parameters.arguments?["id"]?.stringValue else {
        return .init(
            content: [.text(text: "Missing required argument: id", annotations: nil, _meta: nil)],
            isError: true)
    }
    guard let id = UUID(uuidString: identifierString) else {
        return .init(
            content: [
                .text(text: "Invalid UUID: \(identifierString)", annotations: nil, _meta: nil)
            ], isError: true)
    }

    guard let fromValue = parameters.arguments?["from"]?.arrayValue else {
        return .init(
            content: [.text(text: "Missing required argument: from", annotations: nil, _meta: nil)],
            isError: true)
    }
    let fromIds = fromValue.compactMap { $0.stringValue }.compactMap { UUID(uuidString: $0) }

    switch graph.dissociate(id, from: fromIds) {
    case .success:
        return .init(
            content: [.text(text: "{\"ok\": true}", annotations: nil, _meta: nil)], isError: false)
    case .failure(let error):
        return .init(
            content: [
                .text(text: "Error: \(error.localizedDescription)", annotations: nil, _meta: nil)
            ], isError: true)
    }
}

private func handleForget(_ graph: MemoryGraphBox, _ parameters: CallTool.Parameters)
    -> CallTool.Result
{
    var idsToForget: [UUID] = []

    // Prefer "ids" array (tool definition), fall back to single "id" string
    if let idsValue = parameters.arguments?["ids"]?.arrayValue {
        idsToForget = idsValue.compactMap { $0.stringValue }.compactMap { UUID(uuidString: $0) }
    } else if let identifierString = parameters.arguments?["id"]?.stringValue {
        if let uuid = UUID(uuidString: identifierString) {
            idsToForget = [uuid]
        }
    } else {
        return .init(
            content: [.text(text: "Missing required argument: ids", annotations: nil, _meta: nil)],
            isError: true)
    }

    guard !idsToForget.isEmpty else {
        return .init(
            content: [.text(text: "No IDs provided", annotations: nil, _meta: nil)], isError: true)
    }

    switch graph.forget(idsToForget) {
    case .success:
        // Return success - Stage 10 format would be {"ok": true}
        return .init(
            content: [.text(text: "{\"ok\": true}", annotations: nil, _meta: nil)], isError: false)
    case .failure(let error):
        return .init(
            content: [
                .text(text: "Error: \(error.localizedDescription)", annotations: nil, _meta: nil)
            ], isError: true)
    }
}

// Note: parseRange and parseSortOrder are now in QueryParser (core/)
