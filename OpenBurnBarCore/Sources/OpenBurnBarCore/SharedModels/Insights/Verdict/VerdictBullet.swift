import Foundation

/// One opinionated claim in the verdict.
///
/// Voice contract §3.2 — every bullet must contain ≥1 numeric token and
/// ≥1 citation; the post-processor drops bullets that don't comply.
/// `delta` is rendered as a chip after the claim text; `acceptAction` is
/// the optional reciprocal button at the right edge.
public struct VerdictBullet: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var type: VerdictBulletType
    /// The full claim sentence (≤200 chars). The renderer applies typography;
    /// the string itself is plain text so it round-trips clean across platforms.
    public var claim: String
    /// Session/model/agent/day citations. Required (≥1).
    public var citations: [InsightCitation]
    /// Optional delta chip rendered after the claim.
    public var delta: VerdictDelta?
    /// Optional one-tap follow-through.
    public var acceptAction: VerdictAcceptAction?
    /// Confidence in this individual bullet. The renderer dims low-confidence
    /// bullets and italicizes them per §6.5.
    public var confidence: InsightConfidence

    public init(
        id: UUID = UUID(),
        type: VerdictBulletType,
        claim: String,
        citations: [InsightCitation],
        delta: VerdictDelta? = nil,
        acceptAction: VerdictAcceptAction? = nil,
        confidence: InsightConfidence = .medium
    ) {
        self.id = id
        self.type = type
        self.claim = claim
        self.citations = citations
        self.delta = delta
        self.acceptAction = acceptAction
        self.confidence = confidence
    }
}
