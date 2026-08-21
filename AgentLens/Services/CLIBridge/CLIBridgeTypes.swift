import Foundation
import OpenBurnBarCore

/// Parsed from Claude `stream-json` lines (and Codex text deltas).
enum CLIChatStreamEvent: Hashable {
    case text(String)
    case reasoning(String)
    case refusal(String)
    case toolUse(name: String, detail: String?)
    case toolResult(name: String, detail: String?)
    case usage(CLIUsageSnapshot)
    /// A provider-owned session identifier for multi-turn continuation
    /// (fx `session_id`, passed back as `--resume <id>` on the next send).
    case sessionID(String)

    init?(_ event: HermesStreamEvent) {
        switch event {
        case .messageChunk(let text):
            self = .text(text)
        case .reasoningChunk(let text):
            self = .reasoning(text)
        case .refusalChunk(let text):
            self = .refusal(text)
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
        case .reasoning(let text):
            return .reasoningChunk(text: text)
        case .refusal(let text):
            return .refusalChunk(text: text)
        case .toolUse(let name, let detail):
            return .toolCallChunk(id: name, index: 0, name: name, argumentsDelta: detail ?? "")
        case .toolResult(let name, let detail):
            return .toolResult(id: nil, name: name, detail: detail)
        case .usage(let usage):
            return .messageStop(finishReason: nil, outcome: .normal, usage: usage.hermesTokenUsage)
        case .sessionID:
            // Hermes has no provider-session continuation concept; drop it.
            return .notice(level: "info", text: "")
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
    /// T-AI-08: the requested model is not in the gateway's advertised/approved
    /// allowlist. Fail closed rather than letting a poisoned or typo model id
    /// reach an upstream provider.
    case disallowedModel(backend: String, model: String)
    case hermesSSEError(String)
    case emptyResponse
    /// Junie has no enforceable read-only/no-shell flags, so launching it
    /// without a full interactive grant would leave capability limits as
    /// prompt text only. Fail closed instead.
    case junieRequiresFullGrant
    /// fx surfaced an error in its structured `ask --json` response.
    case fxError(String)
    /// Grok and Kimi reach the Mac over the ACP mission relay, so `CLIBridge` has
    /// no chat stream for them. Fail closed instead of opening an empty stream the
    /// user would read as a hung assistant.
    case acpChatUnavailable(String)

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
        case .disallowedModel(let backend, let model):
            return "Model \"\(model)\" is not allowed for \(backend). Pick a model advertised by the gateway."
        case .hermesSSEError(let detail):
            return "Chat server error: \(detail)"
        case .emptyResponse:
            return "CLI returned an empty response."
        case .junieRequiresFullGrant:
            return "Junie cannot run in read-only mode. Grant file edits and shell access for this thread, or pick a different assistant."
        case .fxError(let message):
            return message
        case .acpChatUnavailable(let backend):
            return "\(backend) is not available in dashboard chat yet. Pick a different assistant for this thread."
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
