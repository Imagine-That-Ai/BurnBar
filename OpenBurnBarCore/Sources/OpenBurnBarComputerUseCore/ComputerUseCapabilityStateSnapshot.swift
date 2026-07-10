import Foundation

/// Origin and age of one policy input carried in a capability projection.
///
/// `observedAt` is when the app last received a non-cache server snapshot (or
/// completed StoreKit verification). `updatedAt` is the upstream document's
/// own update time when that source exposes one. Neither value is replaced by
/// the projection publish time, so republishing cannot extend stale authority.
public struct ComputerUseAuthorityProvenance: Codable, Hashable, Sendable {
    public enum Source: String, Codable, Hashable, Sendable {
        case firestoreServer = "firestore_server"
        case verifiedStoreKit = "verified_storekit"
    }

    public let source: Source
    public let observedAt: Date
    public let updatedAt: Date?

    public init(source: Source, observedAt: Date, updatedAt: Date? = nil) {
        self.source = source
        self.observedAt = observedAt
        self.updatedAt = updatedAt
    }
}

public enum ComputerUseCapabilityFreshness {
    /// Source listeners are revalidated before this window expires. The daemon
    /// independently enforces the same bound.
    public static let maximumSourceObservationAge: TimeInterval = 10 * 60
    /// The cloud budget evaluator runs hourly. Two missed evaluations deny use.
    public static let maximumBudgetUpdateAge: TimeInterval = 2 * 60 * 60
    public static let maximumFutureSkew: TimeInterval = 15

    public static func sourceIsFresh(
        _ provenance: ComputerUseAuthorityProvenance,
        now: Date
    ) -> Bool {
        provenance.observedAt <= now.addingTimeInterval(maximumFutureSkew)
            && now.timeIntervalSince(provenance.observedAt) <= maximumSourceObservationAge
    }
}

/// Fresh projection of the app-owned commercial and fleet safety authorities
/// consumed by the daemon-owned browser Computer Use path.
///
/// The projection is transported over the existing authenticated, capability-
/// attenuated daemon socket. It is not a second policy authority: every value
/// comes from the same StoreKit/Firestore/Remote Config sources used by the Mac
/// coordinator. The daemon persists the last accepted revision and rejects a
/// missing, stale, incomplete, future-dated, or rolled-back projection.
public struct ComputerUseCapabilityStateSnapshot: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let publisherInstanceID: String
    public let revision: UInt64
    public let generatedAt: Date
    public let userID: String
    public let entitlement: ComputerUseEntitlementSnapshot
    public let entitlementProvenance: ComputerUseAuthorityProvenance
    public let budgetEnvelope: ComputerUseBudgetEnvelope
    public let budgetProvenance: ComputerUseAuthorityProvenance
    public let quotaUsage: ComputerUseQuotaUsage
    public let quotaProvenance: ComputerUseAuthorityProvenance
    public let concurrentSessionActive: Bool
    public let killSwitch: Bool
    public let authorizationRevoked: Bool
    /// False while any upstream listener has not produced an authoritative
    /// snapshot. The daemon treats this exactly like missing state.
    public let isComplete: Bool

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        publisherInstanceID: String,
        revision: UInt64,
        generatedAt: Date,
        userID: String,
        entitlement: ComputerUseEntitlementSnapshot,
        entitlementProvenance: ComputerUseAuthorityProvenance,
        budgetEnvelope: ComputerUseBudgetEnvelope,
        budgetProvenance: ComputerUseAuthorityProvenance,
        quotaUsage: ComputerUseQuotaUsage,
        quotaProvenance: ComputerUseAuthorityProvenance,
        concurrentSessionActive: Bool,
        killSwitch: Bool,
        authorizationRevoked: Bool = false,
        isComplete: Bool
    ) {
        self.schemaVersion = schemaVersion
        self.publisherInstanceID = publisherInstanceID
        self.revision = revision
        self.generatedAt = generatedAt
        self.userID = userID
        self.entitlement = entitlement
        self.entitlementProvenance = entitlementProvenance
        self.budgetEnvelope = budgetEnvelope
        self.budgetProvenance = budgetProvenance
        self.quotaUsage = quotaUsage
        self.quotaProvenance = quotaProvenance
        self.concurrentSessionActive = concurrentSessionActive
        self.killSwitch = killSwitch
        self.authorizationRevoked = authorizationRevoked
        self.isComplete = isComplete
    }
}

public struct ComputerUseCapabilityStateUpdateRequest: Codable, Hashable, Sendable {
    public let state: ComputerUseCapabilityStateSnapshot

    public init(state: ComputerUseCapabilityStateSnapshot) {
        self.state = state
    }
}

public struct ComputerUseCapabilityStateUpdateResponse: Codable, Hashable, Sendable {
    public let accepted: Bool
    public let publisherInstanceID: String
    public let revision: UInt64
    public let expiresAt: Date

    public init(
        accepted: Bool,
        publisherInstanceID: String,
        revision: UInt64,
        expiresAt: Date
    ) {
        self.accepted = accepted
        self.publisherInstanceID = publisherInstanceID
        self.revision = revision
        self.expiresAt = expiresAt
    }
}
