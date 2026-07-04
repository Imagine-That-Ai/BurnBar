import Foundation

/// How quota percentages and usage are formatted in macOS / mobile UI.
public enum QuotaPercentageDisplayMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case remainingPercent
    case usedPercent
    case absoluteValues
    case fractional

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .remainingPercent: return "Remaining % (e.g., 20%)"
        case .usedPercent: return "Used % (e.g., 80%)"
        case .absoluteValues: return "Absolute values (e.g., 4.0M / 20.0M)"
        case .fractional: return "Decimal fraction (e.g., 0.20)"
        }
    }
}