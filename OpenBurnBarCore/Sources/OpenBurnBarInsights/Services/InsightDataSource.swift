import Foundation

// MARK: - Snapshot value types

/// Minimal projection of a usage row consumed by the executor.
///
/// Decouples the executor and digest builder from any particular storage
/// layer (SQLite on macOS, Firestore on mobile, in-memory in tests).
public struct InsightUsageRow: Codable, Hashable, Sendable {
    public var sessionID: String
    public var provider: String
    public var model: String
    public var projectName: String?
    public var deviceID: String?
    public var deviceName: String?
    public var startTime: Date
    public var endTime: Date
    public var inputTokens: Int
    public var outputTokens: Int
    public var reasoningTokens: Int
    public var cacheReadTokens: Int
    public var cacheCreationTokens: Int
    public var totalTokens: Int
    public var costUSD: Double

    public init(
        sessionID: String,
        provider: String,
        model: String,
        projectName: String? = nil,
        deviceID: String? = nil,
        deviceName: String? = nil,
        startTime: Date,
        endTime: Date,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        reasoningTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheCreationTokens: Int = 0,
        totalTokens: Int = 0,
        costUSD: Double = 0
    ) {
        self.sessionID = sessionID
        self.provider = provider
        self.model = model
        self.projectName = projectName
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.startTime = startTime
        self.endTime = endTime
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.totalTokens = totalTokens
        self.costUSD = costUSD
    }
}

/// Conversation-level summary row.
public struct InsightSessionRow: Codable, Hashable, Sendable {
    public var sessionID: String
    public var provider: String
    public var projectName: String?
    public var startTime: Date
    public var endTime: Date
    public var messageCount: Int
    public var inferredTaskTitle: String?
    /// Top tool names referenced (already short list from the indexer).
    public var keyTools: [String]
    /// Top commands referenced.
    public var keyCommands: [String]
    /// Top file paths referenced — these are not in the digest (privacy),
    /// but are used locally by `InsightToolBroker` to compute per-file
    /// rankings; only stable hashes of paths are surfaced externally.
    public var keyFiles: [String]

    public init(sessionID: String, provider: String, projectName: String?,
                startTime: Date, endTime: Date, messageCount: Int,
                inferredTaskTitle: String?, keyTools: [String],
                keyCommands: [String], keyFiles: [String]) {
        self.sessionID = sessionID; self.provider = provider
        self.projectName = projectName
        self.startTime = startTime; self.endTime = endTime
        self.messageCount = messageCount
        self.inferredTaskTitle = inferredTaskTitle
        self.keyTools = keyTools; self.keyCommands = keyCommands
        self.keyFiles = keyFiles
    }
}

/// Quota bucket lift from the live quota subsystem.
public struct InsightQuotaBucket: Codable, Hashable, Sendable, Identifiable {
    public var id: String                 // "providerID/bucket"
    public var providerKey: String
    public var providerDisplayName: String
    public var bucketName: String
    public var used: Double
    public var limit: Double?
    public var resetsAt: Date?
    public var sourceKind: String
    public var confidence: String
    public init(providerKey: String, providerDisplayName: String,
                bucketName: String, used: Double, limit: Double?,
                resetsAt: Date?, sourceKind: String, confidence: String) {
        self.id = "\(providerKey)/\(bucketName)"
        self.providerKey = providerKey
        self.providerDisplayName = providerDisplayName
        self.bucketName = bucketName
        self.used = used; self.limit = limit
        self.resetsAt = resetsAt
        self.sourceKind = sourceKind
        self.confidence = confidence
    }
}

/// Daemon operating-action history row.
public struct InsightOperatingAction: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var sessionID: String?
    public var actionKind: String
    public var projectName: String?
    public var occurredAt: Date
    public var duration: TimeInterval?
    public var summary: String
    public init(id: String, sessionID: String? = nil, actionKind: String, projectName: String?,
                occurredAt: Date, duration: TimeInterval? = nil, summary: String) {
        self.id = id; self.sessionID = sessionID; self.actionKind = actionKind
        self.projectName = projectName
        self.occurredAt = occurredAt; self.duration = duration; self.summary = summary
    }
}

/// Summary-runs log row.
public struct InsightSummaryRun: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var providerKey: String
    public var modelID: String
    public var costUSD: Double
    public var ranAt: Date
    public init(id: String, providerKey: String, modelID: String,
                costUSD: Double, ranAt: Date) {
        self.id = id; self.providerKey = providerKey
        self.modelID = modelID; self.costUSD = costUSD; self.ranAt = ranAt
    }
}

/// All rows + side data the executor and digest builder will consume.
public struct InsightDataSnapshot: Codable, Hashable, Sendable {
    public var window: DateInterval
    public var generatedAt: Date
    public var usages: [InsightUsageRow]
    public var sessions: [InsightSessionRow]
    public var quotaBuckets: [InsightQuotaBucket]
    public var operatingActions: [InsightOperatingAction]
    public var summaryRuns: [InsightSummaryRun]
    public var modelBenchmarks: [InsightDigest.ModelBenchmarkSummary]

    public init(window: DateInterval,
                generatedAt: Date = Date(),
                usages: [InsightUsageRow] = [],
                sessions: [InsightSessionRow] = [],
                quotaBuckets: [InsightQuotaBucket] = [],
                operatingActions: [InsightOperatingAction] = [],
                summaryRuns: [InsightSummaryRun] = [],
                modelBenchmarks: [InsightDigest.ModelBenchmarkSummary] = []) {
        self.window = window
        self.generatedAt = generatedAt
        self.usages = usages
        self.sessions = sessions
        self.quotaBuckets = quotaBuckets
        self.operatingActions = operatingActions
        self.summaryRuns = summaryRuns
        self.modelBenchmarks = modelBenchmarks
    }
}

// MARK: - Protocol

/// The single interface the executor / digest builder / tool broker use
/// for data access. Platform shells (macOS DataStore, mobile Firestore)
/// provide their own concrete adapter.
public protocol InsightDataSource: Sendable {
    /// Snapshot all rows intersecting `window`.
    func snapshot(window: DateInterval) async throws -> InsightDataSnapshot
}
