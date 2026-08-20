import Foundation
import OpenBurnBarCore

/// One prompt in, one complete answer out, over whichever backend the user has
/// already connected.
///
/// Extracted from `ChartInsightEngine`, which grew this logic first and is now
/// one of its two callers — the monthly recap's editorial pass is the other.
/// Keeping a single copy matters because the fiddly parts (the hard timeout so a
/// wedged CLI cannot pin a loading state, and Hermes' separate bearer-token
/// path) are exactly the parts that rot when duplicated.
/// Main-actor isolated: `PetChatProviders` and every `CLIBridge` chat entry
/// point are, and this logic previously lived inside a `@MainActor` type where
/// that was implicit.
@MainActor
enum CLIOneShotChat {

    /// Backends tried in order; the first `.ready` one wins.
    /// Local-first: the Hermes gateway on localhost outranks any cloud CLI.
    static let preferredOrder: [ChatBackendID] = [.hermes, .claude, .codex]

    /// The connected backends worth trying, preferred ones first.
    static func candidates(from enabled: [ChatBackendID]) -> [ChatBackendID] {
        preferredOrder.filter { enabled.contains($0) }
            + enabled.filter { !preferredOrder.contains($0) }
    }

    /// The first connected backend that answers, with its identity.
    ///
    /// `attempts` prompts are tried in order against each backend — the usual
    /// shape is the real prompt, then a "JSON only" reminder — and the first
    /// answer accepted by `isAcceptable` wins.
    static func firstAnswer(
        backends: [ChatBackendID],
        bridge: CLIBridge,
        systemPrompt: String,
        attempts: [String],
        timeout: TimeInterval = 90,
        isAcceptable: (String) -> Bool = { !$0.isEmpty }
    ) async -> (text: String, backend: ChatBackendID)? {
        for backend in backends {
            let provider = PetChatProviders.provider(for: backend, bridge: bridge)
            guard await provider.checkAuth() == .ready else { continue }

            for message in attempts {
                if Task.isCancelled { return nil }
                guard let text = await collect(
                    backend: backend,
                    bridge: bridge,
                    systemPrompt: systemPrompt,
                    message: message,
                    timeout: timeout
                ), !text.isEmpty else { break }
                if isAcceptable(text) { return (text, backend) }
            }
        }
        return nil
    }

    /// Accumulates a full one-shot response, bounded by a hard timeout so a
    /// wedged CLI can never pin the caller.
    static func collect(
        backend: ChatBackendID,
        bridge: CLIBridge,
        systemPrompt: String,
        message: String,
        timeout: TimeInterval = 90
    ) async -> String? {
        let stream: AsyncThrowingStream<CLIChatStreamEvent, Error>
        switch backend {
        case .hermes:
            // try?-ok(no stored token is a normal unauthenticated state; chatHermes takes an Optional bearer)
            let bearerToken = try? PetKeychainStore().get(.hermes)
            stream = bridge.chatHermes(
                systemPrompt: systemPrompt,
                history: [ChatMessageRecord(role: .user, content: message)],
                bearerToken: bearerToken
            )
        case .claude:
            stream = bridge.chatClaudeStream(
                systemPrompt: systemPrompt, userMessage: message, workspaceDirectory: nil
            )
        case .codex:
            stream = bridge.chatCodexStream(
                systemPrompt: systemPrompt, userMessage: message, workspaceDirectory: nil
            )
        default:
            return nil
        }

        return await withTaskGroup(of: String?.self) { group in
            group.addTask {
                var collected = ""
                do {
                    for try await event in stream {
                        if case let .text(chunk) = event { collected += chunk }
                    }
                } catch {
                    return collected.isEmpty ? nil : collected
                }
                return collected
            }
            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                } catch {
                    return nil
                }
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
