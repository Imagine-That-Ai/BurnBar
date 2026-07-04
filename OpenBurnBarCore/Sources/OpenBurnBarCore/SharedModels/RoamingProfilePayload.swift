import Foundation

public enum RoamingProfilePayloadError: LocalizedError, Sendable {
    case unsupportedSchemaVersion(Int)
    case secretLikeField(String)
    case invalidEndpointURL(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let version):
            return "Unsupported roaming profile schema version \(version)."
        case .secretLikeField(let field):
            return "Roaming profile contains secret-like material in \(field)."
        case .invalidEndpointURL(let field):
            return "Roaming profile endpoint URL is invalid in \(field)."
        }
    }
}

public struct RoamingProfileProviderAccount: Codable, Hashable, Sendable {
    public let id: String
    public let providerID: ProviderID
    public let label: String
    public let identityHint: String?
    public let status: ProviderAccountStatus
    public let credentialKind: CredentialKind
    public let storageScope: ProviderAccountStorageScope
    public let redactedLabel: String
    public let sourceDeviceID: String?
    public let linkedSwitcherProfileID: String?
    public let isDefault: Bool
    public let sortKey: Double
    public let lastValidatedAt: Date?
    public let lastRefreshAt: Date?
    public let lastErrorCode: String?
    public let schemaVersion: Int
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: String,
        providerID: ProviderID,
        label: String,
        identityHint: String? = nil,
        status: ProviderAccountStatus,
        credentialKind: CredentialKind,
        storageScope: ProviderAccountStorageScope,
        redactedLabel: String,
        sourceDeviceID: String? = nil,
        linkedSwitcherProfileID: String? = nil,
        isDefault: Bool,
        sortKey: Double,
        lastValidatedAt: Date? = nil,
        lastRefreshAt: Date? = nil,
        lastErrorCode: String? = nil,
        schemaVersion: Int = 1,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.providerID = providerID
        self.label = label
        self.identityHint = identityHint
        self.status = status
        self.credentialKind = credentialKind
        self.storageScope = storageScope
        self.redactedLabel = redactedLabel
        self.sourceDeviceID = sourceDeviceID
        self.linkedSwitcherProfileID = linkedSwitcherProfileID
        self.isDefault = isDefault
        self.sortKey = sortKey
        self.lastValidatedAt = lastValidatedAt
        self.lastRefreshAt = lastRefreshAt
        self.lastErrorCode = lastErrorCode
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(_ account: ProviderAccountDoc) {
        self.init(
            id: account.id,
            providerID: account.providerID,
            label: account.label,
            identityHint: account.identityHint,
            status: account.status,
            credentialKind: account.credentialKind,
            storageScope: account.storageScope,
            redactedLabel: account.redactedLabel,
            sourceDeviceID: account.sourceDeviceID,
            linkedSwitcherProfileID: account.linkedSwitcherProfileID,
            isDefault: account.isDefault,
            sortKey: account.sortKey,
            lastValidatedAt: account.lastValidatedAt,
            lastRefreshAt: account.lastRefreshAt,
            lastErrorCode: account.lastErrorCode,
            schemaVersion: account.schemaVersion,
            createdAt: account.createdAt,
            updatedAt: account.updatedAt
        )
    }

    public var providerAccountDoc: ProviderAccountDoc {
        ProviderAccountDoc(
            id: id,
            providerID: providerID,
            label: label,
            identityHint: identityHint,
            status: status,
            credentialKind: credentialKind,
            storageScope: storageScope,
            redactedLabel: redactedLabel,
            sourceDeviceID: sourceDeviceID,
            linkedSwitcherProfileID: linkedSwitcherProfileID,
            isDefault: isDefault,
            sortKey: sortKey,
            lastValidatedAt: lastValidatedAt,
            lastRefreshAt: lastRefreshAt,
            lastErrorCode: lastErrorCode,
            schemaVersion: schemaVersion,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

public struct RoamingOllamaEndpoint: Codable, Hashable, Sendable {
    public let id: String
    public let baseURL: String
    public let label: String
    public let priority: Int

    public init(id: String, baseURL: String, label: String, priority: Int) {
        self.id = id
        self.baseURL = baseURL
        self.label = label
        self.priority = priority
    }
}

public enum RoamingModelEquivalenceAction: String, Codable, CaseIterable, Hashable, Sendable {
    case pin
    case exclude
}

public struct RoamingModelEquivalenceOverride: Codable, Hashable, Sendable {
    public let canonicalModelID: String
    public let action: RoamingModelEquivalenceAction
    public let classID: String?

    public init(canonicalModelID: String, action: RoamingModelEquivalenceAction, classID: String? = nil) {
        self.canonicalModelID = canonicalModelID
        self.action = action
        self.classID = classID
    }
}

public struct RoamingQuotaDisplayPreferences: Codable, Hashable, Sendable {
    public let providerOrder: [String]
    public let visibleProviders: [String]
    public let hiddenBuckets: [String]
    public let bucketOrders: [String: [String]]
    public let percentageDisplayMode: String
    public let cumulativeAcrossAccounts: Bool

    public init(
        providerOrder: [String] = [],
        visibleProviders: [String] = [],
        hiddenBuckets: [String] = [],
        bucketOrders: [String: [String]] = [:],
        percentageDisplayMode: String = "remainingPercent",
        cumulativeAcrossAccounts: Bool = false
    ) {
        self.providerOrder = providerOrder
        self.visibleProviders = visibleProviders
        self.hiddenBuckets = hiddenBuckets
        self.bucketOrders = bucketOrders
        self.percentageDisplayMode = percentageDisplayMode
        self.cumulativeAcrossAccounts = cumulativeAcrossAccounts
    }
}

public struct RoamingProfilePayload: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let routerMode: ProviderRouterMode
    public let crossProviderFailoverEnabled: Bool
    public let accountOrder: [String]
    public let providerAccounts: [RoamingProfileProviderAccount]
    public let ollamaEndpoints: [RoamingOllamaEndpoint]
    public let equivalenceOverrides: [RoamingModelEquivalenceOverride]
    public let quotaDisplayPreferences: RoamingQuotaDisplayPreferences
    public let updatedAt: Date
    public let sourceDeviceID: String

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        routerMode: ProviderRouterMode,
        crossProviderFailoverEnabled: Bool,
        accountOrder: [String],
        providerAccounts: [RoamingProfileProviderAccount] = [],
        ollamaEndpoints: [RoamingOllamaEndpoint] = [],
        equivalenceOverrides: [RoamingModelEquivalenceOverride] = [],
        quotaDisplayPreferences: RoamingQuotaDisplayPreferences = RoamingQuotaDisplayPreferences(),
        updatedAt: Date,
        sourceDeviceID: String
    ) {
        self.schemaVersion = schemaVersion
        self.routerMode = routerMode
        self.crossProviderFailoverEnabled = crossProviderFailoverEnabled
        self.accountOrder = accountOrder
        self.providerAccounts = providerAccounts
        self.ollamaEndpoints = ollamaEndpoints
        self.equivalenceOverrides = equivalenceOverrides
        self.quotaDisplayPreferences = quotaDisplayPreferences
        self.updatedAt = updatedAt
        self.sourceDeviceID = sourceDeviceID
    }

    public func validatedForCloudVaultSeal() throws -> Self {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw RoamingProfilePayloadError.unsupportedSchemaVersion(schemaVersion)
        }
        try SecretScanner.scanEncodable(self, path: "RoamingProfilePayload")
        try validateEndpointURLs()
        return self
    }

    private func validateEndpointURLs() throws {
        for endpoint in ollamaEndpoints {
            guard let components = URLComponents(string: endpoint.baseURL),
                  let scheme = components.scheme?.lowercased(),
                  (scheme == "http" || scheme == "https"),
                  components.host?.isEmpty == false,
                  (components.user?.isEmpty ?? true),
                  (components.password?.isEmpty ?? true) else {
                throw RoamingProfilePayloadError.invalidEndpointURL("ollamaEndpoints.\(endpoint.id).baseURL")
            }
        }
    }
}

enum CloudVaultJSON {
    static let roamingProfileEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let roamingProfileDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

private enum SecretScanner {
    private static let secretKeyNames = [
        "access_token", "api_key", "apikey", "authorization", "bearer_token",
        "cookie", "oauth_bundle", "password", "refresh_token", "secret",
        "session_cookie", "session_token"
    ]

    private static let secretValuePatterns: [String] = [
        #"(?i)\bbearer\s+[a-z0-9._~+/\-=]{16,}"#,
        #"(?i)\bsk-[a-z0-9_-]{16,}"#,
        #"(?i)\b(api[_-]?key|oauth|refresh[_-]?token|session[_-]?token)\b\s*[:=]\s*['"]?[a-z0-9._~+/\-=]{12,}"#
    ]

    static func scanEncodable<T: Encodable>(_ value: T, path: String) throws {
        let data = try CloudVaultJSON.roamingProfileEncoder.encode(value)
        let object = try JSONSerialization.jsonObject(with: data)
        try scan(object, path: path)
    }

    private static func scan(_ value: Any, path: String) throws {
        if let dictionary = value as? [String: Any] {
            for (key, nested) in dictionary {
                let normalized = key.lowercased().replacingOccurrences(of: "-", with: "_")
                if secretKeyNames.contains(normalized) {
                    throw RoamingProfilePayloadError.secretLikeField("\(path).\(key)")
                }
                try scan(nested, path: "\(path).\(key)")
            }
            return
        }
        if let array = value as? [Any] {
            for (index, nested) in array.enumerated() {
                try scan(nested, path: "\(path)[\(index)]")
            }
            return
        }
        if let string = value as? String {
            for pattern in secretValuePatterns where string.range(of: pattern, options: .regularExpression) != nil {
                throw RoamingProfilePayloadError.secretLikeField(path)
            }
        }
    }
}
