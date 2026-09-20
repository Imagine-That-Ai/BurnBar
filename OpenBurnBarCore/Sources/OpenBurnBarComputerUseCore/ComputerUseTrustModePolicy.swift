import Foundation

/// Mid-session Computer Use trust is downgrade-only. Elevation requires a
/// fresh session (Mac UI). Shared by the Mac coordinator and the safety harness.
public enum ComputerUseTrustModePolicy: Sendable {
    public static func resolve(
        requested: ComputerUseTrustMode,
        current: ComputerUseTrustMode,
        sessionIsLive: Bool
    ) -> ComputerUseTrustMode {
        if sessionIsLive, requested > current {
            return current
        }
        return requested
    }

    public static func rejectsElevation(
        requested: ComputerUseTrustMode,
        current: ComputerUseTrustMode,
        sessionIsLive: Bool
    ) -> Bool {
        resolve(requested: requested, current: current, sessionIsLive: sessionIsLive) != requested
    }
}
