import Foundation

// MARK: - PetAuthStatus

/// Live auth state for a provider, shown in the onboarding chip and used to gate
/// sends (PLAN §6 "`checkAuth()` returns `needs-login`/`error`"). Mirrors the web
/// `AuthStatus`.
enum PetAuthStatus: String, Sendable, Equatable {
    /// The provider's CLI / gateway is present and believed usable.
    case ready
    /// The provider exists but the user must authenticate (no token / not logged in).
    case needsLogin = "needs-login"
    /// The provider is unreachable or errored while probing.
    case error
    /// The provider is installed but this surface cannot satisfy its launch
    /// requirements (e.g. Junie refuses to run without a full desktop grant,
    /// which the pet surface never holds).
    case unavailable
    /// Not yet probed.
    case unknown

    /// Human-facing label for the onboarding row.
    var label: String {
        switch self {
        case .ready: return "Ready"
        case .needsLogin: return "Needs login"
        case .error: return "Error"
        case .unavailable: return "Unavailable"
        case .unknown: return "Checking…"
        }
    }
}

// MARK: - AgentChatProvider

/// The pet's answering-agent contract (PLAN C6): identity, a live ``checkAuth()``
/// for onboarding, and a token ``send(history:)`` stream.
///
/// **Reuse, not reinvention (Ground Truth #2).** The app already spawns the agent
/// child processes and parses their tokens in ``CLIBridge`` and orchestrates a
/// full send in ``ChatSessionController``. So the *primary* chat path the bubble
/// uses is ``PetChatController`` driving the shared ``ChatSessionController``
/// directly — these providers do **not** replace that transport. They are the
/// thin, uniform façade onboarding needs to (a) show a live auth state per
/// provider and (b) offer a provider-agnostic throwing token stream for any
/// surface that wants tokens without the heavyweight controller. Each concrete
/// provider *wraps* the matching ``CLIBridge`` stream method and maps
/// `CLIChatStreamEvent.text` into bare token strings; upstream errors either
/// use the local floor before any token is emitted or propagate after partial
/// output so callers never mistake a truncated stream for a complete answer.
@MainActor
protocol AgentChatProvider: AnyObject {
    /// The backend this provider answers as.
    var id: ChatBackendID { get }
    /// Display name (reuses ``ChatBackendID.displayName``).
    var displayName: String { get }
    /// Probe whether the provider is usable *right now* (CLI present / gateway up).
    func checkAuth() async -> PetAuthStatus
    /// Stream a reply token-by-token for `history`. Implementations translate the
    /// underlying `CLIChatStreamEvent.text` to bare strings.
    func send(history: [ChatMessageRecord]) -> AsyncThrowingStream<String, Error>
}

extension AgentChatProvider {
    var displayName: String { id.displayName }
}

// MARK: - PetChatProviders factory

/// Builds the concrete providers over the shared ``CLIBridge`` and a persona
/// system prompt. One factory so onboarding and any token-only surface resolve
/// providers the same way.
@MainActor
enum PetChatProviders {
    /// The short persona prompt the pet answers with — deliberately lighter than
    /// the app's "database analyst" prompt (Ground Truth #2 gap): casual front-desk
    /// guide, no retrieval pass.
    static let personaPrompt =
        "You are the BurnBar desktop companion: a concise, warm studio guide. " +
        "Answer in one or two short sentences. If you don't know, say so plainly."

    /// All providers in ``ChatBackendID`` order, sharing one bridge + keychain.
    static func all(
        bridge: CLIBridge,
        keychain: PetKeychainStore = PetKeychainStore(),
        workspace: URL? = nil
    ) -> [AgentChatProvider] {
        ChatBackendID.allCases.map { provider(for: $0, bridge: bridge, keychain: keychain, workspace: workspace) }
    }

    static func provider(
        for backend: ChatBackendID,
        bridge: CLIBridge,
        keychain: PetKeychainStore = PetKeychainStore(),
        workspace: URL? = nil
    ) -> AgentChatProvider {
        CLIBridgeChatProvider(
            id: backend,
            bridge: bridge,
            keychain: keychain,
            workspace: workspace
        )
    }
}

// MARK: - CLIBridgeChatProvider

/// A provider that wraps the existing ``CLIBridge`` stream methods for one
/// ``ChatBackendID``. It owns no transport of its own — it forwards to the app's
/// already-shipping send+stream engine and only re-shapes the event stream into
/// bare tokens and the availability probe into a ``PetAuthStatus``.
@MainActor
final class CLIBridgeChatProvider: AgentChatProvider {
    let id: ChatBackendID
    private let bridge: CLIBridge
    private let keychain: PetKeychainStore
    private let workspace: URL?

    init(id: ChatBackendID, bridge: CLIBridge, keychain: PetKeychainStore, workspace: URL?) {
        self.id = id
        self.bridge = bridge
        self.keychain = keychain
        self.workspace = workspace
    }

    // MARK: checkAuth

    func checkAuth() async -> PetAuthStatus {
        switch id {
        case .codex:
            return await bridge.isExecutableAvailable(named: "codex") ? .ready : .needsLogin
        case .claude:
            // The Claude CLI or a stored Anthropic API key both count as usable.
            if await bridge.isExecutableAvailable(named: "claude") { return .ready }
            return keychain.has(.claude) ? .ready : .needsLogin
        case .hermes:
            await bridge.probeHermesAvailability(bearerToken: try? keychain.get(.hermes))
            return bridge.hermesAvailable ? .ready : .error
        case .openclaw:
            await bridge.probeOpenClawAvailability(baseURL: openClawBaseURL(), bearerToken: try? keychain.get(.openclaw))
            return bridge.openClawAvailable ? .ready : .error
        case .piAgent:
            let base = piAgentBaseURL()
            await bridge.probePiAgentAvailability(baseURL: base, bearerToken: try? keychain.get(.piAgent))
            return bridge.piAgentAvailable ? .ready : .error
        case .droid:
            return await bridge.isExecutableAvailable(named: "droid") ? .ready : .needsLogin
        case .forge:
            return await bridge.isExecutableAvailable(named: "forge") ? .ready : .needsLogin
        case .antigravity:
            return await bridge.isExecutableAvailable(named: "agy") ? .ready : .needsLogin
        case .cursorAgent:
            return await bridge.isExecutableAvailable(named: "cursor-agent") ? .ready : .needsLogin
        case .openClaude:
            return await bridge.isExecutableAvailable(named: "openclaude") ? .ready : .needsLogin
        case .junie:
            // Junie fails closed without a full desktop capability grant
            // (CLIBridgeError.junieRequiresFullGrant), and the pet surface
            // never plumbs one — advertising "Ready" here would offer a pet
            // that silently answers from the local fallback instead of Junie.
            return .unavailable
        case .grok, .kimi:
            return .unavailable
        case .omp:
            return await bridge.isExecutableAvailable(named: "omp") ? .ready : .needsLogin
        }
    }

    // MARK: send

    func send(history: [ChatMessageRecord]) -> AsyncThrowingStream<String, Error> {
        let user = history.last { $0.role == .user }?.content ?? ""
        let upstream = upstreamStream(userMessage: user, history: history)
        return AsyncThrowingStream { continuation in
            let task = Task {
                var sentTokens = false
                do {
                    for try await event in upstream {
                        if case let .text(chunk) = event, !chunk.isEmpty {
                            sentTokens = true
                            continuation.yield(chunk)
                        }
                    }
                } catch {
                    if !sentTokens {
                        for await token in Self.fallbackStream(history: history) {
                            continuation.yield(token)
                        }
                    } else {
                        continuation.finish(throwing: error)
                        return
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func upstreamStream(
        userMessage: String,
        history: [ChatMessageRecord]
    ) -> AsyncThrowingStream<CLIChatStreamEvent, Error> {
        let persona = PetChatProviders.personaPrompt
        switch id {
        case .codex:
            return bridge.chatCodexStream(systemPrompt: persona, userMessage: userMessage, workspaceDirectory: workspace)
        case .claude:
            return bridge.chatClaudeStream(systemPrompt: persona, userMessage: userMessage, workspaceDirectory: workspace)
        case .hermes:
            return bridge.chatHermes(systemPrompt: persona, history: history, bearerToken: try? keychain.get(.hermes))
        case .openclaw:
            return bridge.chatOpenClaw(
                baseURL: openClawBaseURL(),
                systemPrompt: persona,
                history: history,
                bearerToken: try? keychain.get(.openclaw)
            )
        case .piAgent:
            return bridge.chatPiAgent(
                baseURL: piAgentBaseURL(),
                systemPrompt: persona,
                history: history,
                bearerToken: try? keychain.get(.piAgent)
            )
        case .droid:
            return bridge.chatDroidStream(systemPrompt: persona, userMessage: userMessage, workspaceDirectory: workspace)
        case .forge:
            return bridge.chatForgeStream(systemPrompt: persona, userMessage: userMessage, workspaceDirectory: workspace)
        case .antigravity:
            return bridge.chatAntigravityStream(systemPrompt: persona, userMessage: userMessage, workspaceDirectory: workspace)
        case .cursorAgent:
            return bridge.chatCursorAgentStream(systemPrompt: persona, userMessage: userMessage, workspaceDirectory: workspace)
        case .openClaude:
            return bridge.chatOpenClaudeStream(systemPrompt: persona, userMessage: userMessage, workspaceDirectory: workspace)
        case .junie:
            return bridge.chatJunieStream(systemPrompt: persona, userMessage: userMessage, workspaceDirectory: workspace)
        case .grok, .kimi:
            return nil
        case .omp:
            return bridge.chatOMPStream(systemPrompt: persona, userMessage: userMessage, workspaceDirectory: workspace)
        }
    }

    private static func fallbackStream(history: [ChatMessageRecord]) -> AsyncStream<String> {
        let turns = history.map { record in
            let role: PetChatFallback.Turn.Role
            switch record.role {
            case .user: role = .user
            case .assistant: role = .assistant
            case .system: role = .system
            }
            return PetChatFallback.Turn(role: role, text: record.content)
        }
        return PetChatFallback.stream(history: turns)
    }

    /// The configured OpenClaw base URL (stored alongside the token under a
    /// distinct Keychain account), falling back to the local gateway default.
    private func openClawBaseURL() -> URL {
        if let raw = try? keychain.get(.openclaw, account: "baseURL"), let url = URL(string: raw) {
            return url
        }
        return URL(string: "http://localhost:8642")!
    }

    private func piAgentBaseURL() -> URL {
        if let raw = try? keychain.get(.piAgent, account: "baseURL"), let url = URL(string: raw) {
            return url
        }
        return URL(string: "http://127.0.0.1:8765")!
    }
}
