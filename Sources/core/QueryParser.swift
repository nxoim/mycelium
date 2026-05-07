import Foundation

public enum QuerySortOrder {
    public static let chronological = "chronological"
    public static let reverseChronological = "reverseChronological"
    public static let relevance = "relevance"
}

public enum QueryDepth {
    public static let noAssociations = -1
    public static let noAssociationsString = "no-associations"
    public static let defaultDepth = 0
}

public enum QueryParser {
    public static func parseSortOrder(_ input: String?) -> SortOrder {
        if input == QuerySortOrder.chronological { return .chronological }
        if input == QuerySortOrder.reverseChronological { return .reverseChronological }
        if input == QuerySortOrder.relevance { return .relevance }
        return .chronological
    }

    public static func parseSortOrderStrict(_ input: String?) -> SortOrder? {
        if input == QuerySortOrder.chronological { return .chronological }
        if input == QuerySortOrder.reverseChronological { return .reverseChronological }
        if input == QuerySortOrder.relevance { return .relevance }
        return nil
    }
}

extension QueryParser {
    public static func parseRange(_ input: String?) -> Range<Int>? {
        guard let input = input else { return nil }
        let parts = input.split(separator: ":").map(String.init)
        guard parts.count == 2,
            let lower = Int(parts[0]),
            let upper = Int(parts[1])
        else {
            return nil
        }
        return lower..<upper
    }
}

extension QueryParser {
    public static func parseQueryArray(_ query: String?, _ key: String) -> [String] {
        guard let query = query, let value = parseQueryParam(query, key) else { return [] }
        return value.split(separator: ",").map(String.init)
    }

    public static func parseQueryParam(_ query: String?, _ key: String) -> String? {
        guard let query = query else { return nil }
        let components = query.split(separator: "&")
        for component in components {
            let parts = component.split(separator: "=")
            if parts.count == 2, String(parts[0]) == key {
                return String(parts[1]).removingPercentEncoding
            }
        }
        return nil
    }
}

extension QueryParser {
    public static func parseDepth(_ input: String) -> Int {
        if input == QueryDepth.noAssociationsString {
            return QueryDepth.noAssociations
        }
        return Int(input) ?? QueryDepth.defaultDepth
    }
}
