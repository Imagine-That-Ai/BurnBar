import Foundation

/// The shape of a single verdict bullet.
///
/// The renderer reads this to pick the right glyph and tone:
/// `reflective_fact` is a calm gray stat; `recommendation` gets a primary
/// accept button; `anomaly` gets a warning tint. The post-processor uses
/// the type to enforce shape rules (e.g. a `recommendation` must carry an
/// `acceptAction`).
public enum VerdictBulletType: String, Codable, Hashable, Sendable, CaseIterable {
    /// "You spent $4.12 yesterday." Single observation.
    case reflectiveFact = "reflective_fact"
    /// "Spend is 28% under your 4-week average." Anchored to a baseline.
    case comparison
    /// "53% of your Sonnet calls were under 500 input tokens."
    case pattern
    /// "Cache hit dropped from 89→62% on Thursday." Surface only when z>2.
    case anomaly
    /// "Switch default to Haiku — saves $14/week." Requires acceptAction.
    case recommendation
    /// "Your local Pi handled 38% of insights this month." Identity moment.
    case discovery
    /// "At this pace you'll hit your Anthropic quota Tuesday afternoon."
    case forecast
    /// "You shipped your 1,000th Claude session today."
    case achievement
    /// "You've been pasting near-secrets 4 times this week."
    case risk
    /// "Late-night Tuesday is your peak coding hour." Narrative thread.
    case story
}
