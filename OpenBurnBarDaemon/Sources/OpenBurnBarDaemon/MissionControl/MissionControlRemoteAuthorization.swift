import Foundation
import OpenBurnBarCore

// M2 of the split-brain remediation program
// (docs/SURFACE_SPRAWL_AND_SPLITBRAIN_REMEDIATION_PLAN.md, Phase 2).
//
// Pure decision logic behind `daemon.mission.authorizeRemote`: the daemon's
// verdict over a remote (mobile/Wand) mission whose sealed payload the GUI
// transport has already unsealed. Four decision classes, all fail-closed:
//
//   (a) trust     — the daemon applies its OWN policy over the GUI-reported
//                   escrow trust state; unknown states are denied.
//   (b) approval  — ports the GUI listener's semantics, REUSING the shared
//                   `InsightMissionApprovalPolicy` (unknown approvalMode fails
//                   closed inside the shared policy).
//   (c) ceiling   — the authorized capability grant is never wider than
//                   requested; unrecognized capability identifiers are denied
//                   by default (dropped from the ceiling).
//   (d) fan-out   — the requested Wand fan-out must fit the entitlement
//                   tier's parallelism cap; unknown tiers fail closed to the
//                   smallest cap.
//
// Deliberately stateless and synchronous so every verdict branch is table-
// testable. Peer authentication + `mission_control` capability attenuation
// happen upstream in `BurnBarDaemonServer.responseData` before dispatch ever
// reaches this policy.
public enum BurnBarRemoteMissionAuthorizationPolicy {

    /// The single trust state that may execute remote missions. Everything
    /// else — known-untrusted or unrecognized — is refused.
    static let trustedStates: Set<String> = ["trusted"]

    /// Known NOT-trusted escrow states, distinguished from unrecognized input
    /// only for the typed denial reason; both deny.
    static let knownUntrustedStates: Set<String> = [
        "pending", "untrusted", "revoked", "rejected", "denied"
    ]

    /// Approval statuses that terminally refuse the mission.
    static let rejectedApprovalStatuses: Set<String> = [
        "rejected", "canceled", "cancelled"
    ]

    /// `additionalCapabilities` identifiers this daemon build recognizes.
    /// Empty today: the forward-compat lane exists so NEW identifiers arriving
    /// from newer clients are provably denied by default, not silently echoed.
    static let recognizedAdditionalCapabilities: Set<String> = []

    public static func evaluate(
        _ request: BurnBarRemoteMissionAuthorizeRequest
    ) -> BurnBarRemoteMissionAuthorizeResponse {
        // (a) Trust — fail closed on anything but an exact known-trusted state.
        let trustState = normalized(request.executorTrustState)
        guard trustedStates.contains(trustState) else {
            let reason: BurnBarRemoteMissionDenialReason = knownUntrustedStates.contains(trustState)
                ? .untrustedDevice
                : .unknownTrustState
            return BurnBarRemoteMissionAuthorizeResponse(
                verdict: .denied,
                deniedReason: reason,
                detail: "Executor trust state '\(trustState)' does not permit remote mission execution."
            )
        }

        // (d) Fan-out — malformed counts are invalid; anything over the tier
        // cap is refused. Unknown tiers fail closed to the smallest cap.
        guard request.requestedFanOutCount >= 1 else {
            return BurnBarRemoteMissionAuthorizeResponse(
                verdict: .denied,
                deniedReason: .invalidRequest,
                detail: "Requested fan-out count \(request.requestedFanOutCount) is not a positive mission count."
            )
        }
        let cap = fanOutCap(forEntitlementTier: request.entitlementTier)
        guard request.requestedFanOutCount <= cap else {
            return BurnBarRemoteMissionAuthorizeResponse(
                verdict: .denied,
                deniedReason: .fanOutCapExceeded,
                detail: "Requested fan-out \(request.requestedFanOutCount) exceeds the cap of \(cap) for tier '\(normalized(request.entitlementTier))'."
            )
        }

        // (b) Approval — a rejected/cancelled handshake is terminal.
        let approvalStatus = normalized(request.approvalStatus ?? "")
        if rejectedApprovalStatuses.contains(approvalStatus) {
            return BurnBarRemoteMissionAuthorizeResponse(
                verdict: .denied,
                deniedReason: .approvalRejected,
                detail: "Mission approval was \(approvalStatus) by the approver."
            )
        }

        // (c) Capability ceiling — computed for every non-denied verdict.
        let ceiling = grantCeiling(for: request.requestedGrant)

        // (b, continued) — anything short of an explicit "approved" consults
        // the SHARED pre-dispatch approval policy (unknown approvalMode fails
        // closed inside `InsightMissionApprovalPolicy`).
        if approvalStatus != "approved",
           InsightMissionApprovalPolicy.requiresPreDispatchApproval(
               approvalMode: request.approvalMode,
               commandsAllowed: request.requestedGrant.commandsAllowed,
               fileEditsAllowed: request.requestedGrant.fileEditsAllowed
           ) {
            return BurnBarRemoteMissionAuthorizeResponse(
                verdict: .requiresApproval,
                detail: "Pre-dispatch operator approval is required before this mission may execute.",
                grantCeiling: ceiling
            )
        }

        return BurnBarRemoteMissionAuthorizeResponse(
            verdict: .authorized,
            grantCeiling: ceiling,
            backendDecision: backendDecision(for: request)
        )
    }

    /// (c) The authorized ceiling: exactly the requested known capabilities —
    /// never wider — with unrecognized forward-compat identifiers denied.
    static func grantCeiling(
        for requested: BurnBarRemoteMissionCapabilityGrantRequest
    ) -> BurnBarRemoteMissionCapabilityGrantRequest {
        BurnBarRemoteMissionCapabilityGrantRequest(
            commandsAllowed: requested.commandsAllowed,
            fileEditsAllowed: requested.fileEditsAllowed,
            additionalCapabilities: requested.additionalCapabilities.filter {
                recognizedAdditionalCapabilities.contains(normalized($0))
            }
        )
    }

    /// (d) Wand fan-out cap per entitlement tier — same table as
    /// `WandFanOut.maxParallel(for:)`; unrecognized tier names fail closed to
    /// the free-tier cap.
    static func fanOutCap(forEntitlementTier tier: String) -> Int {
        switch normalized(tier) {
        case "ultra":
            return WandFanOut.maxParallel(for: .ultra)
        case "pro", "pro_max", "promax":
            return WandFanOut.maxParallel(for: .pro)
        case "cloud":
            return WandFanOut.maxParallel(for: .cloud)
        default:
            // "none", "free", "", and every unknown tier: fail closed.
            return WandFanOut.maxParallel(for: CloudTier.none)
        }
    }

    /// The backend decision carried on an authorized verdict. M2 passes the
    /// requested runtime through (defaulting to "auto"); real Wand backend
    /// resolution stays GUI-side until execution migrates in M5.
    static func backendDecision(
        for request: BurnBarRemoteMissionAuthorizeRequest
    ) -> BurnBarRemoteMissionBackendDecision {
        let runtime = request.requestedRuntime?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let model = request.requestedModelID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let runtime, !runtime.isEmpty {
            return BurnBarRemoteMissionBackendDecision(
                runtimeID: runtime,
                modelID: (model?.isEmpty == false) ? model : nil,
                reason: "requested_runtime_carried"
            )
        }
        return BurnBarRemoteMissionBackendDecision(
            runtimeID: "auto",
            modelID: (model?.isEmpty == false) ? model : nil,
            reason: "defaulted_to_auto"
        )
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
