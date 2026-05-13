import Foundation

/// A drill-down anchor a widget can attach to its narrative so the user can
/// click "show me" and land on the underlying evidence.
///
/// Citations are opaque to the LLM by design — it produces them, but never
/// needs to know the storage layout. The shell layer resolves each citation
/// against its data source.
public struct InsightCitation: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let kind: Kind
    /// Short human-readable label rendered as a chip ("session #abc",
    /// "Aug 14 spike", "Claude Sonnet 4.6").
    public let label: String

    public init(id: UUID = UUID(), kind: Kind, label: String) {
        self.id = id
        self.kind = kind
        self.label = label
    }

    public enum Kind: Codable, Hashable, Sendable {
        /// A specific conversation/session.
        case session(id: String, provider: String?)
        /// A specific model — clicking opens the model breakdown.
        case model(id: String)
        /// A specific agent provider — clicking filters by it.
        case agent(provider: String)
        /// A specific project name.
        case project(name: String)
        /// A specific day in user-local time, midnight-anchored ISO-8601.
        case day(date: String)
        /// A specific anomaly id produced by the local executor.
        case anomaly(id: String)
        /// A free-form search query.
        case query(text: String)
        /// A specific quota bucket on a provider.
        case quota(provider: String, bucket: String)
    }
}
