import Foundation
import OpenBurnBarKernel

/// Daemon-owned entitlement decision for Safari continuous learning.
///
/// The server resolves this from the canonical membership snapshot. Keeping the
/// decision injectable makes the coordinator independently testable and avoids
/// teaching the persistence layer how membership caches are represented.
public struct SafariLearningEligibility: Sendable, Equatable {
    public let tier: String
    public let isEligible: Bool
    public let hostedProfileSyncAllowed: Bool

    public init(
        tier: String,
        isEligible: Bool,
        hostedProfileSyncAllowed: Bool = false
    ) {
        self.tier = tier.trimmingCharacters(in: .whitespacesAndNewlines)
        self.isEligible = isEligible
        self.hostedProfileSyncAllowed = hostedProfileSyncAllowed
    }

    /// Conservative convenience for callers that already trust a membership
    /// tier string. Unknown tiers remain ineligible.
    public static func canonical(tier rawTier: String) -> Self {
        let tier = rawTier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        switch tier {
        case "pro", "burnbar_pro":
            return Self(tier: rawTier, isEligible: true)
        case "pro_max", "promax", "burnbar_pro_max":
            return Self(tier: rawTier, isEligible: true)
        case "ultra", "burnbar_ultra":
            return Self(tier: rawTier, isEligible: true, hostedProfileSyncAllowed: true)
        default:
            return Self(tier: rawTier.isEmpty ? "free" : rawTier, isEligible: false)
        }
    }
}

public struct SafariLearningReviewContext: Codable, Sendable, Equatable {
    public let trigger: BurnBarSafariLearningTrigger
    public let actionCount: Int
    public let sourceOrigin: String
    public let sourceTitle: String
    public let wrappedEvidence: String
    public let existingEntriesOverview: [String]
    public let recentRefinements: [String]

    public init(
        trigger: BurnBarSafariLearningTrigger,
        actionCount: Int,
        sourceOrigin: String,
        sourceTitle: String,
        wrappedEvidence: String,
        existingEntriesOverview: [String],
        recentRefinements: [String]
    ) {
        self.trigger = trigger
        self.actionCount = actionCount
        self.sourceOrigin = sourceOrigin
        self.sourceTitle = sourceTitle
        self.wrappedEvidence = wrappedEvidence
        self.existingEntriesOverview = existingEntriesOverview
        self.recentRefinements = recentRefinements
    }
}

public enum SafariLearningReviewAction: String, Codable, CaseIterable, Sendable {
    case create
    case update
    case delete
}

/// Strict reviewer result. The coordinator accepts exactly these six JSON keys
/// and rejects unknown or missing fields before any durable write.
public struct SafariLearningReviewOutput: Codable, Sendable, Equatable {
    public let action: SafariLearningReviewAction
    public let kind: String
    public let title: String
    public let content: String
    public let reason: String
    public let expectedOutcome: String

    public init(
        action: SafariLearningReviewAction,
        kind: String,
        title: String,
        content: String,
        reason: String,
        expectedOutcome: String
    ) {
        self.action = action
        self.kind = kind
        self.title = title
        self.content = content
        self.reason = reason
        self.expectedOutcome = expectedOutcome
    }
}

public struct SafariLearningRecallEntry: Sendable, Equatable {
    public let id: String
    public let text: String
    public let proposalID: String?

    public init(id: String, text: String, proposalID: String? = nil) {
        self.id = id
        self.text = text
        self.proposalID = proposalID
    }
}

public enum SafariLearningSkillUsageEvent: String, Codable, CaseIterable, Sendable {
    case use
    case view
    case patch
}

public enum SafariLearningSkillLifecycle: String, Codable, CaseIterable, Sendable {
    case active
    case stale
    case archived
    case quarantined
}

public struct SafariLearningSkillUsage: Codable, Sendable, Equatable {
    public var useCount: Int
    public var viewCount: Int
    public var patchCount: Int
    public var lastUsedAt: Date?
    public var updatedAt: Date

    public init(
        useCount: Int = 0,
        viewCount: Int = 0,
        patchCount: Int = 0,
        lastUsedAt: Date? = nil,
        updatedAt: Date
    ) {
        self.useCount = useCount
        self.viewCount = viewCount
        self.patchCount = patchCount
        self.lastUsedAt = lastUsedAt
        self.updatedAt = updatedAt
    }
}

public struct SafariLearningAvailability: Sendable, Equatable {
    public let available: Bool
    public let optedIn: Bool
    public let tier: String
    public let hostedProfileSyncAllowed: Bool

    public init(
        available: Bool,
        optedIn: Bool,
        tier: String,
        hostedProfileSyncAllowed: Bool
    ) {
        self.available = available
        self.optedIn = optedIn
        self.tier = tier
        self.hostedProfileSyncAllowed = hostedProfileSyncAllowed
    }
}

public struct SafariLearningMaintenanceResult: Sendable, Equatable {
    public let markedStale: [String]
    public let archived: [String]

    public init(markedStale: [String], archived: [String]) {
        self.markedStale = markedStale
        self.archived = archived
    }
}

public enum SafariLearningCoordinatorError: Error, LocalizedError, Sendable, Equatable {
    case ineligibleTier(String)
    case optInRequired
    case invalidConsentVersion
    case invalidObservation(String)
    case duplicateObservation
    case triggerThresholdNotMet(current: Int, required: Int)
    case sourceDenied
    case reviewerUnavailable
    case malformedReviewerOutput(String)
    case reviewerRejected(String)
    case sensitiveContentRejected([String])
    case proposalNotFound(String)
    case versionConflict(expected: Int, actual: Int)
    case invalidTransition(String)
    case memoryIntegrationUnavailable
    case memoryRecallUnavailable
    case skillQuarantined([String])
    case skillNotFound(String)
    case unsafePath
    case insecurePermissions(String)
    case malformedStore
    case storeTooLarge
    case storeCapacityExceeded

    public var errorDescription: String? {
        switch self {
        case .ineligibleTier(let tier):
            return "Safari learning requires an active Pro, Pro Max, or Ultra membership; current tier is \(tier)."
        case .optInRequired:
            return "Safari learning is off until the user explicitly opts in."
        case .invalidConsentVersion:
            return "The Safari learning consent version is unsupported."
        case .invalidObservation(let detail):
            return "Safari learning rejected an invalid or noisy observation: \(detail)"
        case .duplicateObservation:
            return "This Safari learning observation was already processed."
        case .triggerThresholdNotMet(let current, let required):
            return "The explicit learning trigger has \(current) qualifying occurrence(s); \(required) are required."
        case .sourceDenied:
            return "Safari learning is not permitted for this page origin."
        case .reviewerUnavailable:
            return "The Safari learning review gate is unavailable."
        case .malformedReviewerOutput(let detail):
            return "The Safari learning reviewer returned invalid strict JSON: \(detail)"
        case .reviewerRejected(let reason):
            return "The Safari learning reviewer rejected this observation: \(reason)"
        case .sensitiveContentRejected(let findings):
            return "Safari learning rejected sensitive content: \(findings.joined(separator: ", "))."
        case .proposalNotFound(let proposalID):
            return "Safari learning proposal \(proposalID) was not found."
        case .versionConflict(let expected, let actual):
            return "Safari learning proposal changed; expected version \(expected), current version is \(actual)."
        case .invalidTransition(let detail):
            return "Safari learning proposal transition is invalid: \(detail)"
        case .memoryIntegrationUnavailable:
            return "The approved-memory persistence integration is unavailable."
        case .memoryRecallUnavailable:
            return "The personal-memory recall integration is unavailable."
        case .skillQuarantined(let findings):
            return "The learned Safari skill was quarantined: \(findings.joined(separator: ", "))."
        case .skillNotFound(let proposalID):
            return "The learned Safari skill for proposal \(proposalID) was not found."
        case .unsafePath:
            return "Safari learning refused an unsafe storage path."
        case .insecurePermissions(let path):
            return "Safari learning storage permissions are too broad at \(path)."
        case .malformedStore:
            return "The persisted Safari learning store is malformed."
        case .storeTooLarge:
            return "The persisted Safari learning store exceeds its size limit."
        case .storeCapacityExceeded:
            return "The Safari learning store reached its bounded capacity."
        }
    }
}

struct SafariLearningConsent: Codable, Sendable, Equatable {
    var enabled: Bool
    let consentVersion: Int
    let consentedAt: Date
    var updatedAt: Date
}

struct SafariLearningRepeatSignal: Codable, Sendable, Equatable {
    let fingerprint: String
    var count: Int
    var lastObservedAt: Date
}

struct SafariLearningObservationReceipt: Codable, Sendable, Equatable {
    let observationID: String
    let proposalID: String?
    let recordedAt: Date
}

struct SafariLearningProposalSnapshot: Codable, Sendable, Equatable {
    let proposal: BurnBarSafariLearningProposal
    let externalMemoryID: String?
    let skillSlug: String?
    let skillLifecycle: SafariLearningSkillLifecycle?
    let skillUsage: SafariLearningSkillUsage?
    let pinned: Bool
    let capturedAt: Date
}

struct SafariLearningProposalRecord: Codable, Sendable, Equatable {
    var proposal: BurnBarSafariLearningProposal
    let trigger: BurnBarSafariLearningTrigger
    let tags: [String]
    let sourceTitle: String
    let reviewerAction: SafariLearningReviewAction
    let redactionFindingIDs: [String]
    var externalMemoryID: String?
    var skillSlug: String?
    var skillLifecycle: SafariLearningSkillLifecycle?
    var skillUsage: SafariLearningSkillUsage?
    var pinned: Bool
    var history: [SafariLearningProposalSnapshot]
}

struct SafariLearningStoreEnvelope: Codable, Sendable, Equatable {
    let schemaVersion: Int
    var consent: SafariLearningConsent?
    var proposals: [SafariLearningProposalRecord]
    var repeatSignals: [SafariLearningRepeatSignal]
    var observationReceipts: [SafariLearningObservationReceipt]
    var updatedAt: Date
}
