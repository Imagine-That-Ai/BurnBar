import Foundation

public enum BurnBarProxyRouteFinalStatus: String, Codable, Hashable, CaseIterable, Sendable {
    case exact
    case sameModelFailover = "same_model_failover"
    case crossVendorFallback = "cross_vendor_fallback"
    case failed
    case rejected
    case interrupted
}

public enum BurnBarProxyRewriteKind: String, Codable, Hashable, CaseIterable, Sendable {
    case none
    case modelAlias = "model_alias"
    case thinkingVariant = "thinking_variant"
    case legacyOllamaCloud = "legacy_ollama_cloud"
    case crossVendorFallback = "cross_vendor_fallback"
}

public enum BurnBarProxyTransportKind: String, Codable, Hashable, CaseIterable, Sendable {
    case http
    case factoryDroid = "factory_droid"
    case claudeInteractive = "claude_interactive"
}

public enum BurnBarProxyExactModelInvariant: String, Codable, Hashable, CaseIterable, Sendable {
    case passed
    case failed
    case unavailable
    case notApplicable = "not_applicable"
}

public struct BurnBarProxyRouteUsage: Codable, Hashable, Sendable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheCreationTokens: Int
    public let cacheReadTokens: Int
    public let reasoningTokens: Int
    public let cost: Double
    public let confidence: BurnBarUsageConfidence

    public init(
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int = 0,
        cacheReadTokens: Int = 0,
        reasoningTokens: Int = 0,
        cost: Double,
        confidence: BurnBarUsageConfidence = .unknown
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.reasoningTokens = reasoningTokens
        self.cost = cost
        self.confidence = confidence
    }
}

public struct BurnBarProxyRouteAttempt: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let sequence: Int
    public let startedAt: Date
    public let completedAt: Date?
    public let durationMilliseconds: Int?
    public let providerID: String
    public let providerName: String
    public let providerLogoKey: String?
    public let accountID: String?
    public let accountLabel: String?
    public let routingModelSlug: String
    public let upstreamModelSlug: String
    public let canonicalModelID: String?
    public let formatFamily: String
    public let endpointProfileID: String?
    public let transportKind: BurnBarProxyTransportKind
    public let status: BurnBarProxyRouteFinalStatus
    public let httpStatus: Int?
    public let failureMessage: String?

    public init(
        id: String = UUID().uuidString,
        sequence: Int,
        startedAt: Date,
        completedAt: Date? = nil,
        durationMilliseconds: Int? = nil,
        providerID: String,
        providerName: String,
        providerLogoKey: String? = nil,
        accountID: String? = nil,
        accountLabel: String? = nil,
        routingModelSlug: String,
        upstreamModelSlug: String,
        canonicalModelID: String? = nil,
        formatFamily: String,
        endpointProfileID: String? = nil,
        transportKind: BurnBarProxyTransportKind,
        status: BurnBarProxyRouteFinalStatus,
        httpStatus: Int? = nil,
        failureMessage: String? = nil
    ) {
        self.id = id
        self.sequence = sequence
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.durationMilliseconds = durationMilliseconds
        self.providerID = providerID
        self.providerName = providerName
        self.providerLogoKey = providerLogoKey
        self.accountID = accountID
        self.accountLabel = accountLabel
        self.routingModelSlug = routingModelSlug
        self.upstreamModelSlug = upstreamModelSlug
        self.canonicalModelID = canonicalModelID
        self.formatFamily = formatFamily
        self.endpointProfileID = endpointProfileID
        self.transportKind = transportKind
        self.status = status
        self.httpStatus = httpStatus
        self.failureMessage = failureMessage
    }
}

public struct BurnBarProxyRouteLogEntry: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let occurredAt: Date
    public let completedAt: Date?
    public let durationMilliseconds: Int?
    public let requestPath: String
    public let endpoint: String
    public let clientModelSlug: String
    public let advertisedModelSlug: String?
    public let routingModelSlug: String?
    public let upstreamModelSlug: String?
    public let providerReportedModelSlug: String?
    public let clientModelDisplayName: String?
    public let routingModelDisplayName: String?
    public let upstreamModelDisplayName: String?
    public let providerID: String?
    public let providerName: String?
    public let providerLogoKey: String?
    public let accountID: String?
    public let accountLabel: String?
    public let requestedCanonicalModelID: String?
    public let servedCanonicalModelID: String?
    public let formatFamily: String?
    public let endpointProfileID: String?
    public let transportKind: BurnBarProxyTransportKind?
    public let rewriteKind: BurnBarProxyRewriteKind
    public let exactModelInvariant: BurnBarProxyExactModelInvariant
    public let finalStatus: BurnBarProxyRouteFinalStatus
    public let streamed: Bool
    public let streamInterrupted: Bool
    public let httpStatus: Int?
    public let attempts: [BurnBarProxyRouteAttempt]
    public let usage: BurnBarProxyRouteUsage?
    public let failureMessage: String?

    public init(
        id: String = UUID().uuidString,
        occurredAt: Date,
        completedAt: Date? = nil,
        durationMilliseconds: Int? = nil,
        requestPath: String,
        endpoint: String,
        clientModelSlug: String,
        advertisedModelSlug: String? = nil,
        routingModelSlug: String? = nil,
        upstreamModelSlug: String? = nil,
        providerReportedModelSlug: String? = nil,
        clientModelDisplayName: String? = nil,
        routingModelDisplayName: String? = nil,
        upstreamModelDisplayName: String? = nil,
        providerID: String? = nil,
        providerName: String? = nil,
        providerLogoKey: String? = nil,
        accountID: String? = nil,
        accountLabel: String? = nil,
        requestedCanonicalModelID: String? = nil,
        servedCanonicalModelID: String? = nil,
        formatFamily: String? = nil,
        endpointProfileID: String? = nil,
        transportKind: BurnBarProxyTransportKind? = nil,
        rewriteKind: BurnBarProxyRewriteKind = .none,
        exactModelInvariant: BurnBarProxyExactModelInvariant = .notApplicable,
        finalStatus: BurnBarProxyRouteFinalStatus,
        streamed: Bool = false,
        streamInterrupted: Bool = false,
        httpStatus: Int? = nil,
        attempts: [BurnBarProxyRouteAttempt] = [],
        usage: BurnBarProxyRouteUsage? = nil,
        failureMessage: String? = nil
    ) {
        self.id = id
        self.occurredAt = occurredAt
        self.completedAt = completedAt
        self.durationMilliseconds = durationMilliseconds
        self.requestPath = requestPath
        self.endpoint = endpoint
        self.clientModelSlug = clientModelSlug
        self.advertisedModelSlug = advertisedModelSlug
        self.routingModelSlug = routingModelSlug
        self.upstreamModelSlug = upstreamModelSlug
        self.providerReportedModelSlug = providerReportedModelSlug
        self.clientModelDisplayName = clientModelDisplayName
        self.routingModelDisplayName = routingModelDisplayName
        self.upstreamModelDisplayName = upstreamModelDisplayName
        self.providerID = providerID
        self.providerName = providerName
        self.providerLogoKey = providerLogoKey
        self.accountID = accountID
        self.accountLabel = accountLabel
        self.requestedCanonicalModelID = requestedCanonicalModelID
        self.servedCanonicalModelID = servedCanonicalModelID
        self.formatFamily = formatFamily
        self.endpointProfileID = endpointProfileID
        self.transportKind = transportKind
        self.rewriteKind = rewriteKind
        self.exactModelInvariant = exactModelInvariant
        self.finalStatus = finalStatus
        self.streamed = streamed
        self.streamInterrupted = streamInterrupted
        self.httpStatus = httpStatus
        self.attempts = attempts
        self.usage = usage
        self.failureMessage = failureMessage
    }
}

public struct BurnBarProxyRouteLogRecentRequest: Codable, Hashable, Sendable {
    public let limit: Int

    public init(limit: Int = 50) {
        self.limit = limit
    }
}

public struct BurnBarProxyRouteLogRecentResponse: Codable, Hashable, Sendable {
    public let entries: [BurnBarProxyRouteLogEntry]

    public init(entries: [BurnBarProxyRouteLogEntry]) {
        self.entries = entries
    }
}

public struct BurnBarProxyRouteLogClearRequest: Codable, Hashable, Sendable {
    public init() {}
}

public struct BurnBarProxyRouteLogClearResponse: Codable, Hashable, Sendable {
    public let cleared: Bool

    public init(cleared: Bool) {
        self.cleared = cleared
    }
}
