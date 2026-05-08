import Foundation

// MARK: - Home Assistant REST client
//
// Talks to the local Home Assistant API:
//   GET    /api/                                        — health probe
//   GET    /api/states                                  — entity discovery
//   POST   /api/services/<domain>/<service>             — invoke a service
//   POST   /api/config/automation/config/<id>           — create/update automation
//   GET    /api/config/automation/config/<id>           — read automation
//   POST   /api/webhook/<id>                            — webhook trigger
//
// Reference: https://developers.home-assistant.io/docs/api/rest/
//
// Design notes:
//   - actor: token state + URLSession ownership stays single-threaded
//   - URLProtocol-injectable URLSession: the entire test surface uses
//     `URLProtocol` mocks, so we never hit the network from CI
//   - ProbeResult is a tiny enum; HA's /api/ endpoint returns an
//     `{"message": "API running."}` body when both the URL and the
//     token are valid. We surface a granular outcome so the wizard
//     can show actionable errors

actor HomeAssistantClient {

    // MARK: - Errors

    enum ClientError: LocalizedError, Equatable {
        case invalidURL
        case unauthorized
        case forbidden
        case notFound(String)
        case rateLimited
        case server(Int, String)
        case transport(String)
        case decoding(String)
        case missingToken
        case timeout

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Home Assistant URL is invalid."
            case .unauthorized:
                return "Home Assistant rejected the access token. Issue a new long-lived access token and paste it again."
            case .forbidden:
                return "Home Assistant blocked the request. The token may not have admin scope."
            case .notFound(let path):
                return "Home Assistant did not have an endpoint at \(path)."
            case .rateLimited:
                return "Home Assistant is rate-limiting requests; try again in a moment."
            case .server(let code, let message):
                return "Home Assistant returned HTTP \(code): \(message)"
            case .transport(let message):
                return "Could not reach Home Assistant: \(message)"
            case .decoding(let message):
                return "Could not parse Home Assistant response: \(message)"
            case .missingToken:
                return "Home Assistant is not connected. Paste your long-lived access token first."
            case .timeout:
                return "Home Assistant did not answer in time. Make sure it's reachable on this network."
            }
        }
    }

    // MARK: - Probe / Auth

    enum ProbeStatus: Equatable {
        case ok(version: String?)              // /api/ returned 200 with optional X-HA-Version
        case unauthorized                      // base URL works, token does not
        case noHomeAssistantHere               // host responds but the body isn't HA
        case unreachable(String)               // transport or DNS error
    }

    // MARK: - Models

    struct State: Decodable, Sendable, Equatable {
        let entityID: String
        let state: String
        let attributes: [String: AttributeValue]

        enum CodingKeys: String, CodingKey {
            case entityID = "entity_id"
            case state
            case attributes
        }
    }

    /// Subset of HA attribute values we actually use. HA returns a
    /// heterogeneous dict where every value can be a string, number,
    /// bool, list, or null. We dynamic-decode and surface convenience
    /// accessors instead of trying to enumerate every possible shape.
    enum AttributeValue: Decodable, Sendable, Equatable {
        case string(String)
        case number(Double)
        case bool(Bool)
        case array([AttributeValue])
        case null

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let s = try? container.decode(String.self) {
                self = .string(s)
            } else if let b = try? container.decode(Bool.self) {
                self = .bool(b)
            } else if let n = try? container.decode(Double.self) {
                self = .number(n)
            } else if let a = try? container.decode([AttributeValue].self) {
                self = .array(a)
            } else {
                self = .null
            }
        }

        var stringValue: String? {
            switch self {
            case .string(let s): return s
            case .number(let n): return String(n)
            case .bool(let b): return String(b)
            default: return nil
            }
        }
    }

    /// Tightly-typed view of a `media_player` state document.
    struct MediaPlayer: Sendable, Equatable, Identifiable {
        let entityID: String
        let friendlyName: String
        let model: String?
        let supportsCast: Bool
        let supportedFeatures: Int
        let state: String
        var id: String { entityID }
    }

    // MARK: - Configuration

    private let session: URLSession
    private let timeout: TimeInterval

    init(session: URLSession = .shared, timeout: TimeInterval = 10) {
        self.session = session
        self.timeout = timeout
    }

    // MARK: - Endpoints

    func probe(baseURL: URL) async -> ProbeStatus {
        let endpoint = Self.haEndpoint(base: baseURL, path: "api/")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = timeout

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .noHomeAssistantHere
            }
            // /api/ always requires auth on modern HA. Without a token we
            // expect 401 — that's enough to confirm HA is here.
            switch http.statusCode {
            case 401:
                let version = http.value(forHTTPHeaderField: "X-Ha-Version")
                    ?? http.value(forHTTPHeaderField: "X-HA-Version")
                return .ok(version: version)
            case 200..<300:
                let version = http.value(forHTTPHeaderField: "X-Ha-Version")
                    ?? http.value(forHTTPHeaderField: "X-HA-Version")
                return .ok(version: version)
            case 404:
                return .noHomeAssistantHere
            default:
                return .ok(version: nil)
            }
        } catch {
            let message = (error as NSError).code == NSURLErrorTimedOut
                ? "Timed out"
                : error.localizedDescription
            return .unreachable(message)
        }
    }

    func validateToken(baseURL: URL, accessToken: String) async throws {
        let endpoint = Self.haEndpoint(base: baseURL, path: "api/")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await sendRequest(request)
        try ensureSuccess(response: response, data: data, path: "/api/")
        // We don't strictly need the body, but if HA returned the canonical
        // health body, surface a helpful decoding error if it's something else.
        if let body = String(data: data, encoding: .utf8),
           !body.contains("API running") && !body.contains("API is running") {
            // Tolerated: some proxies strip the message; only treat it as a
            // failure if the body is explicitly not JSON.
            if (try? JSONSerialization.jsonObject(with: data)) == nil {
                throw ClientError.decoding("unexpected /api/ body: \(body.prefix(120))")
            }
        }
    }

    /// Fetches every entity and projects the `media_player.*` rows into a
    /// clean MediaPlayer model. We sort by friendly name for the picker.
    func listMediaPlayers(baseURL: URL, accessToken: String) async throws -> [MediaPlayer] {
        let endpoint = Self.haEndpoint(base: baseURL, path: "api/states")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await sendRequest(request)
        try ensureSuccess(response: response, data: data, path: "/api/states")

        let decoder = JSONDecoder()
        let states: [State]
        do {
            states = try decoder.decode([State].self, from: data)
        } catch {
            throw ClientError.decoding("states response: \(error.localizedDescription)")
        }

        return states
            .filter { $0.entityID.hasPrefix("media_player.") }
            .map { state in
                let friendlyName = state.attributes["friendly_name"]?.stringValue
                    ?? state.entityID.replacingOccurrences(of: "media_player.", with: "")
                let model = state.attributes["model_name"]?.stringValue
                    ?? state.attributes["device_model"]?.stringValue
                let supportedFeatures = Int(state.attributes["supported_features"]?.stringValue ?? "0") ?? 0
                let supportsCast = MediaPlayer.entityLooksCastable(
                    entityID: state.entityID,
                    friendlyName: friendlyName,
                    model: model,
                    supportedFeatures: supportedFeatures
                )
                return MediaPlayer(
                    entityID: state.entityID,
                    friendlyName: friendlyName,
                    model: model,
                    supportsCast: supportsCast,
                    supportedFeatures: supportedFeatures,
                    state: state.state
                )
            }
            .sorted { lhs, rhs in
                if lhs.supportsCast != rhs.supportsCast {
                    return lhs.supportsCast && !rhs.supportsCast
                }
                return lhs.friendlyName.localizedCaseInsensitiveCompare(rhs.friendlyName) == .orderedAscending
            }
    }

    /// Creates or updates an HA automation by ID. HA exposes
    /// `/api/config/automation/config/<id>` (POST) which writes into
    /// `automations.yaml` and reloads the automation manager.
    /// `payload` should be the body documented at
    /// https://developers.home-assistant.io/docs/api/rest/#post-apiconfigautomationconfigid
    func upsertAutomation(
        baseURL: URL,
        accessToken: String,
        automationID: String,
        payload: [String: Any]
    ) async throws {
        let endpoint = Self.haEndpoint(base: baseURL, path: "api/config/automation/config/\(automationID)")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

        let (data, response) = try await sendRequest(request)
        try ensureSuccess(response: response, data: data, path: "/api/config/automation/config")
    }

    /// Triggers any HA service. Used for `media_player.media_stop`,
    /// `media_player.play_media`, etc., during the live test step.
    func callService(
        baseURL: URL,
        accessToken: String,
        domain: String,
        service: String,
        body: [String: Any]
    ) async throws {
        let endpoint = Self.haEndpoint(base: baseURL, path: "api/services/\(domain)/\(service)")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, response) = try await sendRequest(request)
        try ensureSuccess(response: response, data: data, path: "/api/services/\(domain)/\(service)")
    }

    /// POSTs an empty body to the local webhook. HA accepts any HTTP
    /// method by default; we use POST so the trigger body matches the
    /// production recovery payload.
    func triggerWebhook(_ url: URL, payload: Data?) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload

        let (data, response) = try await sendRequest(request)
        // Webhooks return 200 even when no automation is bound, so we only
        // bail on hard transport errors. The wizard verifies via state,
        // not status code.
        try ensureSuccess(response: response, data: data, path: "/api/webhook")
    }

    // MARK: - Internal

    /// Builds an HA endpoint URL preserving any trailing slash in `path`.
    /// `URL.appendingPathComponent` strips trailing slashes on macOS, which
    /// would break path-equality checks in tests and confuse strict proxies.
    static func haEndpoint(base: URL, path: String) -> URL {
        let baseString = base.absoluteString
        let trimmedBase = baseString.hasSuffix("/")
            ? String(baseString.dropLast())
            : baseString
        let trimmedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return URL(string: "\(trimmedBase)/\(trimmedPath)") ?? base.appendingPathComponent(path)
    }

    private func sendRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let urlError as URLError where urlError.code == .timedOut {
            throw ClientError.timeout
        } catch let urlError as URLError {
            throw ClientError.transport(urlError.localizedDescription)
        } catch {
            throw ClientError.transport(error.localizedDescription)
        }
    }

    private func ensureSuccess(response: URLResponse, data: Data, path: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.transport("non-HTTP response")
        }
        switch http.statusCode {
        case 200..<300:
            return
        case 401:
            throw ClientError.unauthorized
        case 403:
            throw ClientError.forbidden
        case 404:
            throw ClientError.notFound(path)
        case 429:
            throw ClientError.rateLimited
        default:
            let message = String(data: data, encoding: .utf8)?.prefix(160).description ?? "no body"
            throw ClientError.server(http.statusCode, message)
        }
    }
}

// MARK: - Cast detection

extension HomeAssistantClient.MediaPlayer {

    /// HA's media_player feature bitmask. We only check `PLAY_MEDIA`
    /// (1 << 9 = 512) because that's the minimum requirement to push a
    /// dashboard URL. Anything else (cast volume, app launch) is gravy.
    static let playMediaFeatureBit = 0x200

    static func entityLooksCastable(
        entityID: String,
        friendlyName: String,
        model: String?,
        supportedFeatures: Int
    ) -> Bool {
        if supportedFeatures & playMediaFeatureBit != 0 { return true }
        let haystacks = [entityID, friendlyName, model ?? ""].joined(separator: " ").lowercased()
        if haystacks.contains("nest hub") || haystacks.contains("chromecast")
            || haystacks.contains("google tv") || haystacks.contains("display")
            || haystacks.contains("nest mini") || haystacks.contains("nest audio")
            || haystacks.contains("home mini") || haystacks.contains("home max")
            || haystacks.contains("google home") {
            return true
        }
        return false
    }

    /// Heuristic: highest scoring entity is the one whose friendly name
    /// matches the discovered Cast device. Used to pre-select the picker.
    static func bestMatch(in players: [HomeAssistantClient.MediaPlayer], for friendlyName: String) -> HomeAssistantClient.MediaPlayer? {
        let needle = friendlyName.lowercased()
        if needle.isEmpty { return players.first(where: { $0.supportsCast }) }
        let score: (HomeAssistantClient.MediaPlayer) -> Int = { player in
            let haystack = (player.friendlyName + " " + player.entityID + " " + (player.model ?? "")).lowercased()
            if haystack == needle { return 100 }
            if haystack.contains(needle) { return 80 }
            if needle.contains(haystack) { return 60 }
            // word-token overlap
            let needleWords = Set(needle.split(whereSeparator: { !$0.isLetter && !$0.isNumber }))
            let hayWords = Set(haystack.split(whereSeparator: { !$0.isLetter && !$0.isNumber }))
            return needleWords.intersection(hayWords).count * 10
        }
        let scored = players.filter(\.supportsCast).map { ($0, score($0)) }
        let best = scored.max(by: { $0.1 < $1.1 })
        if let best, best.1 > 0 { return best.0 }
        return players.first(where: { $0.supportsCast })
    }
}
