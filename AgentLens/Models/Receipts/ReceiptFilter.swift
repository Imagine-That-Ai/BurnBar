import Foundation

// MARK: - Receipt Grouping Mode

public enum ReceiptGroupingMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case date
    case project
    case provider
    case harness
    case model

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

// MARK: - Filter Modifiers

public struct ReceiptFilterModifiers: Hashable, Sendable {
    public var minSpend: Double?
    public var maxSpend: Double?
    public var minCache: Double?
    public var model: String?
    public var project: String?
    public var starred: Bool?

    public init(
        minSpend: Double? = nil,
        maxSpend: Double? = nil,
        minCache: Double? = nil,
        model: String? = nil,
        project: String? = nil,
        starred: Bool? = nil
    ) {
        self.minSpend = minSpend
        self.maxSpend = maxSpend
        self.minCache = minCache
        self.model = model
        self.project = project
        self.starred = starred
    }
}

// MARK: - Receipt Filter

/// Filter and search criteria for querying the receipt drawer.
public struct ReceiptFilter: Hashable, Sendable {
    public var searchQuery: String = ""
    public var provider: AgentProvider?
    public var harness: String?
    public var projectName: String?
    public var minCost: Double?
    public var maxCost: Double?
    public var minCachePercentage: Double?
    public var isStarredOnly: Bool = false
    public var dateRange: ClosedRange<Date>?
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
    public static func parseSmartQuery(_ input: String) -> (cleanedQuery: String, filterModifiers: ReceiptFilterModifiers) {
        let tokens = input.split(separator: " ").map(String.init)
        var cleanedTokens: [String] = []
        var minSpend: Double?
        var maxSpend: Double?
        var minCache: Double?
        var model: String?
        var project: String?
        var starred: Bool?

        for token in tokens {
            let lower = token.lowercased()
            if lower.hasPrefix("spend:>=") {
                let valueStr = token.dropFirst("spend:>=".count).replacingOccurrences(of: "$", with: "")
                if let val = Double(valueStr) { minSpend = val; continue }
            } else if lower.hasPrefix("cost:>=") {
                let valueStr = token.dropFirst("cost:>=".count).replacingOccurrences(of: "$", with: "")
                if let val = Double(valueStr) { minSpend = val; continue }
            } else if lower.hasPrefix("spend:>") {
                let valueStr = token.dropFirst("spend:>".count).replacingOccurrences(of: "$", with: "")
                if let val = Double(valueStr) { minSpend = val; continue }
            } else if lower.hasPrefix("cost:>") {
                let valueStr = token.dropFirst("cost:>".count).replacingOccurrences(of: "$", with: "")
                if let val = Double(valueStr) { minSpend = val; continue }
            } else if lower.hasPrefix("spend:<=") {
                let valueStr = token.dropFirst("spend:<=".count).replacingOccurrences(of: "$", with: "")
                if let val = Double(valueStr) { maxSpend = val; continue }
            } else if lower.hasPrefix("cost:<=") {
                let valueStr = token.dropFirst("cost:<=".count).replacingOccurrences(of: "$", with: "")
                if let val = Double(valueStr) { maxSpend = val; continue }
            } else if lower.hasPrefix("spend:<") {
                let valueStr = token.dropFirst("spend:<".count).replacingOccurrences(of: "$", with: "")
                if let val = Double(valueStr) { maxSpend = val; continue }
            } else if lower.hasPrefix("cost:<") {
                let valueStr = token.dropFirst("cost:<".count).replacingOccurrences(of: "$", with: "")
                if let val = Double(valueStr) { maxSpend = val; continue }
            } else if lower.hasPrefix("cache:>=") {
                let valueStr = token.dropFirst("cache:>=".count).replacingOccurrences(of: "%", with: "")
                if let val = Double(valueStr) { minCache = val; continue }
            } else if lower.hasPrefix("cache:>") {
                let valueStr = token.dropFirst("cache:>".count).replacingOccurrences(of: "%", with: "")
                if let val = Double(valueStr) { minCache = val; continue }
            } else if lower.hasPrefix("model:") {
                model = String(token.dropFirst("model:".count))
                continue
            } else if lower.hasPrefix("project:") {
                project = String(token.dropFirst("project:".count))
                continue
            } else if lower == "is:starred" || lower == "starred:true" || lower == "has:star" {
                starred = true
                continue
            }
            cleanedTokens.append(token)
        }

        let cleaned = cleanedTokens.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let modifiers = ReceiptFilterModifiers(
            minSpend: minSpend,
            maxSpend: maxSpend,
            minCache: minCache,
            model: model,
            project: project,
            starred: starred
        )
        return (cleaned, modifiers)
    }
}
