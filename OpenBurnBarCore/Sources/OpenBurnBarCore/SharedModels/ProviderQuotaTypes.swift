import Foundation

// MARK: - Provider Quota Source Kind

public enum ProviderQuotaSourceKind: String, Codable, Sendable {
    case provider
}

// MARK: - Provider Quota Confidence

public enum ProviderQuotaConfidence: String, Codable, Sendable {
    case high
    case medium
    case low
    case stale
}

// MARK: - Provider Quota Unit

public enum ProviderQuotaUnit: String, Codable, Sendable {
    case tokens
    case requests
    case fastCalls = "fast-calls"
    case credits
    case unknown
}

// MARK: - Provider Quota Window Kind

public enum ProviderQuotaWindowKind: String, Codable, Sendable {
    case daily
    case monthly
    case lifetime
    case custom
}

// MARK: - Provider Quota Bucket

public struct ProviderQuotaBucket: Codable, Hashable, Sendable {
    public let name: String
    public let used: Double
    public let limit: Double
    public let remaining: Double
    public let window: String?
    public let meta: [String: String]?

    public init(
        name: String,
        used: Double,
        limit: Double,
        remaining: Double,
        window: String? = nil,
        meta: [String: String]? = nil
    ) {
        self.name = name
        self.used = used
        self.limit = limit
        self.remaining = remaining
        self.window = window
        self.meta = meta
    }
}

// MARK: - Provider Quota Snapshot

public struct ProviderQuotaSnapshot: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let provider: String
    public let sourceKind: ProviderQuotaSourceKind
    public let sourceId: String
    public let fetchedAt: Date
    public let source: String
    public let confidence: ProviderQuotaConfidence
    public let managementURL: String?
    public let statusMessage: String?
    public let buckets: [ProviderQuotaBucket]
    public let schemaVersion: Int
    public let updatedAt: Date

    public init(
        id: String,
        provider: String,
        sourceKind: ProviderQuotaSourceKind,
        sourceId: String,
        fetchedAt: Date,
        source: String,
        confidence: ProviderQuotaConfidence,
        managementURL: String? = nil,
        statusMessage: String? = nil,
        buckets: [ProviderQuotaBucket],
        schemaVersion: Int,
        updatedAt: Date
    ) {
        self.id = id
        self.provider = provider
        self.sourceKind = sourceKind
        self.sourceId = sourceId
        self.fetchedAt = fetchedAt
        self.source = source
        self.confidence = confidence
        self.managementURL = managementURL
        self.statusMessage = statusMessage
        self.buckets = buckets
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
    }
}
