import Foundation
import OpenBurnBarEngine

// M2 of the split-brain remediation program
// (docs/SURFACE_SPRAWL_AND_SPLITBRAIN_REMEDIATION_PLAN.md, Phase 2).
//
// Pure decision logic behind `daemon.mission.authorizeRemote`: the daemon's
// verdict over a remote (mobile/Wand) mission whose sealed payload the GUI
// transport has already unsealed. Four decision classes, all fail-closed:
//
//   (a) trust     — the daemon applies its OWN policy over the GUI-reported
//                   escrow trust state; unknown states are denied.
//   (b) approval  — ports the GUI listener's pre-dispatch approval and
//                   backend-consent semantics locally so the daemon owns the
//                   policy decision on every platform.
//   (c) ceiling   — the authorized capability grant is never wider than
//                   requested; unrecognized capability identifiers are denied
//                   by default (dropped from the ceiling).
//   (d) fan-out   — the requested Wand fan-out must fit the daemon-trusted
//                   entitlement cap. Caller-supplied tier text is advisory
//                   only and never widens authority.
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
    static let recognizedAdditionalCapabilities: Set<String> = ["input.grok_bot"]

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

        // (d) Fan-out — malformed counts are invalid; anything over the
        // daemon-trusted cap is refused. The trusted cap is the GUI-resolved
        // entitlement cap (read from server-signed Firestore entitlement docs,
        // NOT the advisory `entitlementTier` text), hard-clamped here to the
        // maximum tier so a compromised transport can never widen fan-out past
        // the ceiling. When the GUI reports no resolved cap (older build /
        // unresolved), the daemon fails closed to the free-tier cap.
        guard request.requestedFanOutCount >= 1 else {
            return BurnBarRemoteMissionAuthorizeResponse(
                verdict: .denied,
                deniedReason: .invalidRequest,
                detail: "Requested fan-out count \(request.requestedFanOutCount) is not a positive mission count."
            )
        }
        let cap = trustedFanOutCap(reportedCap: request.trustedFanOutCap)
        guard request.requestedFanOutCount <= cap else {
            return BurnBarRemoteMissionAuthorizeResponse(
                verdict: .denied,
                deniedReason: .fanOutCapExceeded,
                detail: "Requested fan-out \(request.requestedFanOutCount) exceeds the daemon-trusted cap of \(cap)."
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
        if approvalStatus == "approved" {
            let approver = normalized(request.approverDeviceID ?? "")
            if approver.isEmpty {
                return BurnBarRemoteMissionAuthorizeResponse(
                    verdict: .denied,
                    deniedReason: .approvalRejected,
                    detail: "Approved missions require approvedByDeviceId."
                )
            }
        }

        // (c) Capability ceiling — computed for every non-denied verdict.
        let ceiling = grantCeiling(
            for: request.requestedGrant,
            personaScope: request.personaScope
        )

        // (b, continued) — anything short of an explicit "approved" consults
        // the daemon's local copy of the pre-dispatch approval policy plus
        // backend consent for Mac CLI assistants. Unknown approval modes and
        // unresolved/auto CLI backends fail closed to an approval requirement.
        if approvalStatus != "approved",
           requiresPreDispatchApproval(
               approvalMode: request.approvalMode,
               commandsAllowed: request.requestedGrant.commandsAllowed,
               fileEditsAllowed: request.requestedGrant.fileEditsAllowed
           ) || requiresBackendConsent(forRequestedRuntime: request.requestedRuntime) {
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
        for requested: BurnBarRemoteMissionCapabilityGrantRequest,
        personaScope: PersonaScopeEnvelope?
    ) -> BurnBarRemoteMissionCapabilityGrantRequest {
        BurnBarRemoteMissionCapabilityGrantRequest(
            commandsAllowed: requested.commandsAllowed && (personaScope?.permitShell ?? true),
            fileEditsAllowed: requested.fileEditsAllowed && (personaScope?.permitFileEdits ?? true),
            additionalCapabilities: requested.additionalCapabilities.filter {
                recognizedAdditionalCapabilities.contains(normalized($0))
            }
        )
    }

    /// (d) Trusted Wand fan-out cap. The daemon has no direct entitlement store,
    /// so the GUI reports the cap it resolved from the server-signed Firestore
    /// entitlement documents. The daemon honors that cap but never trusts it
    /// verbatim: it is clamped to `[freeCap, ultraCap]` so a compromised or
    /// buggy transport can neither widen fan-out past the maximum tier nor drop
    /// it below the always-available free cap. A `nil` reported cap (older GUI /
    /// unresolved) fails closed to the free cap.
    static func trustedFanOutCap(reportedCap: Int?) -> Int {
        let freeCap = WandFanOut.maxParallel(for: .none)
        let ultraCap = WandFanOut.maxParallel(for: .ultra)
        guard let reportedCap else { return freeCap }
        return min(max(reportedCap, freeCap), ultraCap)
    }

    static func requiresPreDispatchApproval(
        approvalMode: String?,
        commandsAllowed: Bool,
        fileEditsAllowed: Bool
    ) -> Bool {
        let riskyExecutionRequested = commandsAllowed || fileEditsAllowed
        guard !riskyExecutionRequested else {
            return true
        }

        switch approvalMode?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "manual_all":
            return true
        case "risky_only", "existing_policy", "read_only", nil, "":
            return false
        default:
            return true
        }
    }

    static func requiresBackendConsent(forRequestedRuntime requestedRuntime: String?) -> Bool {
        let normalizedRuntime = normalized(requestedRuntime ?? "")
        switch normalizedRuntime {
        case "hermes":
            return false
        case "", "auto":
            return true
        case "codex", "claude", "claude-code", "claudecode",
             "openclaw", "open-claw", "openclaude", "open-claude",
             "pi", "piagent", "pi-agent",
             "droid", "factory", "factory-droid", "factorydroid",
             "forge", "forge-dev", "forgedev",
             "antigravity", "agy", "google-antigravity", "googleantigravity",
             "cursoragent", "cursor-agent",
             "opencode", "ollama",
             "omp", "ohmypi", "oh-my-pi", "oh my pi",
             "junie", "grok", "grok-build", "xai", "grok-agent":
            return true
        default:
            return true
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
