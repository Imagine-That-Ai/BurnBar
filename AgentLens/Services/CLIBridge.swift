import Foundation
import OpenBurnBarCore

// MARK: - Stream events

/// Parsed from Claude `stream-json` lines (and Codex text deltas).
enum CLIChatStreamEvent: Hashable {
    case text(String)
    case toolUse(name: String, detail: String?)
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

// MARK: - CLI Bridge

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

    private var runningProcess: Process?
    /// Detached task for OpenAI-compatible SSE (Hermes / OpenClaw).
    private var httpStreamTask: Task<Void, Never>?

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
    func probeHermesAvailability(bearerToken: String? = nil) async {
        let result = await Self.probeHermes(
            baseURL: URL(string: "http://localhost:8642")!,
            bearerToken: bearerToken
        )
        hermesAvailable = result.available
        hermesModelName = result.modelName
    }

    /// Probe OpenClaw gateway (OpenAI-compatible `/v1/models`).
    func probeOpenClawAvailability(baseURL: URL, bearerToken: String? = nil) async {
        openClawAvailable = await Self.probeOpenAICompatibleGateway(baseURL: baseURL, bearerToken: bearerToken)
    }

    nonisolated private static func openAICompatibleModelsURL(baseURL: URL) -> URL? {
        URL(string: "v1/models", relativeTo: baseURL)?.absoluteURL
    }

    nonisolated private static func probeOpenAICompatibleGateway(baseURL: URL, bearerToken: String?) async -> Bool {
        guard let url = openAICompatibleModelsURL(baseURL: baseURL) else { return false }
        var request = URLRequest(url: url, timeoutInterval: 2)
        request.httpMethod = "GET"
        if let token = bearerToken?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else { return false }
            _ = data
            return true
        } catch {
            return false
        }
    }

    nonisolated private static func probeHermes(baseURL: URL, bearerToken: String?) async -> (available: Bool, modelName: String?) {
        guard let url = openAICompatibleModelsURL(baseURL: baseURL) else { return (false, nil) }
        var request = URLRequest(url: url, timeoutInterval: 2)
        request.httpMethod = "GET"
        if let token = bearerToken?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else { return (false, nil) }
            // Parse model name from OpenAI-compatible /v1/models response
            let modelName = Self.parseModelName(from: data)
            return (true, modelName)
        } catch {
            return (false, nil)
        }
    }

    /// Extracts the first model id from an OpenAI-compatible /v1/models response.
    nonisolated private static func parseModelName(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        // Standard format: { "data": [{ "id": "model-name", ... }] }
        if let models = obj["data"] as? [[String: Any]],
           let first = models.first,
           let id = first["id"] as? String, !id.isEmpty {
            return id
        }
        // Fallback: top-level "model" key
        if let model = obj["model"] as? String, !model.isEmpty {
            return model
        }
        return nil
    }

    func cancel() {
        runningProcess?.terminate()
        runningProcess = nil
        httpStreamTask?.cancel()
        httpStreamTask = nil
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
                prompt: Self.combinedPrompt(systemPrompt: systemPrompt, userMessage: userMessage),
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
                prompt: Self.combinedPrompt(systemPrompt: systemPrompt, userMessage: userMessage),
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
                await self.runClaudeStream(
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
                await self.runCodexStream(
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

                let fullPrompt = Self.combinedPrompt(systemPrompt: systemPrompt, userMessage: userMessage)

                switch backend {
                case .claudeCode(let path):
                    await self.runClaudeStream(
                        executable: path,
                        prompt: fullPrompt,
                        model: "",
                        workspaceDirectory: nil,
                        continuation: continuation
                    )
                case .codex(let path):
                    await self.runCodexStream(
                        executable: path,
                        prompt: fullPrompt,
                        model: "",
                        workspaceDirectory: nil,
                        continuation: continuation
                    )
                case .hermes:
                    // Single-turn fallback for Hermes — use chatHermes() for multi-turn
                    continuation.finish(throwing: CLIBridgeError.hermesUnavailable)
                }
            }
        }
    }

    /// Streams assistant text and tool-use events from Hermes gateway API (OpenAI-compatible SSE).
    /// Supports multi-turn: the full message history is sent as the `messages` array.
    func chatHermes(
        systemPrompt: String,
        history: [ChatMessageRecord],
        bearerToken: String? = nil,
        model: String = "hermes"
    ) -> AsyncThrowingStream<CLIChatStreamEvent, Error> {
        let baseURL = URL(string: "http://localhost:8642")!
        let stream = AsyncThrowingStream<CLIChatStreamEvent, Error> { continuation in
            let task = Task.detached { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                await self.runHermesStream(
                    baseURL: baseURL,
                    model: model,
                    systemPrompt: systemPrompt,
                    history: history,
                    bearerToken: bearerToken,
                    continuation: continuation
                )
            }
            self.httpStreamTask = task
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
            let task = Task.detached { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                await self.runOpenClawStream(
                    baseURL: baseURL,
                    model: {
                        let t = model.trimmingCharacters(in: .whitespacesAndNewlines)
                        return t.isEmpty ? "gpt-4o-mini" : t
                    }(),
                    systemPrompt: systemPrompt,
                    history: history,
                    bearerToken: bearerToken,
                    continuation: continuation
                )
            }
            self.httpStreamTask = task
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
                let fullPrompt = Self.combinedPrompt(systemPrompt: systemPrompt, userMessage: userMessage)
                await self.runCodexStream(
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
                let fullPrompt = Self.combinedPrompt(systemPrompt: systemPrompt, userMessage: userMessage)
                await self.runClaudeStream(
                    executable: executable,
                    prompt: fullPrompt,
                    model: model,
                    workspaceDirectory: workspaceDirectory,
                    continuation: continuation
                )
            }
        }
    }

    nonisolated private func runHermesStream(
        baseURL: URL,
        model: String,
        systemPrompt: String,
        history: [ChatMessageRecord],
        bearerToken: String?,
        continuation: AsyncThrowingStream<CLIChatStreamEvent, Error>.Continuation
    ) async {
        await runOpenAICompatibleChatCompletionsStream(
            baseURL: baseURL,
            model: model,
            systemPrompt: systemPrompt,
            history: history,
            bearerToken: bearerToken,
            unavailableError: .hermesUnavailable,
            continuation: continuation
        )
    }

    nonisolated private func runOpenClawStream(
        baseURL: URL,
        model: String,
        systemPrompt: String,
        history: [ChatMessageRecord],
        bearerToken: String?,
        continuation: AsyncThrowingStream<CLIChatStreamEvent, Error>.Continuation
    ) async {
        await runOpenAICompatibleChatCompletionsStream(
            baseURL: baseURL,
            model: model,
            systemPrompt: systemPrompt,
            history: history,
            bearerToken: bearerToken,
            unavailableError: .openClawUnavailable,
            continuation: continuation
        )
    }

    /// Shared SSE path for Hermes gateway API and OpenClaw gateway (OpenAI-compatible).
    nonisolated private func runOpenAICompatibleChatCompletionsStream(
        baseURL: URL,
        model: String,
        systemPrompt: String,
        history: [ChatMessageRecord],
        bearerToken: String?,
        unavailableError: CLIBridgeError,
        continuation: AsyncThrowingStream<CLIChatStreamEvent, Error>.Continuation
    ) async {
        defer {
            Task { @MainActor [weak self] in
                self?.httpStreamTask = nil
            }
        }

        guard let url = URL(string: "v1/chat/completions", relativeTo: baseURL)?.absoluteURL else {
            continuation.finish(throwing: unavailableError)
            return
        }

        let messages = Self.buildHermesMessages(systemPrompt: systemPrompt, history: history)

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 0
        config.timeoutIntervalForResource = 0
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        var streamedAnyContent = false
        do {
            let body: [String: Any] = [
                "model": model,
                "stream": true,
                "messages": messages,
                "stream_options": ["include_usage": true]
            ]
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let token = bearerToken?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (bytes, response) = try await session.bytes(for: request)

            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                continuation.finish(throwing: CLIBridgeError.hermesSSEError("HTTP \(http.statusCode)"))
                return
            }

            for try await line in bytes.lines {
                try Task.checkCancellation()

                guard line.hasPrefix("data: ") else { continue }
                let payload = String(line.dropFirst(6))
                guard payload != "[DONE]" else { break }

                guard let data = payload.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }

                if let usage = Self.openAICompatibleUsage(from: obj) {
                    continuation.yield(.usage(usage))
                }

                guard let choices = obj["choices"] as? [[String: Any]],
                      let choice = choices.first else { continue }

                guard let delta = choice["delta"] as? [String: Any] else { continue }

                if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                    for tc in toolCalls {
                        if let function = tc["function"] as? [String: Any],
                           let name = function["name"] as? String, !name.isEmpty {
                            let args = function["arguments"] as? String
                            continuation.yield(.toolUse(
                                name: name,
                                detail: args.flatMap { $0.isEmpty ? nil : String($0.prefix(200)) }
                            ))
                        }
                    }
                }

                if let content = delta["content"] as? String, !content.isEmpty {
                    continuation.yield(.text(content))
                    streamedAnyContent = true
                }
            }
        } catch is CancellationError {
            continuation.finish()
            return
        } catch {
            continuation.finish(throwing: error)
            return
        }

        if !streamedAnyContent {
            do {
                try Task.checkCancellation()
                let content = try await Self.hermesNonStreamingFallback(
                    url: url,
                    messages: messages,
                    model: model,
                    session: session,
                    bearerToken: bearerToken
                )
                if !content.content.isEmpty {
                    continuation.yield(.text(content.content))
                }
                if let usage = content.usage {
                    continuation.yield(.usage(usage))
                }
            } catch is CancellationError {
                // fine
            } catch {
                continuation.finish(throwing: error)
                return
            }
        }

        continuation.finish()
    }

    /// Replays the same conversation non-streaming to recover content that
    /// Hermes consumed during server-side tool execution.
    nonisolated private static func hermesNonStreamingFallback(
        url: URL,
        messages: [[String: String]],
        model: String,
        session: URLSession,
        bearerToken: String?
    ) async throws -> (content: String, usage: CLIUsageSnapshot?) {
        let body: [String: Any] = ["model": model, "stream": false, "messages": messages]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = bearerToken?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw CLIBridgeError.hermesSSEError("HTTP \(http.statusCode)")
        }

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String
        else { return ("", Self.openAICompatibleUsage(from: (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:])) }

        return (content, Self.openAICompatibleUsage(from: obj))
    }

    nonisolated private static func buildHermesMessages(
        systemPrompt: String,
        history: [ChatMessageRecord]
    ) -> [[String: String]] {
        var messages: [[String: String]] = [
            ["role": "system", "content": systemPrompt]
        ]
        for msg in history {
            let role: String
            switch msg.role {
            case .user: role = "user"
            case .assistant: role = "assistant"
            case .system: continue
            }
            guard !msg.content.isEmpty else { continue }
            messages.append(["role": role, "content": msg.content])
        }
        return messages
    }

    nonisolated static func openAICompatibleUsage(from obj: [String: Any]) -> CLIUsageSnapshot? {
        let usage = (obj["usage"] as? [String: Any]) ?? obj

        func firstInt(paths: [[String]]) -> Int {
            for path in paths {
                var cursor: Any = usage
                var valid = true
                for key in path {
                    guard let dict = cursor as? [String: Any], let next = dict[key] else {
                        valid = false
                        break
                    }
                    cursor = next
                }
                guard valid else { continue }
                if let value = cursor as? Int { return max(value, 0) }
                if let value = cursor as? Int64 { return max(Int(value), 0) }
                if let value = cursor as? Double { return max(Int(value.rounded()), 0) }
                if let value = cursor as? NSNumber { return max(value.intValue, 0) }
                if let value = cursor as? String {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let intValue = Int(trimmed) { return max(intValue, 0) }
                    if let doubleValue = Double(trimmed) { return max(Int(doubleValue.rounded()), 0) }
                }
            }
            return 0
        }

        let inputTokens = firstInt(paths: [
            ["input_tokens"],
            ["prompt_tokens"],
            ["inputTokens"],
            ["promptTokens"]
        ])
        let outputTokens = firstInt(paths: [
            ["output_tokens"],
            ["completion_tokens"],
            ["outputTokens"],
            ["completionTokens"]
        ])
        let cacheCreationTokens = firstInt(paths: [
            ["cache_creation_input_tokens"],
            ["cache_creation_tokens"],
            ["cacheCreationTokens"]
        ])
        let cacheReadTokens = firstInt(paths: [
            ["cache_read_input_tokens"],
            ["cache_read_tokens"],
            ["cacheReadTokens"],
            ["cached_tokens"],
            ["cachedTokens"],
            ["prompt_tokens_details", "cached_tokens"],
            ["promptTokensDetails", "cachedTokens"]
        ])

        // VAL-TOKEN-006: Extract reasoning tokens from all known paths
        let reasoningTokens = firstInt(paths: [
            ["thinking_tokens"],
            ["reasoning_tokens"],
            ["thinkingTokens"],
            ["reasoningTokens"],
            ["completion_tokens_details", "reasoning_tokens"],
            ["output_tokens_details", "reasoning_tokens"]
        ])

        // VAL-TOKEN-004: Guard - return nil only when ALL buckets are unavailable.
        // This is the gating check: fallback should only run when no exact buckets exist.
        guard inputTokens > 0 || outputTokens > 0 || cacheCreationTokens > 0 || cacheReadTokens > 0 || reasoningTokens > 0 else {
            return nil
        }

        return CLIUsageSnapshot(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens,
            reasoningTokens: reasoningTokens
        )
    }

    nonisolated private func runClaudeStream(
        executable: String,
        prompt: String,
        model: String,
        workspaceDirectory: URL? = nil,
        continuation: AsyncThrowingStream<CLIChatStreamEvent, Error>.Continuation
    ) async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Self.claudeArguments(prompt: prompt, model: model)
        process.environment = Self.enrichedProcessEnvironment(executablePath: executable)
        process.currentDirectoryURL = workspaceDirectory ?? FileManager.default.homeDirectoryForCurrentUser

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        let quotaRecorder = CLIBridgeQuotaSignalRecorder()
        let supervisor = Self.makeTerminalSessionSupervisor(
            cliType: .claude,
            process: process,
            quotaRecorder: quotaRecorder
        )

        await MainActor.run {
            self.runningProcess = process
        }

        do {
            try process.run()
        } catch {
            await MainActor.run { self.runningProcess = nil }
            continuation.finish(throwing: error)
            return
        }

        let stderrTask = Task.detached(priority: .utility) {
            await Self.drainPipe(stderrPipe, into: supervisor, source: .stderr)
        }

        let readHandle = stdoutPipe.fileHandleForReading
        while let line = readHandle.readLine() {
            supervisor.ingest(line + "\n", source: .stdout)
            if let detail = quotaRecorder.snapshot() {
                if process.isRunning {
                    process.terminate()
                }
                break
            }
            for event in Self.events(fromStreamJSONLine: line) {
                continuation.yield(event)
            }
        }

        process.waitUntilExit()
        await stderrTask.value

        await MainActor.run { self.runningProcess = nil }

        if let detail = quotaRecorder.snapshot() {
            continuation.finish(throwing: CLIBridgeError.quotaExhausted(detail))
            return
        }
        if process.terminationStatus != 0, process.terminationStatus != 15 {
            continuation.finish(throwing: CLIBridgeError.processExit(code: Int(process.terminationStatus)))
            return
        }
        continuation.finish()
    }

    /// `codex exec --json` writes JSON Lines to stdout while the run is in progress (see OpenAI Codex non-interactive docs).
    nonisolated private func runCodexStream(
        executable: String,
        prompt: String,
        model: String,
        workspaceDirectory: URL? = nil,
        continuation: AsyncThrowingStream<CLIChatStreamEvent, Error>.Continuation
    ) async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Self.codexArguments(prompt: prompt, model: model)
        process.environment = Self.enrichedProcessEnvironment(executablePath: executable)
        process.currentDirectoryURL = workspaceDirectory ?? FileManager.default.homeDirectoryForCurrentUser

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        let quotaRecorder = CLIBridgeQuotaSignalRecorder()
        let supervisor = Self.makeTerminalSessionSupervisor(
            cliType: .codex,
            process: process,
            quotaRecorder: quotaRecorder
        )

        await MainActor.run {
            self.runningProcess = process
        }

        do {
            try process.run()
        } catch {
            await MainActor.run { self.runningProcess = nil }
            continuation.finish(throwing: error)
            return
        }

        let stderrTask = Task.detached(priority: .utility) {
            await Self.drainPipe(stderrPipe, into: supervisor, source: .stderr)
        }

        let readHandle = stdoutPipe.fileHandleForReading
        var lastAgentMessagePrefixLength = 0
        var lastAgentMessageItemId: String?

        while let line = readHandle.readLine() {
            supervisor.ingest(line + "\n", source: .stdout)
            if let detail = quotaRecorder.snapshot() {
                if process.isRunning {
                    process.terminate()
                }
                break
            }
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            if let type = obj["type"] as? String {
                if type == "turn.started" || type == "thread.started" {
                    lastAgentMessagePrefixLength = 0
                    lastAgentMessageItemId = nil
                    if type == "turn.started" {
                        continuation.yield(.toolUse(name: "Codex", detail: "Thinking…"))
                    }
                }
                if type == "error" {
                    let msg = (obj["message"] as? String)
                        ?? (obj["error"] as? String)
                        ?? "Codex reported an error"
                    continuation.finish(throwing: Self.codexEventError(from: msg))
                    if process.isRunning {
                        process.terminate()
                    }
                    await MainActor.run { self.runningProcess = nil }
                    await stderrTask.value
                    return
                }
            }

            if let toolEvent = Self.codexToolEvent(from: obj) {
                continuation.yield(toolEvent)
            }

            guard let fullText = Self.extractCodexAgentMessageText(from: obj), !fullText.isEmpty else {
                continue
            }

            if let itemId = Self.codexAgentMessageItemId(from: obj) {
                if itemId != lastAgentMessageItemId {
                    lastAgentMessagePrefixLength = 0
                    lastAgentMessageItemId = itemId
                }
            }

            if fullText.count < lastAgentMessagePrefixLength {
                lastAgentMessagePrefixLength = 0
            }

            if fullText.count > lastAgentMessagePrefixLength {
                let previousPrefixLength = lastAgentMessagePrefixLength
                let start = fullText.index(fullText.startIndex, offsetBy: previousPrefixLength)
                let delta = String(fullText[start...])
                lastAgentMessagePrefixLength = fullText.count
                if !delta.isEmpty {
                    let eventType = obj["type"] as? String ?? ""
                    // Codex JSONL commonly emits a single final `item.completed` text blob. Chunk that blob so UI can
                    // render progressive text instead of one large jump.
                    let shouldSoftStream = eventType == "item.completed"
                        && previousPrefixLength == 0
                        && delta.count >= 120
                    if shouldSoftStream {
                        for chunk in Self.chunkedCodexText(delta) {
                            continuation.yield(.text(chunk))
                            try? await Task.sleep(nanoseconds: 16_000_000)
                        }
                    } else {
                        continuation.yield(.text(delta))
                    }
                }
            }
        }

        process.waitUntilExit()
        await stderrTask.value

        await MainActor.run { self.runningProcess = nil }

        if let detail = quotaRecorder.snapshot() {
            continuation.finish(throwing: CLIBridgeError.quotaExhausted(detail))
            return
        }
        if process.terminationStatus != 0, process.terminationStatus != 15 {
            continuation.finish(throwing: CLIBridgeError.processExit(code: Int(process.terminationStatus)))
            return
        }
        continuation.finish()
    }

    /// Pulls assistant-visible text from a Codex JSONL object (`codex exec --json`).
    nonisolated private static func extractCodexAgentMessageText(from obj: [String: Any]) -> String? {
        let type = obj["type"] as? String ?? ""

        if type == "item.completed" || type == "item.updated" || type == "item.started" {
            if let item = obj["item"] as? [String: Any],
               (item["type"] as? String) == "agent_message" {
                if let text = item["text"] as? String { return text }
            }
        }

        if let item = obj["item"] as? [String: Any],
           (item["type"] as? String) == "agent_message",
           let text = item["text"] as? String {
            return text
        }

        if let message = obj["message"] as? [String: Any],
           let text = message["text"] as? String {
            return text
        }

        return nil
    }

    /// Stable id for the Codex `agent_message` item when present (used to reset streaming deltas between messages).
    nonisolated private static func codexAgentMessageItemId(from obj: [String: Any]) -> String? {
        guard let item = obj["item"] as? [String: Any],
              (item["type"] as? String) == "agent_message" else {
            return nil
        }
        if let id = item["id"] as? String, !id.isEmpty { return id }
        return nil
    }

    nonisolated private static func codexToolEvent(from obj: [String: Any]) -> CLIChatStreamEvent? {
        guard (obj["type"] as? String) == "item.started",
              let item = obj["item"] as? [String: Any],
              (item["type"] as? String) == "command_execution" else {
            return nil
        }
        let command = (item["command"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let command, !command.isEmpty else {
            return .toolUse(name: "Bash", detail: nil)
        }
        return .toolUse(name: "Bash", detail: String(command.prefix(180)))
    }

    nonisolated static func codexEventError(from message: String) -> CLIBridgeError {
        if let detail = CLIQuotaExhaustionClassifier.classify(for: .codex, in: message) {
            return .quotaExhausted(detail)
        }
        return .codexEvent(message)
    }

    nonisolated private static func makeTerminalSessionSupervisor(
        cliType: SwitcherCLIProfileType,
        process: Process,
        quotaRecorder: CLIBridgeQuotaSignalRecorder
    ) -> CLITerminalSessionSupervisor {
        CLITerminalSessionSupervisor(cliType: cliType) { event in
            guard case .quotaExhausted(let detail, _) = event else { return }
            quotaRecorder.record(detail)
            if process.isRunning {
                process.terminate()
            }
        }
    }

    nonisolated private static func drainPipe(
        _ pipe: Pipe,
        into supervisor: CLITerminalSessionSupervisor,
        source: CLITerminalSessionOutputSource
    ) async {
        let readHandle = pipe.fileHandleForReading
        while let line = readHandle.readLine() {
            supervisor.ingest(line + "\n", source: source)
        }
    }

    nonisolated private static func chunkedCodexText(_ text: String, maxChunkLength: Int = 44) -> [String] {
        guard maxChunkLength > 0 else { return [text] }
        var chunks: [String] = []
        var current = ""
        current.reserveCapacity(min(maxChunkLength, text.count))

        for character in text {
            current.append(character)
            if character == "\n" || current.count >= maxChunkLength {
                chunks.append(current)
                current.removeAll(keepingCapacity: true)
            }
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }

    private func resolveExecutable(named name: String) async -> String? {
        await Task.detached {
            let env = ProcessInfo.processInfo.environment
            let fileManager = FileManager.default
            let homeDirectory = fileManager.homeDirectoryForCurrentUser.path

            if let path = Self.resolveExecutable(
                named: name,
                searchDirectories: Self.baseExecutableSearchDirectories(
                    environment: env,
                    homeDirectory: homeDirectory
                ),
                fileManager: fileManager
            ) {
                return path
            }

            if let path = Self.resolveExecutableFromLoginShell(
                named: name,
                environment: env,
                fileManager: fileManager
            ) {
                return path
            }

            if let path = Self.resolveExecutable(
                named: name,
                searchDirectories: Self.userManagedExecutableSearchDirectories(
                    homeDirectory: homeDirectory,
                    fileManager: fileManager
                ),
                fileManager: fileManager
            ) {
                return path
            }

            return nil
        }.value
    }

    nonisolated static func baseExecutableSearchDirectories(
        environment: [String: String],
        homeDirectory: String
    ) -> [String] {
        let pathEntries = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)

        return deduplicatedDirectories(pathEntries + [
            "\(homeDirectory)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin"
        ])
    }

    nonisolated static func userManagedExecutableSearchDirectories(
        homeDirectory: String,
        fileManager: FileManager = .default
    ) -> [String] {
        var directories = [
            "\(homeDirectory)/.npm-global/bin",
            "\(homeDirectory)/.bun/bin",
            "\(homeDirectory)/.volta/bin",
            "\(homeDirectory)/.asdf/shims",
            "\(homeDirectory)/.mise/shims"
        ]

        directories.append(contentsOf:
            contentsOfDirectory(
                atPath: "\(homeDirectory)/.nvm/versions/node",
                appending: "/bin",
                fileManager: fileManager
            )
        )

        directories.append(contentsOf:
            contentsOfDirectory(
                atPath: "\(homeDirectory)/.fnm/node-versions",
                appending: "/installation/bin",
                fileManager: fileManager
            )
        )

        return deduplicatedDirectories(directories)
    }

    nonisolated static func resolveExecutable(
        named name: String,
        searchDirectories: [String],
        fileManager: FileManager = .default
    ) -> String? {
        for directory in searchDirectories {
            let candidate = URL(fileURLWithPath: directory)
                .appendingPathComponent(name)
                .path
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    nonisolated static func resolveExecutableFromLoginShell(
        named name: String,
        environment: [String: String],
        fileManager: FileManager = .default
    ) -> String? {
        let shellPath = environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        guard fileManager.isExecutableFile(atPath: shellPath) else {
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = ["-lic", "command -v -- \(shellQuoted(name)) 2>/dev/null"]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8),
              let path = parseExecutablePath(fromCommandOutput: output),
              fileManager.isExecutableFile(atPath: path) else {
            return nil
        }

        return path
    }

    nonisolated static func parseExecutablePath(fromCommandOutput output: String) -> String? {
        output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .reversed()
            .first(where: { $0.hasPrefix("/") })
    }

    /// Sanitizes a prompt string for safe passage as a command-line argument.
    /// Removes control characters and newlines that could cause CLI parsing issues.
    /// This is defense-in-depth - Process API passes arguments directly without shell interpretation.
    nonisolated static func sanitizedPrompt(_ input: String) -> String {
        // Remove null bytes and control characters except for common printable range
        let sanitized = input
            .replacingOccurrences(of: "\u{0000}", with: "") // null byte
            .replacingOccurrences(of: "\u{0001}", with: "")
            .replacingOccurrences(of: "\u{0002}", with: "")
            .replacingOccurrences(of: "\u{0003}", with: "")
            .replacingOccurrences(of: "\u{0004}", with: "")
            .replacingOccurrences(of: "\u{0005}", with: "")
            .replacingOccurrences(of: "\u{0006}", with: "")
            .replacingOccurrences(of: "\u{0007}", with: "")
            .replacingOccurrences(of: "\u{0008}", with: "") // backspace
            .replacingOccurrences(of: "\u{000B}", with: "") // vertical tab
            .replacingOccurrences(of: "\u{000C}", with: "") // form feed
            // Keep \t (horizontal tab), \n, \r as they're often in prompts
        return sanitized
    }

    nonisolated static func claudeArguments(prompt: String, model: String = "") -> [String] {
        var arguments = [
            "-p",
            sanitizedPrompt(prompt),
        ]
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedModel.isEmpty == false {
            arguments.append(contentsOf: ["--model", trimmedModel])
        }
        arguments.append(contentsOf: [
            "--output-format",
            "stream-json",
            "--verbose",
        ])
        return arguments
    }

    /// GUI apps often have a minimal `PATH`; CLIs frequently invoke `node`/`python` via the shebang.
    nonisolated private static func enrichedProcessEnvironment(executablePath: String? = nil) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let homeDirectory = NSHomeDirectory()
        var extra = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "\(homeDirectory)/.local/bin",
        ]

        if let executablePath {
            let executableDirectory = URL(fileURLWithPath: executablePath)
                .deletingLastPathComponent()
                .standardizedFileURL
                .path
            extra.insert(executableDirectory, at: 0)
        }

        extra.append(contentsOf: userManagedExecutableSearchDirectories(homeDirectory: homeDirectory))

        let existing = env["PATH"] ?? ""
        let merged = (extra + existing.split(separator: ":").map(String.init))
            .filter { !$0.isEmpty }
        var seen = Set<String>()
        env["PATH"] = merged.filter { seen.insert($0).inserted }.joined(separator: ":")
        return env
    }

    /// Models shown in chat UI and accepted by `codex exec -m` (normalized via `normalizedCodexModel`).
    nonisolated static let codexChatModelIDs: [String] = [
        "gpt-5.4",
        "gpt-5.4-mini",
        "gpt-5.4-nano",
        "gpt-5.4-pro",
        "gpt-5.3-codex",
        "gpt-5.2-codex",
        "gpt-5.2-pro",
        "gpt-5.1-codex",
        "gpt-5.1-codex-mini",
        "gpt-5.1-codex-max"
    ]

    nonisolated static func normalizedCodexModel(_ model: String, fallback: String = "gpt-5.4-mini") -> String {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedModel.isEmpty == false else { return fallback }

        if let canonical = codexChatModelIDs.first(where: {
            $0.caseInsensitiveCompare(trimmedModel) == .orderedSame
        }) {
            return canonical
        }

        return fallback
    }

    nonisolated static func codexArguments(prompt: String, model: String = "gpt-5.4-mini") -> [String] {
        let normalizedModel = normalizedCodexModel(model)
        return [
            "exec",
            "--json",
            "--ephemeral",
            "--skip-git-repo-check",
            "-m",
            normalizedModel,
            "-c",
            #"model_reasoning_effort="medium""#,
            sanitizedPrompt(prompt)
        ]
    }

    nonisolated private static func combinedPrompt(systemPrompt: String, userMessage: String) -> String {
        """
        \(systemPrompt)

        User:
        \(userMessage)
        """
    }

    nonisolated private static func contentsOfDirectory(
        atPath path: String,
        appending suffix: String,
        fileManager: FileManager
    ) -> [String] {
        guard let entries = try? fileManager.contentsOfDirectory(atPath: path) else {
            return []
        }

        return entries
            .sorted(by: >)
            .map { "\(path)/\($0)\(suffix)" }
    }

    nonisolated private static func deduplicatedDirectories(_ directories: [String]) -> [String] {
        var seen = Set<String>()

        return directories.compactMap { directory in
            let expanded = NSString(string: directory).expandingTildeInPath
            guard !expanded.isEmpty else {
                return nil
            }

            let standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path
            guard seen.insert(standardized).inserted else {
                return nil
            }

            return standardized
        }
    }

    nonisolated private static func shellQuoted(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    /// Emits ordered `.text` / `.toolUse` events for one NDJSON line from Claude Code `stream-json`.
    nonisolated private static func events(fromStreamJSONLine line: String) -> [CLIChatStreamEvent] {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        if let message = obj["message"] as? [String: Any],
           let content = message["content"] as? [[String: Any]], !content.isEmpty {
            var out: [CLIChatStreamEvent] = []
            for block in content {
                let kind = block["type"] as? String ?? ""
                if kind == "text", let text = block["text"] as? String, !text.isEmpty {
                    out.append(.text(text))
                } else if kind == "tool_use", let pair = toolUsePayload(from: block) {
                    out.append(.toolUse(name: pair.0, detail: pair.1))
                }
            }
            if !out.isEmpty { return out }
        }

        if (obj["type"] as? String) == "tool_use", let pair = toolUsePayload(from: obj) {
            return [.toolUse(name: pair.0, detail: pair.1)]
        }

        if let text = extractStreamJSONText(from: obj), !text.isEmpty {
            return [.text(text)]
        }

        return []
    }

    nonisolated private static func toolUsePayload(from obj: [String: Any]) -> (String, String?)? {
        let name = (obj["name"] as? String) ?? (obj["tool"] as? String)
        guard let name, !name.isEmpty else { return nil }
        return (name, toolInputSummary(obj["input"] as? [String: Any]))
    }

    nonisolated private static func toolInputSummary(_ input: [String: Any]?) -> String? {
        guard let input else { return nil }
        if let p = input["path"] as? String ?? input["file_path"] as? String, !p.isEmpty { return p }
        if let c = input["command"] as? String, !c.isEmpty { return String(c.prefix(160)) }
        if let p = input["pattern"] as? String, !p.isEmpty { return p }
        if let q = input["query"] as? String, !q.isEmpty { return String(q.prefix(120)) }
        return nil
    }

    nonisolated private static func extractStreamJSONText(from obj: [String: Any]) -> String? {
        if let delta = obj["delta"] as? [String: Any] {
            if let text = delta["text"] as? String { return text }
            if let inner = delta["delta"] as? [String: Any], let text = inner["text"] as? String {
                return text
            }
        }

        if let message = obj["message"] as? [String: Any],
           let content = message["content"] as? [[String: Any]] {
            for block in content {
                if (block["type"] as? String) == "text", let text = block["text"] as? String {
                    return text
                }
            }
        }

        if let event = obj["event"] as? [String: Any],
           let delta = event["delta"] as? [String: Any],
           let text = delta["text"] as? String {
            return text
        }

        return nil
    }
}

enum CLIBridgeError: LocalizedError {
    case noCLI
    case processExit(code: Int)
    case codexEvent(String)
    case quotaExhausted(String)
    case hermesUnavailable
    case openClawUnavailable
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
            return "Hermes isn’t running. Enable API_SERVER_ENABLED in ~/.hermes/.env, run hermes gateway run. Token in Settings only if you use API_SERVER_KEY there."
        case .openClawUnavailable:
            return "OpenClaw gateway is unavailable. Start the OpenClaw gateway (default 127.0.0.1:18789) or check Settings → Chat."
        case .hermesSSEError(let detail):
            return "Chat server error: \(detail)"
        case .emptyResponse:
            return "CLI returned an empty response."
        }
    }
}

private final class CLIBridgeQuotaSignalRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var detail: String?

    func record(_ detail: String) {
        lock.lock()
        if self.detail == nil {
            self.detail = detail
        }
        lock.unlock()
    }

    func snapshot() -> String? {
        lock.lock()
        let value = detail
        lock.unlock()
        return value
    }
}
