import Foundation
import OpenBurnBarCore

@MainActor
final class CLIBridge: ObservableObject {
    enum Backend: Equatable {
        case claudeCode(path: String)
        case codex(path: String)
        case hermes(baseURL: URL)
    }

    private(set) var detectedBackend: Backend?
    private(set) var hermesAvailable: Bool = false
    private(set) var openClawAvailable: Bool = false
    /// The model name currently loaded in Hermes (fetched from /v1/models).
    private(set) var hermesModelName: String?

    nonisolated private let resolver = CLIExecutableResolver()
    nonisolated private let streamRuntime = CLIBridgeStreamRuntimeCoordinator()

    /// Whether a CLI binary exists on PATH (used to validate Codex vs Claude selection).
    func isExecutableAvailable(named name: String) async -> Bool {
        await resolveExecutable(named: name) != nil
    }

    func detect() async {
        // Prefer Codex when both are installed so chat remains available if Claude CLI auth/config is broken.
        if let path = await resolveExecutable(named: "codex") {
            detectedBackend = .codex(path: path)
            return
        }
        if let path = await resolveExecutable(named: "claude") {
            detectedBackend = .claudeCode(path: path)
            return
        }
        detectedBackend = nil
    }

    /// Non-blocking probe for Hermes gateway API availability. Does not set `detectedBackend`.
    /// Also fetches the current model name from the models endpoint.
    func probeHermesAvailability(
        baseURL: URL = URL(string: "http://127.0.0.1:8642")!,
        bearerToken: String? = nil
    ) async {
        let result = await Self.probeHermes(
            baseURL: baseURL,
            bearerToken: bearerToken
        )
        hermesAvailable = result.available
        hermesModelName = result.modelName
    }

    /// Probe OpenClaw gateway (OpenAI-compatible `/v1/models`).
    func probeOpenClawAvailability(baseURL: URL, bearerToken: String? = nil) async {
        openClawAvailable = await OpenAICompatibleModelProbe.probe(baseURL: baseURL, bearerToken: bearerToken)
    }

    func cancel() {
        Task {
            await streamRuntime.cancelAll()
        }
    }

    func generateTextWithClaude(
        model: String,
        systemPrompt: String,
        userMessage: String
    ) async throws -> String {
        guard let executable = await resolveExecutable(named: "claude") else {
            throw CLIBridgeError.noCLI
        }

        return try await collectText(
            from: streamClaude(
                executable: executable,
                prompt: CLIArgumentBuilder.combinedPrompt(systemPrompt: systemPrompt, userMessage: userMessage),
                model: model
            )
        )
    }

    func generateTextWithCodex(
        model: String,
        systemPrompt: String,
        userMessage: String
    ) async throws -> String {
        guard let executable = await resolveExecutable(named: "codex") else {
            throw CLIBridgeError.noCLI
        }

        return try await collectText(
            from: streamCodex(
                executable: executable,
                prompt: CLIArgumentBuilder.combinedPrompt(systemPrompt: systemPrompt, userMessage: userMessage),
                model: model
            )
        )
    }

    private func collectText(
        from stream: AsyncThrowingStream<CLIChatStreamEvent, Error>
    ) async throws -> String {
        var output = ""
        for try await event in stream {
            guard case .text(let chunk) = event, chunk.isEmpty == false else { continue }
            output += chunk
        }

        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            throw CLIBridgeError.emptyResponse
        }
        return trimmed
    }

    private func streamClaude(
        executable: String,
        prompt: String,
        model: String
    ) -> AsyncThrowingStream<CLIChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task.detached { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                await CLIProcessStreamRunner(runtime: self.streamRuntime).runClaude(
                    executable: executable,
                    prompt: prompt,
                    model: model,
                    workspaceDirectory: nil,
                    continuation: continuation
                )
            }
        }
    }

    private func streamCodex(
        executable: String,
        prompt: String,
        model: String
    ) -> AsyncThrowingStream<CLIChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task.detached { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                await CLIProcessStreamRunner(runtime: self.streamRuntime).runCodex(
                    executable: executable,
                    prompt: prompt,
                    model: model,
                    workspaceDirectory: nil,
                    continuation: continuation
                )
            }
        }
    }

    /// Streams assistant text and tool-use events from the CLI (Claude `stream-json`, Codex JSONL text only).
    func chat(systemPrompt: String, userMessage: String) -> AsyncThrowingStream<CLIChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task.detached { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                let backend = await MainActor.run { self.detectedBackend }
                guard let backend else {
                    continuation.finish(throwing: CLIBridgeError.noCLI)
                    return
                }

                let fullPrompt = CLIArgumentBuilder.combinedPrompt(systemPrompt: systemPrompt, userMessage: userMessage)
                let runner = CLIProcessStreamRunner(runtime: self.streamRuntime)

                switch backend {
                case .claudeCode(let path):
                    await runner.runClaude(
                        executable: path,
                        prompt: fullPrompt,
                        model: "",
                        workspaceDirectory: nil,
                        continuation: continuation
                    )
                case .codex(let path):
                    await runner.runCodex(
                        executable: path,
                        prompt: fullPrompt,
                        model: "",
                        workspaceDirectory: nil,
                        continuation: continuation
                    )
                case .hermes:
                    continuation.finish(throwing: CLIBridgeError.hermesUnavailable)
                }
            }
        }
    }

    /// Streams assistant text and tool-use events from Hermes gateway API (OpenAI-compatible SSE).
    func chatHermes(
        baseURL: URL = URL(string: "http://127.0.0.1:8642")!,
        systemPrompt: String,
        history: [ChatMessageRecord],
        bearerToken: String? = nil,
        model: String = "hermes"
    ) -> AsyncThrowingStream<CLIChatStreamEvent, Error> {
        let stream = AsyncThrowingStream<CLIChatStreamEvent, Error> { continuation in
            let streamIDTask = Task { [streamRuntime] in
                await streamRuntime.nextHTTPStreamID()
            }
            let task = Task.detached { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                let streamID = await streamIDTask.value
                await OpenAICompatibleChatGatewayClient(runtime: self.streamRuntime).runStream(
                    baseURL: baseURL,
                    model: model,
                    systemPrompt: systemPrompt,
                    history: history,
                    bearerToken: bearerToken,
                    unavailableError: .hermesUnavailable,
                    httpStreamID: streamID,
                    continuation: continuation
                )
            }
            continuation.onTermination = { [streamRuntime] _ in
                task.cancel()
                Task {
                    let streamID = await streamIDTask.value
                    await streamRuntime.cancelHTTPStreamTask(streamID: streamID)
                }
            }
            Task.detached { [streamRuntime] in
                let streamID = await streamIDTask.value
                await streamRuntime.installHTTPStreamTask(task, streamID: streamID)
            }
        }
        return stream
    }

    /// OpenClaw gateway — OpenAI-compatible SSE (`/v1/chat/completions`).
    func chatOpenClaw(
        baseURL: URL,
        systemPrompt: String,
        history: [ChatMessageRecord],
        bearerToken: String?,
        model: String = "gpt-4o-mini"
    ) -> AsyncThrowingStream<CLIChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let streamIDTask = Task { [streamRuntime] in
                await streamRuntime.nextHTTPStreamID()
            }
            let task = Task.detached { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                let streamID = await streamIDTask.value
                await OpenAICompatibleChatGatewayClient(runtime: self.streamRuntime).runStream(
                    baseURL: baseURL,
                    model: {
                        let t = model.trimmingCharacters(in: .whitespacesAndNewlines)
                        return t.isEmpty ? "gpt-4o-mini" : t
                    }(),
                    systemPrompt: systemPrompt,
                    history: history,
                    bearerToken: bearerToken,
                    unavailableError: .openClawUnavailable,
                    httpStreamID: streamID,
                    continuation: continuation
                )
            }
            continuation.onTermination = { [streamRuntime] _ in
                task.cancel()
                Task {
                    let streamID = await streamIDTask.value
                    await streamRuntime.cancelHTTPStreamTask(streamID: streamID)
                }
            }
            Task.detached { [streamRuntime] in
                let streamID = await streamIDTask.value
                await streamRuntime.installHTTPStreamTask(task, streamID: streamID)
            }
        }
    }

    /// Streams using Codex CLI only (ignores Claude if both are installed).
    func chatCodexStream(
        systemPrompt: String,
        userMessage: String,
        workspaceDirectory: URL? = nil,
        model: String = ""
    ) -> AsyncThrowingStream<CLIChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task.detached { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                guard let executable = await self.resolveExecutable(named: "codex") else {
                    continuation.finish(throwing: CLIBridgeError.noCLI)
                    return
                }
                let fullPrompt = CLIArgumentBuilder.combinedPrompt(systemPrompt: systemPrompt, userMessage: userMessage)
                await CLIProcessStreamRunner(runtime: self.streamRuntime).runCodex(
                    executable: executable,
                    prompt: fullPrompt,
                    model: model,
                    workspaceDirectory: workspaceDirectory,
                    continuation: continuation
                )
            }
        }
    }

    /// Streams using Claude Code CLI only.
    func chatClaudeStream(
        systemPrompt: String,
        userMessage: String,
        workspaceDirectory: URL? = nil,
        model: String = ""
    ) -> AsyncThrowingStream<CLIChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task.detached { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                guard let executable = await self.resolveExecutable(named: "claude") else {
                    continuation.finish(throwing: CLIBridgeError.noCLI)
                    return
                }
                let fullPrompt = CLIArgumentBuilder.combinedPrompt(systemPrompt: systemPrompt, userMessage: userMessage)
                await CLIProcessStreamRunner(runtime: self.streamRuntime).runClaude(
                    executable: executable,
                    prompt: fullPrompt,
                    model: model,
                    workspaceDirectory: workspaceDirectory,
                    continuation: continuation
                )
            }
        }
    }

    private func resolveExecutable(named name: String) async -> String? {
        await resolver.resolveExecutable(named: name)
    }

    nonisolated private static func probeHermes(baseURL: URL, bearerToken: String?) async -> (available: Bool, modelName: String?) {
        await OpenAICompatibleModelProbe.probeWithModel(baseURL: baseURL, bearerToken: bearerToken)
    }
}
