import Foundation

/// Validates an Anthropic credential against the real Anthropic Messages API
/// before OpenBurnBar accepts it as a routable account.
///
/// Two credential shapes are supported, mirroring what
/// `BurnBarAnthropicProviderExecutor` accepts on the gateway:
///   1. **Console API keys** (`sk-ant-…`) sent via the `x-api-key` header.
///   2. **Pro/Team OAuth bearers** sent via `Authorization: Bearer …`.
///
/// The probe issues a real `POST /v1/messages` with `max_tokens: 1` so the
/// account is charged at most one output token for the verification. A 200
/// response classifies the credential as healthy; the upstream's status code
/// classifies any other outcome.
///
/// The probe never echoes the credential into logs or the structured result —
/// only the trailing four characters are surfaced as a `redactedLabel`.
struct AnthropicCredentialProbe: Sendable {

    static let defaultBaseURL = URL(string: "https://api.anthropic.com/v1")!
    /// Anthropic Messages API version header. Mirror the daemon's
    /// `BurnBarAnthropicProviderExecutor.defaultAnthropicVersion` — bump in
    /// lockstep when Anthropic ships a new pinned version.
    static let defaultAnthropicVersion = "2023-06-01"
    static let defaultProbeModel = "claude-haiku-4-5"

    enum Shape: String, Sendable {
        case consoleAPIKey
        case oauthBearer
    }

    enum Verdict: Sendable, Equatable {
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

    struct Result: Sendable, Equatable {
        let verdict: Verdict
        let shape: Shape
        let redactedLabel: String
        let probedAt: Date

        var isHealthy: Bool { verdict.isHealthy }
    }

    private let session: URLSession
    private let baseURL: URL
    private let anthropicVersion: String
    private let probeModel: String
    private let clock: @Sendable () -> Date

    init(
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
    static func detectShape(_ rawCredential: String) -> Shape {
        let trimmed = rawCredential.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("sk-ant-") ? .consoleAPIKey : .oauthBearer
    }

    /// Render a non-sensitive label for UI ("…ABCD").
    static func redactedLabel(_ rawCredential: String) -> String {
        let trimmed = rawCredential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 4 else { return "…" }
        return "…\(trimmed.suffix(4))"
    }

    /// Run the 1-token probe against `/v1/messages`.
    func probe(credential rawCredential: String) async -> Result {
        let shape = Self.detectShape(rawCredential)
        let label = Self.redactedLabel(rawCredential)
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
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        } catch {
            return Result(
                verdict: .unexpected(status: 0, message: "could not encode probe body"),
                shape: shape,
                redactedLabel: label,
                probedAt: clock()
            )
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return Result(
                    verdict: .networkError(message: "missing HTTP response"),
                    shape: shape,
                    redactedLabel: label,
                    probedAt: clock()
                )
            }
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            let verdict = classify(status: http.statusCode, body: bodyText)
            return Result(verdict: verdict, shape: shape, redactedLabel: label, probedAt: clock())
        } catch {
            return Result(
                verdict: .networkError(message: error.localizedDescription),
                shape: shape,
                redactedLabel: label,
                probedAt: clock()
            )
        }
    }

    private func classify(status: Int, body: String) -> Verdict {
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
