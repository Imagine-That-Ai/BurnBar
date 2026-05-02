import Foundation

// MARK: - Usage Display Mode

public enum UsageDisplayMode: String, CaseIterable, Identifiable, Hashable, Sendable {
    case currency
    case tokens

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .currency: return "USD"
        case .tokens: return "Tokens"
        }
    }
}

// MARK: - Double Formatting

public extension Double {
    func formatAsCost() -> String {
        if abs(self) < 1e-9 { return "$0.00" }
        if self < 0.01 { return String(format: "$.4f", self) }
        return String(format: "$%.2f", self)
    }
}

// MARK: - Int Formatting

public extension Int {
    /// Session-level and detail views: K / short M.
    func formatAsTokens() -> String {
        if self >= 1_000_000 { return String(format: "%.1fM", Double(self) / 1_000_000) }
        if self >= 1_000 { return String(format: "%.1fK", Double(self) / 1_000) }
        return "\(self)"
    }

    /// High-volume totals: auto-scale to millions or billions.
    func formatAsTokenVolume() -> String {
        if self >= 1_000_000_000 {
            return String(format: "%.2fB", Double(self) / 1_000_000_000)
        }
        if self >= 1_000_000 {
            return String(format: "%.2fM", Double(self) / 1_000_000)
        }
        if self >= 1_000 {
            return String(format: "%.1fK", Double(self) / 1_000)
        }
        return "\(self)"
    }
}
