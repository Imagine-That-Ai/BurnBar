#if canImport(UIKit)
import Foundation
import OpenBurnBarComputerUseCore

/// Mobile-only summary for the current watched Computer Use session.
/// The canonical state lives on the Mac; this struct is the compact
/// projection shown in phone sheets and widgets.
public struct AgentWatchSessionSnapshot: Codable, Hashable, Sendable {
    public var sessionId: ComputerUseSessionID?
    public var startedAt: Date?
    public var trustMode: ComputerUseTrustMode
    public var actionsExecuted: Int
    public var dailySpentUSD: Double
    public var lastDeniedReason: ComputerUseDenyReason?

    public init(
        sessionId: ComputerUseSessionID? = nil,
        startedAt: Date? = nil,
        trustMode: ComputerUseTrustMode = .manual,
        actionsExecuted: Int = 0,
        dailySpentUSD: Double = 0,
        lastDeniedReason: ComputerUseDenyReason? = nil
    ) {
        self.sessionId = sessionId
        self.startedAt = startedAt
        self.trustMode = trustMode
        self.actionsExecuted = actionsExecuted
        self.dailySpentUSD = dailySpentUSD
        self.lastDeniedReason = lastDeniedReason
    }
}

public extension AgentWatchState {
    var snapshot: AgentWatchSessionSnapshot {
        AgentWatchSessionSnapshot(
            sessionId: sessionId,
            startedAt: sessionStartedAt,
            trustMode: liveTrustMode,
            actionsExecuted: actionsExecuted,
            dailySpentUSD: dailySpentUSD,
            lastDeniedReason: lastDeniedReason
        )
    }
}
#endif
