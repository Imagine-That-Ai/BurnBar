import Foundation

// MARK: - Receipt Grouping Mode

public enum ReceiptGroupingMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case date = "date"
    case project = "project"
    case provider = "provider"
    case harness = "harness"
    case model = "model"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .date: return "By Date"
        case .project: return "By Project"
        case .provider: return "By Provider"
        case .harness: return "By Harness"
        case .model: return "By Model"
        }
    }
}

// MARK: - Receipt Filter

/// Filter and search criteria for querying the receipt drawer.
public struct ReceiptFilter: Hashable, Sendable {
    public var searchQuery: String = ""
    public var provider: AgentProvider? = nil
    public var harness: String? = nil
    public var projectName: String? = nil
    public var minCost: Double? = nil
    public var maxCost: Double? = nil
    public var minCachePercentage: Double? = nil
    public var isStarredOnly: Bool = false
    public var dateRange: ClosedRange<Date>? = nil
    public var grouping: ReceiptGroupingMode = .date

    public init(
        searchQuery: String = "",
        provider: AgentProvider? = nil,
        harness: String? = nil,
        projectName: String? = nil,
        minCost: Double? = nil,
        maxCost: Double? = nil,
        minCachePercentage: Double? = nil,
        isStarredOnly: Bool = false,
        dateRange: ClosedRange<Date>? = nil,
        grouping: ReceiptGroupingMode = .date
    ) {
        self.searchQuery = searchQuery
        self.provider = provider
        self.harness = harness
        self.projectName = projectName
        self.minCost = minCost
        self.maxCost = maxCost
        self.minCachePercentage = minCachePercentage
        self.isStarredOnly = isStarredOnly
        self.dateRange = dateRange
        self.grouping = grouping
    }

    /// Whether any filter criteria are active beyond default.
    public var hasActiveFilters: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        provider != nil ||
        harness != nil ||
        projectName != nil ||
        minCost != nil ||
        maxCost != nil ||
        minCachePercentage != nil ||
        isStarredOnly ||
        dateRange != nil
    }

    /// Reset all filters to default state.
    public mutating func reset() {
        searchQuery = ""
        provider = nil
        harness = nil
        projectName = nil
        minCost = nil
        maxCost = nil
        minCachePercentage = nil
        isStarredOnly = false
        dateRange = nil
    }

    // MARK: - Smart Syntax Parsing

    /// Parse inline power tokens from the search query (e.g. `spend:>1.00`, `cache:>80%`, `model:sonnet`, `project:BurnBar`).
    public static func parseSmartQuery(_ input: String) -> (cleanedQuery: String, filterModifiers: (minSpend: Double?, maxSpend: Double?, minCache: Double?, model: String?, project: String?, starred: Bool?)) {
        var tokens = input.split(separator: " ").map(String.init)
        var cleanedTokens: [String] = []
        var minSpend: Double? = nil
        var maxSpend: Double? = nil
        var minCache: Double? = nil
        var model: String? = nil
        var project: String? = nil
        var starred: Bool? = nil

        for token in tokens {
            let lower = token.lowercased()
            if lower.hasPrefix("spend:>") || lower.hasPrefix("cost:>") {
                let valueStr = token.dropFirst(7).replacingOccurrences(of: "$", with: "")
                if let val = Double(valueStr) { minSpend = val; continue }
            } else if lower.hasPrefix("spend:<") || lower.hasPrefix("cost:<") {
                let valueStr = token.dropFirst(7).replacingOccurrences(of: "$", with: "")
                if let val = Double(valueStr) { maxSpend = val; continue }
            } else if lower.hasPrefix("cache:>") {
                let valueStr = token.dropFirst(7).replacingOccurrences(of: "%", with: "")
                if let val = Double(valueStr) { minCache = val; continue }
            } else if lower.hasPrefix("model:") {
                model = String(token.dropFirst(6))
                continue
            } else if lower.hasPrefix("project:") {
                project = String(token.dropFirst(8))
                continue
            } else if lower == "is:starred" || lower == "starred:true" {
                starred = true
                continue
            }
            cleanedTokens.append(token)
        }

        let cleaned = cleanedTokens.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned, (minSpend, maxSpend, minCache, model, project, starred))
    }
}
