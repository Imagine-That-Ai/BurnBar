import OpenBurnBarCore
import Foundation

public typealias BurnBarConnectorTransport = @Sendable (_ request: URLRequest) async throws -> (Data, HTTPURLResponse)

// MARK: - Connector URL Validation Errors

/// Errors thrown when a connector base URL fails SSRF or scheme validation.
///
/// Connectors attach `Authorization: Bearer` credentials to outbound requests,
/// so the base URL must be HTTPS-only and must not point to private/reserved IPs
/// (RFC 1918, link-local, loopback, cloud metadata endpoints).
public enum BurnBarConnectorURLValidationError: Error, Sendable, Equatable, CustomStringConvertible {
    case emptyURL
    case invalidURL(String)
    case schemeNotHTTPS(String)
    case missingHost
    case privateOrReservedIP(String)
    case cloudMetadataEndpoint

    public var description: String {
        switch self {
        case .emptyURL:
            return "Connector base URL must not be empty."
        case .invalidURL(let raw):
            return "Connector base URL is not a valid URL: \(raw)"
        case .schemeNotHTTPS(let scheme):
            return "Connector base URL must use HTTPS (got \(scheme)). HTTP is not permitted because credentials are sent in the Authorization header."
        case .missingHost:
            return "Connector base URL must have a non-empty hostname."
        case .privateOrReservedIP(let host):
            return "Connector base URL must not point to a private or reserved IP address (\(host)). This blocks SSRF attacks that could exfiltrate credentials."
        case .cloudMetadataEndpoint:
            return "Connector base URL must not point to a cloud metadata endpoint (169.254.169.254)."
        }
    }
}

private struct BurnBarStoredConnectorConfig: Codable, Hashable {
    let kind: BurnBarConnectorKind
    var isEnabled: Bool
    var baseURL: String
    var authKind: BurnBarConnectorAuthKind
    var metadata: [String: BurnBarJSONValue]
}

private struct BurnBarStoredConnectorValidation: Codable, Hashable {
    var status: BurnBarConnectorHealthStatus
    var checkedAt: Date
    var detail: String?
}

private struct BurnBarStoredConnectorPlaneFile: Codable, Hashable {
    var updatedAt: Date
    var configs: [String: BurnBarStoredConnectorConfig]
    var validations: [String: BurnBarStoredConnectorValidation]
}

public actor BurnBarConnectorPlaneService {
    private let fileURL: URL
    private let secretStore: any BurnBarConnectorSecretStoring
    private let transport: BurnBarConnectorTransport
    private let logger: BurnBarDaemonLogger
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var cachedState: BurnBarStoredConnectorPlaneFile?

    public init(
        fileURL: URL = BurnBarDaemonPaths.defaultConnectorPlaneURL,
        secretStore: any BurnBarConnectorSecretStoring = BurnBarConnectorKeychainSecretStore(),
        transport: BurnBarConnectorTransport? = nil,
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(category: "connector-plane")
    ) {
        self.fileURL = fileURL
        self.secretStore = secretStore
        self.transport = transport ?? { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            return (data, httpResponse)
        }
        self.logger = logger
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    // MARK: - Connector URL Validation (SSRF + HTTPS enforcement)

    /// Validates that a connector base URL is HTTPS-only and does not point to
    /// a private, reserved, or cloud-metadata IP address.
    ///
    /// This is stricter than `validatedProviderBaseURL` (which allows HTTP for
    /// localhost Ollama) because connectors always attach `Authorization: Bearer`
    /// credentials to outbound requests.
    ///
    /// - Parameter rawValue: The raw URL string from the connector config.
    /// - Returns: A validated `URL`.
    /// - Throws: `BurnBarConnectorURLValidationError` if validation fails.
    static func validatedConnectorBaseURL(_ rawValue: String) throws -> URL {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            throw BurnBarConnectorURLValidationError.emptyURL
        }
        guard let url = URL(string: trimmed) else {
            throw BurnBarConnectorURLValidationError.invalidURL(trimmed)
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "https" else {
            throw BurnBarConnectorURLValidationError.schemeNotHTTPS(url.scheme ?? "(none)")
        }
        guard let host = url.host, host.isEmpty == false else {
            throw BurnBarConnectorURLValidationError.missingHost
        }
        let lowerHost = host.lowercased()
        // Block cloud metadata endpoints
        if lowerHost == "169.254.169.254" || lowerHost == "metadata.google.internal" {
            throw BurnBarConnectorURLValidationError.cloudMetadataEndpoint
        }
        // Block private/reserved IPs
        if isPrivateOrReservedIP(host: lowerHost) {
            throw BurnBarConnectorURLValidationError.privateOrReservedIP(host)
        }
        return url
    }

    /// Returns `true` if the hostname is a private, reserved, or loopback IP.
    ///
    /// Covers: loopback (127.x, ::1), RFC 1918 (10.x, 172.16-31.x, 192.168.x),
    /// link-local (169.254.x except the metadata endpoint handled above),
    /// and zero address (0.0.0.0).
    private static func isPrivateOrReservedIP(host: String) -> Bool {
        // IPv4 check
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 4, let a = Int(parts[0]), let b = Int(parts[1]) {
            // 127.x.x.x — loopback
            if a == 127 { return true }
            // 10.x.x.x — RFC 1918 Class A
            if a == 10 { return true }
            // 172.16.x.x – 172.31.x.x — RFC 1918 Class B
            if a == 172, (16...31).contains(b) { return true }
            // 192.168.x.x — RFC 1918 Class C
            if a == 192, b == 168 { return true }
            // 169.254.x.x — link-local (metadata endpoint caught above)
            if a == 169, b == 254 { return true }
            // 0.0.0.0 — unspecified
            if a == 0, b == 0 { return true }
        }
        // IPv6 loopback
        if host == "::1" || host == "[::1]" || host == "0:0:0:0:0:0:0:1" { return true }
        return false
    }

    // MARK: - Internal

    public func snapshot() async throws -> BurnBarConnectorPlaneSnapshot {
        let state = try loadStateIfNeeded()
        var connectors: [BurnBarConnectorConfigSnapshot] = []
        connectors.reserveCapacity(BurnBarConnectorKind.allCases.count)

        for kind in BurnBarConnectorKind.allCases {
            let config = state.configs[kind.rawValue] ?? Self.defaultConfig(for: kind)
            let validation = state.validations[kind.rawValue]
            let secret = try await secretStore.secret(for: kind)
            connectors.append(
                Self.snapshot(
                    for: config,
                    secret: secret,
                    validation: validation
                )
            )
        }

        return BurnBarConnectorPlaneSnapshot(
            updatedAt: state.updatedAt,
            connectors: connectors.sorted { $0.displayName < $1.displayName }
        )
    }

    public func updateConfig(_ request: BurnBarConnectorConfigUpdateRequest) async throws -> BurnBarConnectorPlaneSnapshot {
        var state = try loadStateIfNeeded()
        let trimmedBaseURL = request.config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        state.configs[request.config.kind.rawValue] = BurnBarStoredConnectorConfig(
            kind: request.config.kind,
            isEnabled: request.config.isEnabled,
            baseURL: trimmedBaseURL,
            authKind: request.config.authKind,
            metadata: request.config.metadata
        )
        if request.replaceSecret {
            try await secretStore.setSecret(request.secret, for: request.config.kind)
        }
        state.validations[request.config.kind.rawValue] = nil
        state.updatedAt = Date()
        try persist(state)
        return try await snapshot()
    }

    public func performAction(_ request: BurnBarConnectorActionRequest) async throws -> BurnBarConnectorActionResponse {
        var state = try loadStateIfNeeded()
        let config = state.configs[request.kind.rawValue] ?? Self.defaultConfig(for: request.kind)
        let secret = try await secretStore.secret(for: request.kind)
        let now = Date()

        guard config.isEnabled else {
            let response = BurnBarConnectorActionResponse(
                kind: request.kind,
                action: request.action,
                ok: false,
                summary: "\(Self.displayName(for: request.kind)) is disabled.",
                detail: "Enable the connector before testing it.",
                recordedAt: now
            )
            state.validations[request.kind.rawValue] = BurnBarStoredConnectorValidation(
                status: .disabled,
                checkedAt: now,
                detail: response.detail
            )
            try persist(state)
            return response
        }

        guard let secret, secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            let response = BurnBarConnectorActionResponse(
                kind: request.kind,
                action: request.action,
                ok: false,
                summary: "\(Self.displayName(for: request.kind)) is missing credentials.",
                detail: "Save a token or access credential in OpenBurnBar Settings first.",
                recordedAt: now
            )
            state.validations[request.kind.rawValue] = BurnBarStoredConnectorValidation(
                status: .missingSecret,
                checkedAt: now,
                detail: response.detail
            )
            try persist(state)
            return response
        }

        do {
            let response = try await performRemoteAction(
                request,
                config: config,
                secret: secret,
                recordedAt: now
            )
            state.validations[request.kind.rawValue] = BurnBarStoredConnectorValidation(
                status: .healthy,
                checkedAt: now,
                detail: response.summary
            )
            state.updatedAt = now
            try persist(state)
            return response
        } catch {
            let response = BurnBarConnectorActionResponse(
                kind: request.kind,
                action: request.action,
                ok: false,
                summary: "\(Self.displayName(for: request.kind)) request failed.",
                detail: error.localizedDescription,
                recordedAt: now
            )
            state.validations[request.kind.rawValue] = BurnBarStoredConnectorValidation(
                status: .degraded,
                checkedAt: now,
                detail: error.localizedDescription
            )
            state.updatedAt = now
            try persist(state)
            return response
        }
    }

    private func performRemoteAction(
        _ request: BurnBarConnectorActionRequest,
        config: BurnBarStoredConnectorConfig,
        secret: String,
        recordedAt: Date
    ) async throws -> BurnBarConnectorActionResponse {
        let urlRequest = try makeRequest(for: request.kind, config: config, secret: secret)
        let (data, response) = try await transport(urlRequest)
        guard (200 ..< 300).contains(response.statusCode) else {
            throw NSError(
                domain: "BurnBarConnectorPlaneService",
                code: response.statusCode,
                userInfo: [NSLocalizedDescriptionKey: Self.httpErrorDetail(data: data, statusCode: response.statusCode)]
            )
        }

        let jsonObject = try Self.jsonObject(from: data)
        let payload = Self.jsonValue(from: jsonObject)
        let (summary, detail) = Self.responseSummary(for: request.kind, payload: jsonObject)

        return BurnBarConnectorActionResponse(
            kind: request.kind,
            action: request.action,
            ok: true,
            summary: summary,
            detail: detail,
            payload: payload,
            recordedAt: recordedAt
        )
    }

    private func makeRequest(
        for kind: BurnBarConnectorKind,
        config: BurnBarStoredConnectorConfig,
        secret: String
    ) throws -> URLRequest {
        let trimmedBaseURL = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL = URL(string: trimmedBaseURL), trimmedBaseURL.isEmpty == false else {
            throw NSError(
                domain: "BurnBarConnectorPlaneService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Connector base URL is invalid."]
            )
        }

        switch kind {
        case .github:
            var request = URLRequest(url: baseURL.appendingPathComponent("user"))
            request.httpMethod = "GET"
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            return request
        case .slack:
            var request = URLRequest(url: baseURL.appendingPathComponent("auth.test"))
            request.httpMethod = "POST"
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
            return request
        case .linear:
            var request = URLRequest(url: baseURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(secret, forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONEncoder().encode(["query": "{ viewer { id name email } }"])
            return request
        case .posthog:
            var components = URLComponents(url: baseURL.appendingPathComponent("projects"), resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "limit", value: "1")]
            guard let url = components?.url else {
                throw URLError(.badURL)
            }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
            return request
        case .sentry:
            var request = URLRequest(url: baseURL.appendingPathComponent("organizations"))
            request.httpMethod = "GET"
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
            return request
        case .gmail:
            var request = URLRequest(url: baseURL.appendingPathComponent("users/me/profile"))
            request.httpMethod = "GET"
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
            return request
        }
    }

    private func loadStateIfNeeded() throws -> BurnBarStoredConnectorPlaneFile {
        if let cachedState {
            return cachedState
        }

        let defaultState = Self.defaultState()
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            cachedState = defaultState
            return defaultState
        }

        let data = try Data(contentsOf: fileURL)
        let decoded = try decoder.decode(BurnBarStoredConnectorPlaneFile.self, from: data)
        cachedState = decoded
        return decoded
    }

    private func persist(_ state: BurnBarStoredConnectorPlaneFile) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try encoder.encode(state)
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        cachedState = state
    }

    private static func defaultState() -> BurnBarStoredConnectorPlaneFile {
        BurnBarStoredConnectorPlaneFile(
            updatedAt: Date(),
            configs: Dictionary(
                uniqueKeysWithValues: BurnBarConnectorKind.allCases.map { kind in
                    (kind.rawValue, defaultConfig(for: kind))
                }
            ),
            validations: [:]
        )
    }

    private static func defaultConfig(for kind: BurnBarConnectorKind) -> BurnBarStoredConnectorConfig {
        switch kind {
        case .github:
            return BurnBarStoredConnectorConfig(kind: kind, isEnabled: false, baseURL: "https://api.github.com", authKind: .bearerToken, metadata: [:])
        case .slack:
            return BurnBarStoredConnectorConfig(kind: kind, isEnabled: false, baseURL: "https://slack.com/api", authKind: .bearerToken, metadata: [:])
        case .linear:
            return BurnBarStoredConnectorConfig(kind: kind, isEnabled: false, baseURL: "https://api.linear.app/graphql", authKind: .bearerToken, metadata: [:])
        case .posthog:
            return BurnBarStoredConnectorConfig(kind: kind, isEnabled: false, baseURL: "https://app.posthog.com/api", authKind: .bearerToken, metadata: [:])
        case .sentry:
            return BurnBarStoredConnectorConfig(kind: kind, isEnabled: false, baseURL: "https://sentry.io/api/0", authKind: .bearerToken, metadata: [:])
        case .gmail:
            return BurnBarStoredConnectorConfig(kind: kind, isEnabled: false, baseURL: "https://gmail.googleapis.com/gmail/v1", authKind: .oauthAccessToken, metadata: [:])
        }
    }

    private static func snapshot(
        for config: BurnBarStoredConnectorConfig,
        secret: String?,
        validation: BurnBarStoredConnectorValidation?
    ) -> BurnBarConnectorConfigSnapshot {
        let secretConfigured = secret?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let status: BurnBarConnectorHealthStatus
        if config.isEnabled == false {
            status = .disabled
        } else if !secretConfigured {
            status = .missingSecret
        } else {
            status = validation?.status ?? .configured
        }

        return BurnBarConnectorConfigSnapshot(
            kind: config.kind,
            displayName: displayName(for: config.kind),
            isEnabled: config.isEnabled,
            baseURL: config.baseURL,
            authKind: config.authKind,
            secretConfigured: secretConfigured,
            secretHint: secretConfigured ? Self.secretHint(for: secret) : nil,
            status: status,
            lastCheckedAt: validation?.checkedAt,
            statusDetail: validation?.detail,
            supportedActions: BurnBarConnectorActionKind.allCases,
            metadata: config.metadata
        )
    }

    private static func displayName(for kind: BurnBarConnectorKind) -> String {
        switch kind {
        case .github: return "GitHub"
        case .slack: return "Slack"
        case .linear: return "Linear"
        case .posthog: return "PostHog"
        case .sentry: return "Sentry"
        case .gmail: return "Gmail"
        }
    }

    private static func secretHint(for secret: String?) -> String? {
        guard let secret, secret.count >= 4 else { return nil }
        return "\(secret.prefix(2))…\(secret.suffix(2))"
    }

    private static func jsonObject(from data: Data) throws -> Any {
        try JSONSerialization.jsonObject(with: data)
    }

    private static func jsonValue(from object: Any) -> BurnBarJSONValue {
        switch object {
        case let string as String:
            return .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            return .number(number.doubleValue)
        case let dictionary as [String: Any]:
            return .object(dictionary.mapValues(jsonValue(from:)))
        case let array as [Any]:
            return .array(array.map(jsonValue(from:)))
        default:
            return .null
        }
    }

    private static func responseSummary(
        for kind: BurnBarConnectorKind,
        payload: Any
    ) -> (String, String?) {
        let dictionary = payload as? [String: Any]
        switch kind {
        case .github:
            let login = dictionary?["login"] as? String ?? "unknown account"
            return ("Connected to GitHub as \(login).", dictionary?["html_url"] as? String)
        case .slack:
            let team = dictionary?["team"] as? String ?? "Slack workspace"
            let user = dictionary?["user"] as? String ?? "unknown user"
            return ("Connected to Slack workspace \(team).", "Authenticated as \(user).")
        case .linear:
            let viewer = ((dictionary?["data"] as? [String: Any])?["viewer"] as? [String: Any]) ?? [:]
            let name = viewer["name"] as? String ?? "Linear viewer"
            let email = viewer["email"] as? String
            return ("Connected to Linear as \(name).", email)
        case .posthog:
            let results = (dictionary?["results"] as? [[String: Any]]) ?? []
            let projectName = results.first?["name"] as? String ?? "PostHog project"
            return ("Connected to PostHog.", projectName)
        case .sentry:
            let organizations = (payload as? [[String: Any]]) ?? []
            let first = organizations.first
            let name = first?["name"] as? String ?? first?["slug"] as? String ?? "Sentry organization"
            return ("Connected to Sentry.", name)
        case .gmail:
            let email = dictionary?["emailAddress"] as? String ?? "Gmail profile"
            let messages = dictionary?["messagesTotal"] as? Int
            return ("Connected to Gmail as \(email).", messages.map { "\($0) total messages." })
        }
    }

    private static func httpErrorDetail(data: Data, statusCode: Int) -> String {
        if let string = String(data: data, encoding: .utf8),
           string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return "HTTP \(statusCode): \(string)"
        }
        return "HTTP \(statusCode)"
    }
}
