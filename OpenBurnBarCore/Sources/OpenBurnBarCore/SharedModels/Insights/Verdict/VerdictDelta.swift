import Foundation

/// A signed change against a baseline, rendered as a delta chip
/// ("↓ 28% vs 4-week avg").
///
/// The shape is shared between `VerdictNumber` (the KPI tile) and
/// `VerdictBullet` (the bullet body) so the renderer has one delta-chip
/// component. `value` is signed — negative is good for spend/cost and bad
/// for sessions/cache, so the renderer reads `direction` rather than sign
/// when picking colors.
public struct VerdictDelta: Codable, Hashable, Sendable {

    /// The metric unit. Drives formatter selection in the renderer.
    public enum Unit: String, Codable, Hashable, Sendable, CaseIterable {
        case usd
        case tokens
        case sessions
        case percent = "pct"
        case days
        case milliseconds = "ms"
        case ratio
        case count
    }

    /// Whether a positive change in this metric is "better" or "worse".
    /// The renderer uses this with the sign of `value` to pick green/red.
    public enum Direction: String, Codable, Hashable, Sendable, CaseIterable {
        /// Up is good (sessions, cache hit rate).
        case higherIsBetter
        /// Down is good (spend, latency).
        case lowerIsBetter
        /// Neutral — render as informational, not judgmental.
        case neutral
    }

    /// Signed change. May be negative.
    public var value: Double
    public var unit: Unit
    /// Short human-readable baseline label ("vs 4-week avg", "vs yesterday").
    public var baseline: String
    public var direction: Direction

    public init(
        value: Double,
        unit: Unit,
        baseline: String,
        direction: Direction = .neutral
    ) {
        self.value = value
        self.unit = unit
        self.baseline = baseline
        self.direction = direction
    }

    /// True when the delta should render in the renderer's "positive" tint
    /// (green-ish). False when negative tint or neutral.
    public var isFavorable: Bool {
        switch direction {
        case .higherIsBetter: return value > 0
        case .lowerIsBetter: return value < 0
        case .neutral: return false
        }
    }
}
