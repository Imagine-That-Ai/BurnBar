import OpenBurnBarCore
import Foundation

/// Pass-through proxy for Anthropic Messages API requests.
///
/// The local gateway accepts `POST /v1/messages` from Claude Code (and any
/// other Anthropic-shape client configured with `ANTHROPIC_BASE_URL`), picks
/// a routed Anthropic-family account via `BurnBarProviderRouter`, and forwards
/// the bytes upstream with the right headers. No format translation — the
/// request body and the response body are shipped verbatim between the
/// client and the chosen Anthropic account.
///
/// Failover semantics mirror the OpenAI executor: on a retryable upstream
/// status (`429`, `401`, `402`, `403`, quota / rate-limit error text) the
/// gateway server marks the slot and retries against the next-best slot in
/// the same Anthropic-family pool.
public struct BurnBarAnthropicProviderExecutor: Sendable {
    public static let defaultAnthropicVersion = "2023-06-01"

    private let session: URLSession
    private let anthropicVersion: String

    public init(
        session: URLSession = .shared,
        anthropicVersion: String = BurnBarAnthropicProviderExecutor.defaultAnthropicVersion
    ) {
        self.session = session
        self.anthropicVersion = anthropicVersion
    }

    /// Forward an Anthropic Messages request to the chosen upstream account.
    ///
    /// - Parameters:
    ///   - body: Raw JSON bytes the client sent on `/v1/messages`.
    ///   - route: Routing decision from `BurnBarProviderRouter`.
    /// - Returns: The upstream response, ready to write back to the client.
    public func proxyMessages(
        body: Data,
        route: BurnBarProviderRoute
    ) async throws -> BurnBarProviderProxyResponse {
        guard let baseURL = URL(string: route.baseURL) else {
            throw BurnBarProviderExecutorError.invalidBaseURL(route.baseURL)
        }

        let outboundBody = try Self.rewritingModel(in: body, to: route.resolvedModelID)
        let endpoint = baseURL.appending(path: "messages")
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

    private static func rewritingModel(in body: Data, to resolvedModelID: String) throws -> Data {
        guard var json = try JSONSerialization.jsonObject(with: body, options: []) as? [String: Any] else {
            return body
        }
        json["model"] = resolvedModelID
        // Claude Code's first-party client can send fields that are valid for
        // its native transport but rejected by the public Messages endpoint.
        // BurnBar routes through /v1/messages, so strip known transport-only
        // keys instead of making Claude retry a deterministic 400 forever.
        json.removeValue(forKey: "context_management")
        return try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
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
