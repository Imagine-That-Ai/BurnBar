import Foundation

// MARK: - Usage Provenance Method

/// Describes how token usage values were obtained for a given row.
public enum UsageProvenanceMethod: String, Codable, Hashable, CaseIterable, Sendable, Comparable {
    case providerLog = "provider_log"
    case connectorBridge = "connector_bridge"
    case daemonBridge = "daemon_bridge"
    case inAppChat = "in_app_chat"
    case billingAPI = "billing_api"
    case heuristicEstimate = "heuristic_estimate"
    case cloudSync = "cloud_sync"
    case unknown = "unknown"

    public var precedence: Int {
        switch self {
        case .providerLog: return 6
        case .billingAPI: return 5
        case .connectorBridge: return 4
        case .daemonBridge: return 4
        case .inAppChat: return 3
        case .cloudSync: return 2
        case .heuristicEstimate: return 1
        case .unknown: return 0
        }
    }

    public static func < (lhs: UsageProvenanceMethod, rhs: UsageProvenanceMethod) -> Bool {
        lhs.precedence < rhs.precedence
    }
}

// MARK: - Usage Provenance Confidence

public enum UsageProvenanceConfidence: String, Codable, Hashable, CaseIterable, Comparable, Sendable {
    case exact = "exact"
    case derivedExact = "derived_exact"
    case highConfidenceEstimate = "high_confidence_estimate"
    case lowConfidenceEstimate = "low_confidence_estimate"
    case unknown = "unknown"

    public var precedence: Int {
        switch self {
        case .exact: return 4
        case .derivedExact: return 3
        case .highConfidenceEstimate: return 2
        case .lowConfidenceEstimate: return 1
        case .unknown: return 0
        }
    }

    public static func < (lhs: UsageProvenanceConfidence, rhs: UsageProvenanceConfidence) -> Bool {
        lhs.precedence < rhs.precedence
    }
}

// MARK: - Usage Source

public enum UsageSource: String, Codable, Hashable, CaseIterable, Sendable {
    case providerLog = "provider_log"
    case inAppChat = "in_app_chat"
    case cursorBridge = "cursor_bridge"
    case billingAPI = "billing_api"
    case daemon = "daemon"
    case unknown = "unknown"
}

// MARK: - Token Usage Record

public struct TokenUsage: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let provider: AgentProvider
    public let sessionId: String
    public let projectName: String
    public let model: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheCreationTokens: Int
    public let cacheReadTokens: Int
    public let reasoningTokens: Int
    public let totalTokens: Int
    public let cost: Double
    public let startTime: Date
    public let endTime: Date
    public let createdAt: Date
    public let usageSource: UsageSource
    public let sourceDeviceId: String?
    public let sourceDeviceName: String?
    public let isRemote: Bool
    public let providerID: ProviderID
    public let providerAccountID: String?
    public let providerAccountLabel: String?
    public let providerAccountSource: ProviderAccountStorageScope?
    public let provenanceMethod: UsageProvenanceMethod
    public let provenanceConfidence: UsageProvenanceConfidence
    public let estimatorVersion: String

    public var costUSD: Double { cost }

    public init(
        id: UUID = UUID(),
        provider: AgentProvider,
        sessionId: String,
        projectName: String,
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int = 0,
        cacheReadTokens: Int = 0,
        reasoningTokens: Int = 0,
        costUSD: Double = 0,
        startTime: Date,
        endTime: Date,
        createdAt: Date = Date(),
        usageSource: UsageSource = .providerLog,
        sourceDeviceId: String? = nil,
        sourceDeviceName: String? = nil,
        isRemote: Bool = false,
        providerID: ProviderID? = nil,
        providerAccountID: String? = nil,
        providerAccountLabel: String? = nil,
        providerAccountSource: ProviderAccountStorageScope? = nil,
        provenanceMethod: UsageProvenanceMethod = .unknown,
        provenanceConfidence: UsageProvenanceConfidence = .unknown,
        estimatorVersion: String = ""
    ) {
        self.id = id
        self.provider = provider
        self.sessionId = sessionId
        self.projectName = projectName
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.reasoningTokens = reasoningTokens
        self.totalTokens = Self.billedTotalTokens(
            input: inputTokens,
            output: outputTokens,
            cacheCreation: cacheCreationTokens,
            cacheRead: cacheReadTokens,
            reasoning: reasoningTokens
        )
        self.cost = costUSD
        self.startTime = startTime
        self.endTime = endTime
        self.createdAt = createdAt
        self.usageSource = usageSource
        self.sourceDeviceId = sourceDeviceId
        self.sourceDeviceName = sourceDeviceName
        self.isRemote = isRemote
        self.providerID = providerID ?? provider.providerID
        self.providerAccountID = providerAccountID
        self.providerAccountLabel = providerAccountLabel
        self.providerAccountSource = providerAccountSource
        self.provenanceMethod = provenanceMethod
        self.provenanceConfidence = provenanceConfidence
        self.estimatorVersion = estimatorVersion
    }

    public static func billedTotalTokens(
        input: Int,
        output: Int,
        cacheCreation: Int,
        cacheRead: Int,
        reasoning: Int
    ) -> Int {
        max(0, input) + max(0, output) + max(0, cacheCreation) + max(0, cacheRead) + max(0, reasoning)
    }

    private enum CodingKeys: String, CodingKey {
        case id, provider, sessionId, projectName, model
        case inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens, reasoningTokens
        case totalTokens, cost, startTime, endTime, createdAt, usageSource
        case sourceDeviceId, sourceDeviceName, isRemote
        case providerID, providerAccountID, providerAccountLabel, providerAccountSource
        case provenanceMethod, provenanceConfidence, estimatorVersion
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        provider = try c.decode(AgentProvider.self, forKey: .provider)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        projectName = try c.decode(String.self, forKey: .projectName)
        model = try c.decode(String.self, forKey: .model)
        inputTokens = try c.decode(Int.self, forKey: .inputTokens)
        outputTokens = try c.decode(Int.self, forKey: .outputTokens)
        cacheCreationTokens = try c.decodeIfPresent(Int.self, forKey: .cacheCreationTokens) ?? 0
        cacheReadTokens = try c.decodeIfPresent(Int.self, forKey: .cacheReadTokens) ?? 0
        reasoningTokens = try c.decodeIfPresent(Int.self, forKey: .reasoningTokens) ?? 0
        totalTokens = try c.decodeIfPresent(Int.self, forKey: .totalTokens)
            ?? Self.billedTotalTokens(
                input: inputTokens,
                output: outputTokens,
                cacheCreation: cacheCreationTokens,
                cacheRead: cacheReadTokens,
                reasoning: reasoningTokens
            )
        cost = try c.decode(Double.self, forKey: .cost)
        startTime = try c.decode(Date.self, forKey: .startTime)
        endTime = try c.decode(Date.self, forKey: .endTime)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        usageSource = try c.decodeIfPresent(UsageSource.self, forKey: .usageSource) ?? .unknown
        sourceDeviceId = try c.decodeIfPresent(String.self, forKey: .sourceDeviceId)
        sourceDeviceName = try c.decodeIfPresent(String.self, forKey: .sourceDeviceName)
        isRemote = try c.decodeIfPresent(Bool.self, forKey: .isRemote) ?? false
        providerID = try c.decodeIfPresent(ProviderID.self, forKey: .providerID) ?? provider.providerID
        providerAccountID = try c.decodeIfPresent(String.self, forKey: .providerAccountID)
        providerAccountLabel = try c.decodeIfPresent(String.self, forKey: .providerAccountLabel)
        providerAccountSource = try c.decodeIfPresent(ProviderAccountStorageScope.self, forKey: .providerAccountSource)
        provenanceMethod = try c.decodeIfPresent(UsageProvenanceMethod.self, forKey: .provenanceMethod) ?? .unknown
        provenanceConfidence = try c.decodeIfPresent(UsageProvenanceConfidence.self, forKey: .provenanceConfidence) ?? .unknown
        estimatorVersion = try c.decodeIfPresent(String.self, forKey: .estimatorVersion) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(provider, forKey: .provider)
        try c.encode(sessionId, forKey: .sessionId)
        try c.encode(projectName, forKey: .projectName)
        try c.encode(model, forKey: .model)
        try c.encode(inputTokens, forKey: .inputTokens)
        try c.encode(outputTokens, forKey: .outputTokens)
        try c.encode(cacheCreationTokens, forKey: .cacheCreationTokens)
        try c.encode(cacheReadTokens, forKey: .cacheReadTokens)
        try c.encode(reasoningTokens, forKey: .reasoningTokens)
        try c.encode(totalTokens, forKey: .totalTokens)
        try c.encode(cost, forKey: .cost)
        try c.encode(startTime, forKey: .startTime)
        try c.encode(endTime, forKey: .endTime)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(usageSource, forKey: .usageSource)
        try c.encodeIfPresent(sourceDeviceId, forKey: .sourceDeviceId)
        try c.encodeIfPresent(sourceDeviceName, forKey: .sourceDeviceName)
        try c.encode(isRemote, forKey: .isRemote)
        try c.encode(providerID, forKey: .providerID)
        try c.encodeIfPresent(providerAccountID, forKey: .providerAccountID)
        try c.encodeIfPresent(providerAccountLabel, forKey: .providerAccountLabel)
        try c.encodeIfPresent(providerAccountSource, forKey: .providerAccountSource)
        try c.encode(provenanceMethod, forKey: .provenanceMethod)
        try c.encode(provenanceConfidence, forKey: .provenanceConfidence)
        try c.encode(estimatorVersion, forKey: .estimatorVersion)
    }

    public var duration: TimeInterval {
        endTime.timeIntervalSince(startTime)
    }

    public var formattedDuration: String {
        let interval = Int(duration)
        let hours = interval / 3600
        let minutes = (interval % 3600) / 60
        let seconds = interval % 60
        if hours > 0 {
            return String(format: "%dh %dm", hours, minutes)
        } else if minutes > 0 {
            return String(format: "%dm %ds", minutes, seconds)
        } else {
            return String(format: "%ds", seconds)
        }
    }

    public func intersects(dateRange: ClosedRange<Date>) -> Bool {
        let s = min(startTime, endTime)
        let e = max(startTime, endTime)
        return s <= dateRange.upperBound && e >= dateRange.lowerBound
    }
}
