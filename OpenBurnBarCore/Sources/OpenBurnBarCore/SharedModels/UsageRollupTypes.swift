import Foundation

// MARK: - Rollup Window Key

public enum RollupWindowKey: String, Codable, CaseIterable, Sendable {
    case today
    case sevenDays = "7d"
    case thirtyDays = "30d"
    case ninetyDays = "90d"
    case allTime = "all_time"

    public var displayLabel: String {
        switch self {
        case .today: return "Today"
        case .sevenDays: return "7 Days"
        case .thirtyDays: return "30 Days"
        case .ninetyDays: return "90 Days"
        case .allTime: return "All Time"
        }
    }
}

// MARK: - Provider Summary

public struct RollupProviderSummary: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let provider: String
    public let providerID: ProviderID
    public let totalRequests: Int
    public let totalTokens: Int
    public let totalCost: Double?

    public init(
        id: String? = nil,
        provider: String,
        providerID: ProviderID? = nil,
        totalRequests: Int,
        totalTokens: Int,
        totalCost: Double? = nil
    ) {
        self.id = id ?? provider
        self.provider = provider
        self.providerID = providerID ?? ProviderID(rawValue: provider)
        self.totalRequests = totalRequests
        self.totalTokens = totalTokens
        self.totalCost = totalCost
    }

    private enum CodingKeys: String, CodingKey {
        case id, provider, providerID, totalRequests, totalTokens, totalCost
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decode(String.self, forKey: .provider)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? provider
        providerID = try c.decodeIfPresent(ProviderID.self, forKey: .providerID) ?? ProviderID(rawValue: provider)
        totalRequests = try c.decode(Int.self, forKey: .totalRequests)
        totalTokens = try c.decode(Int.self, forKey: .totalTokens)
        totalCost = try c.decodeIfPresent(Double.self, forKey: .totalCost)
    }
}

// MARK: - Provider Account Summary

public struct RollupProviderAccountSummary: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let providerID: ProviderID
    public let accountID: String?
    public let accountLabel: String
    public let storageScope: ProviderAccountStorageScope?
    public let totalRequests: Int
    public let totalTokens: Int
    public let totalCost: Double?

    public init(
        id: String? = nil,
        providerID: ProviderID,
        accountID: String?,
        accountLabel: String,
        storageScope: ProviderAccountStorageScope? = nil,
        totalRequests: Int,
        totalTokens: Int,
        totalCost: Double? = nil
    ) {
        let summaryID = accountID ?? "\(providerID.rawValue):unattributed"
        self.id = id ?? summaryID
        self.providerID = providerID
        self.accountID = accountID
        self.accountLabel = accountLabel
        self.storageScope = storageScope
        self.totalRequests = totalRequests
        self.totalTokens = totalTokens
        self.totalCost = totalCost
    }
}

// MARK: - Model Summary

public struct RollupModelSummary: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let model: String
    public let provider: String
    public let requests: Int
    public let tokens: Int
    public let cost: Double?

    public init(
        id: String? = nil,
        model: String,
        provider: String,
        requests: Int,
        tokens: Int,
        cost: Double? = nil
    ) {
        self.id = id ?? "\(provider):\(model)"
        self.model = model
        self.provider = provider
        self.requests = requests
        self.tokens = tokens
        self.cost = cost
    }
}

// MARK: - Device Summary

public struct RollupDeviceSummary: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let deviceId: String
    public let requests: Int
    public let tokens: Int

    public init(
        deviceId: String,
        requests: Int,
        tokens: Int
    ) {
        self.id = deviceId
        self.deviceId = deviceId
        self.requests = requests
        self.tokens = tokens
    }
}

// MARK: - Daily Point

public struct RollupDailyPoint: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let date: Date
    public let value: Double

    public init(date: Date, value: Double) {
        self.id = ISO8601DateFormatter().string(from: date)
        self.date = date
        self.value = value
    }
}

// MARK: - Usage Rollup Document

public struct UsageRollupDoc: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let windowKey: RollupWindowKey
    public let totals: RollupTotals
    public let providerSummaries: [RollupProviderSummary]
    public let accountSummaries: [RollupProviderAccountSummary]
    public let modelSummaries: [RollupModelSummary]
    public let deviceSummaries: [RollupDeviceSummary]
    public let dailyPoints: [RollupDailyPoint]
    public let computedAt: Date
    public let schemaVersion: Int

    public init(
        windowKey: RollupWindowKey,
        totals: RollupTotals,
        providerSummaries: [RollupProviderSummary],
        accountSummaries: [RollupProviderAccountSummary] = [],
        modelSummaries: [RollupModelSummary],
        deviceSummaries: [RollupDeviceSummary],
        dailyPoints: [RollupDailyPoint],
        computedAt: Date,
        schemaVersion: Int
    ) {
        self.id = windowKey.rawValue
        self.windowKey = windowKey
        self.totals = totals
        self.providerSummaries = providerSummaries
        self.accountSummaries = accountSummaries
        self.modelSummaries = modelSummaries
        self.deviceSummaries = deviceSummaries
        self.dailyPoints = dailyPoints
        self.computedAt = computedAt
        self.schemaVersion = schemaVersion
    }

    private enum CodingKeys: String, CodingKey {
        case windowKey, totals, providerSummaries, accountSummaries
        case modelSummaries, deviceSummaries, dailyPoints, computedAt, schemaVersion
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        windowKey = try c.decode(RollupWindowKey.self, forKey: .windowKey)
        id = windowKey.rawValue
        totals = try c.decode(RollupTotals.self, forKey: .totals)
        providerSummaries = try c.decode([RollupProviderSummary].self, forKey: .providerSummaries)
        accountSummaries = try c.decodeIfPresent([RollupProviderAccountSummary].self, forKey: .accountSummaries) ?? []
        modelSummaries = try c.decode([RollupModelSummary].self, forKey: .modelSummaries)
        deviceSummaries = try c.decode([RollupDeviceSummary].self, forKey: .deviceSummaries)
        dailyPoints = try c.decode([RollupDailyPoint].self, forKey: .dailyPoints)
        computedAt = try c.decode(Date.self, forKey: .computedAt)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
    }
}

// MARK: - Rollup Totals

public struct RollupTotals: Codable, Hashable, Sendable {
    public let requests: Int
    public let tokens: Int
    public let costUsd: Double

    public init(requests: Int, tokens: Int, costUsd: Double) {
        self.requests = requests
        self.tokens = tokens
        self.costUsd = costUsd
    }
}
