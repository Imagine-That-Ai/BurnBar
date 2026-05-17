import Foundation

/// Mirror of the `ops/media_budget_status/state/current` Firestore document
/// surfaced to both platforms by `MediaBudgetReader`. Read-only on the
/// client; the canonical writer is the `evaluateMediaBudget` Cloud
/// Function (`functions/src/mediaBudget.ts`) running hourly.
///
/// See `docs/runbooks/media-budget.md` for the operator playbook.
public struct MediaBudgetStatus: Sendable, Codable, Equatable {
    public enum Level: String, Sendable, Codable, Equatable {
        case normal
        case softCap = "soft_cap"
        case hardCap = "hard_cap"
    }

    public var level: Level
    public var projectedMonthEndUSD: Double
    public var monthToDateUSD: Double
    public var lastEvaluatedAt: Date
    public var activeEnvelope: MediaBudgetEnvelope

    public init(
        level: Level,
        projectedMonthEndUSD: Double,
        monthToDateUSD: Double,
        lastEvaluatedAt: Date,
        activeEnvelope: MediaBudgetEnvelope
    ) {
        self.level = level
        self.projectedMonthEndUSD = projectedMonthEndUSD
        self.monthToDateUSD = monthToDateUSD
        self.lastEvaluatedAt = lastEvaluatedAt
        self.activeEnvelope = activeEnvelope
    }
}

public struct MediaBudgetEnvelope: Sendable, Codable, Equatable {
    public var screenShareDailyMinutes: Int
    public var screenSharePerSessionMinutes: Int
    public var videoCallDailyMinutes: Int
    public var videoCallPerCallMinutes: Int
    public var fileTransferDailyGBIn: Int
    public var fileTransferDailyGBOut: Int

    public init(
        screenShareDailyMinutes: Int,
        screenSharePerSessionMinutes: Int,
        videoCallDailyMinutes: Int,
        videoCallPerCallMinutes: Int,
        fileTransferDailyGBIn: Int,
        fileTransferDailyGBOut: Int
    ) {
        self.screenShareDailyMinutes = screenShareDailyMinutes
        self.screenSharePerSessionMinutes = screenSharePerSessionMinutes
        self.videoCallDailyMinutes = videoCallDailyMinutes
        self.videoCallPerCallMinutes = videoCallPerCallMinutes
        self.fileTransferDailyGBIn = fileTransferDailyGBIn
        self.fileTransferDailyGBOut = fileTransferDailyGBOut
    }

    /// Caps in normal mode (matches the master plan § F.2 capability matrix).
    public static let normal = MediaBudgetEnvelope(
        screenShareDailyMinutes: 120,
        screenSharePerSessionMinutes: 60,
        videoCallDailyMinutes: 240,
        videoCallPerCallMinutes: 30,
        fileTransferDailyGBIn: 5,
        fileTransferDailyGBOut: 5
    )

    /// Soft cap envelope (Decision 4). Tightens automatically when the
    /// `evaluateMediaBudget` projection crosses $600/mo.
    public static let softCap = MediaBudgetEnvelope(
        screenShareDailyMinutes: 30,
        screenSharePerSessionMinutes: 30,
        videoCallDailyMinutes: 120,
        videoCallPerCallMinutes: 20,
        fileTransferDailyGBIn: 2,
        fileTransferDailyGBOut: 2
    )

    /// Hard cap envelope (Decision 4). Effectively zero — `media_kill_switch`
    /// also flips so new sessions are refused before they reach quota.
    public static let hardCap = MediaBudgetEnvelope(
        screenShareDailyMinutes: 0,
        screenSharePerSessionMinutes: 0,
        videoCallDailyMinutes: 0,
        videoCallPerCallMinutes: 0,
        fileTransferDailyGBIn: 0,
        fileTransferDailyGBOut: 0
    )
}

extension MediaBudgetEnvelope {
    /// Whether a session of the given feature can start under this envelope.
    /// `false` means the per-session ceiling is zero — the receiver is
    /// expected to refuse the session and surface a "media paused" toast.
    public func allowsSession(for feature: MediaStreamClass.Feature) -> Bool {
        switch feature {
        case .fileTransfer:
            return fileTransferDailyGBIn > 0 || fileTransferDailyGBOut > 0
        case .screenShare:
            return screenSharePerSessionMinutes > 0
        case .computerUse:
            return screenSharePerSessionMinutes > 0
        case .videoCall:
            return videoCallPerCallMinutes > 0
        }
    }
}
