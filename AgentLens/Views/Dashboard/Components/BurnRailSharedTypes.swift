import Foundation

// MARK: - Shared types

enum BurnRailViewMode: String, CaseIterable, Identifiable {
    case agents, models
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var systemImage: String {
        switch self {
        case .agents: return "sparkles"
        case .models: return "cube.transparent"
        }
    }
}

enum BurnRailUnit: String, CaseIterable, Identifiable {
    case tokens, cost
    var id: String { rawValue }
    var glyph: String {
        switch self {
        case .tokens: return "number"
        case .cost:   return "dollarsign"
        }
    }
    var label: String {
        switch self {
        case .tokens: return "Tokens"
        case .cost:   return "Cost"
        }
    }
}

enum BurnRailSearchScope: String, CaseIterable, Identifiable {
    case all, sessions, projects, models
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all:       return "All"
        case .sessions:  return "Sessions"
        case .projects:  return "Projects"
        case .models:    return "Models"
        }
    }
    var systemImage: String {
        switch self {
        case .all:       return "sparkle.magnifyingglass"
        case .sessions:  return "bubble.left.and.bubble.right"
        case .projects:  return "folder"
        case .models:    return "cube"
        }
    }
    /// Compose a query that prefixes the search with the scope token.
    func qualify(_ query: String) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard self != .all else { return trimmed }
        return "in:\(rawValue) \(trimmed)"
    }
}

struct BurnRailTelemetry {
    var headlineValue: String   // e.g. "1.79B" or "$284.12"
    var headlineSuffix: String? // e.g. "tok"
    var deltaPercent: Double?   // signed vs. previous period
    var sparkline: [Double]     // 0...1 normalized
    var isLive: Bool
}
