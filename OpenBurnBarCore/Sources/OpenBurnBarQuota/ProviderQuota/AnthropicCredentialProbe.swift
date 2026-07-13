import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Validates an Anthropic credential against the real Anthropic Messages API
/// before OpenBurnBar accepts it as a routable account.
///
/// Two credential shapes are supported, mirroring what
/// `BurnBarAnthropicProviderExecutor` accepts on the gateway:
///   1. **Console API keys** (`sk-ant-api…`) sent via the `x-api-key` header.
///   2. **Pro/Team OAuth bearers** sent via `Authorization: Bearer …`.
///
/// The probe issues a real `POST /v1/messages` with `max_tokens: 1` so the
/// account is charged at most one output token for the verification. A 200
/// response classifies the credential as healthy; the upstream's status code
/// classifies any other outcome.
///
/// The probe never echoes the credential into logs or the structured result —
/// only the trailing four characters are surfaced as a `redactedLabel`.
public struct AnthropicCredentialProbe: Sendable {

    public static let defaultBaseURL = URL(string: "https://api.anthropic.com/v1")!
    /// Anthropic Messages API version header. Mirror the daemon's
    /// `BurnBarAnthropicProviderExecutor.defaultAnthropicVersion` — bump in
    /// lockstep when Anthropic ships a new pinned version.
    public static let defaultAnthropicVersion = "2023-06-01"
    public static let defaultProbeModel = "claude-haiku-4-5"

public enum Shape: String, Sendable {
        case consoleAPIKey
        case oauthBearer
    }

public enum Verdict: Sendable, Equatable {
        case ok(model: String)
        case authFailed
        case rateLimited
        case quotaExhausted
        case modelUnavailable(message: String)
        case networkError(message: String)
        case unexpected(status: Int, message: String)

        var isHealthy: Bool {
            if case .ok = self { return true }
            return false
        }

        /// User-facing one-liner. Never contains the credential.
        var summary: String {
            switch self {
            case .ok(let model):
                return "Healthy — Anthropic responded for \(model)."
            case .authFailed:
                return "Anthropic rejected the credential (auth failed)."
            case .rateLimited:
                return "Anthropic is rate-limiting this account right now."
            case .quotaExhausted:
                return "Anthropic reports this account is out of quota."
            case .modelUnavailable(let message):
                return "Anthropic could not run a 1-token probe: \(message)."
            case .networkError(let message):
                return "Could not reach Anthropic: \(message)."
            case .unexpected(let status, let message):
                return "Anthropic returned HTTP \(status): \(message)."
            }
        }
    }

    /// Authoritative per-organization rate-limit data extracted from the
    /// `anthropic-ratelimit-*` headers Anthropic returns on every Messages API
    /// response. For Claude Max/Pro consumer plans these are the `unified-*`
    /// headers (5-hour/7-day rolling token budget); for Console API keys they
    /// are the standard per-minute RPM/ITPM/OTPM headers.
    ///
    /// The `-reset` values are seconds-until-reset (per Anthropic's docs), not
    /// absolute timestamps. The caller converts to an absolute `Date`.
public struct RateLimitHeaders: Sendable, Equatable {
        // Unified (Claude Max / Pro consumer plans)
        let unifiedTokensLimit: Double?
        let unifiedTokensRemaining: Double?
        let unifiedTokensResetSeconds: Double?

        // Standard (Console API keys)
        let requestsLimit: Double?
        let requestsRemaining: Double?
        let requestsResetSeconds: Double?
        let inputTokensLimit: Double?
        let inputTokensRemaining: Double?
        let inputTokensResetSeconds: Double?
        let outputTokensLimit: Double?
        let outputTokensRemaining: Double?
        let outputTokensResetSeconds: Double?

        var hasUnifiedData: Bool {
            unifiedTokensLimit != nil || unifiedTokensRemaining != nil
        }

        var hasStandardData: Bool {
            requestsLimit != nil || requestsRemaining != nil
                || inputTokensLimit != nil || inputTokensRemaining != nil
                || outputTokensLimit != nil || outputTokensRemaining != nil
        }

        var isEmpty: Bool { !hasUnifiedData && !hasStandardData }

        static let empty = RateLimitHeaders(
            unifiedTokensLimit: nil, unifiedTokensRemaining: nil, unifiedTokensResetSeconds: nil,
            requestsLimit: nil, requestsRemaining: nil, requestsResetSeconds: nil,
            inputTokensLimit: nil, inputTokensRemaining: nil, inputTokensResetSeconds: nil,
            outputTokensLimit: nil, outputTokensRemaining: nil, outputTokensResetSeconds: nil
        )

        /// Parse rate-limit headers from an HTTP response. Header lookup is
        /// case-insensitive via `HTTPURLResponse.value(forHTTPHeaderField:)`.
        static func parse(from response: HTTPURLResponse) -> RateLimitHeaders {
            func doubleValue(_ name: String) -> Double? {
                guard let raw = response.value(forHTTPHeaderField: name),
                      let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines) as String?,
                      !trimmed.isEmpty else { return nil }
                return Double(trimmed)
            }

            return RateLimitHeaders(
                unifiedTokensLimit: doubleValue("anthropic-ratelimit-unified-tokens-limit"),
                unifiedTokensRemaining: doubleValue("anthropic-ratelimit-unified-tokens-remaining"),
                unifiedTokensResetSeconds: doubleValue("anthropic-ratelimit-unified-tokens-reset"),
                requestsLimit: doubleValue("anthropic-ratelimit-requests-limit"),
                requestsRemaining: doubleValue("anthropic-ratelimit-requests-remaining"),
                requestsResetSeconds: doubleValue("anthropic-ratelimit-requests-reset"),
                inputTokensLimit: doubleValue("anthropic-ratelimit-input-tokens-limit"),
                inputTokensRemaining: doubleValue("anthropic-ratelimit-input-tokens-remaining"),
                inputTokensResetSeconds: doubleValue("anthropic-ratelimit-input-tokens-reset"),
                outputTokensLimit: doubleValue("anthropic-ratelimit-output-tokens-limit"),
                outputTokensRemaining: doubleValue("anthropic-ratelimit-output-tokens-remaining"),
                outputTokensResetSeconds: doubleValue("anthropic-ratelimit-output-tokens-reset")
            )
        }
    }

public struct Result: Sendable, Equatable {
        let verdict: Verdict
        let shape: Shape
        let redactedLabel: String
        let probedAt: Date
        let rateLimitHeaders: RateLimitHeaders

        var isHealthy: Bool { verdict.isHealthy }
    }

    private let session: URLSession
    private let baseURL: URL
    private let anthropicVersion: String
    private let probeModel: String
    private let clock: @Sendable () -> Date

    public init(
        session: URLSession = .shared,
        baseURL: URL = AnthropicCredentialProbe.defaultBaseURL,
        anthropicVersion: String = AnthropicCredentialProbe.defaultAnthropicVersion,
        probeModel: String = AnthropicCredentialProbe.defaultProbeModel,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session
        self.baseURL = baseURL
        self.anthropicVersion = anthropicVersion
        self.probeModel = probeModel
        self.clock = clock
    }

    /// Detect which header shape applies to a candidate credential.
public static func detectShape(_ rawCredential: String) -> Shape {
        let trimmed = rawCredential.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.lowercased().hasPrefix("sk-ant-api") ? .consoleAPIKey : .oauthBearer
    }

    /// Render a non-sensitive label for UI ("…ABCD").
public static func redactedLabel(_ rawCredential: String) -> String {
        let trimmed = rawCredential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 4 else { return "…" }
        return "…\(trimmed.suffix(4))"
    }

    /// Build the outbound 1-token probe request (test seam for header dispatch).
public func buildProbeRequest(credential rawCredential: String) throws -> (request: URLRequest, shape: Shape) {
        let shape = Self.detectShape(rawCredential)
        let endpoint = baseURL.appending(path: "messages")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        switch shape {
        case .consoleAPIKey:
            request.setValue(rawCredential, forHTTPHeaderField: "x-api-key")
        case .oauthBearer:
            request.setValue("Bearer \(rawCredential)", forHTTPHeaderField: "Authorization")
        }

        let body: [String: Any] = [
            "model": probeModel,
            "max_tokens": 1,
            "messages": [
                ["role": "user", "content": "ping"]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return (request, shape)
    }

    /// Run the 1-token probe against `/v1/messages`.
public func probe(credential rawCredential: String) async -> Result {
        let label = Self.redactedLabel(rawCredential)
        let built: (request: URLRequest, shape: Shape)
        do {
            built = try buildProbeRequest(credential: rawCredential)
        } catch {
            let shape = Self.detectShape(rawCredential)
            return Result(
                verdict: .unexpected(status: 0, message: "could not encode probe body"),
                shape: shape,
                redactedLabel: label,
                probedAt: clock(),
                rateLimitHeaders: .empty
            )
        }
        let request = built.request
        let shape = built.shape

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return Result(
                    verdict: .networkError(message: "missing HTTP response"),
                    shape: shape,
                    redactedLabel: label,
                    probedAt: clock(),
                    rateLimitHeaders: .empty
                )
            }
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            let verdict = classify(status: http.statusCode, body: bodyText)
            let headers = RateLimitHeaders.parse(from: http)
            return Result(verdict: verdict, shape: shape, redactedLabel: label, probedAt: clock(), rateLimitHeaders: headers)
        } catch {
            return Result(
                verdict: .networkError(message: error.localizedDescription),
                shape: shape,
                redactedLabel: label,
                probedAt: clock(),
                rateLimitHeaders: .empty
            )
        }
    }

public func classify(status: Int, body: String) -> Verdict {
        if (200..<300).contains(status) {
            return .ok(model: probeModel)
        }
        let lowered = body.lowercased()
        switch status {
        case 401, 403:
            return .authFailed
        case 402:
            return .quotaExhausted
        case 429:
            if lowered.contains("quota") || lowered.contains("insufficient") || lowered.contains("exhaust") {
                return .quotaExhausted
            }
            return .rateLimited
        case 404, 400:
            // Anthropic returns 404 for unknown model IDs; 400 for malformed
            // requests. Either points the user at fixing the probe target.
            return .modelUnavailable(message: shortMessage(from: body))
        default:
            return .unexpected(status: status, message: shortMessage(from: body))
        }
    }

    private func shortMessage(from body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "empty body" }
        if trimmed.count > 200 {
            return String(trimmed.prefix(197)) + "…"
        }
        return trimmed
    }
}
