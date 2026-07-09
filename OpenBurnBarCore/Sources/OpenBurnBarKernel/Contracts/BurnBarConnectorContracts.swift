import Foundation

public enum BurnBarConnectorKind: String, Codable, CaseIterable, Hashable, Sendable {
    case github
    case slack
    case linear
    case posthog
    case sentry
    case gmail
}

public enum BurnBarConnectorAuthKind: String, Codable, CaseIterable, Hashable, Sendable {
    case bearerToken = "bearer_token"
    case apiKey = "api_key"
    case oauthAccessToken = "oauth_access_token"
}

public enum BurnBarConnectorHealthStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case disabled
    case missingSecret = "missing_secret"
    case configured
    case healthy
    case degraded
}

public enum BurnBarConnectorActionKind: String, Codable, CaseIterable, Hashable, Sendable {
    case testConnection = "test_connection"
    case sampleRequest = "sample_request"
}

public struct BurnBarConnectorConfigMutation: Codable, Hashable, Sendable {
    public let kind: BurnBarConnectorKind
    public let isEnabled: Bool
    public let baseURL: String
    public let authKind: BurnBarConnectorAuthKind
    public let metadata: [String: BurnBarJSONValue]

    public init(
        kind: BurnBarConnectorKind,
        isEnabled: Bool,
        baseURL: String,
        authKind: BurnBarConnectorAuthKind,
        metadata: [String: BurnBarJSONValue] = [:]
    ) {
        self.kind = kind
        self.isEnabled = isEnabled
        self.baseURL = baseURL
        self.authKind = authKind
        self.metadata = metadata
    }
}

public struct BurnBarConnectorConfigSnapshot: Codable, Hashable, Identifiable, Sendable {
    public let kind: BurnBarConnectorKind
    public let displayName: String
    public let isEnabled: Bool
    public let baseURL: String
    public let authKind: BurnBarConnectorAuthKind
    public let secretConfigured: Bool
    public let secretHint: String?
    public let status: BurnBarConnectorHealthStatus
    public let lastCheckedAt: Date?
    public let statusDetail: String?
    public let supportedActions: [BurnBarConnectorActionKind]
    public let metadata: [String: BurnBarJSONValue]

    public var id: BurnBarConnectorKind { kind }

    public init(
        kind: BurnBarConnectorKind,
        displayName: String,
        isEnabled: Bool,
        baseURL: String,
        authKind: BurnBarConnectorAuthKind,
        secretConfigured: Bool,
        secretHint: String? = nil,
        status: BurnBarConnectorHealthStatus,
        lastCheckedAt: Date? = nil,
        statusDetail: String? = nil,
        supportedActions: [BurnBarConnectorActionKind] = BurnBarConnectorActionKind.allCases,
        metadata: [String: BurnBarJSONValue] = [:]
    ) {
        self.kind = kind
        self.displayName = displayName
        self.isEnabled = isEnabled
        self.baseURL = baseURL
        self.authKind = authKind
        self.secretConfigured = secretConfigured
        self.secretHint = secretHint
        self.status = status
        self.lastCheckedAt = lastCheckedAt
        self.statusDetail = statusDetail
        self.supportedActions = supportedActions
        self.metadata = metadata
    }
}

public struct BurnBarConnectorPlaneSnapshot: Codable, Hashable, Sendable {
    public let updatedAt: Date
    public let connectors: [BurnBarConnectorConfigSnapshot]

    public init(updatedAt: Date, connectors: [BurnBarConnectorConfigSnapshot]) {
        self.updatedAt = updatedAt
        self.connectors = connectors
    }
}

public struct BurnBarConnectorPlaneResponse: Codable, Hashable, Sendable {
    public let snapshot: BurnBarConnectorPlaneSnapshot

    public init(snapshot: BurnBarConnectorPlaneSnapshot) {
        self.snapshot = snapshot
    }
}

public struct BurnBarConnectorConfigUpdateRequest: Codable, Hashable, Sendable {
    public let config: BurnBarConnectorConfigMutation
    public let secret: String?
    public let replaceSecret: Bool

    public init(
        config: BurnBarConnectorConfigMutation,
        secret: String? = nil,
        replaceSecret: Bool = false
    ) {
        self.config = config
        self.secret = secret
        self.replaceSecret = replaceSecret
    }
}

public struct BurnBarConnectorActionRequest: Codable, Hashable, Sendable {
    public let kind: BurnBarConnectorKind
    public let action: BurnBarConnectorActionKind

    public init(kind: BurnBarConnectorKind, action: BurnBarConnectorActionKind) {
        self.kind = kind
        self.action = action
    }
}

public struct BurnBarConnectorActionResponse: Codable, Hashable, Sendable {
    public let kind: BurnBarConnectorKind
    public let action: BurnBarConnectorActionKind
    public let ok: Bool
    public let summary: String
    public let detail: String?
    public let payload: BurnBarJSONValue?
    public let recordedAt: Date

    public init(
        kind: BurnBarConnectorKind,
        action: BurnBarConnectorActionKind,
        ok: Bool,
        summary: String,
        detail: String? = nil,
        payload: BurnBarJSONValue? = nil,
        recordedAt: Date
    ) {
        self.kind = kind
        self.action = action
        self.ok = ok
        self.summary = summary
        self.detail = detail
        self.payload = payload
        self.recordedAt = recordedAt
    }
}

// MARK: - Browser Tooling

public enum BurnBarBrowserEngineKind: String, Codable, CaseIterable, Hashable, Sendable {
    case systemBrowser = "system_browser"
    case urlSession = "url_session"
    case playwright
    case lightpanda
}

public enum BurnBarBrowserToolStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case disabled
    case ready
    case unavailable
    case degraded
}

public enum BurnBarBrowserActionKind: String, Codable, CaseIterable, Hashable, Sendable {
    case openExternal = "open_external"
    case fetchDocument = "fetch_document"
    case extractLinks = "extract_links"
    // Computer Use — Path B. Implemented over Playwright JSON-RPC in
    // OpenBurnBarPlaywrightDriver. Older daemons that don't recognize
    // these cases reply with a BurnBarToolExecutionError(.unknown).
    case click
    case fill
    case goto
    case key
    case select
    case screenshot
    case extract
}

/// Optional argument carrier for a Computer Use browser action. Reused
/// by the daemon dispatcher and the Mac side BrowserActionDispatcher so
/// argument decoding only lives in one place.
public struct BurnBarBrowserActionArguments: Codable, Hashable, Sendable {
    public let selector: String?
    public let text: String?
    public let url: String?
    public let key: String?
    public let value: String?
    public let positionX: Int?
    public let positionY: Int?
    public let timeoutMillis: Int?

    public init(
        selector: String? = nil,
        text: String? = nil,
        url: String? = nil,
        key: String? = nil,
        value: String? = nil,
        positionX: Int? = nil,
        positionY: Int? = nil,
        timeoutMillis: Int? = nil
    ) {
        self.selector = selector
        self.text = text
        self.url = url
        self.key = key
        self.value = value
        self.positionX = positionX
        self.positionY = positionY
        self.timeoutMillis = timeoutMillis
    }
}

public struct BurnBarBrowserEnginePreference: Codable, Hashable, Sendable {
    public let kind: BurnBarBrowserEngineKind
    public let isEnabled: Bool

    public init(kind: BurnBarBrowserEngineKind, isEnabled: Bool) {
        self.kind = kind
        self.isEnabled = isEnabled
    }
}

public struct BurnBarBrowserEngineSnapshot: Codable, Hashable, Identifiable, Sendable {
    public let kind: BurnBarBrowserEngineKind
    public let displayName: String
    public let isEnabled: Bool
    public let status: BurnBarBrowserToolStatus
    public let executablePath: String?
    public let detail: String?
    public let supportsFetch: Bool
    public let supportsExternalNavigation: Bool

    public var id: BurnBarBrowserEngineKind { kind }

    public init(
        kind: BurnBarBrowserEngineKind,
        displayName: String,
        isEnabled: Bool,
        status: BurnBarBrowserToolStatus,
        executablePath: String? = nil,
        detail: String? = nil,
        supportsFetch: Bool,
        supportsExternalNavigation: Bool
    ) {
        self.kind = kind
        self.displayName = displayName
        self.isEnabled = isEnabled
        self.status = status
        self.executablePath = executablePath
        self.detail = detail
        self.supportsFetch = supportsFetch
        self.supportsExternalNavigation = supportsExternalNavigation
    }
}

public struct BurnBarBrowserToolingSnapshot: Codable, Hashable, Sendable {
    public let updatedAt: Date
    public let preferredEngine: BurnBarBrowserEngineKind
    public let allowExternalNavigation: Bool
    public let engines: [BurnBarBrowserEngineSnapshot]

    public init(
        updatedAt: Date,
        preferredEngine: BurnBarBrowserEngineKind,
        allowExternalNavigation: Bool,
        engines: [BurnBarBrowserEngineSnapshot]
    ) {
        self.updatedAt = updatedAt
        self.preferredEngine = preferredEngine
        self.allowExternalNavigation = allowExternalNavigation
        self.engines = engines
    }
}

public struct BurnBarBrowserToolingResponse: Codable, Hashable, Sendable {
    public let snapshot: BurnBarBrowserToolingSnapshot

    public init(snapshot: BurnBarBrowserToolingSnapshot) {
        self.snapshot = snapshot
    }
}

public struct BurnBarBrowserToolingUpdateRequest: Codable, Hashable, Sendable {
    public let preferredEngine: BurnBarBrowserEngineKind
    public let allowExternalNavigation: Bool
    public let enginePreferences: [BurnBarBrowserEnginePreference]

    public init(
        preferredEngine: BurnBarBrowserEngineKind,
        allowExternalNavigation: Bool,
        enginePreferences: [BurnBarBrowserEnginePreference]
    ) {
        self.preferredEngine = preferredEngine
        self.allowExternalNavigation = allowExternalNavigation
        self.enginePreferences = enginePreferences
    }
}

public struct BurnBarBrowserActionRequest: Codable, Hashable, Sendable {
    public let action: BurnBarBrowserActionKind
    public let url: String
    public let preferredEngine: BurnBarBrowserEngineKind?
    public let maxLinks: Int
    public let arguments: BurnBarBrowserActionArguments?

    public init(
        action: BurnBarBrowserActionKind,
        url: String,
        preferredEngine: BurnBarBrowserEngineKind? = nil,
        maxLinks: Int = 10,
        arguments: BurnBarBrowserActionArguments? = nil
    ) {
        self.action = action
        self.url = url
        self.preferredEngine = preferredEngine
        self.maxLinks = maxLinks
        self.arguments = arguments
    }
}

public struct BurnBarBrowserActionResponse: Codable, Hashable, Sendable {
    public let action: BurnBarBrowserActionKind
    public let engine: BurnBarBrowserEngineKind
    public let ok: Bool
    public let summary: String
    public let detail: String?
    public let title: String?
    public let document: String?
    public let links: [String]
    public let recordedAt: Date

    public init(
        action: BurnBarBrowserActionKind,
        engine: BurnBarBrowserEngineKind,
        ok: Bool,
        summary: String,
        detail: String? = nil,
        title: String? = nil,
        document: String? = nil,
        links: [String] = [],
        recordedAt: Date
    ) {
        self.action = action
        self.engine = engine
        self.ok = ok
        self.summary = summary
        self.detail = detail
        self.title = title
        self.document = document
        self.links = links
        self.recordedAt = recordedAt
    }
}
