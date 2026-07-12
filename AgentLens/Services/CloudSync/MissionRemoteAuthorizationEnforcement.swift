import Foundation
@preconcurrency import FirebaseFirestore
import OpenBurnBarCore
import OSLog

// MARK: - Mission remote-authorization ENFORCEMENT writeback (split-brain M4)
//
// docs/SURFACE_SPRAWL_AND_SPLITBRAIN_REMEDIATION_PLAN.md — Phase M4 makes the
// daemon's `daemon.mission.authorizeRemote` verdict the SOLE mission-authority
// decision and deletes the GUI's own allow/approve/deny computation. What the
// GUI keeps is EXECUTION and STATE writeback: these helpers render the daemon's
// verdict into mission state. They carry NO policy of their own — the daemon
// decided; this only surfaces the decision.
//
// This file is DELIBERATELY named outside the `CLIAgentMissionRequestListener`
// cluster prefix (like `MissionRemoteAuthorizationShadow.swift`): the mission
// split-brain shrink-only ratchet freezes that cluster, and new code that
// carries us TOWARD collapsing the split-brain belongs in a fresh home so the
// cluster keeps shrinking.

/// The wire vocabulary for `executorTrustState` on the daemon authorize
/// request. `BurnBarRemoteMissionAuthorizationPolicy` keys on exactly these
/// strings: `"trusted"` authorizes; `"pending"` / `"revoked"` are typed
/// known-untrusted denials; anything else (including `"unknown_trust_state"`)
/// is an unrecognized-state fail-closed denial.
enum MissionRemoteExecutorTrustState {
    /// Escrow record could not be read / verified — fail closed as unknown.
    static let unknown = "unknown_trust_state"
}

extension CLIAgentMissionRequestListener {
    /// Daemon verdict `.requiresApproval`: pause the mission for pre-dispatch
    /// operator approval. Terminal approval rejections never reach here (the
    /// daemon maps them to `.denied`), so this only ever transitions a pending
    /// mission into the waiting-for-approval writeback — unless it is already
    /// waiting (idempotent: a re-observed pending mission must not re-request).
    func driveApprovalWriteback(
        document: QueryDocumentSnapshot,
        data: [String: Any],
        backend: CLIAgentMissionBackend
    ) async {
        let status = ((data["status"] as? String) ?? "pending").lowercased()
        if status == "waiting_for_approval" { return }
        await requestApproval(document: document, data: data, backend: backend)
    }

    /// Daemon verdict `.denied`: refuse the mission and write a terminal blocked
    /// state carrying the daemon's typed denial reason. An `approvalRejected`
    /// reason routes through the existing rejected/cancelled cancellation
    /// writeback so mobile sees the "approval rejected/canceled" resolution.
    func failDaemonDenied(
        document: QueryDocumentSnapshot,
        backend: CLIAgentMissionBackend,
        reason: BurnBarRemoteMissionDenialReason?,
        detail: String?
    ) async {
        if reason == .approvalRejected {
            let approvalStatus = ((document.data()["approvalStatus"] as? String) ?? "rejected").lowercased()
            let resolved = ["rejected", "canceled", "cancelled"].contains(approvalStatus) ? approvalStatus : "rejected"
            await cancelAfterApprovalDecision(document: document, approvalStatus: resolved)
            return
        }
        let base: String
        switch reason {
        case .untrustedDevice:
            base = "This Mac is not approved for mobile mission execution. Approve it in OpenBurnBar Devices and Sync, then send the mission again."
        case .unknownTrustState:
            base = "This Mac's trust state could not be verified, so the mission was refused. Re-approve this Mac in OpenBurnBar Devices and Sync, then send the mission again."
        case .fanOutCapExceeded:
            base = "This Wand cast requested more parallel workers than your plan allows on this Mac."
        case .invalidRequest:
            base = "The mission request was malformed and could not be authorized."
        case .approvalRejected, .none:
            base = "The daemon refused this mission."
        }
        let message = detail?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank.map { "\(base) (\($0))" } ?? base
        await failAfterTrustedClaim(document: document, backend: backend, message: message)
    }

    /// Fail closed when the daemon is unreachable: remote missions require a
    /// healthy daemon to authorize them, and the existing supervisor / needs-
    /// repair UI already surfaces the daemon-unhealthy state to the operator.
    func failDaemonRequired(document: QueryDocumentSnapshot, detail: String) async {
        let safeDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        let message = "The OpenBurnBar daemon is required to authorize remote missions but is not available on this Mac. "
            + "Open OpenBurnBar and repair the daemon (Devices and Sync), then send the mission again."
            + (safeDetail.map { " (\($0))" } ?? "")
        await fail(document: document, message: message)
    }
}
