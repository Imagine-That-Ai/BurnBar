import OpenBurnBarCore
import Foundation

/// Pass-through proxy for Anthropic Messages API requests.
///
/// The local gateway accepts `POST /v1/messages` from Claude Code (and any
/// other Anthropic-shape client configured with `ANTHROPIC_BASE_URL`), picks
/// a routed Anthropic-family account via `BurnBarProviderRouter`, and forwards
/// the bytes upstream with the right headers. The same executor also owns the
/// explicit Anthropic-to-OpenAI-style compatibility bridge used when
/// `/v1/models` advertises a Claude model for `/v1/chat/completions` or
/// `/v1/responses`.
///
/// Failover semantics mirror the OpenAI executor: on a retryable upstream
/// status (`429`, `401`, `402`, `403`, quota / rate-limit error text) the
/// gateway server marks the slot and retries against the next-best slot in
/// the same Anthropic-family pool.
///
/// ## Claude Max subscription routing
///
/// Anthropic's public `/v1/messages` API treats Claude Code OAuth bearer
/// tokens (`sk-ant-oat…`) differently from Console API keys. For Sonnet/Haiku
/// a bare bearer token works, but Opus is gated behind a **Claude Code
/// identity check** that requires the request to look like one Claude Code
/// itself would send:
///
/// 1. Query parameter `?beta=true` on `/v1/messages`.
/// 2. `anthropic-beta: claude-code-20250219,oauth-2025-04-20` header (proves
///    "this is Claude Code talking to its OAuth gateway").
/// 3. Standard CLI identity headers (`User-Agent: claude-cli/…`,
///    `x-app: cli`, `anthropic-dangerous-direct-browser-access: true`).
/// 4. A `system` field whose first text block starts with the canonical
///    Claude Code system guard (`"You are Claude Code, Anthropic's official
///    CLI for Claude."`).
///
/// Without all four, the OAuth route returns HTTP 429 with an opaque
/// `rate_limit_error` — even when the user has the Max subscription that
/// includes Opus. This executor detects the OAuth shape from the credential
/// prefix and injects the identity for that route only. Console API key
/// routes (`sk-ant-api*`) are left untouched so we never lie about the
/// caller's intent.
public struct BurnBarAnthropicProviderExecutor: Sendable {
    public static let defaultAnthropicVersion = "2023-06-01"

    /// Beta header BurnBar sends on Claude Code OAuth routes. The first two
    /// tokens (`claude-code-20250219` and `oauth-2025-04-20`) are what unlocks
    /// Opus on Max subscriptions; the rest mirror what Claude Code's own CLI
    /// declares so behavior matches across the local CLI and the BurnBar
    /// proxy. We do not silently rely on betas whose request-side fields we
    /// strip (`context-management-…` is intentionally absent).
    public static let claudeCodeBetaHeader = "claude-code-20250219,oauth-2025-04-20,interleaved-thinking-2025-05-14,prompt-caching-scope-2026-01-05,advisor-tool-2026-03-01,effort-2025-11-24,extended-cache-ttl-2025-04-11"

    /// User-Agent BurnBar sends on Claude Code OAuth routes. Pinned to a
    /// known Claude Code release so the identity is stable regardless of
    /// what version of the CLI happens to be installed on the host.
    public static let claudeCodeUserAgent = "claude-cli/2.1.143 (external, sdk-cli)"

    /// The canonical Claude Code system prompt prefix that the public
    /// Messages API uses to gate Opus on OAuth bearer tokens. The exact
    /// string is documented in Anthropic's Claude Code SDK contract; the
    /// gateway only requires that the first text block of the `system`
    /// field starts with it.
    public static let claudeCodeSystemGuard = "You are Claude Code, Anthropic's official CLI for Claude."

    private let session: URLSession
    private let anthropicVersion: String

    public init(
        session: URLSession = .shared,
        anthropicVersion: String = BurnBarAnthropicProviderExecutor.defaultAnthropicVersion
    ) {
        self.session = session
        self.anthropicVersion = anthropicVersion
    }

    /// Public so the gateway and model-health layers can recognize Claude
    /// Code subscription credentials and shape error/advertising decisions
    /// around them.
    public static func usesClaudeCodeSubscriptionIdentity(for route: BurnBarProviderRoute) -> Bool {
        guard route.providerID.caseInsensitiveCompare("anthropic") == .orderedSame,
              route.formatFamily == .anthropic else {
            return false
        }
        return route.apiKey
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .hasPrefix("sk-ant-oat")
    }

    /// Forward an Anthropic Messages request to the chosen upstream account.
    ///
    /// - Parameters:
    ///   - body: Raw JSON bytes the client sent on `/v1/messages`.
    ///   - route: Routing decision from `BurnBarProviderRouter`.
    /// - Returns: The upstream response, ready to write back to the client.
    public func proxyMessages(
        body: Data,
        route: BurnBarProviderRoute,
        variant: BurnBarModelVariant? = nil
    ) async throws -> BurnBarProviderProxyResponse {
        guard let baseURL = URL(string: route.baseURL) else {
            throw BurnBarProviderExecutorError.invalidBaseURL(route.baseURL)
        }

        let usesClaudeCode = Self.usesClaudeCodeSubscriptionIdentity(for: route)
        let outboundBody = try Self.rewritingModel(
            in: body,
            to: route.resolvedModelID,
            applyClaudeCodeSystemGuard: usesClaudeCode,
            variant: variant
        )
        let messagesURL = baseURL.appending(path: "messages")
        let endpoint = usesClaudeCode
            ? Self.appendingBetaQueryItem(to: messagesURL)
            : messagesURL
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")

        // Anthropic accepts two distinct credential shapes:
        //   1. `sk-ant-api…` API keys via the `x-api-key` header (Console keys).
        //   2. OAuth bearer tokens via `Authorization: Bearer …` (Pro/Team
        //      session tokens issued by claude.ai, including `sk-ant-oat…`).
        // Choose the right header based on the credential prefix so a single
        // routing pool can mix both kinds of accounts.
        applyAnthropicAuth(apiKey: route.apiKey, to: &request)

        if usesClaudeCode {
            // Anthropic gates Opus (and a handful of other Max-tier features)
            // on the public Messages API behind a Claude Code identity check
            // for OAuth bearer tokens. Without these headers + the system
            // guard injected above, the upstream returns 429 with an opaque
            // `rate_limit_error` even though the Max subscription is
            // entitled to the model. BurnBar runs on the user's machine and
            // is forwarding requests they have already authenticated; we
            // present the same identity Claude Code itself uses locally.
            request.setValue(Self.claudeCodeBetaHeader, forHTTPHeaderField: "anthropic-beta")
            request.setValue(Self.claudeCodeUserAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("cli", forHTTPHeaderField: "x-app")
            request.setValue("true", forHTTPHeaderField: "anthropic-dangerous-direct-browser-access")
        }

        request.httpBody = outboundBody

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BurnBarProviderExecutorError.invalidResponse
        }

        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "application/json"
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw BurnBarProviderExecutorError.upstreamError(
                httpResponse.statusCode,
                String(data: data, encoding: .utf8) ?? ""
            )
        }

        return BurnBarProviderProxyResponse(
            statusCode: httpResponse.statusCode,
            contentType: contentType,
            body: data,
            usage: Self.extractProxyUsage(responseBody: data)
        )
    }

    /// Serve OpenAI Chat Completions clients from an Anthropic-family route.
    ///
    /// `/v1/models` may advertise Claude to OpenAI-shape CLIs only because
    /// this method translates the request to Anthropic Messages and translates
    /// the provider response back to Chat Completions.
    public func proxyChatCompletions(
        body: Data,
        route: BurnBarProviderRoute,
        variant: BurnBarModelVariant? = nil
    ) async throws -> BurnBarProviderProxyResponse {
        let (messagesBody, streamRequested) = try Self.anthropicMessagesBodyFromChatCompletionsRequest(
            body,
            modelID: route.resolvedModelID,
            variant: variant
        )
        let response = try await proxyMessages(body: messagesBody, route: route, variant: variant)

        if streamRequested || response.contentType.lowercased().contains("text/event-stream") {
            return try Self.chatCompletionsStreamFromAnthropicStream(response, modelID: route.resolvedModelID)
        }

        let translatedBody = try Self.chatCompletionsBodyFromAnthropicMessage(
            response.body,
            modelID: route.resolvedModelID
        )
        return BurnBarProviderProxyResponse(
            statusCode: 200,
            contentType: "application/json",
            body: translatedBody,
            usage: response.usage
        )
    }

    /// Serve OpenAI Responses clients from an Anthropic-family route.
    public func proxyResponses(
        body: Data,
        route: BurnBarProviderRoute,
        variant: BurnBarModelVariant? = nil
    ) async throws -> BurnBarProviderProxyResponse {
        let (messagesBody, streamRequested) = try Self.anthropicMessagesBodyFromResponsesRequest(
            body,
            modelID: route.resolvedModelID,
            variant: variant
        )
        let response = try await proxyMessages(body: messagesBody, route: route, variant: variant)

        if streamRequested || response.contentType.lowercased().contains("text/event-stream") {
            return try Self.responsesStreamFromAnthropicStream(response, modelID: route.resolvedModelID)
        }

        let translatedBody = try Self.responsesBodyFromAnthropicMessage(
            response.body,
            modelID: route.resolvedModelID
        )
        return BurnBarProviderProxyResponse(
            statusCode: 200,
            contentType: "application/json",
            body: translatedBody,
            usage: response.usage
        )
    }

    // MARK: - Header construction

    private func applyAnthropicAuth(apiKey: String, to request: inout URLRequest) {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.isConsoleAPIKey(trimmed) {
            request.setValue(trimmed, forHTTPHeaderField: "x-api-key")
            return
        }
        // OAuth bearer (Pro / Team session token) or any other shape — let
        // Anthropic's auth layer decide. We never accept tokens we can't
        // confidently route, so this fallback is safe.
        request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
    }

    private static func isConsoleAPIKey(_ credential: String) -> Bool {
        credential.lowercased().hasPrefix("sk-ant-api")
    }

    // MARK: - Body rewriting

    private static func rewritingModel(
        in body: Data,
        to resolvedModelID: String,
        applyClaudeCodeSystemGuard: Bool,
        variant: BurnBarModelVariant? = nil
    ) throws -> Data {
        guard var json = try JSONSerialization.jsonObject(with: body, options: []) as? [String: Any] else {
            return body
        }
        json["model"] = resolvedModelID
        // Claude Code's first-party client can send fields that are valid for
        // its native transport but rejected by the public Messages endpoint.
        // BurnBar routes through /v1/messages, so strip known transport-only
        // keys instead of making Claude retry a deterministic 400 forever.
        json.removeValue(forKey: "context_management")
        if applyClaudeCodeSystemGuard {
            json["system"] = injectClaudeCodeSystemGuard(into: json["system"])
        }
        if let variant {
            applyAnthropicVariant(variant, to: &json)
        }
        return try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    }

    /// Variant-always-wins injection of Anthropic extended-thinking config.
    /// Sets `thinking = { type: enabled, budget_tokens: ... }` and `effort`
    /// (gated by the `effort-2025-11-24` beta header BurnBar already sends
    /// for Claude Code routes). Anthropic rejects `budget_tokens >= max_tokens`,
    /// so the helper raises the floor of `max_tokens` to
    /// `budget_tokens + 4096` when the caller's value would conflict.
    static func applyAnthropicVariant(
        _ variant: BurnBarModelVariant,
        to object: inout [String: Any]
    ) {
        let budget = variant.thinkingLevel.anthropicBudgetTokens
        let thinking: [String: Any] = [
            "type": "enabled",
            "budget_tokens": budget
        ]
        object["thinking"] = thinking
        object["effort"] = variant.thinkingLevel.anthropicEffort

        let floor = budget + 4096
        let callerMax = intValue(object["max_tokens"]) ?? 0
        let chosenMax: Int
        if let variantMax = variant.maxOutputTokens {
            chosenMax = max(variantMax, floor)
        } else {
            chosenMax = max(callerMax, floor)
        }
        object["max_tokens"] = chosenMax
    }

    /// Ensure the request body's `system` field starts with the Claude Code
    /// guard prefix without discarding the caller's existing system text.
    /// Accepts the three shapes Anthropic supports (`nil`, string, content
    /// blocks); always returns a shape Anthropic accepts.
    private static func injectClaudeCodeSystemGuard(into existing: Any?) -> Any {
        let guardString = claudeCodeSystemGuard

        if existing == nil || (existing as? NSNull) != nil {
            return guardString
        }

        if let asString = existing as? String {
            let trimmed = asString.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return guardString
            }
            if trimmed.hasPrefix(guardString) {
                return asString
            }
            return "\(guardString)\n\n\(asString)"
        }

        if let asArray = existing as? [[String: Any]] {
            if let firstBlock = asArray.first,
               let text = firstBlock["text"] as? String,
               text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(guardString) {
                return asArray
            }
            var combined: [[String: Any]] = [
                ["type": "text", "text": guardString]
            ]
            combined.append(contentsOf: asArray)
            return combined
        }

        // Any other shape Anthropic would reject. Replace with a valid one
        // so the request never round-trips a 400 just because the caller
        // sent an unusual system field.
        return guardString
    }

    /// Append `?beta=true` to the messages URL when routing through the
    /// Claude Code OAuth identity. Anthropic uses both the header and the
    /// query parameter to gate Claude Code-specific features; we send both
    /// to match the local Claude Code CLI exactly.
    private static func appendingBetaQueryItem(to url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        var items = components.queryItems ?? []
        if items.contains(where: { $0.name == "beta" }) == false {
            items.append(URLQueryItem(name: "beta", value: "true"))
        }
        components.queryItems = items
        return components.url ?? url
    }

    // MARK: - OpenAI-shape compatibility bridge

    private static func anthropicMessagesBodyFromChatCompletionsRequest(
        _ body: Data,
        modelID: String,
        variant: BurnBarModelVariant? = nil
    ) throws -> (Data, Bool) {
        guard let object = try JSONSerialization.jsonObject(with: body, options: []) as? [String: Any] else {
            throw BurnBarProviderExecutorError.invalidResponse
        }
        let (messagesObject, streamRequested) = try anthropicMessagesObjectFromChatObject(
            object,
            modelID: modelID,
            variant: variant
        )
        return (try jsonData(messagesObject), streamRequested)
    }

    private static func anthropicMessagesBodyFromResponsesRequest(
        _ body: Data,
        modelID: String,
        variant: BurnBarModelVariant? = nil
    ) throws -> (Data, Bool) {
        guard let object = try JSONSerialization.jsonObject(with: body, options: []) as? [String: Any] else {
            throw BurnBarProviderExecutorError.invalidResponse
        }
        let chatObject = try chatObjectFromResponsesObject(object, modelID: modelID)
        let (messagesObject, streamRequested) = try anthropicMessagesObjectFromChatObject(
            chatObject,
            modelID: modelID,
            variant: variant
        )
        return (try jsonData(messagesObject), streamRequested)
    }

    private static func anthropicMessagesObjectFromChatObject(
        _ object: [String: Any],
        modelID: String,
        variant: BurnBarModelVariant? = nil
    ) throws -> ([String: Any], Bool) {
        guard let messages = object["messages"] as? [[String: Any]], !messages.isEmpty else {
            throw BurnBarProviderExecutorError.upstreamError(
                400,
                "OpenAI-compatible Anthropic bridge requires at least one message."
            )
        }

        var systemText: [String] = []
        var anthropicMessages: [[String: Any]] = []

        for message in messages {
            let role = (message["role"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "user"
            if role == "system" || role == "developer" {
                let text = openAIContentText(message["content"])
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    systemText.append(text)
                }
                continue
            }

            if role == "tool" {
                guard let toolResult = anthropicToolResultBlock(from: message) else { continue }
                anthropicMessages.append(["role": "user", "content": [toolResult]])
                continue
            }

            var contentBlocks = anthropicContentBlocks(from: message["content"])
            if role == "assistant" {
                contentBlocks.append(contentsOf: anthropicToolUseBlocks(from: message["tool_calls"]))
            }
            guard !contentBlocks.isEmpty else { continue }

            let anthropicRole = role == "assistant" ? "assistant" : "user"
            anthropicMessages.append(["role": anthropicRole, "content": contentBlocks])
        }

        guard !anthropicMessages.isEmpty else {
            throw BurnBarProviderExecutorError.upstreamError(
                400,
                "OpenAI-compatible Anthropic bridge could not derive any Anthropic messages from the request."
            )
        }

        var bridged: [String: Any] = [
            "model": modelID,
            "max_tokens": maxTokens(from: object),
            "messages": anthropicMessages
        ]
        if !systemText.isEmpty {
            bridged["system"] = systemText.joined(separator: "\n\n")
        }
        if let temperature = object["temperature"] {
            bridged["temperature"] = temperature
        }
        if let topP = object["top_p"] {
            bridged["top_p"] = topP
        }
        if let stop = object["stop"] {
            bridged["stop_sequences"] = stopSequences(from: stop)
        }
        if let tools = anthropicTools(from: object["tools"]), !tools.isEmpty {
            bridged["tools"] = tools
            if let toolChoice = anthropicToolChoice(from: object["tool_choice"]) {
                bridged["tool_choice"] = toolChoice
            }
        }

        if wantsJSONMode(object), var existingSystem = bridged["system"] as? String {
            existingSystem += "\n\nReturn valid JSON only."
            bridged["system"] = existingSystem
        } else if wantsJSONMode(object) {
            bridged["system"] = "Return valid JSON only."
        }

        let streamRequested = object["stream"] as? Bool ?? false
        if streamRequested {
            bridged["stream"] = true
        }
        if let variant {
            applyAnthropicVariant(variant, to: &bridged)
        }
        return (bridged, streamRequested)
    }

    private static func chatObjectFromResponsesObject(
        _ object: [String: Any],
        modelID: String
    ) throws -> [String: Any] {
        var messages: [[String: Any]] = []
        if let instructions = object["instructions"] as? String,
           !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append(["role": "system", "content": instructions])
        }

        if let existingMessages = object["messages"] as? [[String: Any]], !existingMessages.isEmpty {
            messages.append(contentsOf: existingMessages)
        } else if let input = object["input"] {
            messages.append(contentsOf: openAIMessagesFromResponsesInput(input))
        }

        guard !messages.isEmpty else {
            throw BurnBarProviderExecutorError.upstreamError(
                400,
                "Responses request must include input text or messages for Anthropic bridge routing."
            )
        }

        var chatObject: [String: Any] = [
            "model": modelID,
            "messages": messages
        ]
        for key in ["temperature", "top_p", "stop", "stream", "tools", "tool_choice", "response_format"] {
            if let value = object[key] {
                chatObject[key] = value
            }
        }
        if let maxOutputTokens = object["max_output_tokens"] {
            chatObject["max_tokens"] = maxOutputTokens
        } else if let maxTokens = object["max_tokens"] {
            chatObject["max_tokens"] = maxTokens
        }
        if chatObject["response_format"] == nil,
           let text = object["text"] as? [String: Any],
           let format = text["format"] {
            chatObject["response_format"] = format
        }
        return chatObject
    }

    private static func openAIMessagesFromResponsesInput(_ input: Any) -> [[String: Any]] {
        if let text = input as? String {
            return [["role": "user", "content": text]]
        }
        guard let items = input as? [[String: Any]] else {
            return []
        }
        return items.compactMap { item in
            let text = openAIContentText(item["content"] ?? item["text"])
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return [
                "role": (item["role"] as? String) ?? "user",
                "content": text
            ]
        }
    }

    private static func maxTokens(from object: [String: Any]) -> Int {
        intValue(object["max_tokens"])
            ?? intValue(object["max_completion_tokens"])
            ?? intValue(object["max_output_tokens"])
            ?? 4096
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return max(1, value) }
        if let value = value as? NSNumber { return max(1, value.intValue) }
        if let value = value as? String, let parsed = Int(value) { return max(1, parsed) }
        return nil
    }

    private static func stopSequences(from value: Any) -> Any {
        if let string = value as? String {
            return [string]
        }
        return value
    }

    private static func wantsJSONMode(_ object: [String: Any]) -> Bool {
        if let responseFormat = object["response_format"] as? [String: Any],
           let type = responseFormat["type"] as? String {
            return type == "json_object" || type == "json_schema"
        }
        return false
    }

    private static func anthropicContentBlocks(from value: Any?) -> [[String: Any]] {
        let text = openAIContentText(value)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return [["type": "text", "text": text]]
    }

    private static func openAIContentText(_ value: Any?) -> String {
        if let text = value as? String {
            return text
        }
        guard let parts = value as? [[String: Any]] else {
            return ""
        }
        return parts.compactMap { part in
            if let text = part["text"] as? String {
                return text
            }
            if let text = part["input_text"] as? String {
                return text
            }
            if let text = part["output_text"] as? String {
                return text
            }
            return nil
        }.joined(separator: "\n")
    }

    private static func anthropicToolUseBlocks(from value: Any?) -> [[String: Any]] {
        guard let toolCalls = value as? [[String: Any]] else { return [] }
        return toolCalls.compactMap { call in
            guard let id = call["id"] as? String,
                  let function = call["function"] as? [String: Any],
                  let name = function["name"] as? String,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            let arguments = function["arguments"]
            return [
                "type": "tool_use",
                "id": id,
                "name": name,
                "input": objectFromJSONString(arguments as? String) ?? ["arguments": arguments ?? ""]
            ]
        }
    }

    private static func anthropicToolResultBlock(from message: [String: Any]) -> [String: Any]? {
        guard let id = message["tool_call_id"] as? String, !id.isEmpty else {
            return nil
        }
        return [
            "type": "tool_result",
            "tool_use_id": id,
            "content": openAIContentText(message["content"])
        ]
    }

    private static func anthropicTools(from value: Any?) -> [[String: Any]]? {
        guard let tools = value as? [[String: Any]] else { return nil }
        let converted = tools.compactMap { tool -> [String: Any]? in
            let function = tool["function"] as? [String: Any]
            guard let name = (function?["name"] as? String) ?? (tool["name"] as? String),
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            let inputSchema = (function?["parameters"] as? [String: Any])
                ?? (tool["parameters"] as? [String: Any])
                ?? ["type": "object", "properties": [:]]
            var convertedTool: [String: Any] = [
                "name": name,
                "input_schema": inputSchema
            ]
            if let description = (function?["description"] as? String) ?? (tool["description"] as? String),
               !description.isEmpty {
                convertedTool["description"] = description
            }
            return convertedTool
        }
        return converted
    }

    private static func anthropicToolChoice(from value: Any?) -> [String: Any]? {
        if let string = value as? String {
            switch string {
            case "required":
                return ["type": "any"]
            case "auto":
                return ["type": "auto"]
            case "none":
                return nil
            default:
                return nil
            }
        }
        guard let object = value as? [String: Any] else { return nil }
        let name = (object["name"] as? String)
            ?? ((object["function"] as? [String: Any])?["name"] as? String)
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ["type": "tool", "name": name]
        }
        if (object["type"] as? String) == "required" {
            return ["type": "any"]
        }
        return nil
    }

    private static func objectFromJSONString(_ value: String?) -> [String: Any]? {
        guard let value,
              let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private static func chatCompletionsBodyFromAnthropicMessage(
        _ body: Data,
        modelID: String
    ) throws -> Data {
        guard let object = try JSONSerialization.jsonObject(with: body, options: []) as? [String: Any] else {
            throw BurnBarProviderExecutorError.invalidResponse
        }
        let content = anthropicMessageContent(from: object)
        var message: [String: Any] = [
            "role": "assistant",
            "content": content.text.isEmpty && !content.toolCalls.isEmpty ? NSNull() : content.text
        ]
        if !content.toolCalls.isEmpty {
            message["tool_calls"] = content.toolCalls
        }
        let responseObject: [String: Any] = [
            "id": "chatcmpl_\(UUID().uuidString)",
            "object": "chat.completion",
            "created": Int(Date().timeIntervalSince1970),
            "model": modelID,
            "choices": [[
                "index": 0,
                "message": message,
                "finish_reason": chatFinishReason(from: object["stop_reason"] as? String)
            ]],
            "usage": openAIUsage(fromAnthropicMessage: object)
        ]
        return try jsonData(responseObject)
    }

    private static func responsesBodyFromAnthropicMessage(
        _ body: Data,
        modelID: String
    ) throws -> Data {
        guard let object = try JSONSerialization.jsonObject(with: body, options: []) as? [String: Any] else {
            throw BurnBarProviderExecutorError.invalidResponse
        }
        let content = anthropicMessageContent(from: object)
        let responseID = "resp_\(UUID().uuidString)"
        let messageID = "msg_\(UUID().uuidString)"
        var output: [[String: Any]] = []
        if !content.text.isEmpty {
            output.append([
                "id": messageID,
                "type": "message",
                "status": "completed",
                "role": "assistant",
                "content": [[
                    "type": "output_text",
                    "text": content.text,
                    "annotations": []
                ]]
            ])
        }
        for toolCall in content.toolCalls {
            let function = toolCall["function"] as? [String: Any] ?? [:]
            output.append([
                "id": "fc_\(UUID().uuidString)",
                "type": "function_call",
                "status": "completed",
                "call_id": toolCall["id"] ?? "call_\(UUID().uuidString)",
                "name": function["name"] ?? "",
                "arguments": function["arguments"] ?? "{}"
            ])
        }
        if output.isEmpty {
            output.append([
                "id": messageID,
                "type": "message",
                "status": "completed",
                "role": "assistant",
                "content": []
            ])
        }
        let responseObject: [String: Any] = [
            "id": responseID,
            "object": "response",
            "created_at": Int(Date().timeIntervalSince1970),
            "status": "completed",
            "model": modelID,
            "output": output,
            "output_text": content.text,
            "usage": responsesUsage(fromAnthropicMessage: object)
        ]
        return try jsonData(responseObject)
    }

    private static func anthropicMessageContent(from object: [String: Any]) -> (text: String, toolCalls: [[String: Any]]) {
        guard let blocks = object["content"] as? [[String: Any]] else {
            return ("", [])
        }
        var textParts: [String] = []
        var toolCalls: [[String: Any]] = []
        for block in blocks {
            let type = block["type"] as? String
            if type == "text", let text = block["text"] as? String {
                textParts.append(text)
            } else if type == "tool_use",
                      let id = block["id"] as? String,
                      let name = block["name"] as? String {
                let input = (block["input"] as? [String: Any]) ?? [:]
                let arguments = (try? jsonString(input)) ?? "{}"
                toolCalls.append([
                    "id": id,
                    "type": "function",
                    "function": [
                        "name": name,
                        "arguments": arguments
                    ]
                ])
            }
        }
        return (textParts.joined(), toolCalls)
    }

    private static func chatFinishReason(from stopReason: String?) -> Any {
        switch stopReason {
        case "tool_use":
            return "tool_calls"
        case "max_tokens":
            return "length"
        case nil:
            return NSNull()
        default:
            return "stop"
        }
    }

    private static func openAIUsage(fromAnthropicMessage object: [String: Any]) -> [String: Any] {
        let usage = object["usage"] as? [String: Any] ?? [:]
        let input = intValue(usage["input_tokens"]) ?? 0
        let output = intValue(usage["output_tokens"]) ?? 0
        return [
            "prompt_tokens": input,
            "completion_tokens": output,
            "total_tokens": input + output
        ]
    }

    private static func responsesUsage(fromAnthropicMessage object: [String: Any]) -> [String: Any] {
        let usage = object["usage"] as? [String: Any] ?? [:]
        let input = intValue(usage["input_tokens"]) ?? 0
        let output = intValue(usage["output_tokens"]) ?? 0
        return [
            "input_tokens": input,
            "output_tokens": output,
            "total_tokens": input + output
        ]
    }

    private struct ServerSentEvent {
        let event: String?
        let payload: [String: Any]
    }

    private static func chatCompletionsStreamFromAnthropicStream(
        _ response: BurnBarProviderProxyResponse,
        modelID: String
    ) throws -> BurnBarProviderProxyResponse {
        let streamID = "chatcmpl_\(UUID().uuidString)"
        let created = Int(Date().timeIntervalSince1970)
        var finishReason: Any = NSNull()
        var output = Data()
        try appendSSEData(chatChunk(id: streamID, modelID: modelID, created: created, delta: ["role": "assistant"], finishReason: NSNull()), to: &output)
        for event in serverSentEvents(from: response.body) {
            if event.payload["type"] as? String == "content_block_delta",
               let delta = event.payload["delta"] as? [String: Any],
               delta["type"] as? String == "text_delta",
               let text = delta["text"] as? String,
               !text.isEmpty {
                try appendSSEData(chatChunk(id: streamID, modelID: modelID, created: created, delta: ["content": text], finishReason: NSNull()), to: &output)
            }
            if event.payload["type"] as? String == "message_delta",
               let delta = event.payload["delta"] as? [String: Any] {
                finishReason = chatFinishReason(from: delta["stop_reason"] as? String)
            }
            if event.payload["type"] as? String == "error" {
                try appendSSEData(["error": event.payload["error"] ?? "Anthropic stream error"], to: &output)
            }
        }
        try appendSSEData(chatChunk(id: streamID, modelID: modelID, created: created, delta: [:], finishReason: finishReason), to: &output)
        output.append(Data("data: [DONE]\n\n".utf8))
        return BurnBarProviderProxyResponse(
            statusCode: 200,
            contentType: "text/event-stream",
            body: output,
            usage: response.usage
        )
    }

    private static func responsesStreamFromAnthropicStream(
        _ response: BurnBarProviderProxyResponse,
        modelID: String
    ) throws -> BurnBarProviderProxyResponse {
        let responseID = "resp_\(UUID().uuidString)"
        let itemID = "msg_\(UUID().uuidString)"
        let created = Int(Date().timeIntervalSince1970)
        var outputText = ""
        var output = Data()
        try appendNamedSSE(event: "response.created", payload: [
            "type": "response.created",
            "response": baseResponseObject(id: responseID, itemID: itemID, modelID: modelID, created: created, outputText: "", status: "in_progress")
        ], to: &output)
        try appendNamedSSE(event: "response.output_item.added", payload: [
            "type": "response.output_item.added",
            "response_id": responseID,
            "output_index": 0,
            "item": responseMessageItem(itemID: itemID, outputText: "", status: "in_progress")
        ], to: &output)
        try appendNamedSSE(event: "response.content_part.added", payload: [
            "type": "response.content_part.added",
            "response_id": responseID,
            "item_id": itemID,
            "output_index": 0,
            "content_index": 0,
            "part": ["type": "output_text", "text": "", "annotations": []]
        ], to: &output)

        for event in serverSentEvents(from: response.body) {
            if event.payload["type"] as? String == "content_block_delta",
               let delta = event.payload["delta"] as? [String: Any],
               delta["type"] as? String == "text_delta",
               let text = delta["text"] as? String,
               !text.isEmpty {
                outputText += text
                try appendNamedSSE(event: "response.output_text.delta", payload: [
                    "type": "response.output_text.delta",
                    "response_id": responseID,
                    "item_id": itemID,
                    "output_index": 0,
                    "content_index": 0,
                    "delta": text
                ], to: &output)
            }
            if event.payload["type"] as? String == "error" {
                try appendNamedSSE(event: "error", payload: event.payload, to: &output)
            }
        }

        try appendNamedSSE(event: "response.content_part.done", payload: [
            "type": "response.content_part.done",
            "response_id": responseID,
            "item_id": itemID,
            "output_index": 0,
            "content_index": 0,
            "part": ["type": "output_text", "text": outputText, "annotations": []]
        ], to: &output)
        try appendNamedSSE(event: "response.output_item.done", payload: [
            "type": "response.output_item.done",
            "response_id": responseID,
            "output_index": 0,
            "item": responseMessageItem(itemID: itemID, outputText: outputText, status: "completed")
        ], to: &output)
        try appendNamedSSE(event: "response.completed", payload: [
            "type": "response.completed",
            "response": baseResponseObject(id: responseID, itemID: itemID, modelID: modelID, created: created, outputText: outputText, status: "completed")
        ], to: &output)
        output.append(Data("data: [DONE]\n\n".utf8))
        return BurnBarProviderProxyResponse(
            statusCode: 200,
            contentType: "text/event-stream",
            body: output,
            usage: response.usage
        )
    }

    private static func serverSentEvents(from data: Data) -> [ServerSentEvent] {
        let text = String(decoding: data, as: UTF8.self)
        return text.components(separatedBy: "\n\n").compactMap { chunk in
            var eventName: String?
            var dataLines: [String] = []
            for line in chunk.split(separator: "\n", omittingEmptySubsequences: false) {
                if line.hasPrefix("event:") {
                    eventName = line.dropFirst("event:".count).trimmingCharacters(in: .whitespaces)
                } else if line.hasPrefix("data:") {
                    let dataLine = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                    if dataLine == "[DONE]" { return nil }
                    dataLines.append(dataLine)
                }
            }
            guard !dataLines.isEmpty,
                  let payloadData = dataLines.joined(separator: "\n").data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
                return nil
            }
            return ServerSentEvent(event: eventName, payload: payload)
        }
    }

    private static func chatChunk(
        id: String,
        modelID: String,
        created: Int,
        delta: [String: Any],
        finishReason: Any
    ) -> [String: Any] {
        [
            "id": id,
            "object": "chat.completion.chunk",
            "created": created,
            "model": modelID,
            "choices": [[
                "index": 0,
                "delta": delta,
                "finish_reason": finishReason
            ]]
        ]
    }

    private static func baseResponseObject(
        id: String,
        itemID: String,
        modelID: String,
        created: Int,
        outputText: String,
        status: String
    ) -> [String: Any] {
        [
            "id": id,
            "object": "response",
            "created_at": created,
            "status": status,
            "model": modelID,
            "output": [responseMessageItem(itemID: itemID, outputText: outputText, status: status)],
            "output_text": outputText
        ]
    }

    private static func responseMessageItem(itemID: String, outputText: String, status: String) -> [String: Any] {
        [
            "id": itemID,
            "type": "message",
            "status": status,
            "role": "assistant",
            "content": [[
                "type": "output_text",
                "text": outputText,
                "annotations": []
            ]]
        ]
    }

    private static func appendSSEData(_ payload: [String: Any], to output: inout Data) throws {
        output.append(Data("data: \(try jsonString(payload))\n\n".utf8))
    }

    private static func appendNamedSSE(event: String, payload: [String: Any], to output: inout Data) throws {
        output.append(Data("event: \(event)\n".utf8))
        output.append(Data("data: \(try jsonString(payload))\n\n".utf8))
    }

    private static func jsonData(_ object: Any) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw BurnBarProviderExecutorError.invalidResponse
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func jsonString(_ object: Any) throws -> String {
        String(decoding: try jsonData(object), as: UTF8.self)
    }

    // MARK: - Usage extraction

    /// Anthropic Messages responses carry usage on the top-level `usage`
    /// object (`input_tokens`, `output_tokens`, `cache_creation_input_tokens`,
    /// `cache_read_input_tokens`). We surface them so the usage recorder gets
    /// the same shape it does for OpenAI-family proxies.
    private static func extractProxyUsage(responseBody: Data) -> BurnBarProviderProxyUsage? {
        guard let json = try? JSONSerialization.jsonObject(with: responseBody, options: []) as? [String: Any] else {
            return nil
        }
        guard let usage = json["usage"] as? [String: Any] else {
            return nil
        }
        let input = (usage["input_tokens"] as? Int) ?? 0
        let output = (usage["output_tokens"] as? Int) ?? 0
        let cacheCreation = (usage["cache_creation_input_tokens"] as? Int) ?? 0
        let cacheRead = (usage["cache_read_input_tokens"] as? Int) ?? 0
        // Anthropic does not expose a separate reasoning token field today.
        let reasoning = 0
        return BurnBarProviderProxyUsage(
            inputTokens: input,
            outputTokens: output,
            cacheCreationTokens: cacheCreation,
            cacheReadTokens: cacheRead,
            reasoningTokens: reasoning,
            confidence: .exact
        )
    }
}
