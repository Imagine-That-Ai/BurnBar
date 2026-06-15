import OpenBurnBarCore
import Darwin
import Foundation

/// Result of one local `codex exec` invocation: the raw exit code plus the
/// captured stdout/stderr. Mirrors `FactoryDroidProcessResult` so the daemon's
/// local-CLI executors share a uniform process-runner shape.
public struct BurnBarCodexProcessResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Abstraction over spawning the local `codex` binary so tests can inject a
/// stub runner without touching the real process. Modeled on
/// `FactoryDroidProcessRunning`.
public protocol BurnBarCodexProcessRunning: Sendable {
    func runCodex(
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL,
        timeout: TimeInterval
    ) async throws -> BurnBarCodexProcessResult
}

/// Default `codex` runner that spawns the consent-gated local `codex` binary as
/// a one-shot subprocess (`codex exec --json …`). It never inherits daemon
/// secrets and runs read-only by default, matching the CLI-assistant consent
/// gate used elsewhere in the app.
public struct BurnBarCodexSystemProcessRunner: BurnBarCodexProcessRunning {
    private let executableURL: URL?

    public init(executableURL: URL? = nil) {
        self.executableURL = executableURL
    }

    public func runCodex(
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL,
        timeout: TimeInterval
    ) async throws -> BurnBarCodexProcessResult {
        try await Task.detached(priority: .utility) {
            try Self.runSynchronously(
                executableURL: executableURL ?? Self.defaultCodexExecutableURL(),
                arguments: arguments,
                environment: environment,
                workingDirectory: workingDirectory,
                timeout: timeout
            )
        }.value
    }

    private static func defaultCodexExecutableURL() -> URL {
        var candidates = [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin/codex")
                .path,
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/usr/bin/codex"
        ]
        let pathCandidates = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("codex").path }
        candidates.append(contentsOf: pathCandidates)
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        return URL(fileURLWithPath: "/usr/bin/env")
    }

    private static func runSynchronously(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL,
        timeout: TimeInterval
    ) throws -> BurnBarCodexProcessResult {
        let process = Process()
        if executableURL.lastPathComponent == "env" {
            process.executableURL = executableURL
            process.arguments = ["codex"] + arguments
        } else {
            process.executableURL = executableURL
            process.arguments = arguments
        }
        process.environment = environment
        process.currentDirectoryURL = workingDirectory

        let fileManager = FileManager.default
        let captureDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("openburnbar-codex-process-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(
            at: captureDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? fileManager.removeItem(at: captureDirectory) }

        let stdoutURL = captureDirectory.appendingPathComponent("stdout.log", isDirectory: false)
        let stderrURL = captureDirectory.appendingPathComponent("stderr.log", isDirectory: false)
        fileManager.createFile(atPath: stdoutURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        fileManager.createFile(atPath: stderrURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdoutHandle.close()
            try? stderrHandle.close()
        }
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle

        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.2)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            throw BurnBarProviderExecutorError.upstreamError(504, "Codex execution timed out.")
        }

        return BurnBarCodexProcessResult(
            exitCode: process.terminationStatus,
            stdout: readUTF8File(stdoutURL, cappedAt: 2 * 1024 * 1024),
            stderr: readUTF8File(stderrURL, cappedAt: 2 * 1024 * 1024)
        )
    }

    private static func readUTF8File(_ url: URL, cappedAt byteLimit: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: byteLimit)
        let truncated = ((try? handle.offset()) ?? 0) >= UInt64(byteLimit)
        let text = String(data: data, encoding: .utf8) ?? ""
        return truncated ? text + "\n<openburnbar-output-truncated>" : text
    }
}

/// Gateway-routable executor that serves a completion through the **local,
/// consent-gated** `codex` CLI (`codex exec --json …`). This makes `codex` a
/// first-class provider so a mixed Elder Wand panel can include it alongside
/// HTTP providers, instead of only being reachable as an interactive CLI
/// assistant.
///
/// ## Consent gate (preserved)
///
/// Codex is a local agent CLI that can read files and run commands. This
/// executor keeps the CLI-assistant consent posture intact for an unattended
/// routed completion:
///
/// - It always runs **read-only** (`--sandbox read-only`) and never passes any
///   full-autonomy / workspace-write bypass flags — the same conservative
///   default the interactive CLI bridge uses when no capability grant is
///   active.
/// - It runs with `--ignore-user-config --ignore-rules` so the routed turn does
///   not pick up the user's local Codex automation/config, `--ephemeral` so it
///   leaves no persistent session, and `--skip-git-repo-check` so it works in a
///   throwaway temp cwd.
/// - The process runs in a fresh, isolated 0700 temp directory and inherits a
///   sanitized environment (no daemon tokens, cloud creds, or SSH sockets).
/// - A backend guardrail prepended to the prompt instructs the model to answer
///   directly and not inspect files, run commands, or mention routing.
public struct BurnBarCodexProviderExecutor: BurnBarProviderExecuting, Sendable {
    private let runner: any BurnBarCodexProcessRunning
    private let timeout: TimeInterval

    public init(
        runner: any BurnBarCodexProcessRunning = BurnBarCodexSystemProcessRunner(),
        timeout: TimeInterval = 120
    ) {
        self.runner = runner
        self.timeout = timeout
    }

    public func completeStructured(
        _ request: BurnBarStructuredPromptRequest,
        route: BurnBarProviderRoute
    ) async throws -> BurnBarProviderExecutionResult {
        let prompt = Self.promptText(from: request)
        let output = try await execute(prompt: prompt, route: route)
        return BurnBarProviderExecutionResult(
            outputText: output,
            inputTokens: max(1, prompt.count / 4),
            outputTokens: max(1, output.count / 4),
            cacheCreationTokens: 0,
            cacheReadTokens: 0
        )
    }

    public func proxyChatCompletions(
        body: Data,
        route: BurnBarProviderRoute,
        variant: BurnBarModelVariant? = nil
    ) async throws -> BurnBarProviderProxyResponse {
        let request = try Self.chatCompletionPrompt(from: body)
        let output = try await execute(prompt: request.prompt, route: route)
        let responseBody = try Self.chatCompletionResponseBody(
            modelID: route.resolvedModelID,
            output: output,
            stream: request.stream
        )
        return BurnBarProviderProxyResponse(
            statusCode: 200,
            contentType: request.stream ? "text/event-stream" : "application/json",
            body: responseBody,
            usage: Self.usage(prompt: request.prompt, output: output)
        )
    }

    public func proxyResponses(
        body: Data,
        route: BurnBarProviderRoute,
        variant: BurnBarModelVariant? = nil
    ) async throws -> BurnBarProviderProxyResponse {
        let request = try Self.responsesPrompt(from: body)
        let output = try await execute(prompt: request.prompt, route: route)
        let responseBody = try Self.responsesBody(
            modelID: route.resolvedModelID,
            output: output,
            stream: request.stream
        )
        return BurnBarProviderProxyResponse(
            statusCode: 200,
            contentType: request.stream ? "text/event-stream" : "application/json",
            body: responseBody,
            usage: Self.usage(prompt: request.prompt, output: output)
        )
    }

    // MARK: - Execution

    private func execute(prompt: String, route: BurnBarProviderRoute) async throws -> String {
        guard route.providerID.caseInsensitiveCompare("codex") == .orderedSame else {
            throw BurnBarProviderExecutorError.upstreamError(400, "Codex executor received a non-Codex route.")
        }

        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("openburnbar-codex-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(
            at: tempRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? fileManager.removeItem(at: tempRoot) }

        let arguments = Self.codexArguments(model: route.resolvedModelID, prompt: prompt)
        let environment = Self.sanitizedEnvironment(apiKey: route.apiKey)

        let result = try await runner.runCodex(
            arguments: arguments,
            environment: environment,
            workingDirectory: tempRoot,
            timeout: timeout
        )

        if result.exitCode != 0 {
            throw Self.classifiedError(output: "\(result.stdout)\n\(result.stderr)", route: route)
        }
        if let upstreamError = Self.firstReportedError(in: result.stdout, route: route)
            ?? Self.firstReportedError(in: result.stderr, route: route) {
            throw upstreamError
        }

        let output = Self.extractAgentMessage(fromJSONL: result.stdout)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else {
            throw BurnBarProviderExecutorError.invalidResponse
        }
        return output
    }

    /// Mirrors `CLIArgumentBuilder.codexArguments` for the consent-gated,
    /// read-only path: JSONL output, ephemeral session, high reasoning effort,
    /// no workspace write, and no inherited user config/rules. The prompt is the
    /// final positional argument.
    static func codexArguments(model: String, prompt: String) -> [String] {
        var arguments = [
            "exec",
            "--json",
            "--ephemeral",
            "--skip-git-repo-check",
            "-c",
            #"model_reasoning_effort="high""#
        ]
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedModel.isEmpty {
            arguments.append(contentsOf: ["-m", trimmedModel])
        }
        // Consent gate: read-only sandbox, ignore user automation, no full-auto bypass.
        arguments.append(contentsOf: [
            "--sandbox",
            "read-only",
            "--ignore-user-config",
            "--ignore-rules"
        ])
        arguments.append(prompt)
        return arguments
    }

    static func sanitizedEnvironment(apiKey: String) -> [String: String] {
        let current = ProcessInfo.processInfo.environment
        var environment: [String: String] = [:]
        for key in ["PATH", "LANG", "LC_ALL", "TERM", "TMPDIR"] {
            if let value = current[key], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                environment[key] = value
            }
        }
        if environment["PATH"] == nil {
            environment["PATH"] = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        }
        environment["HOME"] = NSHomeDirectory()
        // Codex authenticates from its local login (`~/.codex/auth.json`) when no
        // key is configured. A configured key (if any) is passed through so a
        // user who routes Codex on a console key keeps working; an empty key
        // leaves the local login in charge.
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            environment["OPENAI_API_KEY"] = trimmedKey
        }
        return environment
    }

    // MARK: - Prompt assembly

    private static func promptText(from request: BurnBarStructuredPromptRequest) -> String {
        var parts: [String] = [backendGuardrail]
        if let systemPrompt = request.systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !systemPrompt.isEmpty {
            parts.append("System:\n\(systemPrompt)")
        }
        for block in request.assistantContextBlocks where !block.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("Prior assistant context:\n\(block)")
        }
        parts.append("User:\n\(request.userPrompt)")
        if request.jsonOnly {
            parts.append("Return valid JSON only.")
        }
        return parts.joined(separator: "\n\n")
    }

    private static let backendGuardrail = """
    You are serving one OpenBurnBar routed completion request through Codex.
    Return only the assistant response for the user request.
    Do not inspect or modify files, run commands, call tools, change models, or mention routing internals.
    """

    static func chatCompletionPrompt(from body: Data) throws -> (prompt: String, stream: Bool) {
        guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw BurnBarProviderExecutorError.invalidResponse
        }
        let messages = (object["messages"] as? [[String: Any]]) ?? []
        var parts = [backendGuardrail]
        for message in messages {
            let role = (message["role"] as? String ?? "user").capitalized
            let content = text(from: message["content"])
            if !content.isEmpty {
                parts.append("\(role):\n\(content)")
            }
        }
        if let responseFormat = object["response_format"] as? [String: Any],
           (responseFormat["type"] as? String) == "json_object" {
            parts.append("Return valid JSON only.")
        }
        return (parts.joined(separator: "\n\n"), object["stream"] as? Bool ?? false)
    }

    static func responsesPrompt(from body: Data) throws -> (prompt: String, stream: Bool) {
        guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw BurnBarProviderExecutorError.invalidResponse
        }
        var parts = [backendGuardrail]
        if let instructions = object["instructions"] as? String,
           !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("System:\n\(instructions)")
        }
        if let input = object["input"] {
            let inputText = text(from: input)
            if !inputText.isEmpty {
                parts.append("User:\n\(inputText)")
            }
        }
        return (parts.joined(separator: "\n\n"), object["stream"] as? Bool ?? false)
    }

    private static func text(from value: Any?) -> String {
        switch value {
        case let string as String:
            return string
        case let array as [Any]:
            return array.map(text(from:)).filter { !$0.isEmpty }.joined(separator: "\n")
        case let object as [String: Any]:
            if let text = object["text"] as? String {
                return text
            }
            if let content = object["content"] {
                return text(from: content)
            }
            if let outputText = object["output_text"] as? String {
                return outputText
            }
            return ""
        default:
            return ""
        }
    }

    // MARK: - Codex JSONL parsing

    /// Walks the `codex exec --json` JSONL transcript and returns the latest
    /// `agent_message` text. Mirrors the production `CodexExecJSONLParser`
    /// extraction (item.completed/updated/started with `item.type ==
    /// "agent_message"` and `item.text`, plus a top-level `message.text`
    /// fallback).
    static func extractAgentMessage(fromJSONL jsonl: String) -> String {
        var latest = ""
        jsonl.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }
            if let text = agentMessageText(from: object), !text.isEmpty {
                latest = text
            }
        }
        return latest
    }

    private static func agentMessageText(from object: [String: Any]) -> String? {
        if let item = object["item"] as? [String: Any],
           (item["type"] as? String) == "agent_message",
           let text = item["text"] as? String {
            return text
        }
        if let message = object["message"] as? [String: Any],
           let text = message["text"] as? String {
            return text
        }
        return nil
    }

    /// Detects a `type:"error"` JSONL line and classifies it. Returns `nil` when
    /// the transcript reports no error.
    static func firstReportedError(
        in jsonl: String,
        route: BurnBarProviderRoute
    ) -> BurnBarProviderExecutorError? {
        var found: BurnBarProviderExecutorError?
        jsonl.enumerateLines { line, stop in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (object["type"] as? String) == "error" else {
                return
            }
            let message = (object["message"] as? String)
                ?? (object["error"] as? String)
                ?? "Codex reported an error."
            found = classifiedError(output: message, route: route)
            stop = true
        }
        return found
    }

    static func classifiedError(output: String, route: BurnBarProviderRoute) -> BurnBarProviderExecutorError {
        let redacted = redactSecrets(output, route: route)
        let lower = redacted.lowercased()
        if lower.contains("unauthorized")
            || lower.contains("invalid api key")
            || lower.contains("not logged in")
            || lower.contains("please log in")
            || lower.contains("login")
            || lower.contains("authentication") {
            return .upstreamError(401, redacted)
        }
        if lower.contains("usage limit")
            || lower.contains("quota")
            || lower.contains("exhaust")
            || lower.contains("insufficient")
            || lower.contains("payment required") {
            return .upstreamError(402, redacted)
        }
        if lower.contains("rate limit") || lower.contains("rate_limit") || lower.contains("429") {
            return .upstreamError(429, redacted)
        }
        return .upstreamError(502, redacted)
    }

    private static func redactSecrets(_ output: String, route: BurnBarProviderRoute) -> String {
        let key = route.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return output }
        return output.replacingOccurrences(of: key, with: "<redacted>")
    }

    // MARK: - Usage + response synthesis

    private static func usage(prompt: String, output: String) -> BurnBarProviderProxyUsage {
        BurnBarProviderProxyUsage(
            inputTokens: max(1, prompt.count / 4),
            outputTokens: max(1, output.count / 4),
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            reasoningTokens: 0,
            confidence: .lowConfidenceEstimate
        )
    }

    private static func chatCompletionResponseBody(modelID: String, output: String, stream: Bool) throws -> Data {
        let id = "chatcmpl-openburnbar-codex-\(UUID().uuidString)"
        if stream {
            let chunk: [String: Any] = [
                "id": id,
                "object": "chat.completion.chunk",
                "created": Int(Date().timeIntervalSince1970),
                "model": modelID,
                "choices": [[
                    "index": 0,
                    "delta": ["role": "assistant", "content": output],
                    "finish_reason": NSNull()
                ]]
            ]
            let done: [String: Any] = [
                "id": id,
                "object": "chat.completion.chunk",
                "created": Int(Date().timeIntervalSince1970),
                "model": modelID,
                "choices": [[
                    "index": 0,
                    "delta": [:],
                    "finish_reason": "stop"
                ]]
            ]
            return try sseBody(events: [chunk, done])
        }
        let body: [String: Any] = [
            "id": id,
            "object": "chat.completion",
            "created": Int(Date().timeIntervalSince1970),
            "model": modelID,
            "choices": [[
                "index": 0,
                "message": ["role": "assistant", "content": output],
                "finish_reason": "stop"
            ]],
            "usage": [
                "prompt_tokens": 0,
                "completion_tokens": max(1, output.count / 4),
                "total_tokens": max(1, output.count / 4)
            ]
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    private static func responsesBody(modelID: String, output: String, stream: Bool) throws -> Data {
        let id = "resp_openburnbar_codex_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        if stream {
            let delta: [String: Any] = [
                "type": "response.output_text.delta",
                "response_id": id,
                "delta": output
            ]
            let completed: [String: Any] = [
                "type": "response.completed",
                "response": [
                    "id": id,
                    "object": "response",
                    "model": modelID,
                    "status": "completed"
                ]
            ]
            return try sseBody(events: [delta, completed])
        }
        let body: [String: Any] = [
            "id": id,
            "object": "response",
            "created_at": Date().timeIntervalSince1970,
            "model": modelID,
            "status": "completed",
            "output": [[
                "type": "message",
                "role": "assistant",
                "content": [[
                    "type": "output_text",
                    "text": output
                ]]
            ]],
            "usage": [
                "input_tokens": 0,
                "output_tokens": max(1, output.count / 4),
                "total_tokens": max(1, output.count / 4)
            ]
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    private static func sseBody(events: [[String: Any]]) throws -> Data {
        var text = ""
        for event in events {
            let data = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
            text += "data: \(String(decoding: data, as: UTF8.self))\n\n"
        }
        text += "data: [DONE]\n\n"
        return Data(text.utf8)
    }
}
