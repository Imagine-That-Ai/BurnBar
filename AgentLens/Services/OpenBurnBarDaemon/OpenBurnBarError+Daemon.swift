import Foundation
import OpenBurnBarCore

extension OpenBurnBarError {
    /// Maps daemon manager / socket client failures into the shared taxonomy.
    static func fromDaemonManager(_ error: OpenBurnBarDaemonManagerError) -> OpenBurnBarError {
        switch error {
        case .daemonBinaryUnavailable:
            return .daemon("binary_unavailable", message: error.localizedDescription ?? "Daemon binary unavailable.")
        case .daemonResourceBundleUnavailable:
            return .daemon("resource_bundle_unavailable", message: error.localizedDescription ?? "Daemon resources missing.")
        case .launchctlFailed:
            return .daemon("launchctl_failed", message: error.localizedDescription ?? "launchctl failed.")
        case .timedOutWaitingForHealth:
            return .daemon("health_timeout", message: error.localizedDescription ?? "Daemon health timeout.")
        case .daemonSocketAuthTokenUnavailable:
            return .daemon("socket_auth_unavailable", message: error.localizedDescription ?? "Daemon socket auth unavailable.")
        case .emptyResponse:
            return .daemon("empty_response", message: error.localizedDescription ?? "Empty daemon response.")
        case .rpcError(let message):
            return .daemon("rpc_error", message: message)
        case .rpcTimedOut(let seconds):
            return .daemon("rpc_timeout", message: "OpenBurnBarDaemon RPC timed out after \(seconds)s.")
        }
    }
}
