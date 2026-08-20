import Foundation
@preconcurrency import FirebaseFirestore
import OpenBurnBarKernel
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

extension CLIAgentMissionPersonaScopeResolution {
    /// True when the persona scope could not be parsed. Only the M4
    /// authorization gate cares, so it lives here rather than growing the
    /// frozen `CLIAgentMissionRequestListener` cluster.
    var isRefused: Bool {
        if case .refused = self { return true }
        return false
    }
}

extension MissionRemoteAuthorizationShadow.ShadowContext {
    /// Build the daemon authorization context from a mission document's
    /// merged (private-payload + public) fields. Callers pass POST-wand-routing
    /// data so the daemon sees the runtime/model this Mac would actually launch.
    static func fromMissionData(
        _ data: [String: Any],
        missionID: String,
        prompt: String,
        fanOutCount: Int,
        runtimeOverride: String? = nil,
        trustedFanOutCap: Int? = nil
    ) -> Self {
        MissionRemoteAuthorizationShadow.ShadowContext(
            missionID: missionID, prompt: prompt,
            runtime: runtimeOverride ?? (data["requestedRuntime"] as? String) ?? "auto",
            modelID: (data["requestedModelID"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            commandsAllowed: (data["commandsAllowed"] as? Bool) ?? false,
            fileEditsAllowed: (data["fileEditsAllowed"] as? Bool) ?? false,
            originDeviceID: (data["originDeviceID"] as? String)?.nilIfBlank ?? (data["createdBy"] as? String)?.nilIfBlank ?? "unknown",
            originPlatform: (data["originPlatform"] as? String)?.nilIfBlank ?? (data["source"] as? String)?.nilIfBlank ?? "unknown",
            personaScopeJSON: (data["personaScopeJSON"] as? String)?.nilIfBlank,
            approvalMode: (data["approvalMode"] as? String)?.nilIfBlank,
            approvalStatus: (data["approvalStatus"] as? String) ?? "",
            approverDeviceID: (data["approvedByDeviceId"] as? String)?.nilIfBlank
                ?? (data["approverDeviceID"] as? String)?.nilIfBlank,
            entitlementTier: (data["entitlementTier"] as? String)?.nilIfBlank ?? "none",
            workingDirectory: (data["workingDirectory"] as? String)?.nilIfBlank,
            fanOutCount: fanOutCount,
            trustedFanOutCap: trustedFanOutCap
        )
    }
}

extension CLIAgentMissionRequestListener {
    /// What the listener does next after the daemon-authority gate.
    enum RemoteMissionAuthorization: Equatable {
        /// The daemon authorized the mission. `grantCeiling` is the ceiling the
        /// caller MUST apply to the mission data before any launch planning —
        /// the daemon may have attenuated the requested capabilities.
        case proceed(grantCeiling: BurnBarRemoteMissionCapabilityGrantRequest)
        /// Stop handling this mission on this Mac. Any terminal Firestore
        /// writeback (fail / approval request / cancellation) already happened,
        /// or the mission was deliberately left `pending` for another executor.
        case stop
    }

    /// Phase M4 daemon-authority gate: the single place the GUI asks
    /// `daemon.mission.authorizeRemote` whether a remote mission may run here.
    ///
    /// This carries NO policy of its own beyond failing closed. It rejects a
    /// mission whose persona scope cannot be parsed (running it would silently
    /// widen permissions), refuses to run at all unless enforcement is on, and
    /// otherwise renders the daemon's verdict:
    ///
    ///   - `authorized`   → `.proceed` with the daemon's capability ceiling
    ///   - `requiresApproval` → pause for operator approval, `.stop`
    ///   - `denied`       → terminal blocked writeback, `.stop` — EXCEPT
    ///     `untrustedDevice`/`unknownTrustState`, which are executor-LOCAL
    ///     failures: the shared `pending` document is left untouched so a
    ///     different trusted Mac on the account can still claim it.
    ///   - `daemonUnreachable` → also executor-local; leave it pending.
    func resolveRemoteMissionAuthorization(
        document: QueryDocumentSnapshot,
        data: [String: Any],
        backend: CLIAgentMissionBackend,
        uid: String,
        prompt: String,
        executorTrustState: String,
        missionGroupContext: MissionGroupClaimContext?
    ) async -> RemoteMissionAuthorization {
        let personaScopeIsMalformed: Bool = {
            guard data["personaScopeJSON"] != nil else { return false }
            return CLIAgentMissionPersonaScopeResolution.resolve(from: data).isRefused
        }()
        if personaScopeIsMalformed {
            await fail(
                document: document,
                message: "The persona scope attached to this mission could not be read, "
                    + "so it was rejected instead of running with broader permissions. "
                    + "Re-send the mission from your device."
            )
            return .stop
        }

        guard MissionRemoteAuthorizationShadow.mode == .enforce else {
            logger.warning("mission id=\(document.documentID, privacy: .public) refused: daemon mission authorization is not enforced (OBB_MISSION_AUTHORIZE_SHADOW=\(MissionRemoteAuthorizationShadow.mode.rawValue, privacy: .public)); remote missions fail closed")
            await fail(
                document: document,
                message: "Remote missions require daemon authorization, which is currently disabled on this Mac. "
                    + "Remove OBB_MISSION_AUTHORIZE_SHADOW (or set it to enforce) to run remote missions."
            )
            return .stop
        }

        // `validateMissionGroupClaimIfNeeded` already read entitlements and
        // checked the group against the tier cap for Wand children; reuse that
        // verdict rather than re-reading, so a transient second read cannot
        // downgrade a validated paid fan-out to the free cap.
        var fanOutCap = missionGroupContext?.tierCap
        if fanOutCap == nil {
            fanOutCap = try? await resolvedWandFanOutCap(uid: uid) // try?-ok(fail-closed entitlement cap)
        }
        let authorization = await MissionRemoteAuthorizationShadow.authorize(
            ctx: .fromMissionData(
                data,
                missionID: document.documentID,
                prompt: prompt,
                fanOutCount: missionGroupContext?.siblingCount ?? 1,
                runtimeOverride: backend.rawValue,
                trustedFanOutCap: fanOutCap
            ),
            executorTrustState: executorTrustState
        )
        switch authorization {
        case let .authorized(grantCeiling):
            guard let grantCeiling else {
                await failDaemonDenied(
                    document: document,
                    backend: backend,
                    reason: .invalidRequest,
                    detail: "Authorized daemon response omitted its capability ceiling."
                )
                return .stop
            }
            return .proceed(grantCeiling: grantCeiling)
        case .requiresApproval:
            await driveApprovalWriteback(document: document, data: data, backend: backend)
            return .stop
        case let .denied(reason, detail):
            switch reason {
            case .some(.untrustedDevice), .some(.unknownTrustState):
                logger.info("mission id=\(document.documentID, privacy: .public) remains pending for another trusted executor")
                await applyHostStatus(
                    document: document,
                    status: "pending",
                    liveSummary: "Released claim so another trusted Mac can take this mission.",
                    releaseClaim: true
                )
                return .stop
            default:
                await failDaemonDenied(document: document, backend: backend, reason: reason, detail: detail)
                return .stop
            }
        case let .daemonUnreachable(detail):
            logger.warning("mission id=\(document.documentID, privacy: .public) remains pending while local daemon is unavailable: \(detail, privacy: .public)")
            await applyHostStatus(
                document: document,
                status: "pending",
                liveSummary: "Released claim while this Mac's daemon is unreachable.",
                releaseClaim: true
            )
            return .stop
        }
    }

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
