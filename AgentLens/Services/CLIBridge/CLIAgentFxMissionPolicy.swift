import Foundation
import OpenBurnBarComputerUseCore

/// fx exposes enforceable permission flags (`--auto` enables automatic
/// review, default mode exits before running unresolved sensitive calls,
/// `--yolo` disables checks), so unlike Junie it does not need a
/// fail-closed full-grant launch gate. The policy here is narrower:
///
/// - `--yolo` is never passed (T-TOOL-02(a): no vendor full-autonomy
///   bypass arguments).
/// - `--auto` is only passed for an active, trusted grant carrying the full
///   desktop capability set, because automatic review can approve sensitive
///   actions without a human in the loop.
/// - Without the full grant, fx runs in its default permission mode,
///   which exits before running unresolved sensitive calls — fail closed
///   by the vendor's own harness.
enum CLIAgentFxMissionPolicy {
    static func hasFullDesktopCapabilities(_ grant: AgentCapabilityGrant) -> Bool {
        grant.capabilities.contains(.shell) && grant.capabilities.contains(.workspaceWrite)
    }

    /// Whether `--auto` may be passed for this grant. The argument builder's
    /// single gate; tests pin the same decision through it.
    static func autoReviewPermitted(_ grant: AgentCapabilityGrant?, now: Date = Date()) -> Bool {
        guard let grant else { return false }
        return grant.isActive(now: now)
            && grant.trustMode == .trusted
            && hasFullDesktopCapabilities(grant)
    }
}
