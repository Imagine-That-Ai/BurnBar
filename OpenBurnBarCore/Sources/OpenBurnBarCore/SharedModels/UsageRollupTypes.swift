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
    public let totalRequests: Int
    public let totalTokens: Int
    public let totalCost: Double?

    public init(
        id: String? = nil,
        provider: String,
        totalRequests: Int,
        totalTokens: Int,
        totalCost: Double? = nil
    ) {
        self.id = id ?? provider
        self.provider = provider
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
    public let modelSummaries: [RollupModelSummary]
    public let deviceSummaries: [RollupDeviceSummary]
    public let dailyPoints: [RollupDailyPoint]
    public let computedAt: Date
    public let schemaVersion: Int

    public init(
        windowKey: RollupWindowKey,
        totals: RollupTotals,
        providerSummaries: [RollupProviderSummary],
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
        self.modelSummaries = modelSummaries
        self.deviceSummaries = deviceSummaries
        self.dailyPoints = dailyPoints
        self.computedAt = computedAt
        self.schemaVersion = schemaVersion
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
