#if canImport(UIKit)
import Foundation
import Combine
import OpenBurnBarCore
import OpenBurnBarMedia
import OpenBurnBarComputerUseCore

/// Live model the phone overlay reads from. Pure-data, `@Observable`
/// when iOS deployment target supports it; here it's exposed as an
/// `ObservableObject` so iOS 17 and the test target can both consume.
///
/// Decodes `control.surface.frame` cursor metadata, `control.action.log.entry`
/// JSON envelopes, and `control.approval.request` frames. Phase 8 ships
/// every field except the live approval row's actions (those become
/// functional in Phase 12 via `PhoneControlSender`).
@MainActor
public final class AgentWatchState: ObservableObject {
    @Published public private(set) var currentCursor: MediaFrame.CursorMetadata?
    @Published public private(set) var actionTimeline: [HermesRealtimeRelayActionLogEntry] = []
    @Published public private(set) var pendingApproval: HermesRealtimeRelayApprovalRequest?
    @Published public private(set) var liveTrustMode: ComputerUseTrustMode = .manual
    @Published public private(set) var sessionId: ComputerUseSessionID?
    @Published public private(set) var sessionStartedAt: Date?
    @Published public private(set) var lastAuditHeadHashHex: String?
    @Published public private(set) var lastDeniedReason: ComputerUseDenyReason?
    /// Rolling 30-day cost tally pulled from `users/{uid}/computer_use_quota_usage`.
    @Published public var dailySpentUSD: Double = 0
    /// Action count this session.
    @Published public private(set) var actionsExecuted: Int = 0

    public init() {}

    public func updateCursor(_ cursor: MediaFrame.CursorMetadata?) {
        currentCursor = cursor
    }

    public func ingestActionLog(_ entry: HermesRealtimeRelayActionLogEntry) {
        if let parentHash = entry.parentEntryBlake3 {
            lastAuditHeadHashHex = parentHash
        }
        if entry.status == .completed {
            actionsExecuted += 1
        }
        actionTimeline.append(entry)
        // Keep the most recent 50 entries in memory; archive flows
        // through the daemon's audit chain export.
        if actionTimeline.count > 50 {
            actionTimeline.removeFirst(actionTimeline.count - 50)
        }
    }

    public func setPendingApproval(_ request: HermesRealtimeRelayApprovalRequest?) {
        pendingApproval = request
    }

    public func setSession(id: ComputerUseSessionID, startedAt: Date) {
        sessionId = id
        sessionStartedAt = startedAt
        actionTimeline.removeAll()
        actionsExecuted = 0
        pendingApproval = nil
        lastDeniedReason = nil
    }

    public func setTrustMode(_ mode: ComputerUseTrustMode) {
        liveTrustMode = mode
    }

    public func clear() {
        currentCursor = nil
        actionTimeline.removeAll()
        pendingApproval = nil
        sessionId = nil
        sessionStartedAt = nil
        actionsExecuted = 0
    }
}
#endif
