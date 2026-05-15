import Foundation
import OpenBurnBarCore

/// Parsed from Claude `stream-json` lines (and Codex text deltas).
enum CLIChatStreamEvent: Hashable {
    case text(String)
    case toolUse(name: String, detail: String?)
    case toolResult(name: String, detail: String?)
    case usage(CLIUsageSnapshot)
}

struct CLIUsageSnapshot: Hashable {
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationTokens: Int
    let cacheReadTokens: Int
    let reasoningTokens: Int

    var totalTokens: Int {
        inputTokens + outputTokens + cacheCreationTokens + reasoningTokens
    }
}

// MARK: - Errors

enum CLIBridgeError: LocalizedError {
    case noCLI
    case processExit(code: Int)
    case codexEvent(String)
    case quotaExhausted(String)
    case hermesUnavailable
    case openClawUnavailable
    case piAgentUnavailable
    case hermesSSEError(String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .noCLI:
            return "No claude or codex CLI found in PATH. Install one to use chat."
        case .processExit(let code):
            if code == 127 {
                return "CLI exited with status 127 (runtime command not found). OpenBurnBar can see the CLI binary, but one of its dependencies (often `node`) is missing from app PATH."
            }
            return "CLI exited with status \(code)."
        case .codexEvent(let message):
            return message
        case .quotaExhausted(let detail):
            return detail
        case .hermesUnavailable:
            return "Hermes is not running. Open Settings → Chat Gateway and choose Open Hermes + Gateway, or enable the startup toggle there."
        case .openClawUnavailable:
            return "OpenClaw gateway is unavailable. Start the OpenClaw gateway (default 127.0.0.1:18789) or check Settings → Chat."
        case .piAgentUnavailable:
            return "Pi agent is not running. Open Settings → Chat Gateway and choose Open Pi + Gateway, or enable the startup toggle there."
        case .hermesSSEError(let detail):
            return "Chat server error: \(detail)"
        case .emptyResponse:
            return "CLI returned an empty response."
        }
    }
}

struct CLIProcessInvocation: Sendable {
    let executable: String
    let arguments: [String]
    let environment: [String: String]
    let workingDirectory: URL
    let cliType: SwitcherCLIProfileType
}
