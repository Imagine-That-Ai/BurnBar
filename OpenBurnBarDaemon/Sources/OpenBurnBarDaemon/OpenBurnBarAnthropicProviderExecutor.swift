import OpenBurnBarEngine
import Foundation
#if canImport(FoundationNetworking)
@preconcurrency import FoundationNetworking
#endif

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
/// 3. Standard Claude Code identity headers (`User-Agent: claude-code/…`,
///    `x-anthropic-billing-header`, `x-app: cli`,
///    `anthropic-dangerous-direct-browser-access: true`).
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

    /// User-Agent BurnBar sends on Claude Code OAuth routes. Pinned to the
    /// current Claude Code native client shape; Anthropic's OAuth edge treats
    /// the older `claude-cli/...` value differently from real Claude Code.
    public static let claudeCodeUserAgent = "claude-code/2.1.187 (sdk-cli)"

    /// Billing/identity header emitted by Claude Code's first-party SDK path.
    /// Keep this on OAuth routes only; Console API keys bill through the
    /// public API-key path and must not be dressed as Claude Code.
    public static let claudeCodeBillingHeader = "cc_version=2.1.187; cc_entrypoint=sdk-cli; cch=00000;"

    /// The canonical Claude Code system prompt prefix that the public
    /// Messages API uses to gate Opus on OAuth bearer tokens. The exact
    /// string is documented in Anthropic's Claude Code SDK contract; the
    /// gateway only requires that the first text block of the `system`
    /// field starts with it.
    public static let claudeCodeSystemGuard = "You are Claude Code, Anthropic's official CLI for Claude."
    static let upstreamRequestTimeout: TimeInterval = 300

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
        request.timeoutInterval = Self.upstreamRequestTimeout
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
            request.setValue(Self.claudeCodeBillingHeader, forHTTPHeaderField: "x-anthropic-billing-header")
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
            headers: BurnBarProxyStreaming.normalizedHeaders(from: httpResponse),
            body: data,
            usage: Self.extractProxyUsage(responseBody: data)
        )
    }

    /// Open a true streaming Anthropic Messages request for verbatim SSE
    /// passthrough. Applies the same Claude Code identity headers as
    /// `proxyMessages` and forces `stream: true` so the upstream emits the
    /// `message_start` / `message_delta` events the gateway accumulates for
    /// usage accounting.
    public func openMessagesStream(
        body: Data,
        route: BurnBarProviderRoute,
        variant: BurnBarModelVariant? = nil
    ) async throws -> BurnBarProviderProxyStream {
        guard let baseURL = URL(string: route.baseURL) else {
            throw BurnBarProviderExecutorError.invalidBaseURL(route.baseURL)
        }

        let usesClaudeCode = Self.usesClaudeCodeSubscriptionIdentity(for: route)
        let outboundBody = try Self.rewritingModel(
            in: body,
            to: route.resolvedModelID,
            applyClaudeCodeSystemGuard: usesClaudeCode,
            variant: variant,
            forceStream: true
        )
        let messagesURL = baseURL.appending(path: "messages")
        let endpoint = usesClaudeCode
            ? Self.appendingBetaQueryItem(to: messagesURL)
            : messagesURL
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = Self.upstreamRequestTimeout
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        applyAnthropicAuth(apiKey: route.apiKey, to: &request)

        if usesClaudeCode {
            request.setValue(Self.claudeCodeBetaHeader, forHTTPHeaderField: "anthropic-beta")
            request.setValue(Self.claudeCodeUserAgent, forHTTPHeaderField: "User-Agent")
            request.setValue(Self.claudeCodeBillingHeader, forHTTPHeaderField: "x-anthropic-billing-header")
            request.setValue("cli", forHTTPHeaderField: "x-app")
            request.setValue("true", forHTTPHeaderField: "anthropic-dangerous-direct-browser-access")
        }

        request.httpBody = outboundBody

        return try await BurnBarProxyStreaming.openByteStream(
            session: BurnBarProxyStreaming.streamingSession,
            request: request,
            defaultContentType: "text/event-stream"
        )
    }

    /// Open a true streaming OpenAI Chat Completions response backed by an
    /// Anthropic Messages stream. The event mapping intentionally mirrors
    /// `chatCompletionsStreamFromAnthropicStream`; this variant performs the
    /// same transform incrementally instead of buffering the upstream SSE body.
    public func openChatCompletionsStream(
        body: Data,
        route: BurnBarProviderRoute,
        variant: BurnBarModelVariant? = nil
    ) async throws -> BurnBarProviderProxyStream {
        let (messagesBody, _) = try Self.anthropicMessagesBodyFromChatCompletionsRequest(
            body,
            modelID: route.resolvedModelID,
            variant: variant
        )
        let upstream = try await openMessagesStream(body: messagesBody, route: route, variant: variant)
        return Self.chatCompletionsStreamFromAnthropicMessagesStream(
            upstream,
            modelID: route.resolvedModelID
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
            headers: response.headers,
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
            headers: response.headers,
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
        variant: BurnBarModelVariant? = nil,
        forceStream: Bool = false
    ) throws -> Data {
        let decoded: AnthropicPassthroughRequest
        do {
            decoded = try JSONDecoder().decode(AnthropicPassthroughRequest.self, from: body)
        } catch {
            // Mirror the legacy guard: valid JSON that is not an object passes
            // through untouched; unparseable bodies rethrow the parse error.
            _ = try JSONSerialization.jsonObject(with: body)
            return body
        }
        var request = decoded
        request.model = .string(resolvedModelID)
        // Claude Code's first-party client can send fields that are valid for
        // its native transport but rejected by the public Messages endpoint.
        // BurnBar routes through /v1/messages, so strip known transport-only
        // keys instead of making Claude retry a deterministic 400 forever.
        request.additionalFields.removeValue(forKey: "context_management")
        request.additionalFields.removeValue(forKey: "effort")
        if applyClaudeCodeSystemGuard {
            request.system = injectClaudeCodeSystemGuard(into: request.system)
        }
        if let variant {
            // Live proxy forwarding: clamp the thinking budget under the
            // caller's max_tokens rather than inflating it (see A3).
            Self.applyAnthropicVariant(
                variant,
                thinking: &request.thinking,
                maxTokens: &request.maxTokens,
                effortOnly: true
            )
        }
        if forceStream {
            request.stream = .bool(true)
        }
        return try BurnBarBridgeJSON.encode(request, sortedKeys: true)
    }

    /// Ensure the request body's `system` field starts with the Claude Code
    /// guard prefix without discarding the caller's existing system text.
    /// Accepts the three shapes Anthropic supports (`nil`, string, content
    /// blocks); always returns a shape Anthropic accepts.
    private static func injectClaudeCodeSystemGuard(into existing: BurnBarBridgeValue?) -> BurnBarBridgeValue {
        let guardString = claudeCodeSystemGuard

        guard let existing, !existing.isNull else {
            return .string(guardString)
        }

        if let asString = existing.string {
            let trimmed = asString.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return .string(guardString)
            }
            if trimmed == guardString {
                return existing
            }
            let callerText: String
            if trimmed.hasPrefix(guardString) {
                callerText = String(trimmed.dropFirst(guardString.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                callerText = asString
            }
            guard !callerText.isEmpty else { return .string(guardString) }
            return .array([
                .object(["type": .string("text"), "text": .string(guardString)]),
                .object(["type": .string("text"), "text": .string(callerText)]),
            ])
        }

        if let asArray = existing.array, asArray.allSatisfy({ $0.object != nil }) {
            if let firstBlock = asArray.first,
               let text = firstBlock["text"]?.string,
               text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(guardString) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed != guardString else { return existing }
                let callerText = String(trimmed.dropFirst(guardString.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                var guardObject = firstBlock.object ?? [:]
                guardObject["text"] = .string(guardString)
                var normalized: [BurnBarBridgeValue] = [.object(guardObject)]
                if !callerText.isEmpty {
                    normalized.append(.object(["type": .string("text"), "text": .string(callerText)]))
                }
                normalized.append(contentsOf: asArray.dropFirst())
                return .array(normalized)
            }
            var combined: [BurnBarBridgeValue] = [
                .object(["type": .string("text"), "text": .string(guardString)]),
            ]
            combined.append(contentsOf: asArray)
            return .array(combined)
        }

        // Any other shape Anthropic would reject. Replace with a valid one
        // so the request never round-trips a 400 just because the caller
        // sent an unusual system field.
        return .string(guardString)
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

    // MARK: - Usage extraction

    /// Anthropic Messages responses carry usage on the top-level `usage`
    /// object (`input_tokens`, `output_tokens`, `cache_creation_input_tokens`,
    /// `cache_read_input_tokens`). We surface them so the usage recorder gets
    /// the same shape it does for OpenAI-family proxies.
    private static func extractProxyUsage(responseBody: Data) -> BurnBarProviderProxyUsage? {
        guard let envelope = try? JSONDecoder().decode(AnthropicUsageEnvelope.self, from: responseBody),
              let usage = envelope.usage else {
            return nil
        }
        let input = usage.inputTokens?.asIntStrict ?? 0
        let output = usage.outputTokens?.asIntStrict ?? 0
        let cacheCreation = usage.cacheCreationInputTokens?.asIntStrict ?? 0
        let cacheRead = usage.cacheReadInputTokens?.asIntStrict ?? 0
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
