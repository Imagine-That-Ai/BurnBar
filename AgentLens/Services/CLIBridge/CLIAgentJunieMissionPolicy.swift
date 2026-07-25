import Foundation
import OpenBurnBarComputerUseCore

/// Junie's CLI exposes no OpenBurnBar-enforceable read-only or no-shell
/// flags, so a remote Junie mission may only run when the phone's grant
/// carries BOTH command execution and file edits. Lives beside the CLI
/// argument builders (not in the CLIAgentMissionRequestListener cluster,
/// which is frozen shrink-only by the mission split-brain budget).
enum CLIAgentJunieMissionPolicy {
    static func hasFullDesktopCapabilities(_ grant: AgentCapabilityGrant) -> Bool {
        grant.capabilities.contains(.shell) && grant.capabilities.contains(.workspaceWrite)
    }

    /// Fail-closed launch gate for the relay/local chat path: Junie may only
    /// be spawned when an active grant carries the full desktop capability
    /// set, mirroring the mission-launch guard.
    static func chatLaunchPermitted(_ grant: AgentCapabilityGrant?, now: Date = Date()) -> Bool {
        guard let grant else { return false }
        return grant.isActive(now: now) && hasFullDesktopCapabilities(grant)
    }

    /// Fail-closed refusal for Junie missions that lack the full desktop
    /// grant. Returns `nil` for non-Junie backends and fully-granted
    /// Junie missions.
    static func directExecutionRefusal(
        backend: CLIAgentMissionBackend,
        grant: AgentCapabilityGrant
    ) -> CLIAgentMissionRequestListener.DirectCLIMissionResult? {
        guard backend.chatBackend == .junie, !hasFullDesktopCapabilities(grant) else { return nil }
        return CLIAgentMissionRequestListener.DirectCLIMissionResult(
            status: "failed",
            output: "",
            errorMessage: "Junie remote missions require both command execution and file-edit approval because the Junie CLI does not expose OpenBurnBar-enforceable read-only or no-shell flags.",
            sessionID: "policy-junie-\(UUID().uuidString)"
        )
    }
}
