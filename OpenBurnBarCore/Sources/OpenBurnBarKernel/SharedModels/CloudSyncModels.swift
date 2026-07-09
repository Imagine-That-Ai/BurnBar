import Foundation

// MARK: - Cloud Profile

/// User-scoped profile published from the primary Mac to Firestore so the
/// mobile companion can render an account header without re-querying providers.
/// Lives at `users/{uid}/cloud_profile/default`.
public struct CloudProfile: Codable, Sendable, Equatable {
    public let uid: String
    public let displayName: String?
    public let avatarURL: URL?
    public let preferences: [String: String]
    public let schemaVersion: Int
    public let updatedAt: Date
    public let sourceDeviceId: String

    public init(
        uid: String,
        displayName: String? = nil,
        avatarURL: URL? = nil,
        preferences: [String: String] = [:],
        schemaVersion: Int = 1,
        updatedAt: Date = Date(),
        sourceDeviceId: String
    ) {
        self.uid = uid
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.preferences = preferences
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.sourceDeviceId = sourceDeviceId
    }
}

// MARK: - Cloud Device

public enum CloudDeviceTrustState: String, Codable, Sendable {
    case pending
    case trusted
    case revoked
    case current
}

/// Public-facing device record used by the mobile Devices surface and the
/// Mac Devices & Sync Settings tab. Contains no secrets or fingerprints
/// beyond what is already in Firestore.
public struct CloudDevice: Codable, Sendable, Equatable, Identifiable {
    public var id: String { deviceId }
    public let deviceId: String
    public let deviceName: String
    public let platform: String
    public let trustState: CloudDeviceTrustState
    public let appVersion: String?
    public let lastActiveAt: Date?
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        deviceId: String,
        deviceName: String,
        platform: String,
        trustState: CloudDeviceTrustState = .pending,
        appVersion: String? = nil,
        lastActiveAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.platform = platform
        self.trustState = trustState
        self.appVersion = appVersion
        self.lastActiveAt = lastActiveAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Sync Watermark

/// Per-collection cloud sync watermark used by listeners to resume after
/// reconnect without re-reading the entire collection.
public enum SyncWatermarkCollection: String, Codable, Sendable {
    case usage
    case conversations
    case quotaSnapshots = "quota_snapshots"
    case providerConnections = "provider_connections"
    case devices
    case escrowEnvelopes = "escrow_envelopes"
}

public struct SyncWatermark: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(accountUid)_\(collectionKind.rawValue)" }
    public let accountUid: String
    public let collectionKind: SyncWatermarkCollection
    public var lastSyncedAt: Date?
    public var lastDocumentId: String?
    public var schemaVersion: Int

    public init(
        accountUid: String,
        collectionKind: SyncWatermarkCollection,
        lastSyncedAt: Date? = nil,
        lastDocumentId: String? = nil,
        schemaVersion: Int = 1
    ) {
        self.accountUid = accountUid
        self.collectionKind = collectionKind
        self.lastSyncedAt = lastSyncedAt
        self.lastDocumentId = lastDocumentId
        self.schemaVersion = schemaVersion
    }
}

// MARK: - Sync Status

/// Per-device sync status published to `users/{uid}/sync_status/{deviceId}`.
/// Mobile listens to the primary Mac's status to render the "last published
/// at" banner and surfaces classified errors in Sync Diagnostics.
public struct SyncStatus: Codable, Sendable, Equatable, Identifiable {
    public var id: String { deviceId }
    public let deviceId: String
    public let isOnline: Bool
    public let lastSyncAt: Date?
    public let lastError: String?
    public let collectionsInSync: [String]
    public let updatedAt: Date

    public init(
        deviceId: String,
        isOnline: Bool,
        lastSyncAt: Date? = nil,
        lastError: String? = nil,
        collectionsInSync: [String] = [],
        updatedAt: Date = Date()
    ) {
        self.deviceId = deviceId
        self.isOnline = isOnline
        self.lastSyncAt = lastSyncAt
        self.lastError = lastError
        self.collectionsInSync = collectionsInSync
        self.updatedAt = updatedAt
    }
}

// MARK: - Recent Usage Summary

/// Lightweight rolling-30-day digest published from Mac to Firestore for the
/// mobile dashboard's "no rollups yet" fallback path.
public struct RecentUsageSummary: Codable, Sendable, Equatable {
    public let totalCost30d: Double
    public let totalTokens30d: Int
    public let totalRequests30d: Int
    public let topProviders: [ProviderCostSummary]
    public let topModels: [ModelCostSummary]
    public let computedAt: Date
    public let sourceDeviceId: String

    public init(
        totalCost30d: Double,
        totalTokens30d: Int,
        totalRequests30d: Int,
        topProviders: [ProviderCostSummary],
        topModels: [ModelCostSummary],
        computedAt: Date = Date(),
        sourceDeviceId: String = ""
    ) {
        self.totalCost30d = totalCost30d
        self.totalTokens30d = totalTokens30d
        self.totalRequests30d = totalRequests30d
        self.topProviders = topProviders
        self.topModels = topModels
        self.computedAt = computedAt
        self.sourceDeviceId = sourceDeviceId
    }
}

public struct ProviderCostSummary: Codable, Sendable, Equatable, Identifiable {
    public var id: String { provider }
    public let provider: String
    public let cost: Double
    public let tokens: Int
    public let requests: Int

    public init(provider: String, cost: Double, tokens: Int, requests: Int) {
        self.provider = provider
        self.cost = cost
        self.tokens = tokens
        self.requests = requests
    }
}

public struct ModelCostSummary: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(provider):\(model)" }
    public let provider: String
    public let model: String
    public let cost: Double
    public let tokens: Int

    public init(provider: String, model: String, cost: Double, tokens: Int) {
        self.provider = provider
        self.model = model
        self.cost = cost
        self.tokens = tokens
    }
}
