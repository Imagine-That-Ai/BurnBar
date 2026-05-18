import Foundation

/// One of the three Activity-style rings on the verdict hero.
///
/// The verdict surface always renders exactly three rings (spend, cache,
/// sessions) so the user's eye learns the layout. The schema enforces
/// this in `InsightVerdict.init` by requiring `rings.count == 3`.
/// The order is canonical: spend, cache, sessions.
public struct VerdictRing: Codable, Hashable, Sendable, Identifiable {

    public enum Identity: String, Codable, Hashable, Sendable, CaseIterable {
        /// $ spent today / configured budget.
        case spend
        /// Cache hit rate / target (default 85%).
        case cache
        /// Sessions logged today / typical day baseline.
        case sessions
    }

    public var id: Identity { identity }
    public var identity: Identity
    /// Short label ("Spend", "Cache", "Sessions").
    public var label: String
    /// Current value in the metric's natural unit.
    public var current: Double
    /// Target value the ring closes at.
    public var target: Double
    public var unit: VerdictDelta.Unit
    /// Human-readable "value/target" rendered under the ring.
    public var valueLabel: String
    /// Optional delta vs prior period for the bottom-of-ring chip.
    public var delta: VerdictDelta?
    /// Tint identity for the ring stroke. Independent of the verdict-wide
    /// `moodSwatch` so each ring can reflect its own provider mix
    /// (e.g. cache ring tinted by the dominant cached provider).
    public var tint: ProviderTint

    public init(
        identity: Identity,
        label: String,
        current: Double,
        target: Double,
        unit: VerdictDelta.Unit,
        valueLabel: String,
        delta: VerdictDelta? = nil,
        tint: ProviderTint = .neutral
    ) {
        self.identity = identity
        self.label = label
        self.current = current
        self.target = target
        self.unit = unit
        self.valueLabel = valueLabel
        self.delta = delta
        self.tint = tint
    }

    /// Clamped progress in [0, 1.5]. The renderer wraps past 1.0 visually
    /// (Activity-app behavior) so over-target reads stay legible.
    public var progress: Double {
        guard target > 0 else { return 0 }
        return max(0, min(current / target, 1.5))
    }

    /// True when current is within 10% of target — drives a subtle pulse
    /// animation on the spend ring when near cap.
    public var isNearCap: Bool {
        guard target > 0 else { return false }
        let p = current / target
        return p >= 0.9 && p < 1.05
    }
}
