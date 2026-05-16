import Foundation
import OpenBurnBarCore
import OpenBurnBarIrohRelay
import OpenBurnBarMedia

/// Mac-side authoritative implementation of `MediaCapabilityGate`
/// (Decision 2 — `plans/2026-05-15-mercury-media-master-plan.md`). The
/// Mac is the source of truth for media session admission; iOS asks the
/// Mac and respects whatever it says.
///
/// Composes three signals:
///   1. `MacCloudEntitlementStore.hostedMediaEntitlement` (Apple-verified
///      `hosted_media_sync` doc).
///   2. Local 24-hour quota counter cache from `media_quota_usage`.
///   3. `ops/media_budget_status/state/current` (n0 hosted-relay budget
///      envelope, see `docs/runbooks/media-budget.md`).
@MainActor
final class MacMediaCapabilityGate: MediaCapabilityGate {
    struct EntitlementState: Sendable, Equatable {
        var active: Bool
        var fileTransfer: Bool
        var screenShare: Bool
        var videoCall: Bool
    }

    typealias EntitlementProvider = @MainActor () -> EntitlementState
    typealias UsageProvider = @MainActor () -> MediaQuotaUsageSnapshot
    typealias BudgetProvider = @MainActor () -> MediaBudgetStatus
    typealias ConcurrentSessionsProvider = @MainActor (MediaStreamClass.Feature) -> Int

    private let entitlementProvider: EntitlementProvider
    private let usageProvider: UsageProvider
    private let budgetProvider: BudgetProvider
    private let concurrentSessionsProvider: ConcurrentSessionsProvider

    init(
        entitlementProvider: @escaping EntitlementProvider,
        usageProvider: @escaping UsageProvider,
        budgetProvider: @escaping BudgetProvider,
        concurrentSessionsProvider: @escaping ConcurrentSessionsProvider
    ) {
        self.entitlementProvider = entitlementProvider
        self.usageProvider = usageProvider
        self.budgetProvider = budgetProvider
        self.concurrentSessionsProvider = concurrentSessionsProvider
    }

    nonisolated func check(
        feature: MediaStreamClass.Feature,
        sessionDurationLimitSeconds: Int?,
        sessionByteBudget: Int64?
    ) async -> MediaCapabilityCheck {
        await MainActor.run {
            let entitlement = entitlementProvider()
            guard entitlement.active else {
                return .denied(reason: .entitlementMissing)
            }
            switch feature {
            case .fileTransfer:
                if !entitlement.fileTransfer { return .denied(reason: .entitlementMissing) }
            case .screenShare:
                if !entitlement.screenShare { return .denied(reason: .entitlementMissing) }
            case .videoCall:
                if !entitlement.videoCall { return .denied(reason: .entitlementMissing) }
            }

            let budget = budgetProvider()
            switch budget.level {
            case .hardCap:
                return .denied(reason: .budgetHardCapReached)
            case .softCap:
                if !budget.activeEnvelope.allowsSession(for: feature) {
                    return .denied(reason: .budgetSoftCapReached)
                }
            case .normal:
                break
            }

            let usage = usageProvider()
            let envelope = effectiveEnvelope(level: budget.level, base: budget.activeEnvelope)
            let dailyDecision = dailyCapDecision(
                feature: feature,
                envelope: envelope,
                usage: usage,
                sessionDurationLimitSeconds: sessionDurationLimitSeconds,
                sessionByteBudget: sessionByteBudget
            )
            if case .denied = dailyDecision { return dailyDecision }

            let concurrent = concurrentSessionsProvider(feature)
            if concurrent >= concurrentLimit(for: feature) {
                return .denied(reason: .concurrentSessionCapReached)
            }

            let result = MediaCapabilityEnvelope(
                feature: feature,
                remainingSecondsToday: remainingSeconds(feature: feature, envelope: envelope, usage: usage),
                remainingBytesToday: remainingBytes(feature: feature, envelope: envelope, usage: usage),
                perSessionMaxSeconds: perSessionMaxSeconds(feature: feature, envelope: envelope),
                perSessionMaxBytes: perSessionMaxBytes(feature: feature, envelope: envelope),
                concurrentSessionsRemaining: max(0, concurrentLimit(for: feature) - concurrent)
            )
            return .allowed(envelope: result)
        }
    }

    private func effectiveEnvelope(
        level: MediaBudgetStatus.Level,
        base: MediaBudgetEnvelope
    ) -> MediaBudgetEnvelope {
        switch level {
        case .normal: return base.allowsSession(for: .fileTransfer) ? base : .normal
        case .softCap: return base
        case .hardCap: return .hardCap
        }
    }

    private func concurrentLimit(for feature: MediaStreamClass.Feature) -> Int {
        switch feature {
        case .fileTransfer: return 4
        case .screenShare: return 1
        case .videoCall: return 1
        }
    }

    private func dailyCapDecision(
        feature: MediaStreamClass.Feature,
        envelope: MediaBudgetEnvelope,
        usage: MediaQuotaUsageSnapshot,
        sessionDurationLimitSeconds: Int?,
        sessionByteBudget: Int64?
    ) -> MediaCapabilityCheck {
        switch feature {
        case .fileTransfer:
            let dailyBytesIn = Int64(envelope.fileTransferDailyGBIn) * 1_000_000_000
            let dailyBytesOut = Int64(envelope.fileTransferDailyGBOut) * 1_000_000_000
            if usage.bytesDownloadedFile >= dailyBytesIn && usage.bytesUploadedFile >= dailyBytesOut {
                return .denied(reason: .dailyCapReached)
            }
            if let sessionByteBudget,
               (usage.bytesUploadedFile + sessionByteBudget) > dailyBytesOut {
                return .denied(reason: .sessionCapReached)
            }
        case .screenShare:
            let dailyCapSeconds = envelope.screenShareDailyMinutes * 60
            if usage.screenShareSecondsUsed >= dailyCapSeconds {
                return .denied(reason: .dailyCapReached)
            }
            if let sessionDurationLimitSeconds,
               sessionDurationLimitSeconds > envelope.screenSharePerSessionMinutes * 60 {
                return .denied(reason: .sessionCapReached)
            }
        case .videoCall:
            let dailyCapSeconds = envelope.videoCallDailyMinutes * 60
            if usage.videoCallSecondsUsed >= dailyCapSeconds {
                return .denied(reason: .dailyCapReached)
            }
            if let sessionDurationLimitSeconds,
               sessionDurationLimitSeconds > envelope.videoCallPerCallMinutes * 60 {
                return .denied(reason: .sessionCapReached)
            }
        }
        let allowance = MediaCapabilityEnvelope(feature: feature)
        return .allowed(envelope: allowance)
    }

    private func remainingSeconds(
        feature: MediaStreamClass.Feature,
        envelope: MediaBudgetEnvelope,
        usage: MediaQuotaUsageSnapshot
    ) -> Int? {
        switch feature {
        case .fileTransfer: return nil
        case .screenShare: return max(0, envelope.screenShareDailyMinutes * 60 - usage.screenShareSecondsUsed)
        case .videoCall: return max(0, envelope.videoCallDailyMinutes * 60 - usage.videoCallSecondsUsed)
        }
    }

    private func remainingBytes(
        feature: MediaStreamClass.Feature,
        envelope: MediaBudgetEnvelope,
        usage: MediaQuotaUsageSnapshot
    ) -> Int64? {
        guard feature == .fileTransfer else { return nil }
        let dailyOut = Int64(envelope.fileTransferDailyGBOut) * 1_000_000_000
        return max(0, dailyOut - usage.bytesUploadedFile)
    }

    private func perSessionMaxSeconds(
        feature: MediaStreamClass.Feature,
        envelope: MediaBudgetEnvelope
    ) -> Int? {
        switch feature {
        case .fileTransfer: return nil
        case .screenShare: return envelope.screenSharePerSessionMinutes * 60
        case .videoCall: return envelope.videoCallPerCallMinutes * 60
        }
    }

    private func perSessionMaxBytes(
        feature: MediaStreamClass.Feature,
        envelope: MediaBudgetEnvelope
    ) -> Int64? {
        guard feature == .fileTransfer else { return nil }
        return 1_000_000_000 // 1 GB / file
    }
}

/// Snapshot mirror of `MediaQuotaUsageDoc` for in-memory use by the
/// capability gate. Refreshed by the Mac side from the cached
/// `media_quota_usage/{day}` document every 30 s.
struct MediaQuotaUsageSnapshot: Sendable, Equatable {
    var bytesUploadedFile: Int64 = 0
    var bytesDownloadedFile: Int64 = 0
    var fileTransfersInitiated: Int = 0
    var fileTransfersFailed: Int = 0
    var screenShareSecondsUsed: Int = 0
    var screenShareSessions: Int = 0
    var videoCallSecondsUsed: Int = 0
    var videoCallSessions: Int = 0
}
