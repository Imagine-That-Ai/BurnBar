import Foundation

/// The single surfaced recommendation on the verdict hero.
///
/// Surfaced only when:
/// 1. the user has ≥60 days of data (trust threshold §3.9),
/// 2. the rule engine or LLM produced a recommendation that comes with a
///    concrete `acceptAction`, and
/// 3. the expected impact crosses a meaningful floor (≥$1/week, ≥5
///    sessions, or a security/privacy classifier).
///
/// "Per push: one accept-action" — the recommendation always renders its
/// accept button right-aligned with the body so the user gains agency
/// every time the recommendation is shown.
public struct VerdictRecommendation: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var headline: String
    public var rationale: String
    /// Short impact phrase ("saves ~$14/week", "closes 3 anomalies").
    public var expectedImpact: String
    public var acceptAction: VerdictAcceptAction
    public var citations: [InsightCitation]
    public var confidence: InsightConfidence

    public init(
        id: UUID = UUID(),
        headline: String,
        rationale: String,
        expectedImpact: String,
        acceptAction: VerdictAcceptAction,
        citations: [InsightCitation],
        confidence: InsightConfidence = .medium
    ) {
        self.id = id
        self.headline = headline
        self.rationale = rationale
        self.expectedImpact = expectedImpact
        self.acceptAction = acceptAction
        self.citations = citations
        self.confidence = confidence
    }
}
