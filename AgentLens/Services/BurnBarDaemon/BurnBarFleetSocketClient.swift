import BurnBarCore
import Foundation

// MARK: - Fleet Client Error

/// Typed failures from the app-side fleet RPC client (M3). The daemon's typed
/// error envelope is classified here so FleetService can render honest load
/// states (VAL-DASH-026/028, VAL-CROSS-007) instead of treating every failure
/// as "daemon down".
enum BurnBarFleetClientError: Error, LocalizedError, Equatable {
    /// The daemon socket is unreachable (ENOENT/ECONNREFUSED or transport failure).
    case daemonUnavailable(String)
    /// The daemon is alive but its first fleet tick has not completed.
    case notReady
    /// The daemon's protocol version or method set does not match this app.
    case protocolMismatch(reason: String)
    /// A typed RPC error envelope was returned.
    case rpcError(code: Int, message: String)
    /// The response envelope carried no result and no error.
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .daemonUnavailable(let detail):
            return "BurnBar daemon unreachable: \(detail)"
        case .notReady:
            return "BurnBar daemon is still preparing its first fleet snapshot."
        case .protocolMismatch(let reason):
            return "BurnBar daemon protocol mismatch: \(reason)"
        case .rpcError(let code, let message):
            return "BurnBar daemon RPC error (\(code)): \(message)"
        case .emptyResponse:
            return "BurnBar daemon returned an empty fleet response."
        }
    }
}

/// Daemon RPC error codes the app-side fleet client classifies (mirrors the
/// daemon's `BurnBarRPCErrorCode` values; kept app-side so the app never
/// depends on daemon-internal types).
private enum BurnBarFleetClientErrorCode {
    static let methodNotFound = -32601
    static let internalError = -32603
    static let protocolVersionMismatch = -32001
}

// MARK: - Fleet Snapshot Client

extension BurnBarDaemonSocketClient {
    /// Fetches the latest completed fleet snapshot (M3). The daemon's typed
    /// error envelope is classified into `BurnBarFleetClientError` so the app
    /// can render honest load/degraded states: an unreachable socket is
    /// `daemonUnavailable`, a pre-first-tick read is `notReady`, and a
    /// protocol/method mismatch is `protocolMismatch` — never a fabricated
    /// snapshot.
    static func fleetSnapshot(at socketURL: URL) throws -> BurnBarFleetSnapshot {
        let envelope: BurnBarRPCResponseEnvelope<BurnBarFleetSnapshotResponse> = try send(
            BurnBarRPCRequestEnvelope(method: .fleetSnapshot),
            socketURL: socketURL
        )

        if let error = envelope.error {
            throw Self.classifyFleetError(error)
        }

        guard let result = envelope.result else {
            throw BurnBarFleetClientError.emptyResponse
        }

        return result.snapshot
    }

    /// Maps a daemon error envelope to the typed app-side fleet error.
    /// - `-32603` with the documented not-ready message → `.notReady`
    /// - `-32601` (unknown method) or `-32001` (protocol mismatch) →
    ///   `.protocolMismatch` (old daemon vs new app, VAL-CROSS-007)
    /// - everything else → `.rpcError(code:message:)`
    private static func classifyFleetError(_ error: BurnBarRPCError) -> BurnBarFleetClientError {
        if error.code == BurnBarFleetClientErrorCode.internalError,
           error.message.contains("not ready") {
            return .notReady
        }
        if error.code == BurnBarFleetClientErrorCode.methodNotFound
            || error.code == BurnBarFleetClientErrorCode.protocolVersionMismatch {
            return .protocolMismatch(reason: error.message)
        }
        return .rpcError(code: error.code, message: error.message)
    }
}
