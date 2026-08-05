import Foundation
import OpenBurnBarEngine

/// A candidate observation, before it becomes an inbox item.
///
/// Findings come from two places and are treated identically downstream:
///   • **Detectors** — deterministic, free, always run. They are the reason the
///     inbox is useful with zero egress.
///   • **The analyst model** — narrative synthesis and cross-signal patterns the
///     detectors were not written to see.
///
/// Every finding carries `evidenceIDs` that must resolve against the pack, which
/// is what makes a model-authored finding falsifiable rather than merely fluent.
struct BurnBarAIInboxFinding: Sendable, Hashable {
    let kind: BurnBarInboxItemKind
    let title: String
    let summaryMarkdown: String
    let priority: BurnBarInboxPriority
    /// 0…1. Detectors report high confidence; the model reports its own.
    let confidence: Double
    let evidenceIDs: [String]
    let projectID: String?
    let projectName: String?
    /// Stable identity of the *condition*. Two ticks observing the same problem
    /// must produce the same fingerprint or the item will duplicate.
    let fingerprint: String
    let metrics: [String: String]
    let actions: [BurnBarInboxAction]
    let memoryCandidates: [BurnBarInboxMemoryCandidate]
    /// Whether an adversarial verification pass should look at this.
    /// Deterministic findings usually do not need one — they are arithmetic.
    let needsVerification: Bool
    /// Set when a deterministic re-check already established the verdict.
    let deterministicVerification: BurnBarInboxVerification?
    let source: Source

    enum Source: String, Sendable, Hashable {
        case detector
        case analyst
    }

    init(
        kind: BurnBarInboxItemKind,
        title: String,
        summaryMarkdown: String,
        priority: BurnBarInboxPriority,
        confidence: Double,
        evidenceIDs: [String],
        projectID: String? = nil,
        projectName: String? = nil,
        fingerprint: String,
        metrics: [String: String] = [:],
        actions: [BurnBarInboxAction] = [],
        memoryCandidates: [BurnBarInboxMemoryCandidate] = [],
        needsVerification: Bool = false,
        deterministicVerification: BurnBarInboxVerification? = nil,
        source: Source
    ) {
        self.kind = kind
        self.title = title
        self.summaryMarkdown = summaryMarkdown
        self.priority = priority
        self.confidence = confidence
        self.evidenceIDs = evidenceIDs
        self.projectID = projectID
        self.projectName = projectName
        self.fingerprint = fingerprint
        self.metrics = metrics
        self.actions = actions
        self.memoryCandidates = memoryCandidates
        self.needsVerification = needsVerification
        self.deterministicVerification = deterministicVerification
        self.source = source
    }

    /// Builds a stable fingerprint. Inputs must be *identity*, never *measurement* —
    /// including a changing number (a failure rate, a cost) would mint a new item
    /// every tick instead of updating the existing one.
    static func fingerprint(kind: BurnBarInboxItemKind, scope: String, subject: String) -> String {
        "\(kind.rawValue):" + BurnBarAIInboxStableHasher.hash([scope, subject])
    }
}
