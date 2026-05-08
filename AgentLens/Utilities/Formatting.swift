import Foundation

// MARK: - Usage display (dashboard / menu bar)

enum UsageDisplayMode: String, CaseIterable, Identifiable, Hashable {
    case currency
    case tokens

    var id: String { rawValue }

    var label: String {
        switch self {
        case .currency: return "USD"
        case .tokens: return "Tokens"
        }
    }
}

extension Double {
    func formatAsCost() -> String {
        let magnitude = abs(self)
        if magnitude < 1e-9 { return "$0.00" }
        let formatted = magnitude < 0.01
            ? String(format: "$%.4f", magnitude)
            : String(format: "$%.2f", magnitude)
        return self < 0 ? "-\(formatted)" : formatted
    }

    /// Display a 0–1 ratio as a percent. Whole numbers when ≥ 10%, one decimal below.
    /// Returns "—" if the value is not finite.
    func formatAsPercent() -> String {
        guard self.isFinite else { return "—" }
        let pct = self * 100
        if pct >= 10 || pct <= -10 { return String(format: "%.0f%%", pct) }
        if abs(pct) < 0.1 && pct != 0 { return String(format: "%.2f%%", pct) }
        return String(format: "%.1f%%", pct)
    }
}

extension Int {
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
