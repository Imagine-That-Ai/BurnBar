import Foundation

/// Controlled vocabulary the LLM must use when tagging conversations,
/// agents, and models.
///
/// The taxonomy is the contract that makes `agentFocusMatrix`,
/// `modelFocusMatrix`, and `useCaseCluster` widgets stable and comparable
/// across runs. Without it, every LLM call would invent its own labels and
/// week-over-week rollups would drift.
public struct InsightTaxonomy: Codable, Hashable, Sendable {

    /// Allowed "focus" tags — the high-level kinds of work an agent or model
    /// is being used for. Stable; new tags require a schema version bump
    /// so historical widgets keep rendering.
    public let focuses: [String]

    /// Allowed "use case" tags — the kinds of tasks individual conversations
    /// fall into. More granular than focuses.
    public let useCases: [String]

    public init(focuses: [String], useCases: [String]) {
        self.focuses = focuses
        self.useCases = useCases
    }

    /// The default v1 taxonomy used everywhere unless an override is provided.
    public static let `default` = InsightTaxonomy(
        focuses: [
            "code",
            "write",
            "debug",
            "research",
            "refactor",
            "ops",
            "test",
            "review",
            "design",
            "data",
            "doc",
            "explore"
        ],
        useCases: [
            "feature-add",
            "bug-fix",
            "refactor",
            "test-write",
            "doc-write",
            "code-explain",
            "code-review",
            "data-analysis",
            "shell-script",
            "spike",
            "spike-cleanup",
            "infra-change",
            "migration",
            "perf-investigation",
            "security-investigation",
            "third-party-eval",
            "learning"
        ]
    )

    /// Returns whether `tag` is a member of the focus vocabulary.
    public func isKnownFocus(_ tag: String) -> Bool {
        focuses.contains(tag)
    }

    /// Returns whether `tag` is a member of the use-case vocabulary.
    public func isKnownUseCase(_ tag: String) -> Bool {
        useCases.contains(tag)
    }
}
