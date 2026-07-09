// Hand-maintained — not emitted by tools/schema-sync (Record<> + @encodedName
// don't round-trip through check-tsp-canon). Canonical doc:
// tools/schema-sync/typespec/domains/community.tsp (tspOnlyModels).

import Foundation

public struct FirestoreCommunityUsageTotal: Codable, Sendable, Equatable {
    public var totalTokens: Int64
    public var costUSD: Double

    public init(totalTokens: Int64 = 0, costUSD: Double = 0) {
        self.totalTokens = totalTokens
        self.costUSD = costUSD
    }
}

/// Uses CodingKeys to map the non-identifier Firestore keys (7d, 30d, 90d, all_time).
public struct FirestoreCommunityWindowTotals: Codable, Sendable, Equatable {
    public var today: FirestoreCommunityUsageTotal
    public var sevenDay: FirestoreCommunityUsageTotal
    public var thirtyDay: FirestoreCommunityUsageTotal
    public var ninetyDay: FirestoreCommunityUsageTotal
    public var allTime: FirestoreCommunityUsageTotal

    enum CodingKeys: String, CodingKey {
        case today
        case sevenDay = "7d"
        case thirtyDay = "30d"
        case ninetyDay = "90d"
        case allTime = "all_time"
    }

    public init(
        today: FirestoreCommunityUsageTotal = .init(),
        sevenDay: FirestoreCommunityUsageTotal = .init(),
        thirtyDay: FirestoreCommunityUsageTotal = .init(),
        ninetyDay: FirestoreCommunityUsageTotal = .init(),
        allTime: FirestoreCommunityUsageTotal = .init()
    ) {
        self.today = today
        self.sevenDay = sevenDay
        self.thirtyDay = thirtyDay
        self.ninetyDay = ninetyDay
        self.allTime = allTime
    }
}

/// Firestore: users/{uid}/community/share_snapshot
public struct FirestoreCommunityShareSnapshotDoc: Codable, Sendable, Equatable {
    public var windows: FirestoreCommunityWindowTotals
    public var modelMix: [String: Double]
    public var purposeMix: [String: Double]
    public var sessionCount: Int?
    public var countryCode: String?
    public var regionKey: String?
    public var cityKey: String?
    public var revoked: Bool?
    public var schemaVersion: Int
    public var updatedAt: String

    public init(
        windows: FirestoreCommunityWindowTotals = .init(),
        modelMix: [String: Double] = [:],
        purposeMix: [String: Double] = [:],
        sessionCount: Int? = nil,
        countryCode: String? = nil,
        regionKey: String? = nil,
        cityKey: String? = nil,
        revoked: Bool? = nil,
        schemaVersion: Int = 1,
        updatedAt: String = ""
    ) {
        self.windows = windows
        self.modelMix = modelMix
        self.purposeMix = purposeMix
        self.sessionCount = sessionCount
        self.countryCode = countryCode
        self.regionKey = regionKey
        self.cityKey = cityKey
        self.revoked = revoked
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
    }
}
