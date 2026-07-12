import Foundation

public enum BurnBarLinuxOnboardingStepID: String, Codable, CaseIterable, Hashable, Sendable {
    case daemon = "daemon"
    case secretStore = "secret_store"
    case providerPaths = "provider_paths"
    case cloudIdentity = "cloud_identity"
    case portalInput = "portal_input"
    case tray = "tray"
    case updates = "updates"
    case privacy = "privacy"
}

public enum BurnBarLinuxOnboardingRequirement: String, Codable, Hashable, Sendable {
    case required
    case optional
}

public enum BurnBarLinuxOnboardingStepState: String, Codable, Hashable, Sendable {
    case pending
    case blocked
    case verified
    case acknowledged
    case skipped
}

public struct BurnBarLinuxOnboardingStepSnapshot: Codable, Hashable, Sendable {
    public let id: BurnBarLinuxOnboardingStepID
    public let requirement: BurnBarLinuxOnboardingRequirement
    public let state: BurnBarLinuxOnboardingStepState
    public let attemptCount: Int
    public let detail: String?
    public let verifiedAt: String?

    public init(
        id: BurnBarLinuxOnboardingStepID,
        requirement: BurnBarLinuxOnboardingRequirement,
        state: BurnBarLinuxOnboardingStepState = .pending,
        attemptCount: Int = 0,
        detail: String? = nil,
        verifiedAt: String? = nil
    ) {
        self.id = id
        self.requirement = requirement
        self.state = state
        self.attemptCount = attemptCount
        self.detail = detail
        self.verifiedAt = verifiedAt
    }
}

public struct BurnBarLinuxOnboardingPrivacyChoices: Codable, Hashable, Sendable {
    public let telemetryEnabled: Bool
    public let cloudSyncEnabled: Bool

    public init(telemetryEnabled: Bool, cloudSyncEnabled: Bool) {
        self.telemetryEnabled = telemetryEnabled
        self.cloudSyncEnabled = cloudSyncEnabled
    }
}

public struct BurnBarLinuxOnboardingSnapshot: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let revision: Int
    public let currentStepID: BurnBarLinuxOnboardingStepID
    public let steps: [BurnBarLinuxOnboardingStepSnapshot]
    public let privacyChoices: BurnBarLinuxOnboardingPrivacyChoices?
    public let completed: Bool
    public let updatedAt: String

    public init(
        schemaVersion: Int = 1,
        revision: Int,
        currentStepID: BurnBarLinuxOnboardingStepID,
        steps: [BurnBarLinuxOnboardingStepSnapshot],
        privacyChoices: BurnBarLinuxOnboardingPrivacyChoices? = nil,
        completed: Bool,
        updatedAt: String
    ) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.currentStepID = currentStepID
        self.steps = steps
        self.privacyChoices = privacyChoices
        self.completed = completed
        self.updatedAt = updatedAt
    }
}

public enum BurnBarLinuxOnboardingAction: String, Codable, Hashable, Sendable {
    case verify
    case acknowledge
    case skip
    case navigate
    case savePrivacyChoices = "save_privacy_choices"
}

public struct BurnBarLinuxOnboardingActionRequest: Codable, Hashable, Sendable {
    public let stepID: BurnBarLinuxOnboardingStepID
    public let action: BurnBarLinuxOnboardingAction
    public let telemetryEnabled: Bool?
    public let cloudSyncEnabled: Bool?

    public init(
        stepID: BurnBarLinuxOnboardingStepID,
        action: BurnBarLinuxOnboardingAction,
        telemetryEnabled: Bool? = nil,
        cloudSyncEnabled: Bool? = nil
    ) {
        self.stepID = stepID
        self.action = action
        self.telemetryEnabled = telemetryEnabled
        self.cloudSyncEnabled = cloudSyncEnabled
    }
}
