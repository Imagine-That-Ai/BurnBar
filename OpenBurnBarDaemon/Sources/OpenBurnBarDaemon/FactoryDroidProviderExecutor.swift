import OpenBurnBarCore
import Darwin
import Foundation

public struct FactoryDroidProcessResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol FactoryDroidProcessRunning: Sendable {
    func runDroid(arguments: [String], environment: [String: String], timeout: TimeInterval) async throws -> FactoryDroidProcessResult
}

public struct FactoryDroidSystemProcessRunner: FactoryDroidProcessRunning {
    private let executableURL: URL?

    public init(executableURL: URL? = nil) {
        self.executableURL = executableURL
    }

    public func runDroid(arguments: [String], environment: [String: String], timeout: TimeInterval) async throws -> FactoryDroidProcessResult {
        try await Task.detached(priority: .utility) {
            try Self.runSynchronously(
                executableURL: executableURL ?? Self.defaultDroidExecutableURL(),
                arguments: arguments,
                environment: environment,
                timeout: timeout
            )
        }.value
    }

    private static func defaultDroidExecutableURL() -> URL {
        var candidates = [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin/droid")
                .path,
            "/opt/homebrew/bin/droid",
            "/usr/local/bin/droid",
            "/usr/bin/droid"
        ]
        let pathCandidates = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("droid").path }
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
        timeout: TimeInterval
    ) throws -> FactoryDroidProcessResult {
        let process = Process()
        if executableURL.lastPathComponent == "env" {
            process.executableURL = executableURL
            process.arguments = ["droid"] + arguments
        } else {
            process.executableURL = executableURL
            process.arguments = arguments
        }
        process.environment = environment

        let fileManager = FileManager.default
        let captureDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("openburnbar-factory-droid-process-\(UUID().uuidString)", isDirectory: true)
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
            throw BurnBarProviderExecutorError.upstreamError(504, "Factory Droid execution timed out.")
        }

        return FactoryDroidProcessResult(
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

public struct FactoryDroidProviderExecutor: BurnBarProviderExecuting, Sendable {
    private let runner: any FactoryDroidProcessRunning
    private let timeout: TimeInterval

    public init(
        runner: any FactoryDroidProcessRunning = FactoryDroidSystemProcessRunner(),
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
        let output = try await execute(prompt: prompt, route: route, variant: nil)
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
        let output = try await execute(prompt: request.prompt, route: route, variant: variant)
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
        let output = try await execute(prompt: request.prompt, route: route, variant: variant)
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

    private func execute(
        prompt: String,
        route: BurnBarProviderRoute,
        variant: BurnBarModelVariant?
    ) async throws -> String {
        guard route.providerID.caseInsensitiveCompare("factory") == .orderedSame else {
            throw BurnBarProviderExecutorError.upstreamError(400, "Factory Droid executor received non-Factory route.")
        }
        let key = route.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw BurnBarProviderExecutorError.upstreamError(401, "Factory Droid API key is missing.")
        }

        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("openburnbar-factory-droid-\(UUID().uuidString)", isDirectory: true)
        let promptURL = tempRoot.appendingPathComponent("prompt.txt", isDirectory: false)
        try fileManager.createDirectory(
            at: tempRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? fileManager.removeItem(at: tempRoot) }
        try prompt.write(to: promptURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: promptURL.path)

        var arguments = [
            "exec",
            "--model", route.resolvedModelID,
            "--output-format", "json",
            "--cwd", tempRoot.path,
            "--disabled-tools", "ApplyPatch,execute-cli",
            "-f", promptURL.path
        ]
        if let effort = Self.droidReasoningEffort(for: route.resolvedModelID, variant: variant) {
            arguments.insert(contentsOf: ["--reasoning-effort", effort], at: 3)
        }

        var environment = Self.sanitizedEnvironment()
        environment["FACTORY_API_KEY"] = key
        environment["HOME"] = NSHomeDirectory()
        environment["OPENBURNBAR_FACTORY_STRICT_STANDARD"] = "1"

        let result = try await runner.runDroid(arguments: arguments, environment: environment, timeout: timeout)
        let combined = "\(result.stdout)\n\(result.stderr)"
        if result.exitCode != 0 {
            throw Self.classifiedError(output: combined, route: route)
        }
        if Self.isStandardModel(route.resolvedModelID), Self.containsDroidCoreDowngradeSignal(combined) {
            throw BurnBarProviderExecutorError.upstreamError(
                402,
                "Factory Standard Usage is exhausted; Droid Core fallback is disabled for strict same-model routing."
            )
        }

        let output = Self.extractAssistantText(from: result.stdout)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else {
            throw BurnBarProviderExecutorError.invalidResponse
        }
        return output
    }

    private static func sanitizedEnvironment() -> [String: String] {
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
        return environment
    }

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
    You are serving one OpenBurnBar routed completion request through Factory Droid.
    Return only the assistant response for the user request.
    Do not inspect or modify files, run commands, call tools, change models, or mention routing internals.
    """

    private static func chatCompletionPrompt(from body: Data) throws -> (prompt: String, stream: Bool) {
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

    private static func responsesPrompt(from body: Data) throws -> (prompt: String, stream: Bool) {
        guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw BurnBarProviderExecutorError.invalidResponse
        }
        var parts = [backendGuardrail]
        if let instructions = object["instructions"] as? String, !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("System:\n\(instructions)")
        }
        if let input = object["input"] {
            let text = text(from: input)
            if !text.isEmpty {
                parts.append("User:\n\(text)")
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

    static func extractAssistantText(from stdout: String) -> String {
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return trimmed
        }
        return textCandidate(in: json) ?? trimmed
    }

    private static func textCandidate(in value: Any) -> String? {
        if let string = value as? String {
            return string
        }
        if let array = value as? [Any] {
            let joined = array.compactMap(textCandidate(in:)).filter { !$0.isEmpty }.joined(separator: "\n")
            return joined.isEmpty ? nil : joined
        }
        guard let object = value as? [String: Any] else { return nil }
        for key in ["result", "response", "content", "message", "text", "output", "summary"] {
            if let candidate = object[key], let text = textCandidate(in: candidate), !text.isEmpty {
                return text
            }
        }
        if let choices = object["choices"] as? [[String: Any]],
           let first = choices.first,
           let message = first["message"],
           let text = textCandidate(in: message) {
            return text
        }
        if let role = object["role"] as? String, role == "assistant",
           let content = object["content"],
           let text = textCandidate(in: content) {
            return text
        }
        return nil
    }

    static func classifiedError(output: String, route: BurnBarProviderRoute) -> BurnBarProviderExecutorError {
        let redacted = redactSecrets(output, route: route)
        let lower = redacted.lowercased()
        if lower.contains("unauthorized")
            || lower.contains("invalid api key")
            || lower.contains("api key")
            || lower.contains("login")
            || lower.contains("authentication") {
            return .upstreamError(401, redacted)
        }
        if lower.contains("standard usage")
            || lower.contains("ask me when i run out")
            || lower.contains("extra usage")
            || lower.contains("usage limit")
            || lower.contains("quota")
            || lower.contains("exhaust") {
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

    private static func containsDroidCoreDowngradeSignal(_ output: String) -> Bool {
        let lower = output.lowercased()
        return lower.contains("droid core")
            || lower.contains("droid-core")
            || lower.contains("standard usage runs out")
            || lower.contains("standard usage is exhausted")
    }

    static func isStandardModel(_ modelID: String) -> Bool {
        !droidCoreModelIDs.contains(modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    public static func isStrictStandardUsageExhaustion(error: Error, route: BurnBarProviderRoute) -> Bool {
        guard route.providerID.caseInsensitiveCompare("factory") == .orderedSame,
              isStandardModel(route.resolvedModelID) else {
            return false
        }

        let message: String
        if let providerError = error as? BurnBarProviderExecutorError,
           case .upstreamError(let statusCode, let body) = providerError {
            guard statusCode == 402 else { return false }
            message = body
        } else {
            message = error.localizedDescription
        }

        let lower = message.lowercased()
        return lower.contains("factory standard usage")
            || lower.contains("standard usage is exhausted")
            || lower.contains("standard usage exhausted")
            || lower.contains("ask me when i run out")
            || lower.contains("droid core fallback is disabled")
    }

    private static let droidCoreModelIDs: Set<String> = [
        "glm-5.1",
        "kimi-k2.6",
        "kimi-k2.5",
        "deepseek-v4-pro",
        "minimax-m2.7",
        "minimax-m2.5"
    ]

    static func droidReasoningEffort(for modelID: String, variant: BurnBarModelVariant?) -> String? {
        guard let level = variant?.thinkingLevel else { return nil }
        let normalized = modelID.lowercased()
        if normalized.contains("gpt-") {
            return level == .max ? "xhigh" : level.rawValue
        }
        if normalized.contains("gemini") {
            switch level {
            case .low, .medium, .high: return level.rawValue
            case .xhigh, .max: return "high"
            }
        }
        if normalized.contains("deepseek-v4-pro") {
            return level == .max ? "max" : "high"
        }
        if droidCoreModelIDs.contains(normalized) {
            return "high"
        }
        return level.rawValue
    }

    private static func usage(prompt: String, output: String) -> BurnBarProviderProxyUsage {
        BurnBarProviderProxyUsage(
            inputTokens: max(1, prompt.count / 4),
            outputTokens: max(1, output.count / 4),
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            reasoningTokens: 0,
            confidence: .highConfidenceEstimate
        )
    }

    private static func chatCompletionResponseBody(modelID: String, output: String, stream: Bool) throws -> Data {
        let id = "chatcmpl-openburnbar-factory-\(UUID().uuidString)"
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
        let id = "resp_openburnbar_factory_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
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

public struct BurnBarCompositeProviderExecutor: BurnBarProviderExecuting {
    private let openAICompatibleExecutor: BurnBarOpenAICompatibleProviderExecutor
    private let factoryExecutor: FactoryDroidProviderExecutor

    public init(
        openAICompatibleExecutor: BurnBarOpenAICompatibleProviderExecutor = BurnBarOpenAICompatibleProviderExecutor(),
        factoryExecutor: FactoryDroidProviderExecutor = FactoryDroidProviderExecutor()
    ) {
        self.openAICompatibleExecutor = openAICompatibleExecutor
        self.factoryExecutor = factoryExecutor
    }

    public func completeStructured(
        _ request: BurnBarStructuredPromptRequest,
        route: BurnBarProviderRoute
    ) async throws -> BurnBarProviderExecutionResult {
        if route.providerID.caseInsensitiveCompare("factory") == .orderedSame {
            return try await factoryExecutor.completeStructured(request, route: route)
        }
        return try await openAICompatibleExecutor.completeStructured(request, route: route)
    }
}
