import Foundation

public enum QueryParser {
    public static func parseSortOrder(_ input: String?) -> SortOrder {
        switch input {
        case "chronological": return .chronological
        case "reverseChronological": return .reverseChronological
        case "relevance": return .relevance
        case nil, _: return .chronological
        }
    }

    public static func parseSortOrderStrict(_ input: String?) -> SortOrder? {
        switch input {
        case "chronological": return .chronological
        case "reverseChronological": return .reverseChronological
        case "relevance": return .relevance
        default: return nil
        }
    }

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
