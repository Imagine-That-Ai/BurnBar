import Foundation

/// The sanitized, privacy-bounded data snapshot that gets shipped to the
/// selected model when authoring/refreshing a canvas.
///
/// The digest is *the* contract for what may leave the device. Every
/// addition here must be checked against `docs/PRIVACY.md`. Hard
/// guarantees enforced by `InsightDigestBuilder` and unit tests:
///
///   • No raw file contents, no source code, no secrets.
///   • No conversation message bodies (only inferred titles + counts).
///   • No API keys, credential labels, OAuth refresh hints.
///   • Device names replaced with stable hashed IDs.
///   • Project paths replaced with stable `project_xxx` IDs.
///   • Total encoded byte size ≤ 24 KB.
public struct InsightDigest: Codable, Hashable, Sendable {

    public static let maxEncodedBytes: Int = 24 * 1024

    /// Stable hash of the digest contents; used as cache key for LLM calls.
    public var contentHash: String

    /// User-local "as of" timestamp.
    public var generatedAt: Date

    /// Time interval the digest summarizes.
    public var window: DateInterval

    /// Total rows summarized (after the privacy filter).
    public var rowCount: Int

    public var totals: Totals
    public var providers: [ProviderSnapshot]
    public var models: [ModelSnapshot]
    public var projects: [ProjectSnapshot]
    public var devices: [DeviceSnapshot]
    public var daily: [DailyPoint]
    public var hourly: [Int]            // 24-bucket
    public var useCaseHistogram: [UseCaseBin]
    public var agentFocusSignals: [AgentFocusSignal]
    public var modelFocusSignals: [ModelFocusSignal]
    public var quotaSnapshots: [QuotaSnapshotSummary]
    public var operatingActions: [ActionDigest]
    public var summaryRunsLog: [SummaryRunDigest]
    public var anomalies: [PrecomputedAnomaly]
    public var glossary: InsightTaxonomy

    public init(
        contentHash: String,
        generatedAt: Date,
        window: DateInterval,
        rowCount: Int,
        totals: Totals,
        providers: [ProviderSnapshot],
        models: [ModelSnapshot],
        projects: [ProjectSnapshot],
        devices: [DeviceSnapshot],
        daily: [DailyPoint],
        hourly: [Int],
        useCaseHistogram: [UseCaseBin],
        agentFocusSignals: [AgentFocusSignal],
        modelFocusSignals: [ModelFocusSignal],
        quotaSnapshots: [QuotaSnapshotSummary],
        operatingActions: [ActionDigest],
        summaryRunsLog: [SummaryRunDigest],
        anomalies: [PrecomputedAnomaly],
        glossary: InsightTaxonomy = .default
    ) {
        self.contentHash = contentHash
        self.generatedAt = generatedAt
        self.window = window
        self.rowCount = rowCount
        self.totals = totals
        self.providers = providers
        self.models = models
        self.projects = projects
        self.devices = devices
        self.daily = daily
        self.hourly = hourly
        self.useCaseHistogram = useCaseHistogram
        self.agentFocusSignals = agentFocusSignals
        self.modelFocusSignals = modelFocusSignals
        self.quotaSnapshots = quotaSnapshots
        self.operatingActions = operatingActions
        self.summaryRunsLog = summaryRunsLog
        self.anomalies = anomalies
        self.glossary = glossary
    }

    // MARK: - Field types

    public struct Totals: Codable, Hashable, Sendable {
        public var costUSD: Double
        public var totalTokens: Int
        public var inputTokens: Int
        public var outputTokens: Int
        public var reasoningTokens: Int
        public var cacheReadTokens: Int
        public var cacheCreationTokens: Int
        public var sessionCount: Int
        public init(costUSD: Double = 0, totalTokens: Int = 0, inputTokens: Int = 0,
                    outputTokens: Int = 0, reasoningTokens: Int = 0,
                    cacheReadTokens: Int = 0, cacheCreationTokens: Int = 0,
                    sessionCount: Int = 0) {
            self.costUSD = costUSD; self.totalTokens = totalTokens
            self.inputTokens = inputTokens; self.outputTokens = outputTokens
            self.reasoningTokens = reasoningTokens
            self.cacheReadTokens = cacheReadTokens
            self.cacheCreationTokens = cacheCreationTokens
            self.sessionCount = sessionCount
        }
    }

    public struct ProviderSnapshot: Codable, Hashable, Sendable, Identifiable {
        public var id: String         // AgentProvider.rawValue
        public var displayName: String
        public var costUSD: Double
        public var totalTokens: Int
        public var sessionCount: Int
        public var topModels: [String]            // up to 3
        public var topInferredTaskTitles: [String]  // up to 5
        public var topKeyTools: [String]            // up to 5
        public init(id: String, displayName: String, costUSD: Double, totalTokens: Int,
                    sessionCount: Int, topModels: [String], topInferredTaskTitles: [String],
                    topKeyTools: [String]) {
            self.id = id; self.displayName = displayName
            self.costUSD = costUSD; self.totalTokens = totalTokens
            self.sessionCount = sessionCount; self.topModels = topModels
            self.topInferredTaskTitles = topInferredTaskTitles
            self.topKeyTools = topKeyTools
        }
    }

    public struct ModelSnapshot: Codable, Hashable, Sendable, Identifiable {
        public var id: String      // model identifier
        public var providerID: String
        public var costUSD: Double
        public var totalTokens: Int
        public var sessionCount: Int
        public var avgCostPerSession: Double
        public var cacheHitRate: Double
        public var topInferredTaskTitles: [String]  // up to 5
        public var topProjects: [String]            // up to 3 (anonymized IDs)
        public init(id: String, providerID: String, costUSD: Double, totalTokens: Int,
                    sessionCount: Int, avgCostPerSession: Double, cacheHitRate: Double,
                    topInferredTaskTitles: [String], topProjects: [String]) {
            self.id = id; self.providerID = providerID
            self.costUSD = costUSD; self.totalTokens = totalTokens
            self.sessionCount = sessionCount
            self.avgCostPerSession = avgCostPerSession
            self.cacheHitRate = cacheHitRate
            self.topInferredTaskTitles = topInferredTaskTitles
            self.topProjects = topProjects
        }
    }

    public struct ProjectSnapshot: Codable, Hashable, Sendable, Identifiable {
        public var id: String      // anonymized: "project_xxx"
        public var displayName: String   // safe, hashed name suffix
        public var costUSD: Double
        public var totalTokens: Int
        public var sessionCount: Int
        public init(id: String, displayName: String, costUSD: Double,
                    totalTokens: Int, sessionCount: Int) {
            self.id = id; self.displayName = displayName
            self.costUSD = costUSD; self.totalTokens = totalTokens
            self.sessionCount = sessionCount
        }
    }

    public struct DeviceSnapshot: Codable, Hashable, Sendable, Identifiable {
        public var id: String      // hashed device id
        public var displayName: String   // "Mac · A1B2"
        public var costUSD: Double
        public var sessionCount: Int
        public init(id: String, displayName: String, costUSD: Double, sessionCount: Int) {
            self.id = id; self.displayName = displayName
            self.costUSD = costUSD; self.sessionCount = sessionCount
        }
    }

    public struct DailyPoint: Codable, Hashable, Sendable {
        public var day: Date
        public var costUSD: Double
        public var totalTokens: Int
        public var sessionCount: Int
        public var perProvider: [String: Double]
        public init(day: Date, costUSD: Double, totalTokens: Int,
                    sessionCount: Int, perProvider: [String: Double]) {
            self.day = day; self.costUSD = costUSD
            self.totalTokens = totalTokens; self.sessionCount = sessionCount
            self.perProvider = perProvider
        }
    }

    public struct UseCaseBin: Codable, Hashable, Sendable, Identifiable {
        public var id: String      // useCase tag from taxonomy
        public var count: Int
        public var costUSD: Double
        public init(id: String, count: Int, costUSD: Double) {
            self.id = id; self.count = count; self.costUSD = costUSD
        }
    }

    public struct AgentFocusSignal: Codable, Hashable, Sendable {
        public var agentID: String      // AgentProvider.rawValue
        public var focus: String        // taxonomy focus
        public var weight: Double       // 0…1
        public init(agentID: String, focus: String, weight: Double) {
            self.agentID = agentID; self.focus = focus; self.weight = weight
        }
    }

    public struct ModelFocusSignal: Codable, Hashable, Sendable {
        public var modelID: String
        public var focus: String
        public var weight: Double
        public init(modelID: String, focus: String, weight: Double) {
            self.modelID = modelID; self.focus = focus; self.weight = weight
        }
    }

    public struct QuotaSnapshotSummary: Codable, Hashable, Sendable, Identifiable {
        public var id: String          // "providerID/bucket"
        public var providerID: String
        public var bucketName: String
        public var used: Double
        public var limit: Double?
        public var resetsAt: Date?
        public init(providerID: String, bucketName: String, used: Double,
                    limit: Double?, resetsAt: Date?) {
            self.id = "\(providerID)/\(bucketName)"
            self.providerID = providerID; self.bucketName = bucketName
            self.used = used; self.limit = limit; self.resetsAt = resetsAt
        }
    }

    public struct ActionDigest: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var kind: String           // operating_action_history.actionKind
        public var projectID: String?     // anonymized
        public var occurredAt: Date
        public var summary: String        // already short / sanitized
        public init(id: String, kind: String, projectID: String?,
                    occurredAt: Date, summary: String) {
            self.id = id; self.kind = kind; self.projectID = projectID
            self.occurredAt = occurredAt; self.summary = summary
        }
    }

    public struct SummaryRunDigest: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var providerID: String
        public var modelID: String
        public var costUSD: Double
        public var ranAt: Date
        public init(id: String, providerID: String, modelID: String,
                    costUSD: Double, ranAt: Date) {
            self.id = id; self.providerID = providerID
            self.modelID = modelID; self.costUSD = costUSD; self.ranAt = ranAt
        }
    }

    public struct PrecomputedAnomaly: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var occurredAt: Date
        public var label: String
        public var score: Double      // robust z, two-sided
        public var detail: String?
        public init(id: String, occurredAt: Date, label: String,
                    score: Double, detail: String? = nil) {
            self.id = id; self.occurredAt = occurredAt; self.label = label
            self.score = score; self.detail = detail
        }
    }
}
