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
    /// Compact human-readable format used by chart studio / quota chips:
    /// 1234 → "1.2K", 1_234_567 → "1.2M", 1.5e9 → "1.5B".
    /// `maxFractions` caps decimal precision (default 1).
    func humanReadableNumber(maxFractions: Int = 1) -> String {
        let magnitude = abs(self)
        let formatter: (Double, String) -> String = { value, suffix in
            let format = "%.\(max(0, maxFractions))f"
            let rendered = String(format: format, value)
            // Strip trailing ".0" / "0" so 1.0K becomes 1K.
            if rendered.contains(".") {
                let trimmed = rendered.replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
                let cleaned = trimmed.hasSuffix(".") ? String(trimmed.dropLast()) : trimmed
                return cleaned + suffix
            }
            return rendered + suffix
        }
        let sign = self < 0 ? "-" : ""
        if magnitude >= 1_000_000_000 { return sign + formatter(magnitude / 1_000_000_000, "B") }
        if magnitude >= 1_000_000 { return sign + formatter(magnitude / 1_000_000, "M") }
        if magnitude >= 1_000 { return sign + formatter(magnitude / 1_000, "K") }
        if magnitude >= 1 { return sign + formatter(magnitude, "") }
        // Sub-unit: render with extra precision so 0.42 doesn't render as "".
        return sign + String(format: "%.\(max(maxFractions, 2))f", magnitude)
    }

    func formatAsCost() -> String {
        let magnitude = abs(self)
        if magnitude < 1e-9 {
            return "$0.00"
        }
        let formatted: String
        if magnitude < 0.01 {
            formatted = String(format: "$%.4f", magnitude)
        } else {
            costFormatter.maximumFractionDigits = 2
            formatted = costFormatter.string(from: NSNumber(value: magnitude)) ?? String(format: "$%.2f", magnitude)
        }
        return self < 0 ? "-\(formatted)" : formatted
    }

    /// Compact cost for tight widget spaces.
    func formatAsCostCompact() -> String {
        let magnitude = abs(self)
        if magnitude < 1e-9 { return "$0" }
        let formatted: String
        if magnitude < 0.01 {
            formatted = String(format: "$%.4f", magnitude)
        } else {
            costFormatter.maximumFractionDigits = 2
            formatted = costFormatter.string(from: NSNumber(value: magnitude)) ?? String(format: "$%.2f", magnitude)
        }
        return self < 0 ? "-\(formatted)" : formatted
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
