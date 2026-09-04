import Foundation

/// The versioned knob set for the usage-memory funnel: Stage-0 salience
/// weights and accept threshold, Stage-2 novelty/duplicate thresholds,
/// Stage-3 decay weights, per-source trust, and retention caps.
///
/// This is durable harness state, not code constants: the app persists the
/// active policy as JSON in `app_state` (key `usage_memory.curation_policy`)
/// and the self-improvement loop tunes ONLY this record, with every change
/// audited (`memory.policy_updated`). Privacy and consent boundaries are
/// deliberately NOT representable here — nothing in this type can widen
/// egress, consent, or the G7 gate.
public struct UsageMemoryCurationPolicy: Codable, Equatable, Sendable {
    /// Bumped on any semantic change to this type's interpretation.
    public var policyVersion: Int
    /// Salts extraction idempotency keys so a prompt change never reprocesses
    /// already-extracted batches under stale instructions.
    public var extractionPromptVersion: String

    public struct SalienceWeights: Codable, Equatable, Sendable {
        /// Question-shaped ask ("how do I …?", trailing "?").
        public var questionShape: Double
        /// Explicit correction markers ("no, I meant …") — the strongest
        /// single-event durable signal a member can emit.
        public var correction: Double
        /// First-person durable statements ("I prefer …", "we use …").
        public var firstPersonDurable: Double
        /// Synthesized repeated-workflow candidates from session mining.
        public var toolWorkflow: Double
        /// Per prior sighting of the same SimHash bucket (caller-supplied).
        public var repetitionPerHit: Double
        /// Ceiling on the repetition contribution.
        public var repetitionCap: Double

        public init(
            questionShape: Double,
            correction: Double,
            firstPersonDurable: Double,
            toolWorkflow: Double,
            repetitionPerHit: Double,
            repetitionCap: Double
        ) {
            self.questionShape = questionShape
            self.correction = correction
            self.firstPersonDurable = firstPersonDurable
            self.toolWorkflow = toolWorkflow
            self.repetitionPerHit = repetitionPerHit
            self.repetitionCap = repetitionCap
        }
    }

    public struct DecayWeights: Codable, Equatable, Sendable {
        public var recency: Double
        public var hits: Double
        public var sourceTrust: Double
        public var corroboration: Double
        public var recencyHalfLifeDays: Double

        public init(
            recency: Double,
            hits: Double,
            sourceTrust: Double,
            corroboration: Double,
            recencyHalfLifeDays: Double
        ) {
            self.recency = recency
            self.hits = hits
            self.sourceTrust = sourceTrust
            self.corroboration = corroboration
            self.recencyHalfLifeDays = recencyHalfLifeDays
        }
    }

    public struct Thresholds: Codable, Equatable, Sendable {
        /// Stage-0: minimum salience hint to become a candidate.
        public var accept: Double
        /// Stage-2: cosine above this ⇒ not novel (drop + corroborate).
        public var novelty: Double
        /// Stage-2: cosine above this ⇒ exact-enough duplicate (supersede).
        public var duplicate: Double
        /// Stage-3: quarantined below this (aged, unused) ⇒ evict.
        public var evict: Double
        /// Stage-3: minimum cluster cosine for promotion.
        public var cluster: Double

        public init(accept: Double, novelty: Double, duplicate: Double, evict: Double, cluster: Double) {
            self.accept = accept
            self.novelty = novelty
            self.duplicate = duplicate
            self.evict = evict
            self.cluster = cluster
        }
    }

    public struct SourceTrust: Codable, Equatable, Sendable {
        public var chat: Double
        public var safariAsk: Double
        public var agentSession: Double

        public init(chat: Double, safariAsk: Double, agentSession: Double) {
            self.chat = chat
            self.safariAsk = safariAsk
            self.agentSession = agentSession
        }

        public func trust(for sourceKind: MemorySourceKind) -> Double {
            switch sourceKind {
            // `agent` is member-authored memory like chat, not a passive usage source.
            case .chat, .code, .agent: chat
            case .safariAsk: safariAsk
            case .agentSession: agentSession
            }
        }
    }

    public struct Caps: Codable, Equatable, Sendable {
        public var candidateTTLDays: Int
        public var maxUsageMemories: Int
        public var quarantineEvictDays: Int

        public init(candidateTTLDays: Int, maxUsageMemories: Int, quarantineEvictDays: Int) {
            self.candidateTTLDays = candidateTTLDays
            self.maxUsageMemories = maxUsageMemories
            self.quarantineEvictDays = quarantineEvictDays
        }
    }

    public var salience: SalienceWeights
    public var decay: DecayWeights
    public var thresholds: Thresholds
    public var sourceTrust: SourceTrust
    public var caps: Caps

    public init(
        policyVersion: Int,
        extractionPromptVersion: String,
        salience: SalienceWeights,
        decay: DecayWeights,
        thresholds: Thresholds,
        sourceTrust: SourceTrust,
        caps: Caps
    ) {
        self.policyVersion = policyVersion
        self.extractionPromptVersion = extractionPromptVersion
        self.salience = salience
        self.decay = decay
        self.thresholds = thresholds
        self.sourceTrust = sourceTrust
        self.caps = caps
    }

    /// Compiled-in defaults; the persisted record starts as a copy of these.
    public static let defaults = UsageMemoryCurationPolicy(
        policyVersion: 1,
        extractionPromptVersion: "usage-extract-v1",
        salience: SalienceWeights(
            questionShape: 0.35,
            correction: 0.50,
            firstPersonDurable: 0.40,
            toolWorkflow: 0.40,
            repetitionPerHit: 0.10,
            repetitionCap: 0.30
        ),
        decay: DecayWeights(
            recency: 0.35,
            hits: 0.25,
            sourceTrust: 0.20,
            corroboration: 0.20,
            recencyHalfLifeDays: 30
        ),
        thresholds: Thresholds(
            accept: 0.25,
            novelty: 0.92,
            duplicate: 0.95,
            evict: 0.15,
            cluster: 0.85
        ),
        sourceTrust: SourceTrust(chat: 1.0, safariAsk: 0.7, agentSession: 0.5),
        caps: Caps(candidateTTLDays: 14, maxUsageMemories: 5000, quarantineEvictDays: 21)
    )
}
