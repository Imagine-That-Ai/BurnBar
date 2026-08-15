import Foundation

// MARK: - Founder Lens wire contracts (threads, plan ledger, memory export)
//
// DTOs for the v59 Founder Lens surface: fingerprint-keyed reply threads, the
// Founder Plan Ledger, and the app→daemon approved-memory export. Hand-written
// (like every inbox DTO) — the RPC canon records names, it does not generate
// types.
//
// Sovereignty invariants encoded in these shapes:
//   • The analyst/reply model can only PROPOSE (`BurnBarInboxPlanCandidate`);
//     rows exist only after a human-confirmed accept RPC.
//   • Grades and status transitions arrive via explicit RPCs, never inferred.
//   • Exported memory snippets carry provenance and are treated as untrusted
//     data by the daemon (G8-fenced at prompt time).

// MARK: - Threads

public struct BurnBarInboxThreadMessage: Codable, Hashable, Sendable, Identifiable {
    public enum Role: String, Codable, Hashable, Sendable {
        case user
        case assistant
    }

    public let id: String
    public let fingerprint: String
    public let role: Role
    public let bodyMarkdown: String
    /// Structured plan-step proposals the assistant attached to this turn.
    /// Proposals only — nothing durable happens until the user accepts.
    public let planCandidates: [BurnBarInboxPlanCandidate]
    public let modelProvenance: String?
    public let costUSD: Double
    public let createdAt: Date

    public init(
        id: String,
        fingerprint: String,
        role: Role,
        bodyMarkdown: String,
        planCandidates: [BurnBarInboxPlanCandidate] = [],
        modelProvenance: String? = nil,
        costUSD: Double = 0,
        createdAt: Date
    ) {
        self.id = id
        self.fingerprint = fingerprint
        self.role = role
        self.bodyMarkdown = bodyMarkdown
        self.planCandidates = planCandidates
        self.modelProvenance = modelProvenance
        self.costUSD = costUSD
        self.createdAt = createdAt
    }
}

public struct BurnBarInboxThread: Codable, Hashable, Sendable {
    public let fingerprint: String
    /// Soft bind to the most recent item row for this condition (L1: threads
    /// survive item resolve/reopen churn).
    public let itemID: String?
    public let createdAt: Date
    public let updatedAt: Date
    public let turnCount: Int
    public let totalCostUSD: Double
    public let messages: [BurnBarInboxThreadMessage]

    public init(
        fingerprint: String,
        itemID: String?,
        createdAt: Date,
        updatedAt: Date,
        turnCount: Int,
        totalCostUSD: Double,
        messages: [BurnBarInboxThreadMessage]
    ) {
        self.fingerprint = fingerprint
        self.itemID = itemID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.turnCount = turnCount
        self.totalCostUSD = totalCostUSD
        self.messages = messages
    }
}

public struct BurnBarInboxThreadGetRequest: Codable, Hashable, Sendable {
    public let fingerprint: String
    public init(fingerprint: String) { self.fingerprint = fingerprint }
}

public struct BurnBarInboxThreadGetResponse: Codable, Hashable, Sendable {
    public let thread: BurnBarInboxThread?
    public init(thread: BurnBarInboxThread?) { self.thread = thread }
}

public struct BurnBarInboxReplyRequest: Codable, Hashable, Sendable {
    public let fingerprint: String
    /// The user's message. Untrusted at prompt time like everything else.
    ///
    /// May also carry a `BurnBarInboxReplyDirective` token (see that type) when
    /// the user pressed "explain this differently" instead of typing. The token
    /// travels in this field on purpose: re-explaining an item is a reply turn,
    /// not a new capability, so it needs no new RPC method, no contract-canon
    /// entry, and no second budget/egress gate to keep in sync.
    public let bodyMarkdown: String
    public init(fingerprint: String, bodyMarkdown: String) {
        self.fingerprint = fingerprint
        self.bodyMarkdown = bodyMarkdown
    }

    /// Builds the request for a one-tap "explain this differently" turn.
    public init(fingerprint: String, directive: BurnBarInboxReplyDirective, followUp: String = "") {
        self.fingerprint = fingerprint
        self.bodyMarkdown = directive.encodedBody(followUp: followUp)
    }
}

/// A structured "say that differently" request the app can send as a reply body.
///
/// Why a token in the existing body rather than a new RPC: a reply already
/// carries every gate this needs (feature switches, egress, per-reply budget,
/// thread persistence, redaction). A new method would duplicate all of them,
/// and the duplicate is where they drift apart.
///
/// The token is recognized ONLY at the very start of the body. Anything else —
/// including the same text quoted inside a sentence — is an ordinary user turn,
/// so untrusted item text can never smuggle a directive into the prompt.
public enum BurnBarInboxReplyDirective: String, Codable, Hashable, CaseIterable, Sendable {
    /// Re-explain in short, jargon-free, everyday words.
    case plainEnglish = "plain_english"
    /// Re-explain for a peer who shares the context.
    case professional
    /// Re-explain assuming deep familiarity with the internals.
    case expert
    /// Same register, less of it.
    case shorter
    /// Same register, more mechanism and consequence.
    case deeper

    /// Wire marker. Namespaced and punctuation-heavy so ordinary prose cannot
    /// collide with it by accident.
    public static let bodyPrefix = "@burnbar/rewrite:"

    /// The register this directive asks for, when it names one.
    public var register: BurnBarInboxBriefRegister? {
        switch self {
        case .plainEnglish: return .plainEnglish
        case .professional: return .professional
        case .expert: return .expert
        case .shorter, .deeper: return nil
        }
    }

    /// The depth this directive asks for, when it names one.
    public var detail: BurnBarInboxBriefDetail? {
        switch self {
        case .shorter: return .brief
        case .deeper: return .deep
        case .plainEnglish, .professional, .expert: return nil
        }
    }

    /// What the thread shows as the user's turn. A stored `@burnbar/rewrite:`
    /// token would read as a leaked implementation detail; this reads as the
    /// sentence the user would have typed.
    public var userTurnMarkdown: String {
        switch self {
        case .plainEnglish: return "Explain this again in plain English — short, no jargon."
        case .professional: return "Explain this again the way you would to a colleague on this project."
        case .expert: return "Explain this again at expert depth — assume I know the internals."
        case .shorter: return "Say that again, shorter."
        case .deeper: return "Go deeper on this — mechanism and consequences."
        }
    }

    /// Encodes the directive (plus optional free text) into a reply body.
    public func encodedBody(followUp: String = "") -> String {
        let trimmed = followUp.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = Self.bodyPrefix + rawValue
        return trimmed.isEmpty ? token : token + " " + trimmed
    }

    /// Splits a reply body into its directive and whatever the user typed after
    /// it. Returns nil for an ordinary reply, which is the common case.
    public static func parse(body: String) -> (directive: BurnBarInboxReplyDirective, followUp: String)? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(bodyPrefix) else { return nil }
        let remainder = trimmed.dropFirst(bodyPrefix.count)
        let token = remainder.prefix { $0.isWhitespace == false }
        guard let directive = BurnBarInboxReplyDirective(rawValue: String(token).lowercased()) else { return nil }
        let followUp = String(remainder.dropFirst(token.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return (directive, followUp)
    }
}

public struct BurnBarInboxReplyResponse: Codable, Hashable, Sendable {
    /// The assistant turn, when one was produced.
    public let message: BurnBarInboxThreadMessage?
    /// Set when the reply was refused (budget, egress, disabled) — the UI
    /// renders this instead of a fake answer.
    public let refusalReason: String?
    public init(message: BurnBarInboxThreadMessage?, refusalReason: String? = nil) {
        self.message = message
        self.refusalReason = refusalReason
    }
}

// MARK: - Plan ledger

public enum BurnBarInboxPlanHorizon: String, Codable, Hashable, CaseIterable, Sendable {
    case week
    case month
    case quarter
    case ongoing
}

public enum BurnBarInboxPlanStatus: String, Codable, Hashable, CaseIterable, Sendable {
    case proposed
    case active
    case paused
    case completed
    case killed
}

public enum BurnBarInboxPlanStepStatus: String, Codable, Hashable, CaseIterable, Sendable {
    case proposed
    case accepted
    case inProgress = "in_progress"
    case landed
    case failed
    case killed
}

/// A model-authored plan-step proposal. Never written to the ledger directly —
/// the user accepts it (with edits) through `daemon.inbox.plans.accept`.
public struct BurnBarInboxPlanCandidate: Codable, Hashable, Sendable {
    public let title: String
    public let bodyMarkdown: String
    public let horizon: BurnBarInboxPlanHorizon
    /// Evidence ids from the pack that motivated this proposal.
    public let evidenceIDs: [String]
    /// When set, proposes a step on an existing plan instead of a new one.
    public let planID: String?

    public init(
        title: String,
        bodyMarkdown: String,
        horizon: BurnBarInboxPlanHorizon = .week,
        evidenceIDs: [String] = [],
        planID: String? = nil
    ) {
        self.title = title
        self.bodyMarkdown = bodyMarkdown
        self.horizon = horizon
        self.evidenceIDs = evidenceIDs
        self.planID = planID
    }
}

public struct BurnBarInboxPlanStep: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let planID: String
    public let parentStepID: String?
    public let ordinal: Int
    public let title: String
    public let bodyMarkdown: String
    public let status: BurnBarInboxPlanStepStatus
    public let nextMoveMarkdown: String?
    public let evidenceIDs: [String]
    public let missionID: String?
    public let followupID: String?
    public let inboxFingerprint: String?
    /// 0–100 when graded.
    public let grade: Int?
    public let gradeNoteMarkdown: String?
    public let gradedAt: Date?
    public let createdAt: Date
    public let updatedAt: Date
    public let completedAt: Date?

    public init(
        id: String,
        planID: String,
        parentStepID: String? = nil,
        ordinal: Int,
        title: String,
        bodyMarkdown: String,
        status: BurnBarInboxPlanStepStatus,
        nextMoveMarkdown: String? = nil,
        evidenceIDs: [String] = [],
        missionID: String? = nil,
        followupID: String? = nil,
        inboxFingerprint: String? = nil,
        grade: Int? = nil,
        gradeNoteMarkdown: String? = nil,
        gradedAt: Date? = nil,
        createdAt: Date,
        updatedAt: Date,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.planID = planID
        self.parentStepID = parentStepID
        self.ordinal = ordinal
        self.title = title
        self.bodyMarkdown = bodyMarkdown
        self.status = status
        self.nextMoveMarkdown = nextMoveMarkdown
        self.evidenceIDs = evidenceIDs
        self.missionID = missionID
        self.followupID = followupID
        self.inboxFingerprint = inboxFingerprint
        self.grade = grade
        self.gradeNoteMarkdown = gradeNoteMarkdown
        self.gradedAt = gradedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
    }
}

public struct BurnBarInboxPlan: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let horizon: BurnBarInboxPlanHorizon
    /// Which judgment pack owns this plan's voice ("engOps" / "productStrategy").
    public let pack: String
    public let status: BurnBarInboxPlanStatus
    public let summaryMarkdown: String
    public let createdAt: Date
    public let updatedAt: Date
    public let originFingerprint: String?
    public let memoryID: String?
    public let pensieveVectorID: String?
    public let gradeAverage: Double?
    public let steps: [BurnBarInboxPlanStep]

    public init(
        id: String,
        title: String,
        horizon: BurnBarInboxPlanHorizon,
        pack: String,
        status: BurnBarInboxPlanStatus,
        summaryMarkdown: String,
        createdAt: Date,
        updatedAt: Date,
        originFingerprint: String? = nil,
        memoryID: String? = nil,
        pensieveVectorID: String? = nil,
        gradeAverage: Double? = nil,
        steps: [BurnBarInboxPlanStep] = []
    ) {
        self.id = id
        self.title = title
        self.horizon = horizon
        self.pack = pack
        self.status = status
        self.summaryMarkdown = summaryMarkdown
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.originFingerprint = originFingerprint
        self.memoryID = memoryID
        self.pensieveVectorID = pensieveVectorID
        self.gradeAverage = gradeAverage
        self.steps = steps
    }
}

public struct BurnBarInboxPlansListRequest: Codable, Hashable, Sendable {
    /// Filter to these statuses; empty means "active + proposed".
    public let statuses: [BurnBarInboxPlanStatus]
    public let limit: Int
    public init(statuses: [BurnBarInboxPlanStatus] = [], limit: Int = 50) {
        self.statuses = statuses
        self.limit = min(max(1, limit), 200)
    }

    /// Wire decoding routes through the clamping initializer — synthesized
    /// Decodable would assign the raw JSON value and let an RPC peer request
    /// an unbounded list (each returned plan costs a separate step query).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            statuses: try container.decodeIfPresent([BurnBarInboxPlanStatus].self, forKey: .statuses) ?? [],
            limit: try container.decodeIfPresent(Int.self, forKey: .limit) ?? 50
        )
    }

    private enum CodingKeys: String, CodingKey {
        case statuses
        case limit
    }
}

public struct BurnBarInboxPlansListResponse: Codable, Hashable, Sendable {
    public let plans: [BurnBarInboxPlan]
    public init(plans: [BurnBarInboxPlan]) { self.plans = plans }
}

public struct BurnBarInboxPlanGetRequest: Codable, Hashable, Sendable {
    public let id: String
    public init(id: String) { self.id = id }
}

public struct BurnBarInboxPlanGetResponse: Codable, Hashable, Sendable {
    public let plan: BurnBarInboxPlan?
    public init(plan: BurnBarInboxPlan?) { self.plan = plan }
}

/// The human-confirmed accept. Carries the (possibly user-edited) candidate;
/// creates a plan when `planID` is nil, otherwise appends a step.
public struct BurnBarInboxPlanAcceptRequest: Codable, Hashable, Sendable {
    public let candidate: BurnBarInboxPlanCandidate
    /// The judgment pack owning this plan's voice. Validated server-side.
    public let pack: String
    public init(candidate: BurnBarInboxPlanCandidate, pack: String = "engOps") {
        self.candidate = candidate
        self.pack = pack
    }
}

public struct BurnBarInboxPlanAcceptResponse: Codable, Hashable, Sendable {
    public let plan: BurnBarInboxPlan
    public let step: BurnBarInboxPlanStep
    public init(plan: BurnBarInboxPlan, step: BurnBarInboxPlanStep) {
        self.plan = plan
        self.step = step
    }
}

public struct BurnBarInboxPlanUpdateStepRequest: Codable, Hashable, Sendable {
    public let stepID: String
    public let status: BurnBarInboxPlanStepStatus?
    public let missionID: String?
    public let followupID: String?
    public init(
        stepID: String,
        status: BurnBarInboxPlanStepStatus? = nil,
        missionID: String? = nil,
        followupID: String? = nil
    ) {
        self.stepID = stepID
        self.status = status
        self.missionID = missionID
        self.followupID = followupID
    }
}

public struct BurnBarInboxPlanUpdateStepResponse: Codable, Hashable, Sendable {
    public let step: BurnBarInboxPlanStep
    public init(step: BurnBarInboxPlanStep) { self.step = step }
}

public struct BurnBarInboxPlanGradeRequest: Codable, Hashable, Sendable {
    public let stepID: String
    /// 0–100. Clamped server-side.
    public let grade: Int
    public let noteMarkdown: String?
    public init(stepID: String, grade: Int, noteMarkdown: String? = nil) {
        self.stepID = stepID
        self.grade = grade
        self.noteMarkdown = noteMarkdown
    }
}

public struct BurnBarInboxPlanGradeResponse: Codable, Hashable, Sendable {
    public let step: BurnBarInboxPlanStep
    public let planGradeAverage: Double?
    public init(step: BurnBarInboxPlanStep, planGradeAverage: Double?) {
        self.step = step
        self.planGradeAverage = planGradeAverage
    }
}

// MARK: - Memory export (app → daemon)

public struct BurnBarInboxMemoryExportEntry: Codable, Hashable, Sendable {
    public let memoryID: String
    /// e.g. "ai-inbox:plan:plan_abc:step:step_1"
    public let provenance: String
    public let snippetMarkdown: String
    public let approvedAt: Date
    public init(memoryID: String, provenance: String, snippetMarkdown: String, approvedAt: Date) {
        self.memoryID = memoryID
        self.provenance = provenance
        self.snippetMarkdown = snippetMarkdown
        self.approvedAt = approvedAt
    }
}

/// Full-set replacement: the app pushes every currently-approved inbox-scoped
/// snippet each time, so revocations propagate by omission.
public struct BurnBarInboxMemoryExportRequest: Codable, Hashable, Sendable {
    public let entries: [BurnBarInboxMemoryExportEntry]
    public init(entries: [BurnBarInboxMemoryExportEntry]) { self.entries = entries }
}

public struct BurnBarInboxMemoryExportResponse: Codable, Hashable, Sendable {
    public let stored: Int
    public init(stored: Int) { self.stored = stored }
}
