import Foundation

/// Synchronous gate consulted by both the Mac (authoritative — Decision 2
/// in `plans/2026-05-15-mercury-media-master-plan.md`) and iOS
/// (informational, surfaces the same denial reason in the UI).
///
/// Implementations on each platform compose three signals:
///
/// 1. The peer's `hosted_media_sync` entitlement (Mac-side via
///    `MacCloudEntitlementStore`; iOS receives the gate result over the
///    wire and never owns its own entitlement state).
/// 2. The local 24-hour quota counters cached in `media_quota_usage` for
///    today — never trusted as the only signal because the cache lags the
///    Cloud Function's hourly reconcile.
/// 3. `ops/media_budget_status/current` — the n0 hosted-relay budget
///    envelope (see `docs/runbooks/media-budget.md`).
public protocol MediaCapabilityGate: Sendable {
    func check(
        feature: MediaStreamClass.Feature,
        sessionDurationLimitSeconds: Int?,
        sessionByteBudget: Int64?
    ) async -> MediaCapabilityCheck
}

public enum MediaCapabilityCheck: Sendable, Equatable {
    case allowed(envelope: MediaCapabilityEnvelope)
    case denied(reason: MediaCapabilityDenialReason)

    public var isAllowed: Bool {
        if case .allowed = self { return true }
        return false
    }
}

public enum MediaCapabilityDenialReason: String, Sendable, Codable, Equatable {
    case entitlementMissing
    case entitlementExpired
    case dailyCapReached
    case sessionCapReached
    case concurrentSessionCapReached
    case budgetSoftCapReached
    case budgetHardCapReached
    case killSwitchActive
}

/// Caller-visible envelope returned alongside an `.allowed` decision so the
/// caller knows what its remaining budget looks like before it commits to
/// a session that might immediately bump into the per-session ceiling.
public struct MediaCapabilityEnvelope: Sendable, Equatable, Codable {
    public var feature: MediaStreamClass.Feature
    public var remainingSecondsToday: Int?
    public var remainingBytesToday: Int64?
    public var perSessionMaxSeconds: Int?
    public var perSessionMaxBytes: Int64?
    public var concurrentSessionsRemaining: Int

    public init(
        feature: MediaStreamClass.Feature,
        remainingSecondsToday: Int? = nil,
        remainingBytesToday: Int64? = nil,
        perSessionMaxSeconds: Int? = nil,
        perSessionMaxBytes: Int64? = nil,
        concurrentSessionsRemaining: Int = 1
    ) {
        self.feature = feature
        self.remainingSecondsToday = remainingSecondsToday
        self.remainingBytesToday = remainingBytesToday
        self.perSessionMaxSeconds = perSessionMaxSeconds
        self.perSessionMaxBytes = perSessionMaxBytes
        self.concurrentSessionsRemaining = concurrentSessionsRemaining
    }
}

/// Phase 1 placeholder: always allows. Used by integration tests and by
/// builds that have not yet shipped their platform implementation. Real
/// gates land in:
///   - `AgentLens/Services/Media/MediaCapabilityGate.swift` (Phase 2)
///   - `OpenBurnBarMobile/Services/Media/MediaCapabilityGate.swift` (Phase 2,
///      stays informational)
public struct AlwaysAllowMediaCapabilityGate: MediaCapabilityGate {
    public init() {}

    public func check(
        feature: MediaStreamClass.Feature,
        sessionDurationLimitSeconds _: Int?,
        sessionByteBudget _: Int64?
    ) async -> MediaCapabilityCheck {
        .allowed(envelope: MediaCapabilityEnvelope(feature: feature))
    }
}
