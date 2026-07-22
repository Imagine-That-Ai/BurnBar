import OpenBurnBarEngine
import Foundation

// MARK: - Router Scorecard Types

/// Five-dimensional score for route ranking.
/// All dimensions are normalized to 0.0-1.0 where higher is better.
public struct BurnBarRouteScore: Hashable, Sendable, Codable {
    /// Provider capability score (0.0-1.0) based on provider features.
    public let capability: Double

    /// Cost efficiency score (0.0-1.0) — lower cost = higher score.
    /// Computed relative to the cheapest and most expensive candidates.
    public let cost: Double

    /// Latency score (0.0-1.0) — lower latency = higher score.
    /// Based on historical round-trip time for this slot/provider.
    public let latency: Double

    /// Trust score (0.0-1.0) based on credential slot status and cooldown state.
    public let trust: Double

    /// Policy-fit score (0.0-1.0) based on preferred-provider and preferred-slot alignment.
    public let policyFit: Double

    /// Weighted composite score. Weights: capability=0.20, cost=0.25, latency=0.15, trust=0.25, policyFit=0.15.
    public var composite: Double {
        capability * 0.20 + cost * 0.25 + latency * 0.15 + trust * 0.25 + policyFit * 0.15
    }

    public init(
        capability: Double,
        cost: Double,
        latency: Double,
        trust: Double,
        policyFit: Double
    ) {
        self.capability = Self.clamp01(capability)
        self.cost = Self.clamp01(cost)
        self.latency = Self.clamp01(latency)
        self.trust = Self.clamp01(trust)
        self.policyFit = Self.clamp01(policyFit)
    }

    private static func clamp01(_ value: Double) -> Double {
        max(0.0, min(1.0, value))
    }
}

/// Full score breakdown artifact for a route, used to prove all five dimensions are considered.
public struct BurnBarRouteScoreBreakdown: Hashable, Sendable, Codable {
    public let routeKey: String
    public let providerID: String
    public let slotID: String?
    public let score: BurnBarRouteScore

    /// Raw dimension values before normalization (for debugging/determinism verification).
    public let rawCapability: Double
    public let rawCostPerMToken: Double
    public let rawLatencyMs: Double
    public let rawTrustStatus: String
    public let rawPolicyFitPreferred: Bool

    public init(
        routeKey: String,
        providerID: String,
        slotID: String?,
        score: BurnBarRouteScore,
        rawCapability: Double,
        rawCostPerMToken: Double,
        rawLatencyMs: Double,
        rawTrustStatus: String,
        rawPolicyFitPreferred: Bool
    ) {
        self.routeKey = routeKey
        self.providerID = providerID
        self.slotID = slotID
        self.score = score
        self.rawCapability = rawCapability
        self.rawCostPerMToken = rawCostPerMToken
        self.rawLatencyMs = rawLatencyMs
        self.rawTrustStatus = rawTrustStatus
        self.rawPolicyFitPreferred = rawPolicyFitPreferred
    }
}

/// Ranked route with score breakdown.
public struct BurnBarRankedRoute: Hashable, Sendable {
    public let route: BurnBarProviderRoute
    public let breakdown: BurnBarRouteScoreBreakdown
    public let quotaResetsAt: Date?
    public let quotaRemainingPercent: Double?

    public init(
        route: BurnBarProviderRoute,
        breakdown: BurnBarRouteScoreBreakdown,
        quotaResetsAt: Date? = nil,
        quotaRemainingPercent: Double? = nil
    ) {
        self.route = route
        self.breakdown = breakdown
        self.quotaResetsAt = quotaResetsAt
        self.quotaRemainingPercent = quotaRemainingPercent
    }
}

/// Result of scoring and ranking routes.
public struct BurnBarRouteRankingResult: Hashable, Sendable {
    /// All candidate routes ranked by composite score (highest first).
    /// When `requiredCanonicalModelID` was provided, this contains only exact-model routes.
    public let rankedRoutes: [BurnBarRankedRoute]
    public let routerMode: ProviderRouterMode
    public let taskCategory: ProviderRoutingTaskCategory
    public let benchmarkStatus: ProviderModelBenchmarkStatus?
    public let requiredCanonicalModelID: String?

    /// Legacy same-class blocked routes retained for older audit consumers.
    public let blockedCapabilityClassRoutes: [BurnBarProviderRoute]
    /// Routes excluded because they could not prove the same canonical model identity.
    public let blockedExactModelRoutes: [BurnBarProviderRoute]

    /// The winning route (same as rankedRoutes.first?.route).
    public var winner: BurnBarProviderRoute? {
        rankedRoutes.first?.route
    }

    public init(
        rankedRoutes: [BurnBarRankedRoute],
        routerMode: ProviderRouterMode = .providerFamilyFailover,
        taskCategory: ProviderRoutingTaskCategory = .unknown,
        benchmarkStatus: ProviderModelBenchmarkStatus? = nil,
        requiredCanonicalModelID: String? = nil,
        blockedCapabilityClassRoutes: [BurnBarProviderRoute] = [],
        blockedExactModelRoutes: [BurnBarProviderRoute] = []
    ) {
        self.rankedRoutes = rankedRoutes
        self.routerMode = routerMode
        self.taskCategory = taskCategory
        self.benchmarkStatus = benchmarkStatus
        self.requiredCanonicalModelID = BurnBarCatalogModel.normalizedCanonicalModelID(requiredCanonicalModelID)
        self.blockedCapabilityClassRoutes = blockedCapabilityClassRoutes
        self.blockedExactModelRoutes = blockedExactModelRoutes
    }
}

public actor BurnBarProviderRoutingDecisionEventStore {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let logger: BurnBarDaemonLogger

    public init(
        fileURL: URL = BurnBarDaemonPaths.defaultRoutingDecisionEventsURL,
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(category: "provider-routing-events")
    ) {
        self.fileURL = fileURL
        self.logger = logger
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.encoder.outputFormatting = [.sortedKeys]
    }

    public func append(_ event: ProviderRoutingDecisionEvent) {
        do {
            let directoryURL = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let data = try encoder.encode(event)
            let line = data + Data([0x0A])
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
                try handle.close()
            } else {
                try line.write(to: fileURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            }
        } catch {
            // Routing must never fail because audit persistence failed.
            logger.silentFailure(
                "BurnBarProviderRoutingDecisionEventStore.append",
                error: error,
                context: [
                    "eventID": event.id.uuidString,
                    "selectedProviderID": event.selectedProviderID?.rawValue ?? "none",
                    "modelID": event.modelID ?? "none"
                ]
            )
        }
    }
}

// MARK: - Route Type

public struct BurnBarProviderRoute: Hashable, Sendable {
    public let providerID: String
    public let providerDisplayName: String
    public let credentialSlotID: String?
    public let credentialSlotLabel: String?
    public let baseURL: String
    public let requestedModel: String
    public let resolvedModelID: String
    public let canonicalModelID: String?
    public let apiKey: String
    public let pricing: BurnBarModelPricing
    /// Advisory capability class for scoring, grouping, and legacy audit
    /// consumers. Exact failover is keyed by `canonicalModelID`, not this field.
    public let modelCapabilityClassID: String
    /// Wire-format family this route serves. Determined by the upstream
    /// provider's catalog declaration. The gateway enforces that an incoming
    /// request only matches routes in the same family — Anthropic-shape
    /// requests never get routed to OpenAI-compatible upstreams and vice
    /// versa.
    public let formatFamily: BurnBarProviderFormatFamily
    public let endpointProfileID: String?

    public init(
        providerID: String,
        providerDisplayName: String,
        credentialSlotID: String? = nil,
        credentialSlotLabel: String? = nil,
        baseURL: String,
        requestedModel: String,
        resolvedModelID: String,
        canonicalModelID: String? = nil,
        apiKey: String,
        pricing: BurnBarModelPricing,
        modelCapabilityClassID: String? = nil,
        formatFamily: BurnBarProviderFormatFamily = .openaiCompat,
        endpointProfileID: String? = nil
    ) {
        self.providerID = providerID
        self.providerDisplayName = providerDisplayName
        self.credentialSlotID = credentialSlotID
        self.credentialSlotLabel = credentialSlotLabel
        self.baseURL = baseURL
        self.requestedModel = requestedModel
        self.resolvedModelID = resolvedModelID
        self.canonicalModelID = BurnBarCatalogModel.normalizedCanonicalModelID(canonicalModelID)
        self.apiKey = apiKey
        self.pricing = pricing
        self.modelCapabilityClassID = Self.normalizedCapabilityClassID(
            modelCapabilityClassID ?? resolvedModelID
        )
        self.formatFamily = formatFamily
        self.endpointProfileID = endpointProfileID
    }

    private static func normalizedCapabilityClassID(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

public enum BurnBarProviderRouterError: Error, LocalizedError {
    case noEnabledProviders
    case unsupportedProvider(String)
    case providerDisabled(String)
    case missingCredential(String)
    case credentialsUnavailable(providerID: String, reason: String)
    case unsupportedModel(String)

    public var errorDescription: String? {
        switch self {
        case .noEnabledProviders:
            return "OpenBurnBar daemon has no enabled providers to route through."
        case .unsupportedProvider(let providerID):
            return "Provider '\(providerID)' is not supported by OpenBurnBar daemon routing."
        case .providerDisabled(let providerID):
            return "Provider '\(providerID)' is disabled in the daemon config."
        case .missingCredential(let providerID):
            return "Provider '\(providerID)' is missing credentials."
        case .credentialsUnavailable(let providerID, let reason):
            return "Provider '\(providerID)' has no usable credentials: \(reason)"
        case .unsupportedModel(let modelName):
            return "Model '\(modelName)' is not supported by the configured OpenBurnBar providers."
        }
    }
}
