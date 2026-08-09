import Foundation

// MARK: - AI Inbox wire contracts
//
// The AI Inbox is a daemon-resident background analyst. Every ~5 minutes it
// gates on a cheap local change signature, and — only when something actually
// moved — assembles a redacted evidence pack, runs deterministic detectors,
// optionally asks a cheap model to synthesize a brief, adversarially verifies
// each finding, and publishes ranked inbox items.
//
// These types are the ONLY shape that crosses the socket. They are deliberately
// free of raw conversation text: item bodies are already-synthesized,
// already-redacted prose, and evidence entries carry references (conversation
// ids, PR numbers, file paths) rather than transcripts.

/// Item taxonomy. The raw value is persisted, so cases are append-only.
public enum BurnBarInboxItemKind: String, Codable, Hashable, CaseIterable, Sendable {
    /// A workflow/CI pattern that is burning cycles for no signal.
    case ciWaste = "ci_waste"
    /// Work an agent said it would do that never reached `main`.
    case promisedNotLanded = "promised_not_landed"
    /// A dirty worktree whose session has gone quiet.
    case uncommittedWork = "uncommitted_work"
    /// Local commits that never reached the upstream remote.
    case unpushedCommits = "unpushed_commits"
    /// A branch that is on the remote (or has no local ahead) but never opened a PR / never merged.
    case pushedNotMerged = "pushed_not_merged"
    /// Spend that deviates sharply from the trailing baseline.
    case costAnomaly = "cost_anomaly"
    /// An open PR that has stopped moving.
    case stuckPR = "stuck_pr"
    /// The local index itself is stale or degraded.
    case indexHealth = "index_health"
    /// The periodic narrative synthesis ("what has been going on").
    case brief
    /// The daily cost ceiling was reached; synthesis degraded to rules.
    case budget
    /// First-run explainers, capability notices, degradations.
    case system

    public var isAlert: Bool {
        switch self {
        case .brief, .system:
            return false
        case .ciWaste, .promisedNotLanded, .uncommittedWork, .unpushedCommits, .pushedNotMerged,
             .costAnomaly, .stuckPR, .indexHealth, .budget:
            return true
        }
    }
}

/// Lifecycle of an item. `new` and `updated` are the OPEN states — exactly one
/// open item may exist per fingerprint (enforced by a partial unique index), so
/// a recurring condition updates in place instead of flooding the list, while
/// resolved history is preserved for trend reading.
public enum BurnBarInboxItemState: String, Codable, Hashable, CaseIterable, Sendable {
    case new
    case updated
    case resolved
    case expired

    public var isOpen: Bool { self == .new || self == .updated }

    public static var openStates: [BurnBarInboxItemState] { [.new, .updated] }
}

/// Priority band. P1 is the "you would want to be interrupted for this" tier and
/// is the only band permitted to raise a user notification.
public enum BurnBarInboxPriority: Int, Codable, Hashable, CaseIterable, Sendable, Comparable {
    case p1 = 1
    case p2 = 2
    case p3 = 3
    case p4 = 4

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public init(clamping raw: Int) {
        self = BurnBarInboxPriority(rawValue: min(4, max(1, raw))) ?? .p3
    }
}

/// How far conversation-derived text may travel. `off` is the default and is a
/// hard guarantee: detectors and the rule-based brief run entirely on-device and
/// no prompt is ever constructed.
public enum BurnBarInboxEgressMode: String, Codable, Hashable, CaseIterable, Sendable {
    /// No model calls at all. Deterministic detectors + rule-rendered brief.
    case off
    /// Model calls are allowed but only to a loopback/LAN inference endpoint.
    case local
    /// Model calls may reach the configured cloud providers.
    case cloud

    public var allowsModelCalls: Bool { self != .off }
    public var allowsCloudEgress: Bool { self == .cloud }
}

// MARK: - Evidence

/// A single citation backing an item. Evidence is reference-shaped by design:
/// the inbox points at truth rather than copying it, so the UI can deep-link and
/// the payload stays small.
public struct BurnBarInboxEvidence: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Hashable, CaseIterable, Sendable {
        case conversation
        case pullRequest = "pull_request"
        case issue
        case workflowRun = "workflow_run"
        case commit
        case file
        case usage
        case metric
    }

    /// Stable id used for LLM citation validation (`conv:<id>`, `pr:<repo>#<n>`, …).
    public let id: String
    public let kind: Kind
    /// Short human label rendered in the evidence list.
    public let label: String
    /// One-line supporting detail. Already redacted; never raw transcript.
    public let detail: String?
    /// Optional deep link (`openburnbar://…` or `https://…`).
    public let url: String?
    public let occurredAt: Date?

    public init(
        id: String,
        kind: Kind,
        label: String,
        detail: String? = nil,
        url: String? = nil,
        occurredAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.detail = detail
        self.url = url
        self.occurredAt = occurredAt
    }
}

/// A durable fact the inbox believes is worth remembering. It is a *proposal*:
/// approval happens in the app through the existing quarantine flow, and nothing
/// here is ever injected into a prompt until a human says yes.
public struct BurnBarInboxMemoryCandidate: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    /// The fact, in one or two sentences.
    public let text: String
    /// Free-form kind hint (`decision`, `gotcha`, `convention`, …).
    public let kind: String
    public let confidence: Double
    /// Conversation ids that justify the fact; become memory provenance rows.
    public let citationConversationIDs: [String]

    public init(
        id: String,
        text: String,
        kind: String,
        confidence: Double,
        citationConversationIDs: [String]
    ) {
        self.id = id
        self.text = text
        self.kind = kind
        self.confidence = confidence
        self.citationConversationIDs = citationConversationIDs
    }
}

/// A suggested next step. Actions are declarative so the UI decides how to
/// render them and the daemon never reaches into the app.
public struct BurnBarInboxAction: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Hashable, CaseIterable, Sendable {
        case openURL = "open_url"
        case resumeConversation = "resume_conversation"
        case openSessionLog = "open_session_log"
        case openProject = "open_project"
        case openSettings = "open_settings"
        case runCommand = "run_command"
    }

    public let id: String
    public let kind: Kind
    public let title: String
    /// Interpreted per `kind`: a URL, a conversation id, a project id, a
    /// settings anchor, or a copyable (never auto-executed) shell command.
    public let value: String
    public let isPrimary: Bool

    public init(id: String, kind: Kind, title: String, value: String, isPrimary: Bool = false) {
        self.id = id
        self.kind = kind
        self.title = title
        self.value = value
        self.isPrimary = isPrimary
    }
}

/// The structured body of an item. Versioned so the daemon can evolve the shape
/// without breaking an older app that reads the same database file.
public struct BurnBarInboxItemPayload: Codable, Hashable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let evidence: [BurnBarInboxEvidence]
    public let memoryCandidates: [BurnBarInboxMemoryCandidate]
    public let actions: [BurnBarInboxAction]
    /// Deterministic detector metrics (`wasted_minutes`, `failure_rate`, …).
    /// Kept as strings so the payload stays schema-stable across detectors.
    public let metrics: [String: String]
    /// Verifier outcome, when a verification pass ran.
    public let verification: BurnBarInboxVerification?

    public init(
        version: Int = BurnBarInboxItemPayload.currentVersion,
        evidence: [BurnBarInboxEvidence] = [],
        memoryCandidates: [BurnBarInboxMemoryCandidate] = [],
        actions: [BurnBarInboxAction] = [],
        metrics: [String: String] = [:],
        verification: BurnBarInboxVerification? = nil
    ) {
        self.version = version
        self.evidence = evidence
        self.memoryCandidates = memoryCandidates
        self.actions = actions
        self.metrics = metrics
        self.verification = verification
    }
}

/// Result of the adversarial verification pass. `unverified` means no verifier
/// was reachable — surfaced honestly in the UI rather than silently implied.
public struct BurnBarInboxVerification: Codable, Hashable, Sendable {
    public enum Verdict: String, Codable, Hashable, CaseIterable, Sendable {
        case confirmed
        case refuted
        case unclear
        case unverified
        /// Deterministic re-check alone was sufficient (no model call needed).
        case deterministic
    }

    public let verdict: Verdict
    public let reason: String?
    public let checkedAt: Date
    /// `provider:model` of the verifier, when one ran.
    public let verifierModel: String?

    public init(verdict: Verdict, reason: String? = nil, checkedAt: Date, verifierModel: String? = nil) {
        self.verdict = verdict
        self.reason = reason
        self.checkedAt = checkedAt
        self.verifierModel = verifierModel
    }
}

// MARK: - Items

/// List-row shape. Deliberately excludes the payload so the list RPC stays cheap
/// even with hundreds of rows.
public struct BurnBarInboxItemSummary: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let fingerprint: String
    public let kind: BurnBarInboxItemKind
    public let priority: BurnBarInboxPriority
    public let state: BurnBarInboxItemState
    public let title: String
    public let projectID: String?
    public let projectName: String?
    public let occurrenceCount: Int
    public let firstSeenAt: Date
    public let lastSeenAt: Date
    public let resolvedAt: Date?
    public let resolutionNote: String?
    /// `local-rules`, `deepseek:deepseek-v4-flash`, `…+openai:gpt-5.6-luna`.
    public let modelProvenance: String
    public let hasMemoryCandidates: Bool

    public init(
        id: String,
        fingerprint: String,
        kind: BurnBarInboxItemKind,
        priority: BurnBarInboxPriority,
        state: BurnBarInboxItemState,
        title: String,
        projectID: String? = nil,
        projectName: String? = nil,
        occurrenceCount: Int = 1,
        firstSeenAt: Date,
        lastSeenAt: Date,
        resolvedAt: Date? = nil,
        resolutionNote: String? = nil,
        modelProvenance: String = "local-rules",
        hasMemoryCandidates: Bool = false
    ) {
        self.id = id
        self.fingerprint = fingerprint
        self.kind = kind
        self.priority = priority
        self.state = state
        self.title = title
        self.projectID = projectID
        self.projectName = projectName
        self.occurrenceCount = occurrenceCount
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.resolvedAt = resolvedAt
        self.resolutionNote = resolutionNote
        self.modelProvenance = modelProvenance
        self.hasMemoryCandidates = hasMemoryCandidates
    }
}

/// Full item, fetched on selection.
public struct BurnBarInboxItemDetail: Codable, Hashable, Sendable, Identifiable {
    public let summary: BurnBarInboxItemSummary
    /// Markdown body. Short by contract — this is an inbox, not a report.
    public let summaryMarkdown: String
    public let payload: BurnBarInboxItemPayload
    /// Tick that last touched the row; joins to `ai_inbox_runs`.
    public let tickID: String

    public var id: String { summary.id }

    public init(
        summary: BurnBarInboxItemSummary,
        summaryMarkdown: String,
        payload: BurnBarInboxItemPayload,
        tickID: String
    ) {
        self.summary = summary
        self.summaryMarkdown = summaryMarkdown
        self.payload = payload
        self.tickID = tickID
    }
}

// MARK: - Requests / responses

public struct BurnBarInboxListRequest: Codable, Hashable, Sendable {
    public static let defaultLimit = 60
    public static let maxLimit = 300

    public let states: [BurnBarInboxItemState]?
    public let kinds: [BurnBarInboxItemKind]?
    public let projectID: String?
    public let limit: Int
    /// Keyset cursor: return items with `lastSeenAt` strictly before this.
    public let before: Date?

    public init(
        states: [BurnBarInboxItemState]? = nil,
        kinds: [BurnBarInboxItemKind]? = nil,
        projectID: String? = nil,
        limit: Int = BurnBarInboxListRequest.defaultLimit,
        before: Date? = nil
    ) {
        self.states = states
        self.kinds = kinds
        self.projectID = projectID
        self.limit = min(max(1, limit), Self.maxLimit)
        self.before = before
    }

    /// Routes decoding through the clamping initializer.
    ///
    /// Without this, the synthesized `Decodable` conformance would assign
    /// `limit` directly and a caller could send `limit: 999_999_999` over the
    /// socket to force an unbounded scan — the memberwise clamp would never run.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            states: try container.decodeIfPresent([BurnBarInboxItemState].self, forKey: .states),
            kinds: try container.decodeIfPresent([BurnBarInboxItemKind].self, forKey: .kinds),
            projectID: try container.decodeIfPresent(String.self, forKey: .projectID),
            limit: try container.decodeIfPresent(Int.self, forKey: .limit) ?? Self.defaultLimit,
            before: try container.decodeIfPresent(Date.self, forKey: .before)
        )
    }
}

public struct BurnBarInboxListResponse: Codable, Hashable, Sendable {
    public let items: [BurnBarInboxItemSummary]
    public let nextBefore: Date?
    /// Count of open items across ALL pages — drives the badge without a second
    /// round trip.
    public let openCount: Int

    public init(items: [BurnBarInboxItemSummary], nextBefore: Date? = nil, openCount: Int = 0) {
        self.items = items
        self.nextBefore = nextBefore
        self.openCount = openCount
    }
}

public struct BurnBarInboxGetRequest: Codable, Hashable, Sendable {
    public let id: String
    public init(id: String) { self.id = id }
}

public struct BurnBarInboxGetResponse: Codable, Hashable, Sendable {
    public let item: BurnBarInboxItemDetail?
    public init(item: BurnBarInboxItemDetail?) { self.item = item }
}

/// Per-tick telemetry. Every tick writes exactly one row — including skipped
/// ticks — so the settings pane can prove the loop is alive and cheap.
public struct BurnBarInboxRunTelemetry: Codable, Hashable, Sendable, Identifiable {
    public enum GateResult: String, Codable, Hashable, CaseIterable, Sendable {
        case skippedUnchanged = "skipped_unchanged"
        case skippedDisabled = "skipped_disabled"
        case localChanged = "local_changed"
        case remotePhase = "remote_phase"
        case forced
        case failed
    }

    public let tickID: String
    public let startedAt: Date
    public let finishedAt: Date?
    public let gateResult: GateResult
    public let egressMode: BurnBarInboxEgressMode
    public let llmCalls: Int
    public let inputTokens: Int
    public let outputTokens: Int
    public let costUSD: Double
    public let itemsNew: Int
    public let itemsUpdated: Int
    public let itemsResolved: Int
    public let error: String?

    public var id: String { tickID }

    public init(
        tickID: String,
        startedAt: Date,
        finishedAt: Date? = nil,
        gateResult: GateResult,
        egressMode: BurnBarInboxEgressMode,
        llmCalls: Int = 0,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        costUSD: Double = 0,
        itemsNew: Int = 0,
        itemsUpdated: Int = 0,
        itemsResolved: Int = 0,
        error: String? = nil
    ) {
        self.tickID = tickID
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.gateResult = gateResult
        self.egressMode = egressMode
        self.llmCalls = llmCalls
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.costUSD = costUSD
        self.itemsNew = itemsNew
        self.itemsUpdated = itemsUpdated
        self.itemsResolved = itemsResolved
        self.error = error
    }
}

public struct BurnBarInboxRunsRequest: Codable, Hashable, Sendable {
    public let limit: Int
    public init(limit: Int = 20) { self.limit = min(max(1, limit), 200) }

    /// Clamps on decode for the same reason as `BurnBarInboxListRequest`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(limit: try container.decodeIfPresent(Int.self, forKey: .limit) ?? 20)
    }
}

public struct BurnBarInboxRunsResponse: Codable, Hashable, Sendable {
    public let runs: [BurnBarInboxRunTelemetry]
    /// Rolling spend attributed to the inbox over the current budget day.
    public let todaySpendUSD: Double
    public let dailyBudgetUSD: Double
    public init(runs: [BurnBarInboxRunTelemetry], todaySpendUSD: Double = 0, dailyBudgetUSD: Double = 0) {
        self.runs = runs
        self.todaySpendUSD = todaySpendUSD
        self.dailyBudgetUSD = dailyBudgetUSD
    }
}

/// User-controllable configuration. Persisted daemon-side (single writer) and
/// mutated only through `daemon.inbox.config.update`, so the app never has to
/// keep a shadow copy in sync.
/// Cost ↔ performance preset for the AI Inbox analyst/verifier pair.
///
/// The settings cockpit maps these onto concrete provider/model IDs and verifier
/// budgets. Custom model picks leave the stored config outside every preset.
public enum BurnBarInboxSynthesisPreset: String, Codable, Hashable, CaseIterable, Sendable {
    case fast
    case balanced
    case thorough

    public var title: String {
        switch self {
        case .fast: return "Fast"
        case .balanced: return "Balanced"
        case .thorough: return "Thorough"
        }
    }

    public var subtitle: String {
        switch self {
        case .fast:
            return "Flash writes the brief. No verifier — cheapest active tick."
        case .balanced:
            return "Flash + Luna. The designed pair: cheap narrative, independent check."
        case .thorough:
            return "DeepSeek Pro + Luna with more verifier budget. Higher scrutiny, higher spend."
        }
    }

    /// Rough worst-case USD for one active tick at the preset's defaults.
    public var estimatedCostPerActiveTickUSD: Double {
        switch self {
        case .fast: return 0.010
        case .balanced: return 0.016
        case .thorough: return 0.035
        }
    }

    public var analystProviderID: String {
        switch self {
        case .fast, .balanced: return "deepseek"
        case .thorough: return "deepseek"
        }
    }

    public var analystModel: String {
        switch self {
        case .fast, .balanced: return "deepseek-v4-flash"
        case .thorough: return "deepseek-v4-pro"
        }
    }

    public var verifierProviderID: String { "openai" }

    public var verifierModel: String { "gpt-5.6-luna" }

    public var maxVerifierCallsPerTick: Int {
        switch self {
        case .fast: return 0
        case .balanced: return 3
        case .thorough: return 6
        }
    }

    /// Which preset (if any) matches the stored model/verifier fields.
    public static func matching(config: BurnBarInboxConfig) -> BurnBarInboxSynthesisPreset? {
        allCases.first { preset in
            config.analystProviderID == preset.analystProviderID
                && config.analystModel == preset.analystModel
                && config.verifierProviderID == preset.verifierProviderID
                && config.verifierModel == preset.verifierModel
                && config.maxVerifierCallsPerTick == preset.maxVerifierCallsPerTick
        }
    }

    public func applied(to config: BurnBarInboxConfig) -> BurnBarInboxConfig {
        BurnBarInboxConfig(
            enabled: config.enabled,
            egressMode: config.egressMode,
            tickSeconds: config.tickSeconds,
            remotePhaseEveryNTicks: config.remotePhaseEveryNTicks,
            dailyBudgetUSD: config.dailyBudgetUSD,
            maxVerifierCallsPerTick: maxVerifierCallsPerTick,
            perTickPromptTokenCap: config.perTickPromptTokenCap,
            analystProviderID: analystProviderID,
            analystModel: analystModel,
            verifierProviderID: verifierProviderID,
            verifierModel: verifierModel,
            githubEnabled: config.githubEnabled,
            notifyOnP1: config.notifyOnP1,
            lookbackMinutes: config.lookbackMinutes
        )
    }
}

public struct BurnBarInboxConfig: Codable, Hashable, Sendable {
    public static let defaultTickSeconds = 300
    public static let minimumTickSeconds = 60
    public static let maximumTickSeconds = 3600

    /// Master switch. Off by default: the inbox never starts analyzing until
    /// someone opts in.
    public let enabled: Bool
    public let egressMode: BurnBarInboxEgressMode
    public let tickSeconds: Int
    /// GitHub polling runs every Nth tick to respect API budgets.
    public let remotePhaseEveryNTicks: Int
    public let dailyBudgetUSD: Double
    public let maxVerifierCallsPerTick: Int
    public let perTickPromptTokenCap: Int
    public let analystProviderID: String
    public let analystModel: String
    public let verifierProviderID: String
    public let verifierModel: String
    public let githubEnabled: Bool
    public let notifyOnP1: Bool
    /// Conversation lookback for the evidence pack.
    public let lookbackMinutes: Int

    public init(
        enabled: Bool = false,
        egressMode: BurnBarInboxEgressMode = .off,
        tickSeconds: Int = BurnBarInboxConfig.defaultTickSeconds,
        remotePhaseEveryNTicks: Int = 3,
        dailyBudgetUSD: Double = 1.50,
        maxVerifierCallsPerTick: Int = 3,
        perTickPromptTokenCap: Int = 60_000,
        analystProviderID: String = "deepseek",
        analystModel: String = "deepseek-v4-flash",
        verifierProviderID: String = "openai",
        verifierModel: String = "gpt-5.6-luna",
        githubEnabled: Bool = true,
        notifyOnP1: Bool = true,
        lookbackMinutes: Int = 120
    ) {
        self.enabled = enabled
        self.egressMode = egressMode
        self.tickSeconds = min(max(Self.minimumTickSeconds, tickSeconds), Self.maximumTickSeconds)
        self.remotePhaseEveryNTicks = min(max(1, remotePhaseEveryNTicks), 60)
        self.dailyBudgetUSD = max(0, dailyBudgetUSD)
        self.maxVerifierCallsPerTick = min(max(0, maxVerifierCallsPerTick), 25)
        self.perTickPromptTokenCap = min(max(2_000, perTickPromptTokenCap), 500_000)
        self.analystProviderID = analystProviderID
        self.analystModel = analystModel
        self.verifierProviderID = verifierProviderID
        self.verifierModel = verifierModel
        self.githubEnabled = githubEnabled
        self.notifyOnP1 = notifyOnP1
        self.lookbackMinutes = min(max(15, lookbackMinutes), 24 * 60)
    }

    /// Decodes with per-field defaults so a config written by an older daemon
    /// (or a hand-edited row) never fails the whole load.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = BurnBarInboxConfig()
        self.init(
            enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? fallback.enabled,
            egressMode: try container.decodeIfPresent(BurnBarInboxEgressMode.self, forKey: .egressMode)
                ?? fallback.egressMode,
            tickSeconds: try container.decodeIfPresent(Int.self, forKey: .tickSeconds) ?? fallback.tickSeconds,
            remotePhaseEveryNTicks: try container.decodeIfPresent(Int.self, forKey: .remotePhaseEveryNTicks)
                ?? fallback.remotePhaseEveryNTicks,
            dailyBudgetUSD: try container.decodeIfPresent(Double.self, forKey: .dailyBudgetUSD)
                ?? fallback.dailyBudgetUSD,
            maxVerifierCallsPerTick: try container.decodeIfPresent(Int.self, forKey: .maxVerifierCallsPerTick)
                ?? fallback.maxVerifierCallsPerTick,
            perTickPromptTokenCap: try container.decodeIfPresent(Int.self, forKey: .perTickPromptTokenCap)
                ?? fallback.perTickPromptTokenCap,
            analystProviderID: try container.decodeIfPresent(String.self, forKey: .analystProviderID)
                ?? fallback.analystProviderID,
            analystModel: try container.decodeIfPresent(String.self, forKey: .analystModel) ?? fallback.analystModel,
            verifierProviderID: try container.decodeIfPresent(String.self, forKey: .verifierProviderID)
                ?? fallback.verifierProviderID,
            verifierModel: try container.decodeIfPresent(String.self, forKey: .verifierModel)
                ?? fallback.verifierModel,
            githubEnabled: try container.decodeIfPresent(Bool.self, forKey: .githubEnabled) ?? fallback.githubEnabled,
            notifyOnP1: try container.decodeIfPresent(Bool.self, forKey: .notifyOnP1) ?? fallback.notifyOnP1,
            lookbackMinutes: try container.decodeIfPresent(Int.self, forKey: .lookbackMinutes)
                ?? fallback.lookbackMinutes
        )
    }
}

public struct BurnBarInboxRunNowRequest: Codable, Hashable, Sendable {
    /// Bypass the change gate. Used by the settings "Analyze now" button.
    public let force: Bool
    public init(force: Bool = false) { self.force = force }
}

public struct BurnBarInboxRunNowResponse: Codable, Hashable, Sendable {
    public let tickID: String?
    public let accepted: Bool
    public let reason: String?
    public init(tickID: String?, accepted: Bool, reason: String? = nil) {
        self.tickID = tickID
        self.accepted = accepted
        self.reason = reason
    }
}
