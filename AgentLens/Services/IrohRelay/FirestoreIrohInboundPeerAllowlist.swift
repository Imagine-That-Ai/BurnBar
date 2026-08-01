import Foundation
import FirebaseFunctions
import OpenBurnBarIrohRelay

enum IrohInboundPeerPolicyLoadResult: Sendable, Equatable {
    /// A successfully verified server response. An empty policy is an
    /// authoritative revoke and must replace any locally cached routes.
    case authoritative(IrohInboundPeerPolicy)
    /// The callable could not establish server truth. The host may retain its
    /// last verified policy, but `IrohInboundPeerPolicy` still enforces each
    /// binding's local expiry and therefore fails closed without the server.
    case transientFailure
}

/// Resolves the server-verified controller route that may dial this host.
/// The callable revalidates pairing signatures, trusted devices, authority
/// keys, generation, and expiry; raw Firestore documents are not authority.
enum CallableIrohControllerRouteDirectory {
    static func load(
        uid: String,
        connectionId: String,
        resolve: (String, String) async throws -> [IrohControllerRouteBinding] = { uid, connectionId in
            try await ComputerUseSecurityCallableClient.resolveActiveIrohControllerRoutes(
                uid: uid,
                connectionId: connectionId
            )
        }
    ) async -> IrohInboundPeerPolicyLoadResult {
        do {
            let bindings = try await resolve(uid, connectionId)
            return .authoritative(IrohInboundPeerPolicy(routeBindings: bindings))
        } catch {
            // Failing here empties the inbound allowlist, so the host rejects
            // EVERY dial — the phone shows an endless "connecting"/"reconnecting"
            // cycle while the Mac looks perfectly healthy. `publicErrorMetadata`
            // alone is not readable: `logMetadata` hashes every metadata value,
            // so this line historically logged the failure without ever naming
            // it. Put the sanitized `domain#code` in the `.public` event string.
            let nsError = error as NSError
            AppLogger.network.error(
                "iroh_inbound_controller_route_resolution_failed connectionId=\(connectionId) errorClass=\(nsError.domain)#\(nsError.code) transient=\(isTransientTransportFailure(error))",
                metadata: AppLogger.publicErrorMetadata(error)
            )
            return isTransientTransportFailure(error)
                ? .transientFailure
                : .authoritative(IrohInboundPeerPolicy(routeBindings: []))
        }
    }

    static func isTransientTransportFailure(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            let transientCodes: Set<Int> = [
                NSURLErrorTimedOut,
                NSURLErrorCannotFindHost,
                NSURLErrorCannotConnectToHost,
                NSURLErrorNetworkConnectionLost,
                NSURLErrorDNSLookupFailed,
                NSURLErrorNotConnectedToInternet,
                NSURLErrorInternationalRoamingOff,
                NSURLErrorCallIsActive,
                NSURLErrorDataNotAllowed,
                NSURLErrorSecureConnectionFailed
            ]
            return transientCodes.contains(nsError.code)
        }
        guard nsError.domain == FunctionsErrorDomain,
              let code = FunctionsErrorCode(rawValue: nsError.code) else {
            return false
        }
        return code == .cancelled || code == .deadlineExceeded || code == .unavailable
    }
}
