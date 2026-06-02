import Foundation

// MARK: - Mini-Program Host Contracts (Hermes Square §6.6)
//
// The host primitives exposed to a `custom` card's sandboxed mini-program
// (rendered in WKWebView on iOS, WebView on Android). The JS bridge
// allowlists exactly these 8 verbs (plan §2 Pillar 4). Anything else is
// rejected.
//
// JSON-on-wire shape — JS side calls
//     window.burnbarHostInvoke({ action: "dispatch", payload: {...} })
// and the bridge dispatches into `MiniProgramHostPrimitive.handle(...)`.

public enum MiniProgramHostPrimitive: String, Codable, Sendable, Hashable, CaseIterable {
    case dispatch
    case approve
    case fork
    case forward
    case delegate
    case pin
    case subscribe
    case rollback

    public var displayLabel: String {
        rawValue.capitalized
    }
}

// MARK: - JS bridge envelope

public struct MiniProgramHostCall: Codable, Sendable, Hashable {
    public let action: MiniProgramHostPrimitive
    public let correlationID: String
    public let payload: [String: String]
    public let agentURI: String
    public let cardURI: String

    public init(
        action: MiniProgramHostPrimitive,
        correlationID: String,
        payload: [String: String],
        agentURI: String,
        cardURI: String
    ) {
        self.action = action
        self.correlationID = correlationID
        self.payload = payload
        self.agentURI = agentURI
        self.cardURI = cardURI
    }
}

public struct MiniProgramHostResponse: Codable, Sendable, Hashable {
    public let correlationID: String
    public let success: Bool
    public let resultJSON: String?
    public let error: String?

    public init(correlationID: String, success: Bool, resultJSON: String? = nil, error: String? = nil) {
        self.correlationID = correlationID
        self.success = success
        self.resultJSON = resultJSON
        self.error = error
    }
}

// MARK: - Sandbox Policy

public struct MiniProgramSandboxPolicy: Sendable, Hashable {
    public let url: URL
    public let origin: String
    public let isPackageFile: Bool
    public let isLocalDevelopment: Bool

    public init(url: URL, origin: String, isPackageFile: Bool = false, isLocalDevelopment: Bool = false) {
        self.url = url
        self.origin = origin
        self.isPackageFile = isPackageFile
        self.isLocalDevelopment = isLocalDevelopment
    }
}

public struct MiniProgramHostBridgeRateLimiter: Sendable {
    public let maxCallsPerAction: Int
    public let windowSeconds: TimeInterval
    private var acceptedCallsByAction: [MiniProgramHostPrimitive: [TimeInterval]]

    public init(
        maxCallsPerAction: Int = MiniProgramHostCallValidator.defaultRateLimitPerAction,
        windowSeconds: TimeInterval = MiniProgramHostCallValidator.defaultRateLimitWindowSeconds
    ) {
        self.maxCallsPerAction = max(1, maxCallsPerAction)
        self.windowSeconds = max(0.1, windowSeconds)
        self.acceptedCallsByAction = [:]
    }

    public mutating func allow(_ action: MiniProgramHostPrimitive, at timestamp: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        let cutoff = timestamp - windowSeconds
        var calls = acceptedCallsByAction[action, default: []].filter { $0 > cutoff }
        guard calls.count < maxCallsPerAction else {
            acceptedCallsByAction[action] = calls
            return false
        }
        calls.append(timestamp)
        acceptedCallsByAction[action] = calls
        return true
    }
}

// MARK: - Validation

public enum MiniProgramHostCallValidator {
    public enum ValidationError: LocalizedError {
        case unknownAction(String)
        case payloadTooLarge(bytes: Int, max: Int)
        case fieldTooLarge(field: String, bytes: Int, max: Int)
        case tooManyPayloadEntries(count: Int, max: Int)
        case missingAgentURI
        case unauthorisedAgent(String)
        case agentMismatch(expected: String, actual: String)
        case unauthorisedOrigin(String)
        case unauthorisedSandboxURL(String)
        case rateLimited(action: String, limit: Int, windowSeconds: TimeInterval)

        public var errorDescription: String? {
            switch self {
            case .unknownAction(let s):
                return "Mini-program tried to invoke unknown host action '\(s)'."
            case .payloadTooLarge(let bytes, let max):
                return "Mini-program call payload was \(bytes) bytes; max is \(max)."
            case .fieldTooLarge(let field, let bytes, let max):
                return "Mini-program call field '\(field)' was \(bytes) bytes; max is \(max)."
            case .tooManyPayloadEntries(let count, let max):
                return "Mini-program call payload had \(count) entries; max is \(max)."
            case .missingAgentURI:
                return "Mini-program call missing agentURI."
            case .unauthorisedAgent(let uri):
                return "Mini-program call references unauthorised agent '\(uri)'."
            case .agentMismatch(let expected, let actual):
                return "Mini-program call agentURI '\(actual)' does not match rendered agent '\(expected)'."
            case .unauthorisedOrigin(let origin):
                return "Mini-program bridge call came from unauthorised origin '\(origin)'."
            case .unauthorisedSandboxURL(let url):
                return "Mini-program sandbox URL '\(url)' is not approved for this agent."
            case .rateLimited(let action, let limit, let windowSeconds):
                return "Mini-program host action '\(action)' exceeded \(limit) calls per \(Int(windowSeconds)) seconds."
            }
        }
    }

    /// Per-call payload cap. Keep tiny — the host primitive vocabulary is
    /// already narrow (8 verbs), so legitimate calls fit in well under 16 KB.
    public static let maxCallPayloadBytes = 16_384
    public static let maxCorrelationIDBytes = 128
    public static let maxBridgeStringBytes = 2_048
    public static let maxPayloadKeyBytes = 256
    public static let maxPayloadValueBytes = 4_096
    public static let maxPayloadEntryCount = 64
    public static let defaultRateLimitPerAction = 12
    public static let defaultRateLimitWindowSeconds: TimeInterval = 10

    /// Validate before dispatch. Throws on policy violations; caller
    /// echoes an error response over the bridge.
    public static func validate(
        _ call: MiniProgramHostCall,
        installedAgentURIs: Set<String>,
        expectedAgentURI: String? = nil
    ) throws {
        try validateString(call.correlationID, field: "correlationID", maxBytes: maxCorrelationIDBytes)
        try validateString(call.agentURI, field: "agentURI", maxBytes: maxBridgeStringBytes)
        try validateString(call.cardURI, field: "cardURI", maxBytes: maxBridgeStringBytes)
        try validatePayloadStrings(call.payload)
        if call.agentURI.isEmpty {
            throw ValidationError.missingAgentURI
        }
        if let expectedAgentURI, call.agentURI != expectedAgentURI {
            throw ValidationError.agentMismatch(expected: expectedAgentURI, actual: call.agentURI)
        }
        if !installedAgentURIs.contains(call.agentURI) {
            throw ValidationError.unauthorisedAgent(call.agentURI)
        }
        let callData = try? JSONEncoder().encode(call)
        if let callData {
            try validateRawBridgePayload(callData)
        }
    }

    public static func validateRawBridgePayload(_ data: Data) throws {
        if data.count > maxCallPayloadBytes {
            throw ValidationError.payloadTooLarge(bytes: data.count, max: maxCallPayloadBytes)
        }
    }

    public static func validateRawBridgeMessageBody(_ body: Any) throws {
        var estimatedBytes = 0
        try validateRawJSONValue(body, field: "body", estimatedBytes: &estimatedBytes, depth: 0)
    }

    public static func isAllowedSandboxURL(_ url: URL) -> Bool {
        approvedSandboxPolicy(
            sandboxURL: url.absoluteString,
            approvedOrigins: [],
            approvedPackageDirectoryURLs: [],
            allowLocalDevelopment: false
        ) != nil
    }

    public static func isAllowedSandboxURL(
        _ url: URL,
        approvedOrigins: Set<String>,
        approvedPackageDirectoryURLs: [URL] = [],
        allowLocalDevelopment: Bool = false
    ) -> Bool {
        approvedSandboxPolicy(
            sandboxURL: url.absoluteString,
            approvedOrigins: approvedOrigins,
            approvedPackageDirectoryURLs: approvedPackageDirectoryURLs,
            allowLocalDevelopment: allowLocalDevelopment
        ) != nil
    }

    public static func approvedSandboxOrigins(for agent: AgentIdentity) -> Set<String> {
        var origins = Set<String>()
        if case .userInstalled(let manifestURL) = agent.installSource,
           let origin = URL(string: manifestURL).flatMap(originString(for:)) {
            origins.insert(origin)
        }
        switch agent.dispatchTransport {
        case .httpGateway(let endpoint), .mcpServer(let endpoint):
            if let origin = URL(string: endpoint).flatMap(originString(for:)) {
                origins.insert(origin)
            }
        case .nativeRelay, .macRelay:
            break
        }
        return origins
    }

    public static func approvedSandboxPolicy(
        sandboxURL: String,
        approvedOrigins: Set<String>,
        approvedPackageDirectoryURLs: [URL] = [],
        allowLocalDevelopment: Bool = false
    ) -> MiniProgramSandboxPolicy? {
        guard let url = URL(string: sandboxURL) else { return nil }
        guard url.user == nil, url.password == nil else { return nil }
        switch url.scheme?.lowercased() {
        case "https":
            guard let origin = originString(for: url),
                  normalizedApprovedOrigins(approvedOrigins).contains(origin)
            else { return nil }
            return MiniProgramSandboxPolicy(url: url, origin: origin)
        case "http":
            guard allowLocalDevelopment,
                  let host = url.host,
                  isLoopbackHost(host),
                  let origin = originString(for: url)
            else { return nil }
            return MiniProgramSandboxPolicy(url: url, origin: origin, isLocalDevelopment: true)
        case "file":
            guard approvedPackageDirectoryURLs.contains(where: { isFileURL(url, containedIn: $0) }) else {
                return nil
            }
            return MiniProgramSandboxPolicy(url: url, origin: "'self'", isPackageFile: true)
        default:
            return nil
        }
    }

    public static func isAllowedBridgeOrigin(currentURL: URL?, sandboxURL: String) -> Bool {
        false
    }

    public static func isAllowedBridgeOrigin(currentURL: URL?, policy: MiniProgramSandboxPolicy) -> Bool {
        guard let currentURL else { return false }
        if policy.isPackageFile {
            return currentURL.isFileURL && isFileURL(currentURL, containedIn: policy.url.deletingLastPathComponent())
        }
        guard let currentOrigin = originComponents(currentURL),
              let policyOrigin = originComponents(policy.url) else {
            return false
        }
        return currentOrigin.scheme == policyOrigin.scheme
            && currentOrigin.host == policyOrigin.host
            && currentOrigin.port == policyOrigin.port
    }

    public static func isAllowedBridgeOrigin(
        scheme: String,
        host: String?,
        port: Int?,
        policy: MiniProgramSandboxPolicy
    ) -> Bool {
        guard !policy.isPackageFile else { return false }
        guard let host, let policyOrigin = originComponents(policy.url) else { return false }
        let normalizedScheme = scheme.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        let normalizedPort = (port == nil || port == 0) ? defaultPort(for: normalizedScheme) : port
        return normalizedScheme == policyOrigin.scheme
            && host.lowercased() == policyOrigin.host
            && normalizedPort == policyOrigin.port
    }

    /// Build the strict CSP a `WKWebView` / `WebView` should apply when hosting a mini-program.
    /// The sandbox origin must come from an approved policy, never directly from card payload.
    public static func contentSecurityPolicy(policy: MiniProgramSandboxPolicy?) -> String {
        let origin = policy?.origin ?? "'self'"
        return [
            "default-src 'self' \(origin)",
            "script-src 'self' \(origin)",
            "style-src 'self' 'unsafe-inline' \(origin)",
            "img-src 'self' data: \(origin)",
            "connect-src \(origin)",
            "font-src 'self' \(origin)",
            "object-src 'none'",
            "base-uri 'self'",
            "form-action 'none'",
            "worker-src 'none'",
            "frame-ancestors 'none'"
        ].joined(separator: "; ")
    }

    /// Legacy helper retained for callers that have not yet computed a policy.
    /// It deliberately falls back to self-only instead of trusting the supplied URL.
    public static func contentSecurityPolicy(sandboxURL: String) -> String {
        contentSecurityPolicy(policy: nil)
    }

    private static func validatePayloadStrings(_ payload: [String: String]) throws {
        if payload.count > maxPayloadEntryCount {
            throw ValidationError.tooManyPayloadEntries(count: payload.count, max: maxPayloadEntryCount)
        }
        for (key, value) in payload {
            try validateString(key, field: "payload.key", maxBytes: maxPayloadKeyBytes)
            try validateString(value, field: "payload.\(key)", maxBytes: maxPayloadValueBytes)
        }
    }

    private static func validateRawJSONValue(
        _ value: Any,
        field: String,
        estimatedBytes: inout Int,
        depth: Int
    ) throws {
        if estimatedBytes > maxCallPayloadBytes {
            throw ValidationError.payloadTooLarge(bytes: estimatedBytes, max: maxCallPayloadBytes)
        }
        if depth > 4 {
            throw ValidationError.fieldTooLarge(field: field, bytes: depth, max: 4)
        }
        switch value {
        case let string as String:
            try validateString(string, field: field, maxBytes: maxStringBytes(for: field))
            estimatedBytes += string.utf8.count
        case let dict as [String: Any]:
            if field == "payload", dict.count > maxPayloadEntryCount {
                throw ValidationError.tooManyPayloadEntries(count: dict.count, max: maxPayloadEntryCount)
            }
            estimatedBytes += 2
            for (key, nested) in dict {
                try validateString(key, field: "\(field).key", maxBytes: field == "payload" ? maxPayloadKeyBytes : 64)
                estimatedBytes += key.utf8.count
                let nestedField = field == "body" ? key : "\(field).\(key)"
                try validateRawJSONValue(nested, field: nestedField, estimatedBytes: &estimatedBytes, depth: depth + 1)
            }
        case let array as [Any]:
            estimatedBytes += 2
            for (index, nested) in array.enumerated() {
                try validateRawJSONValue(nested, field: "\(field)[\(index)]", estimatedBytes: &estimatedBytes, depth: depth + 1)
            }
        case is NSNumber:
            estimatedBytes += 32
        case is NSNull:
            estimatedBytes += 4
        default:
            estimatedBytes += 256
        }
        if estimatedBytes > maxCallPayloadBytes {
            throw ValidationError.payloadTooLarge(bytes: estimatedBytes, max: maxCallPayloadBytes)
        }
    }

    private static func validateString(_ value: String, field: String, maxBytes: Int) throws {
        let bytes = value.utf8.count
        if bytes > maxBytes {
            throw ValidationError.fieldTooLarge(field: field, bytes: bytes, max: maxBytes)
        }
    }

    private static func maxStringBytes(for field: String) -> Int {
        if field == "correlationID" { return maxCorrelationIDBytes }
        if field.hasPrefix("payload.") { return maxPayloadValueBytes }
        return maxBridgeStringBytes
    }

    private static func normalizedApprovedOrigins(_ origins: Set<String>) -> Set<String> {
        Set(origins.compactMap { raw in
            URL(string: raw).flatMap(originString(for:))
        })
    }

    private static func originString(for url: URL) -> String? {
        guard let components = originComponents(url),
              let host = components.host
        else { return url.isFileURL ? "'self'" : nil }
        if let port = components.port {
            return "\(components.scheme)://\(host):\(port)"
        }
        return "\(components.scheme)://\(host)"
    }

    private static func originComponents(_ url: URL) -> (scheme: String, host: String?, port: Int?)? {
        guard let scheme = url.scheme?.lowercased() else { return nil }
        if scheme == "file" { return (scheme, nil, nil) }
        guard let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        let port = url.port ?? defaultPort(for: scheme)
        return (scheme, host, port)
    }

    private static func defaultPort(for scheme: String) -> Int? {
        switch scheme {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        let normalized = host.lowercased()
        return normalized == "localhost" || normalized == "127.0.0.1" || normalized == "::1" || normalized == "[::1]"
    }

    private static func isFileURL(_ url: URL, containedIn directory: URL) -> Bool {
        guard url.isFileURL, directory.isFileURL else { return false }
        let filePath = url.standardizedFileURL.path
        let directoryPath = directory.standardizedFileURL.path
        let prefix = directoryPath.hasSuffix("/") ? directoryPath : "\(directoryPath)/"
        return filePath == directoryPath || filePath.hasPrefix(prefix)
    }
}
