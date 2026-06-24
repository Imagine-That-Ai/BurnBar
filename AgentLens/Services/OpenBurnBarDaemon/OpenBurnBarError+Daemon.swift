import Foundation
import OpenBurnBarCore

extension OpenBurnBarError {
    /// Maps daemon manager / socket client failures into the shared taxonomy.
    static func fromDaemonManager(_ error: OpenBurnBarDaemonManagerError) -> OpenBurnBarError {
        switch error {
        case .daemonBinaryUnavailable:
            return .daemon("binary_unavailable", message: error.localizedDescription)
        case .daemonBinarySignatureInvalid:
            return .daemon("binary_signature_invalid", message: error.localizedDescription)
        case .daemonResourceBundleUnavailable:
            return .daemon("resource_bundle_unavailable", message: error.localizedDescription)
        case .daemonProjectCodeMemoryResourceUnavailable:
            return .daemon("project_code_memory_resource_unavailable", message: error.localizedDescription)
        case .launchctlFailed:
            return .daemon("launchctl_failed", message: error.localizedDescription)
        case .timedOutWaitingForHealth:
            return .daemon("health_timeout", message: error.localizedDescription)
        case .daemonSocketAuthTokenUnavailable:
            return .daemon("socket_auth_unavailable", message: error.localizedDescription)
        case .emptyResponse:
            return .daemon("empty_response", message: error.localizedDescription)
        case .rpcError(let message):
            return .daemon("rpc_error", message: message)
        case .rpcTimedOut(let seconds):
            return .daemon("rpc_timeout", message: "OpenBurnBarDaemon RPC timed out after \(seconds)s.")
        case .lifecycleStepFailed:
            return .daemon("lifecycle_step_failed", message: error.localizedDescription)
        }
    }
}
