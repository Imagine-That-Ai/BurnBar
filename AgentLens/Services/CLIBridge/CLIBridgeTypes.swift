import Foundation
import OpenBurnBarCore

/// Parsed from Claude `stream-json` lines (and Codex text deltas).
enum CLIChatStreamEvent: Hashable {
    case text(String)
    case toolUse(name: String, detail: String?)
    case toolResult(name: String, detail: String?)
    case usage(CLIUsageSnapshot)

    init?(_ event: HermesStreamEvent) {
        switch event {
        case .messageChunk(let text), .reasoningChunk(let text), .refusalChunk(let text):
            self = .text(text)
        case .toolCallChunk(_, _, let name, let argumentsDelta):
            self = .toolUse(
                name: Self.nonEmpty(name) ?? "tool",
                detail: Self.nonEmpty(argumentsDelta)
            )
        case .toolCallFinished(_, let name, let arguments):
            self = .toolUse(name: name, detail: Self.nonEmpty(arguments))
        case .toolResult(_, let name, let detail):
            self = .toolResult(name: name, detail: detail)
        case .messageStop(_, _, let usage):
            guard let usage else { return nil }
            self = .usage(CLIUsageSnapshot(
                inputTokens: usage.promptTokens ?? 0,
                outputTokens: usage.outputTokens ?? 0,
                cacheCreationTokens: 0,
                cacheReadTokens: 0,
                reasoningTokens: 0
            ))
        case .longToolHint, .notice:
            return nil
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    var hermesStreamEvent: HermesStreamEvent {
        switch self {
        case .text(let text):
            return .messageChunk(text: text)
        case .toolUse(let name, let detail):
            return .toolCallChunk(id: name, index: 0, name: name, argumentsDelta: detail ?? "")
        case .toolResult(let name, let detail):
            return .toolResult(id: nil, name: name, detail: detail)
        case .usage(let usage):
            return .messageStop(finishReason: nil, outcome: .normal, usage: usage.hermesTokenUsage)
        }
    }
}

struct OpenAICompatibleAdvertisedModel: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let displayName: String
    let providerID: String?
    let providerName: String?
    let routeEligible: Bool
    let modelCapabilities: ModelIOCapabilities?

    init(
        id: String,
        displayName: String,
        providerID: String?,
        providerName: String?,
        routeEligible: Bool,
        modelCapabilities: ModelIOCapabilities? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.providerID = providerID
        self.providerName = providerName
        self.routeEligible = routeEligible
        self.modelCapabilities = modelCapabilities
    }

    var menuTitle: String {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let provider = providerName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let provider, !provider.isEmpty, !name.isEmpty, name != id {
            let normalizedName = name.lowercased()
            if normalizedName.contains(provider.lowercased())
                || normalizedName.contains("openburnbar route")
                || normalizedName.contains("via openburnbar") {
                return name
            }
            return "\(name) · \(provider)"
        }
        if !name.isEmpty { return name }
        return id
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
    case noSelectedModel(String)
    case hermesSSEError(String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .noCLI:
            return "Requested CLI was not found in PATH. Install it and restart OpenBurnBar so the Mac relay can run it."
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
        case .noSelectedModel(let backend):
            return "No model selected for \(backend). Choose a live advertised model before sending."
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
