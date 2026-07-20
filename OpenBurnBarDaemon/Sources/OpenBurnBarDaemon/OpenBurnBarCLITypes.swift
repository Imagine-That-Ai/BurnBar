import OpenBurnBarEngine
import Foundation

public enum BurnBarCLIHealthFormatter {
    public static func format(_ response: BurnBarHealthResponse) -> String {
        "Daemon \(response.daemonVersion) | protocol \(response.protocolVersion) | socket \(response.socketPath ?? "n/a") | ok=\(response.ok)"
    }
}

public enum BurnBarCLIError: LocalizedError {
    case invalidCommand(String)
    case missingArgument(String)
    case missingExecutablePath
    case privacyRPCError(code: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .invalidCommand(let command):
            return "Unsupported OpenBurnBar CLI command '\(command)'."
        case .missingArgument(let usage):
            return usage
        case .missingExecutablePath:
            return "Could not resolve the currently running OpenBurnBarCLI executable."
        case .privacyRPCError(let code, let message):
            return "privacy_rpc_error code=\(code) message=\(message)"
        }
    }
}

public struct BurnBarCLIInvocationResult: Equatable, Sendable {
    public let output: String?
    public let exitCode: Int32

    public init(output: String?, exitCode: Int32) {
        self.output = output
        self.exitCode = exitCode
    }
}

public struct BurnBarCLIStartupPreflightResult: Equatable, Sendable {
    public let output: String
    public let exitCode: Int32
    public let writesToStandardError: Bool

    public init(output: String, exitCode: Int32, writesToStandardError: Bool) {
        self.output = output
        self.exitCode = exitCode
        self.writesToStandardError = writesToStandardError
    }
}
