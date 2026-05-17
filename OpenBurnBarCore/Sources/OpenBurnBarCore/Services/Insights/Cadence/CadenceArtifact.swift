import Foundation

/// A rendered artifact produced by the cadence stack.
///
/// Each artifact carries its provenance, the verdict that authored it,
/// and the raw rendered payload so the platform shell can decide how
/// to deliver it (push, in-tab pin, email, share).
public struct CadenceArtifact: Sendable, Identifiable {
    public let id: UUID
    public let cadence: Cadence
    public let verdict: InsightVerdict
    public let renderedAt: Date
    public let payload: Payload
    public let provenance: InsightModelTag

    public enum Cadence: String, Codable, Sendable, CaseIterable {
        case daily = "daily"
        case weekly = "weekly"
        case monthly = "monthly"
        case annual = "annual"
        case anomaly = "anomaly"
        case milestone = "milestone"
    }

    public enum Payload: Sendable {
        case inTab(InsightVerdict)
        case push(title: String, body: String, deepLink: String?)
        case email(subject: String, htmlBody: String)
        case png(Data)
        case pdf(Data)
        case mp4(Data)
    }

    public init(
        id: UUID = UUID(),
        cadence: Cadence,
        verdict: InsightVerdict,
        renderedAt: Date = Date(),
        payload: Payload,
        provenance: InsightModelTag
    ) {
        self.id = id
        self.cadence = cadence
        self.verdict = verdict
        self.renderedAt = renderedAt
        self.payload = payload
        self.provenance = provenance
    }
}
