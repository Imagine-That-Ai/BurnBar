import Foundation

enum BurnBarFleetClientError: Error, LocalizedError, Equatable {
    case daemonUnavailable(String)
    case notReady
    case protocolMismatch(reason: String)
    case rpcError(code: Int, message: String)
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
            return "BurnBar daemon closed the fleet socket without a response."
        }
    }
}
