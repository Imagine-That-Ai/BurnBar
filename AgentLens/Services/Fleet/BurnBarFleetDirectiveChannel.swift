import BurnBarCore
import Foundation

// MARK: - Delivery Outcomes

/// Typed terminal outcomes of a directive-delivery attempt (M4,
/// VAL-ORCH-014/030/036/037). Channels must fail closed: a malformed or
/// missing acknowledgement never yields `delivered`.
enum BurnBarFleetDeliveryOutcome: Equatable, Sendable {
    /// The channel acknowledged delivery of the directive.
    case delivered
    /// The delivery attempt failed with a non-empty reason (transport,
    /// HTTP, or malformed acknowledgement).
    case failed(reason: String)
    /// The target agent has no documented writable channel (or the channel
    /// reports it cannot deliver). The directive record stays `approved`.
    case unsupported(reason: String)
}

// MARK: - Channel Protocol

/// A documented input channel for delivering human-approved directives (M4).
///
/// Honesty invariants:
/// - delivery happens ONLY after a recorded human approval (the app records
///   `approved` before any channel call);
/// - a malformed acknowledgement fails closed — never a fabricated
///   `delivered` (VAL-ORCH-036);
/// - Claude's `/tmp/cc-socks/*.sock` messaging socket is undocumented
///   internal IPC and is NEVER used (VAL-ORCH-016).
protocol BurnBarFleetDirectiveChannel: Sendable {
    /// The channel's wire name (recorded in `deliveryChannel`).
    var channelName: String { get }
    /// Whether this channel can deliver to the given target agent.
    func supports(targetAgent: BurnBarFleetAgentID) -> Bool
    /// Delivers the directive. Returns a typed outcome; never throws.
    func deliver(_ directive: BurnBarFleetDirective) async -> BurnBarFleetDeliveryOutcome
}

// MARK: - Hermes Channel (Branch A)

/// The Hermes gateway delivery channel (branch A of VAL-ORCH-014).
///
/// The Hermes gateway exposes a documented writable input channel: its
/// `api_server` platform (`POST /v1/chat/completions` on
/// `http://127.0.0.1:8642`, Bearer auth via `API_SERVER_KEY`). This channel
/// delivers approved directives through that endpoint and verifies the
/// documented acknowledgement contract before reporting `delivered`.
///
/// Acknowledgement contract (fail closed): the response must be HTTP 200 and
/// valid JSON carrying
/// `{"burnbar_delivery":{"directive_id":"<id>","status":"delivered"}}`.
/// Invalid JSON, a missing/mismatched `directive_id`, or a status other than
/// `delivered` yields `failed(reason: "malformedAck: ...")` — never
/// `delivered` (VAL-ORCH-036). Transport failures and non-200 responses
/// yield typed `failed(reason:)` outcomes (VAL-ORCH-030).
///
/// The hermetic fixture gateway (`tools/burnbar-fake-hermes-gateway.py`)
/// implements this contract for validation; the real gateway is the same
/// documented endpoint.
final class HermesDirectiveChannel: BurnBarFleetDirectiveChannel, @unchecked Sendable {
    private static let defaultGatewayURL = URL(string: "http://127.0.0.1:8642")!

    /// The default gateway base URL. Overridable via
    /// `BURNBAR_HERMES_GATEWAY_URL` so hermetic validation can point the app
    /// at a loopback fixture gateway on a scratch port. Non-loopback
    /// overrides are ignored unless the explicit `BURNBAR_HERMES_ALLOW_REMOTE`
    /// opt-in is set.
    static func defaultBaseURL() -> URL {
        if let raw = ProcessInfo.processInfo.environment["BURNBAR_HERMES_GATEWAY_URL"],
           let url = URL(string: raw),
           isAllowedEndpoint(url) {
            return url
        }
        return defaultGatewayURL
    }

    /// Returns true only for the documented local Hermes endpoints, unless a
    /// deliberate remote opt-in is present. This guard protects the real
    /// `API_SERVER_KEY` from accidental transmission to an arbitrary URL.
    static func isAllowedEndpoint(_ url: URL) -> Bool {
        guard let rawHost = url.host?.lowercased(), !rawHost.isEmpty else { return false }
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if ["127.0.0.1", "localhost", "::1"].contains(host) {
            return true
        }
        return remoteDeliveryOptedIn
    }

    private static var remoteDeliveryOptedIn: Bool {
        let value = ProcessInfo.processInfo.environment["BURNBAR_HERMES_ALLOW_REMOTE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return value == "1" || value == "true" || value == "yes"
    }

    /// Resolves the gateway API key: `BURNBAR_HERMES_API_KEY` env first,
    /// then the `API_SERVER_KEY` line of `~/.hermes/.env` (structural parse
    /// of that one key only). The key is used for gateway authentication and
    /// is never logged, persisted, or copied into fixtures.
    static func resolveAPIKey() -> String? {
        if let env = ProcessInfo.processInfo.environment["BURNBAR_HERMES_API_KEY"],
           !env.isEmpty {
            return env
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let envURL = home.appendingPathComponent(".hermes/.env")
        guard let content = try? String(contentsOf: envURL, encoding: .utf8) else {
            return nil
        }
        for line in content.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("API_SERVER_KEY=") else { continue }
            var value = String(trimmed.dropFirst("API_SERVER_KEY=".count))
            value = value.trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            let key = value
            return key.isEmpty ? nil : key
        }
        return nil
    }

    let baseURL: URL
    let apiKey: String?
    /// The delivery request timeout. The fixture gateway holds its
    /// acknowledgement in `hold` mode; the default 30s bound is documented
    /// in docs/fleet/BURNBAR_FLEET_API.md.
    let timeout: TimeInterval
    private let session: URLSession

    init(
        baseURL: URL = HermesDirectiveChannel.defaultBaseURL(),
        apiKey: String? = HermesDirectiveChannel.resolveAPIKey(),
        timeout: TimeInterval = 30,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.timeout = timeout
        self.session = session
    }

    var channelName: String { "hermes" }

    func supports(targetAgent: BurnBarFleetAgentID) -> Bool {
        targetAgent == .hermes
    }

    func deliver(_ directive: BurnBarFleetDirective) async -> BurnBarFleetDeliveryOutcome {
        guard Self.isAllowedEndpoint(baseURL) else {
            return .failed(
                reason: "hermes gateway URL rejected: non-loopback endpoint requires "
                    + "BURNBAR_HERMES_ALLOW_REMOTE=true"
            )
        }
        let endpoint = baseURL.appendingPathComponent("v1/chat/completions")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = Self.requestBody(for: directive)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            return .failed(reason: "hermes gateway unreachable: \(error.localizedDescription)")
        }

        guard let http = response as? HTTPURLResponse else {
            return .failed(reason: "hermes gateway error: non-HTTP response")
        }
        guard http.statusCode == 200 else {
            return .failed(reason: "hermes gateway error (HTTP \(http.statusCode))")
        }

        return Self.validateAck(data: data, directiveID: directive.id)
    }

    /// The documented acknowledgement contract (branch A). Any deviation
    /// fails closed with a `malformedAck` reason — never `delivered`
    /// (VAL-ORCH-036).
    static func validateAck(data: Data, directiveID: String) -> BurnBarFleetDeliveryOutcome {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failed(reason: "malformedAck: response is not valid JSON")
        }
        guard let delivery = object["burnbar_delivery"] as? [String: Any] else {
            return .failed(reason: "malformedAck: missing burnbar_delivery acknowledgement")
        }
        guard let ackID = delivery["directive_id"] as? String else {
            return .failed(reason: "malformedAck: missing directive_id in acknowledgement")
        }
        guard ackID == directiveID else {
            return .failed(
                reason: "malformedAck: directive id mismatch (expected \(directiveID), got \(ackID))"
            )
        }
        guard let status = delivery["status"] as? String, status == "delivered" else {
            let got = (delivery["status"] as? String) ?? "missing"
            return .failed(reason: "malformedAck: unknown or contradictory status '\(got)'")
        }
        return .delivered
    }

    /// The chat-completions request body: the directive is embedded in the
    /// user message as `burnbar_directive: {json}` so the gateway (and the
    /// fixture) can correlate the acknowledgement by directive id.
    static func requestBody(for directive: BurnBarFleetDirective) -> Data? {
        let directiveJSON: [String: Any] = [
            "id": directive.id,
            "kind": directive.kind.rawValue,
            "targetAgent": directive.targetAgent?.wireValue ?? NSNull(),
            "payload": directive.payload
        ]
        let body: [String: Any] = [
            "stream": false,
            "messages": [
                [
                    "role": "system",
                    "content": "You are the Hermes gateway. A BurnBar directive has been approved "
                        + "by the human operator. Execute it for the target agent."
                ],
                [
                    "role": "user",
                    "content": "burnbar_directive: \(Self.jsonString(directiveJSON))"
                ]
            ]
        ]
        return try? JSONSerialization.data(withJSONObject: body)
    }

    private static func jsonString(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}
