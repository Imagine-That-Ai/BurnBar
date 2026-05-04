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

// MARK: - Number Formatters

private let costFormatter: NumberFormatter = {
    let f = NumberFormatter()
    f.numberStyle = .currency
    f.currencySymbol = "$"
    f.minimumFractionDigits = 2
    f.maximumFractionDigits = 4
    f.usesGroupingSeparator = true
    return f
}()

private let tokenFormatter: NumberFormatter = {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.usesGroupingSeparator = true
    return f
}()

// MARK: - Double Formatting

public extension Double {
    func formatAsCost() -> String {
        if abs(self) < 1e-9 {
            return "$0.00"
        }
        if self < 0.01 {
            return String(format: "$.4f", self)
        }
        costFormatter.maximumFractionDigits = 2
        return costFormatter.string(from: NSNumber(value: self)) ?? String(format: "$%.2f", self)
    }

    /// Compact cost for tight widget spaces.
    func formatAsCostCompact() -> String {
        if abs(self) < 1e-9 { return "$0" }
        if self < 0.01 { return String(format: "$.4f", self) }
        costFormatter.maximumFractionDigits = 2
        return costFormatter.string(from: NSNumber(value: self)) ?? String(format: "$%.2f", self)
    }
}

// MARK: - Int Formatting

public extension Int {
    /// Session-level and detail views: K / short M.
    func formatAsTokens() -> String {
        if self >= 1_000_000 { return String(format: "%.1fM", Double(self) / 1_000_000) }
        if self >= 1_000 { return String(format: "%.1fK", Double(self) / 1_000) }
        return tokenFormatter.string(from: NSNumber(value: self)) ?? "\(self)"
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
        return tokenFormatter.string(from: NSNumber(value: self)) ?? "\(self)"
    }

    /// Raw comma-separated tokens (no K/M compacting).
    func formatAsTokensRaw() -> String {
        return tokenFormatter.string(from: NSNumber(value: self)) ?? "\(self)"
    }
}
