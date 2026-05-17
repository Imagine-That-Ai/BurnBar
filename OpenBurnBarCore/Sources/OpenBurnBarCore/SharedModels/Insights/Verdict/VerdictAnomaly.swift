import Foundation

/// A discrete anomaly surfaced on the verdict hero.
///
/// Surfaced only when the underlying robust z-score (day-of-week normalized)
/// exceeds 2.0 — anything less is filtered out by the executor/rule engine
/// to keep the surface honest. Renderer shows it with a warning tint and a
/// "Investigate" accept action.
public struct VerdictAnomaly: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var label: String
    public var detail: String
    public var occurredAt: Date
    /// Robust z-score against day-of-week baseline. ≥2.0 by construction.
    public var zScore: Double
    /// Sessions that contributed to the anomaly — populated for drill-through.
    public var affectedSessionIDs: [String]
    public var citations: [InsightCitation]
    public var acceptAction: VerdictAcceptAction?

    public init(
        id: UUID = UUID(),
        label: String,
        detail: String,
        occurredAt: Date,
        zScore: Double,
        affectedSessionIDs: [String] = [],
        citations: [InsightCitation] = [],
        acceptAction: VerdictAcceptAction? = nil
    ) {
        self.id = id
        self.label = label
        self.detail = detail
        self.occurredAt = occurredAt
        self.zScore = zScore
        self.affectedSessionIDs = affectedSessionIDs
        self.citations = citations
        self.acceptAction = acceptAction
    }
}
