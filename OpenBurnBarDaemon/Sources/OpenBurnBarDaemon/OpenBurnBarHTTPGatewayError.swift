import Foundation

// remediation(gateway decomposition): relocated verbatim from
// OpenBurnBarHTTPGatewayServer.swift to shrink that 3,000+-line file. This is a
// top-level public type with no dependency on the actor's private state, so the
// move is mechanically safe and changes no behavior.
public enum BurnBarHTTPGatewayError: Error, LocalizedError {
    case invalidConfiguration(String)
    case listenerCreationFailed(error: Error)
    case invalidHost(String)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let msg):
            return "Gateway configuration error: \(msg)"
        case .listenerCreationFailed(let error):
            return "Failed to create gateway listener: \(error.localizedDescription)"
        case .invalidHost(let host):
            return "Invalid gateway host address: \(host)"
        }
    }
}
