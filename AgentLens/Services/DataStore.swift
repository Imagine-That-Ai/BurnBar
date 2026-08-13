import Foundation
import GRDB
import SwiftUI
import BurnBarCore

// MARK: - Rolling Average + Mood

enum MoodBand: Equatable {
    case light
    case onPace
    case heavy
    case baseline
    case quiet
}

// MARK: - Local Search Records

enum SearchSourceKind: String, Codable, CaseIterable, Sendable {
    case conversation
    case skillDoc = "skill_doc"
    case agentDoc = "agent_doc"
    case sharedArtifact = "shared_artifact"
}

enum ProjectionJobType: String, Codable, CaseIterable, Sendable {
    case project
    case reproject
    case purge
    case reembed
    case rebuild
}

enum ProjectionJobStatus: String, Codable, CaseIterable, Sendable {
    case queued
    case leased
    case running
    case completed
    case failed
    case canceled
}

enum EmbeddingDistanceMetric: String, Codable, CaseIterable, Sendable {
    case cosine
    case dotProduct = "dot_product"
    case euclidean
}

enum RetrievalSubsystem: String, Codable, CaseIterable, Sendable {
    case parserImport = "parser_import"
    case lexical
    case semantic
    case projection
    case discovery
    case rebuild
    case collaboration
    case insightRollups = "insight_rollups"
}

enum RetrievalHealthStatus: String, Codable, CaseIterable, Sendable {
    case healthy
    case degraded
    case failed
}

struct SearchDocumentRecord: Identifiable, Equatable, Sendable {
    let id: String
    let sourceKind: SearchSourceKind
    let sourceID: String
    let sourceVersionID: String
    let provider: String?
    let projectName: String?
    let title: String
    let subtitle: String?
    let bodyPreview: String?
    let sourceUpdatedAt: Date?
    let indexedAt: Date
    let contentHash: String?
    let createdAt: Date
    let updatedAt: Date

    init(
        id: String = UUID().uuidString,
        sourceKind: SearchSourceKind,
        sourceID: String,
        sourceVersionID: String = "",
        provider: String? = nil,
        projectName: String? = nil,
        title: String,
        subtitle: String? = nil,
        bodyPreview: String? = nil,
        sourceUpdatedAt: Date? = nil,
        indexedAt: Date = Date(),
        contentHash: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.sourceKind = sourceKind
        self.sourceID = sourceID
        self.sourceVersionID = sourceVersionID
        self.provider = provider
        self.projectName = projectName
        self.title = title
        self.subtitle = subtitle
        self.bodyPreview = bodyPreview
        self.sourceUpdatedAt = sourceUpdatedAt
        self.indexedAt = indexedAt
        self.contentHash = contentHash
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct SearchChunkRecord: Identifiable, Equatable, Sendable {
    let id: String
    let documentID: String
    let sourceKind: SearchSourceKind
    let sourceID: String
    let sourceVersionID: String
    let ordinal: Int
    let startOffset: Int
    let endOffset: Int
    let messageStartOffset: Int?
    let messageEndOffset: Int?
    let sectionPath: String?
    let text: String
    let createdAt: Date
    let updatedAt: Date

    init(
        id: String = UUID().uuidString,
        documentID: String,
        sourceKind: SearchSourceKind,
        sourceID: String,
        sourceVersionID: String = "",
        ordinal: Int,
        startOffset: Int,
        endOffset: Int,
        messageStartOffset: Int? = nil,
        messageEndOffset: Int? = nil,
        sectionPath: String? = nil,
        text: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.documentID = documentID
        self.sourceKind = sourceKind
        self.sourceID = sourceID
        self.sourceVersionID = sourceVersionID
        self.ordinal = ordinal
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.messageStartOffset = messageStartOffset
        self.messageEndOffset = messageEndOffset
        self.sectionPath = sectionPath
        self.text = text
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

enum SearchVisibilityScope: String, Codable, CaseIterable, Sendable {
    case all
    case personalOnly = "personal_only"
    case sharedOnly = "shared_only"
}

struct SearchChunkLexicalMatch: Identifiable, Equatable, Sendable {
    let chunkID: String
    let documentID: String
    let sourceKind: SearchSourceKind
    let sourceID: String
    let sourceVersionID: String
    let provider: String?
    let projectName: String?
    let title: String
    let subtitle: String?
    let bodyPreview: String?
    let sourceUpdatedAt: Date?
    let indexedAt: Date
    let chunkOrdinal: Int
    let startOffset: Int
    let endOffset: Int
    let sectionPath: String?
    let chunkText: String
    let snippet: String
    let lexicalRank: Double

    var id: String { chunkID }
}

struct ProjectionJobRecord: Identifiable, Equatable, Sendable {
    let id: String
    let jobType: ProjectionJobType
    let sourceKind: SearchSourceKind?
    let sourceID: String?
    let sourceVersionID: String
    let status: ProjectionJobStatus
    let priority: Int
    let attempts: Int
    let maxAttempts: Int
    let payloadJSON: String?
    let lastErrorCode: String?
    let lastErrorMessage: String?
    let scheduledAt: Date
    let availableAt: Date
    let startedAt: Date?
    let completedAt: Date?
    let leaseOwner: String?
    let leaseExpiresAt: Date?
    let createdAt: Date
    let updatedAt: Date

    init(
        id: String = UUID().uuidString,
        jobType: ProjectionJobType,
        sourceKind: SearchSourceKind? = nil,
        sourceID: String? = nil,
        sourceVersionID: String = "",
        status: ProjectionJobStatus = .queued,
        priority: Int = 100,
        attempts: Int = 0,
        maxAttempts: Int = 5,
        payloadJSON: String? = nil,
        lastErrorCode: String? = nil,
        lastErrorMessage: String? = nil,
        scheduledAt: Date = Date(),
        availableAt: Date = Date(),
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        leaseOwner: String? = nil,
        leaseExpiresAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.jobType = jobType
        self.sourceKind = sourceKind
        self.sourceID = sourceID
        self.sourceVersionID = sourceVersionID
        self.status = status
        self.priority = priority
        self.attempts = attempts
        self.maxAttempts = maxAttempts
        self.payloadJSON = payloadJSON
        self.lastErrorCode = lastErrorCode
        self.lastErrorMessage = lastErrorMessage
        self.scheduledAt = scheduledAt
        self.availableAt = availableAt
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.leaseOwner = leaseOwner
        self.leaseExpiresAt = leaseExpiresAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct EmbeddingModelRecord: Identifiable, Equatable, Sendable {
    let id: String
    let provider: String
    let modelName: String
    let dimensions: Int
    let distanceMetric: EmbeddingDistanceMetric
    let createdAt: Date
    let updatedAt: Date

    init(
        id: String = UUID().uuidString,
        provider: String,
        modelName: String,
        dimensions: Int,
        distanceMetric: EmbeddingDistanceMetric,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.provider = provider
        self.modelName = modelName
        self.dimensions = dimensions
        self.distanceMetric = distanceMetric
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct EmbeddingVersionRecord: Identifiable, Equatable, Sendable {
    let id: String
    let modelID: String
    let versionTag: String
    let chunkerVersion: String
    let normalizationVersion: String
    let promptVersion: String
    let isActive: Bool
    let createdAt: Date
    let updatedAt: Date

    init(
        id: String = UUID().uuidString,
        modelID: String,
        versionTag: String,
        chunkerVersion: String,
        normalizationVersion: String,
        promptVersion: String,
        isActive: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.modelID = modelID
        self.versionTag = versionTag
        self.chunkerVersion = chunkerVersion
        self.normalizationVersion = normalizationVersion
        self.promptVersion = promptVersion
        self.isActive = isActive
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct ChunkEmbeddingRecord: Equatable, Sendable {
    let chunkID: String
    let embeddingVersionID: String
    let vectorBlob: Data
    let createdAt: Date
    let updatedAt: Date

    init(
        chunkID: String,
        embeddingVersionID: String,
        vectorBlob: Data,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.chunkID = chunkID
        self.embeddingVersionID = embeddingVersionID
        self.vectorBlob = vectorBlob
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct RetrievalHealthRecord: Equatable, Sendable {
    let subsystem: RetrievalSubsystem
    let status: RetrievalHealthStatus
    let errorCode: String?
    let errorMessage: String?
    let detailsJSON: String?
    let observedAt: Date
    let updatedAt: Date

    init(
        subsystem: RetrievalSubsystem,
        status: RetrievalHealthStatus,
        errorCode: String? = nil,
        errorMessage: String? = nil,
        detailsJSON: String? = nil,
        observedAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.subsystem = subsystem
        self.status = status
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.detailsJSON = detailsJSON
        self.observedAt = observedAt
        self.updatedAt = updatedAt
    }
}

enum SourceArtifactStatus: String, Codable, CaseIterable, Sendable {
    case active
    case deleted
}

enum SourceArtifactWriteDisposition: String, Codable, CaseIterable, Sendable {
    case inserted
    case updated
    case restored
    case unchanged
}

struct SourceArtifactRecord: Identifiable, Equatable, Sendable {
    let id: String
    let sourceKind: SearchSourceKind
    let canonicalPath: String
    let rootPath: String
    let relativePath: String
    let provenance: String
    let title: String
    let body: String
    let contentHash: String
    let fileSizeBytes: Int
    let fileModifiedAt: Date?
    let status: SourceArtifactStatus
    let discoveredAt: Date
    let deletedAt: Date?
    let createdAt: Date
    let updatedAt: Date

    init(
        id: String = UUID().uuidString,
        sourceKind: SearchSourceKind,
        canonicalPath: String,
        rootPath: String,
        relativePath: String,
        provenance: String,
        title: String,
        body: String,
        contentHash: String,
        fileSizeBytes: Int,
        fileModifiedAt: Date? = nil,
        status: SourceArtifactStatus = .active,
        discoveredAt: Date = Date(),
        deletedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.sourceKind = sourceKind
        self.canonicalPath = canonicalPath
        self.rootPath = rootPath
        self.relativePath = relativePath
        self.provenance = provenance
        self.title = title
        self.body = body
        self.contentHash = contentHash
        self.fileSizeBytes = fileSizeBytes
        self.fileModifiedAt = fileModifiedAt
        self.status = status
        self.discoveredAt = discoveredAt
        self.deletedAt = deletedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

enum SharedArtifactSyncStatus: String, Codable, CaseIterable, Sendable {
    case synced
    case pendingUpload = "pending_upload"
    case pendingPull = "pending_pull"
    case conflicted
    case failed
}

struct SharedArtifactSyncStateRecord: Identifiable, Equatable, Sendable {
    let sourceArtifactID: String
    let remoteArtifactID: String
    let workspaceID: String
    let teamID: String
    let ownerUserID: String?
    let revisionID: String
    let remoteContentHash: String?
    let localContentHashAtSync: String?
    let remoteUpdatedAt: Date?
    let lastPulledAt: Date?
    let lastSyncedAt: Date?
    let syncStatus: SharedArtifactSyncStatus
    let lastErrorCode: String?
    let lastErrorMessage: String?
    let createdAt: Date
    let updatedAt: Date

    var id: String { sourceArtifactID }

    init(
        sourceArtifactID: String,
        remoteArtifactID: String,
        workspaceID: String,
        teamID: String,
        ownerUserID: String? = nil,
        revisionID: String,
        remoteContentHash: String? = nil,
        localContentHashAtSync: String? = nil,
        remoteUpdatedAt: Date? = nil,
        lastPulledAt: Date? = nil,
        lastSyncedAt: Date? = nil,
        syncStatus: SharedArtifactSyncStatus = .pendingPull,
        lastErrorCode: String? = nil,
        lastErrorMessage: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.sourceArtifactID = sourceArtifactID
        self.remoteArtifactID = remoteArtifactID
        self.workspaceID = workspaceID
        self.teamID = teamID
        self.ownerUserID = ownerUserID
        self.revisionID = revisionID
        self.remoteContentHash = remoteContentHash
        self.localContentHashAtSync = localContentHashAtSync
        self.remoteUpdatedAt = remoteUpdatedAt
        self.lastPulledAt = lastPulledAt
        self.lastSyncedAt = lastSyncedAt
        self.syncStatus = syncStatus
        self.lastErrorCode = lastErrorCode
        self.lastErrorMessage = lastErrorMessage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

enum SharedArtifactVisibility: String, Codable, CaseIterable, Sendable {
    case personal
    case shared
    case workspace
    case team
}

enum SharedArtifactRole: String, Codable, CaseIterable, Sendable {
    case owner
    case editor
    case viewer
}

enum SharedArtifactPrincipalType: String, Codable, CaseIterable, Sendable {
    case user
    case workspace
    case team
}

enum SharedArtifactPermissionWriteDisposition: String, Codable, CaseIterable, Sendable {
    case inserted
    case updated
    case unchanged
}

struct SharedArtifactPermissionRecord: Identifiable, Equatable, Sendable {
    let sourceArtifactID: String
    let workspaceID: String
    let teamID: String
    let principalType: SharedArtifactPrincipalType
    let principalID: String
    let role: SharedArtifactRole
    let visibility: SharedArtifactVisibility
    let canRead: Bool
    let canWrite: Bool
    let canShare: Bool
    let createdAt: Date
    let updatedAt: Date

    var id: String {
        "\(sourceArtifactID)|\(principalType.rawValue)|\(principalID)"
    }

    init(
        sourceArtifactID: String,
        workspaceID: String,
        teamID: String,
        principalType: SharedArtifactPrincipalType,
        principalID: String,
        role: SharedArtifactRole,
        visibility: SharedArtifactVisibility,
        canRead: Bool = true,
        canWrite: Bool = false,
        canShare: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.sourceArtifactID = sourceArtifactID
        self.workspaceID = workspaceID
        self.teamID = teamID
        self.principalType = principalType
        self.principalID = principalID
        self.role = role
        self.visibility = visibility
        self.canRead = canRead
        self.canWrite = canWrite
        self.canShare = canShare
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct SharedArtifactAccessContext: Equatable, Sendable {
    let userID: String
    let workspaceID: String
    let teamID: String

    static func defaultScope(for userID: String) -> SharedArtifactAccessContext {
        SharedArtifactAccessContext(
            userID: userID,
            workspaceID: "workspace-\(userID)",
            teamID: "team-default"
        )
    }
}

enum SharedArtifactAuditAction: String, Codable, CaseIterable, Sendable {
    case create
    case update
    case share
    case permissionChange = "permission_change"
    case rebuild
    case conflictDetected = "conflict_detected"
    case conflictResolved = "conflict_resolved"
}

struct SharedArtifactAuditEventRecord: Identifiable, Equatable, Sendable {
    let id: String
    let sourceArtifactID: String?
    let remoteArtifactID: String?
    let workspaceID: String
    let teamID: String
    let actorUserID: String?
    let actorRole: SharedArtifactRole?
    let action: SharedArtifactAuditAction
    let detailsJSON: String?
    let occurredAt: Date
    let createdAt: Date

    init(
        id: String = UUID().uuidString,
        sourceArtifactID: String? = nil,
        remoteArtifactID: String? = nil,
        workspaceID: String,
        teamID: String,
        actorUserID: String? = nil,
        actorRole: SharedArtifactRole? = nil,
        action: SharedArtifactAuditAction,
        detailsJSON: String? = nil,
        occurredAt: Date = Date(),
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sourceArtifactID = sourceArtifactID
        self.remoteArtifactID = remoteArtifactID
        self.workspaceID = workspaceID
        self.teamID = teamID
        self.actorUserID = actorUserID
        self.actorRole = actorRole
        self.action = action
        self.detailsJSON = detailsJSON
        self.occurredAt = occurredAt
        self.createdAt = createdAt
    }
}

struct LocalSearchSchemaInventory: Equatable, Sendable {
    let tables: [String]
    let indexes: [String]
}

// MARK: - DataStore

@Observable
@MainActor
final class DataStore {
    static let legacyChatThreadID = "burnbar-chat-legacy"

    private let dbQueue: DatabaseQueue
    private let localSearchStore: LocalSearchStore
    private(set) var usages: [TokenUsage] = []
    private(set) var isLoading = false
    private(set) var lastRefresh: Date?

    private let sqliteDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()
    
    // MARK: - Computed Properties
    
    var totalCostToday: Double {
        let calendar = Calendar.current
        return usages
            .filter { calendar.isDateInToday($0.startTime) }
            .reduce(0) { $0 + $1.cost }
    }
    
    var totalCostThisWeek: Double {
        let calendar = Calendar.current
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        return usages
            .filter { $0.startTime >= weekAgo }
            .reduce(0) { $0 + $1.cost }
    }
    
    var totalCostThisMonth: Double {
        let calendar = Calendar.current
        let monthAgo = calendar.date(byAdding: .month, value: -1, to: Date()) ?? Date()
        return usages
            .filter { $0.startTime >= monthAgo }
            .reduce(0) { $0 + $1.cost }
    }
    
    var totalCostAllTime: Double {
        usages.reduce(0) { $0 + $1.cost }
    }

    var totalTokensToday: Int {
        let calendar = Calendar.current
        return usages
            .filter { calendar.isDateInToday($0.startTime) }
            .reduce(0) { $0 + $1.totalTokens }
    }

    var totalTokensThisWeek: Int {
        let calendar = Calendar.current
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        return usages
            .filter { $0.startTime >= weekAgo }
            .reduce(0) { $0 + $1.totalTokens }
    }

    var totalTokensThisMonth: Int {
        let calendar = Calendar.current
        let monthAgo = calendar.date(byAdding: .month, value: -1, to: Date()) ?? Date()
        return usages
            .filter { $0.startTime >= monthAgo }
            .reduce(0) { $0 + $1.totalTokens }
    }

    var totalTokensAllTime: Int {
        usages.reduce(0) { $0 + $1.totalTokens }
    }

    /// 7-day rolling daily average (zero-fills missing days). Updated in `replaceUsages(_:)`.
    private(set) var rollingDailyAverage: Double = 0

    var moodBand: MoodBand {
        let calendar = Calendar.current
        let distinctDays = Set(usages.map { calendar.startOfDay(for: $0.startTime) })
        guard distinctDays.count >= 2 else { return .baseline }
        let today = totalCostToday
        guard today > 0 else { return .quiet }
        guard rollingDailyAverage > 0 else { return .onPace }
        let ratio = today / rollingDailyAverage
        switch ratio {
        case ..<0.8: return .light
        case 0.8..<1.2: return .onPace
        default: return .heavy
        }
    }

    var moodLabel: String {
        switch moodBand {
        case .light: return "Light day"
        case .onPace: return "On pace"
        case .heavy: return "Heavy day"
        case .baseline: return "Building baseline..."
        case .quiet: return "Quiet day"
        }
    }

    var moodColor: Color {
        switch moodBand {
        case .light: return DesignSystem.Colors.success
        case .onPace: return DesignSystem.Colors.textSecondary
        case .heavy: return DesignSystem.Colors.warning
        case .baseline, .quiet: return DesignSystem.Colors.textMuted
        }
    }

    /// Last 7 calendar days of daily cost, zero-filled, oldest first.
    var last7DayCosts: [Double] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (0..<7).reversed().map { offset -> Double in
            let day = calendar.date(byAdding: .day, value: -offset, to: today)!
            let next = calendar.date(byAdding: .day, value: 1, to: day)!
            return usages
                .filter { $0.startTime >= day && $0.startTime < next }
                .reduce(0) { $0 + $1.cost }
        }
    }

    /// Last 7 calendar days of total tokens per day (for token-mode sparkline).
    var last7DayTokenTotals: [Int] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (0..<7).reversed().map { offset -> Int in
            let day = calendar.date(byAdding: .day, value: -offset, to: today)!
            let next = calendar.date(byAdding: .day, value: 1, to: day)!
            return usages
                .filter { $0.startTime >= day && $0.startTime < next }
                .reduce(0) { $0 + $1.totalTokens }
        }
    }

    /// All-time provider rollups (menu bar, etc.). Dashboard should use `providerSummaries(in:)`
    /// with the same window as the toolbar time picker.
    var providerSummaries: [ProviderSummary] {
        Self.makeProviderSummaries(from: usages)
    }

    /// Provider rollups for sessions whose span overlaps `dateRange`. Pass `nil` for all time.
    func providerSummaries(in dateRange: ClosedRange<Date>?) -> [ProviderSummary] {
        Self.makeProviderSummaries(from: usages(in: dateRange))
    }

    /// Provider rollups for sessions whose span overlaps `dateRange`, including
    /// explicit zero-data entries for every tracked provider. Zero-data
    /// providers (e.g. grokBot, whose parser is an honest no-op) stay reachable
    /// in the usage surface instead of vanishing from the sidebar (VAL-PROV-019).
    /// Data-bearing providers are ranked by cost first; zero-data entries sort
    /// below them, tie-broken by provider name for determinism.
    func providerSummariesIncludingZeroData(in dateRange: ClosedRange<Date>?) -> [ProviderSummary] {
        let withData = Self.makeProviderSummaries(from: usages(in: dateRange))
        var byProvider: [AgentProvider: ProviderSummary] = [:]
        for summary in withData {
            byProvider[summary.provider] = summary
        }
        let zeroData = AgentProvider.allCases.compactMap { provider -> ProviderSummary? in
            guard byProvider[provider] == nil else { return nil }
            return ProviderSummary(
                provider: provider,
                totalCost: 0,
                totalTokens: 0,
                totalInputTokens: 0,
                totalOutputTokens: 0,
                sessionCount: 0,
                modelBreakdown: []
            )
        }
        return (withData + zeroData).sorted {
            if $0.totalCost != $1.totalCost { return $0.totalCost > $1.totalCost }
            return $0.provider.rawValue < $1.provider.rawValue
        }
    }

    private static func makeProviderSummaries(from usages: [TokenUsage]) -> [ProviderSummary] {
        AgentProvider.allCases.compactMap { provider -> ProviderSummary? in
            let providerUsages = usages.filter { $0.provider == provider }
            guard !providerUsages.isEmpty else { return nil }

            let totalCost = providerUsages.reduce(0) { $0 + $1.cost }
            let totalTokens = providerUsages.reduce(0) { $0 + $1.totalTokens }
            let totalInputTokens = providerUsages.reduce(0) { $0 + $1.inputTokens }
            let totalOutputTokens = providerUsages.reduce(0) { $0 + $1.outputTokens }

            var modelData: [String: (input: Int, output: Int, cacheCreation: Int, cacheRead: Int, cost: Double)] = [:]
            for usage in providerUsages {
                let existing = modelData[usage.model] ?? (0, 0, 0, 0, 0)
                modelData[usage.model] = (
                    existing.0 + usage.inputTokens,
                    existing.1 + usage.outputTokens,
                    existing.2 + usage.cacheCreationTokens,
                    existing.3 + usage.cacheReadTokens,
                    existing.4 + usage.cost
                )
            }

            let modelBreakdown = modelData.map { modelName, data in
                let totalModelTokens = data.input + data.output + data.cacheCreation + data.cacheRead
                return ModelUsage(
                    modelName: modelName,
                    inputTokens: data.input,
                    outputTokens: data.output,
                    cacheCreationTokens: data.cacheCreation,
                    cacheReadTokens: data.cacheRead,
                    totalTokens: totalModelTokens,
                    cost: data.cost,
                    percentage: totalCost > 0 ? (data.cost / totalCost) * 100 : 0
                )
            }.sorted { $0.cost > $1.cost }

            return ProviderSummary(
                provider: provider,
                totalCost: totalCost,
                totalTokens: totalTokens,
                totalInputTokens: totalInputTokens,
                totalOutputTokens: totalOutputTokens,
                sessionCount: providerUsages.count,
                modelBreakdown: modelBreakdown
            )
        }.sorted { $0.totalCost > $1.totalCost }
    }

    // MARK: - Model Summaries

    var modelSummaries: [ModelSummary] {
        Self.makeModelSummaries(from: usages)
    }

    func modelSummaries(in dateRange: ClosedRange<Date>?) -> [ModelSummary] {
        Self.makeModelSummaries(from: usages(in: dateRange))
    }

    private static func makeModelSummaries(from usages: [TokenUsage]) -> [ModelSummary] {
        let grouped = Dictionary(grouping: usages) {
            TokenExtractionUtility.normalizeModelKey($0.model)
        }
        return grouped.compactMap { key, modelUsages -> ModelSummary? in
            guard !modelUsages.isEmpty else { return nil }
            let totalCost = modelUsages.reduce(0) { $0 + $1.cost }
            let totalTokens = modelUsages.reduce(0) { $0 + $1.totalTokens }
            let totalInputTokens = modelUsages.reduce(0) { $0 + $1.inputTokens }
            let totalOutputTokens = modelUsages.reduce(0) { $0 + $1.outputTokens }

            let byProvider = Dictionary(grouping: modelUsages) { $0.provider }
            let providerBreakdown = byProvider.map { provider, pUsages -> ProviderUsage in
                let pCost = pUsages.reduce(0) { $0 + $1.cost }
                let pTokens = pUsages.reduce(0) { $0 + $1.totalTokens }
                return ProviderUsage(
                    provider: provider,
                    sessionCount: pUsages.count,
                    totalTokens: pTokens,
                    cost: pCost,
                    percentage: totalCost > 0 ? (pCost / totalCost) * 100 : 0
                )
            }.sorted { $0.cost > $1.cost }

            return ModelSummary(
                modelName: key,
                displayName: TokenExtractionUtility.displayNameForModel(modelUsages.first?.model ?? key),
                totalCost: totalCost,
                totalTokens: totalTokens,
                totalInputTokens: totalInputTokens,
                totalOutputTokens: totalOutputTokens,
                sessionCount: modelUsages.count,
                providerBreakdown: providerBreakdown
            )
        }.sorted { $0.totalCost > $1.totalCost }
    }

    /// Sessions overlapping `dateRange`. `nil` means no time filter (all stored sessions).
    func usages(in dateRange: ClosedRange<Date>?) -> [TokenUsage] {
        guard let dateRange else { return usages }
        return usages.filter { $0.intersects(dateRange: dateRange) }
    }

    func usages(forModel normalizedName: String) -> [TokenUsage] {
        usages.filter { TokenExtractionUtility.normalizeModelKey($0.model) == normalizedName }
    }

    func usages(forModel normalizedName: String, in dateRange: ClosedRange<Date>) -> [TokenUsage] {
        usages.filter {
            TokenExtractionUtility.normalizeModelKey($0.model) == normalizedName
            && $0.intersects(dateRange: dateRange)
        }
    }

    var dailySummaries: [DailyUsageSummary] {
        let calendar = Calendar.current
        var dayData: [Date: [TokenUsage]] = [:]
        
        for usage in usages {
            let dayKey = calendar.startOfDay(for: usage.startTime)
            dayData[dayKey, default: []].append(usage)
        }
        
        return dayData.map { date, usages in
            DailyUsageSummary(
                date: date,
                provider: usages.first?.provider ?? .factory,
                totalInputTokens: usages.reduce(0) { $0 + $1.inputTokens },
                totalOutputTokens: usages.reduce(0) { $0 + $1.outputTokens },
                totalCacheCreationTokens: usages.reduce(0) { $0 + $1.cacheCreationTokens },
                totalCacheReadTokens: usages.reduce(0) { $0 + $1.cacheReadTokens },
                totalTokens: usages.reduce(0) { $0 + $1.totalTokens },
                totalCost: usages.reduce(0) { $0 + $1.cost },
                sessionCount: usages.count,
                models: Array(Set(usages.map { $0.model }))
            )
        }.sorted { $0.date > $1.date }
    }
    
    // MARK: - Initialization

    convenience init() {
        let appDir = try! BurnBarMigration.prepareSupportDirectory()
        let dbPath = appDir.appendingPathComponent(BurnBarIdentity.databaseFileName).path
        let queue = try! DatabaseQueue(path: dbPath)
        try! self.init(databaseQueue: queue)
    }

    init(
        databaseQueue: DatabaseQueue,
        runMigrations: Bool = true,
        refreshOnInit: Bool = true
    ) throws {
        dbQueue = databaseQueue
        localSearchStore = LocalSearchStore(dbQueue: databaseQueue)

        if runMigrations {
            try migrator.migrate(databaseQueue)
        }

        if refreshOnInit {
            refresh()
        }
    }
    
    // MARK: - Database Schema
    
    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_initial") { db in
            try db.create(table: "token_usage") { t in
                t.column("id", .text).primaryKey()
                t.column("provider", .text).notNull().indexed()
                t.column("sessionId", .text).notNull().indexed()
                t.column("projectName", .text).notNull()
                t.column("model", .text).notNull()
                t.column("inputTokens", .integer).notNull()
                t.column("outputTokens", .integer).notNull()
                t.column("cacheCreationTokens", .integer).notNull()
                t.column("cacheReadTokens", .integer).notNull()
                t.column("totalTokens", .integer).notNull()
                t.column("cost", .double).notNull()
                t.column("startTime", .datetime).notNull().indexed()
                t.column("endTime", .datetime).notNull()
                t.column("createdAt", .datetime).notNull()
            }
        }

        migrator.registerMigration("v2_sync") { db in
            try db.alter(table: "token_usage") { t in
                t.add(column: "syncedAt", .datetime)
            }
        }

        migrator.registerMigration("v3_conversations") { db in
            try db.create(table: "conversations") { t in
                t.column("id", .text).primaryKey()
                t.column("provider", .text).notNull().indexed()
                t.column("sessionId", .text).notNull().indexed()
                t.column("projectName", .text).notNull()
                t.column("startTime", .datetime)
                t.column("endTime", .datetime)
                t.column("messageCount", .integer).notNull().defaults(to: 0)
                t.column("userWordCount", .integer).notNull().defaults(to: 0)
                t.column("assistantWordCount", .integer).notNull().defaults(to: 0)
                t.column("keyFiles", .text)
                t.column("keyCommands", .text)
                t.column("keyTools", .text)
                t.column("inferredTaskTitle", .text).notNull().defaults(to: "")
                t.column("lastAssistantMessage", .text).notNull().defaults(to: "")
                t.column("fullText", .text).notNull().defaults(to: "")
                t.column("indexedAt", .datetime).notNull()
                t.column("fileModifiedAt", .datetime)
            }

            try db.create(table: "chat_messages") { t in
                t.column("id", .text).primaryKey()
                t.column("role", .text).notNull()
                t.column("content", .text).notNull()
                t.column("timestamp", .datetime).notNull()
                t.column("cliUsed", .text)
            }

            try db.execute(
                sql: """
                CREATE VIRTUAL TABLE conversations_fts USING fts5(
                    inferredTaskTitle,
                    fullText,
                    content='conversations',
                    content_rowid='rowid',
                    tokenize='porter unicode61'
                )
                """
            )
        }

        migrator.registerMigration("v4_summaries") { db in
            try db.alter(table: "conversations") { t in
                t.add(column: "summary", .text)
            }
        }

        /// Rebuild FTS index from `conversations` so MATCH/snippet queries work. External-content
        /// FTS5 is normally updated automatically on DML; a rebuild fixes empty or stale indexes
        /// (e.g. after upgrades or if the shadow table was not populated).
        migrator.registerMigration("v5_fts_rebuild") { db in
            try db.execute(
                sql: "INSERT INTO conversations_fts(conversations_fts) VALUES('rebuild')"
            )
        }

        /// Replace external-content FTS with a standalone FTS5 table + triggers so the index
        /// is always updated on DML (external-content auto-sync is unreliable with some SQLite builds).
        migrator.registerMigration("v6_fts_standalone_triggers") { db in
            try db.execute(sql: "DROP TRIGGER IF EXISTS conversations_ai")
            try db.execute(sql: "DROP TRIGGER IF EXISTS conversations_ad")
            try db.execute(sql: "DROP TRIGGER IF EXISTS conversations_au")
            try db.execute(sql: "DROP TABLE IF EXISTS conversations_fts")

            try db.execute(
                sql: """
                CREATE VIRTUAL TABLE conversations_fts USING fts5(
                    inferredTaskTitle,
                    fullText,
                    tokenize='porter unicode61'
                )
                """
            )

            try db.execute(
                sql: """
                INSERT INTO conversations_fts(rowid, inferredTaskTitle, fullText)
                SELECT rowid, inferredTaskTitle, fullText FROM conversations
                """
            )

            try db.execute(
                sql: """
                CREATE TRIGGER conversations_ai AFTER INSERT ON conversations BEGIN
                    INSERT INTO conversations_fts(rowid, inferredTaskTitle, fullText)
                    VALUES (new.rowid, new.inferredTaskTitle, new.fullText);
                END
                """
            )
            try db.execute(
                sql: """
                CREATE TRIGGER conversations_ad AFTER DELETE ON conversations BEGIN
                    DELETE FROM conversations_fts WHERE rowid = old.rowid;
                END
                """
            )
            try db.execute(
                sql: """
                CREATE TRIGGER conversations_au AFTER UPDATE ON conversations BEGIN
                    DELETE FROM conversations_fts WHERE rowid = old.rowid;
                    INSERT INTO conversations_fts(rowid, inferredTaskTitle, fullText)
                    VALUES (new.rowid, new.inferredTaskTitle, new.fullText);
                END
                """
            )
        }

        migrator.registerMigration("v7_conversation_cloud_sync") { db in
            try db.alter(table: "conversations") { t in
                t.add(column: "conversationSyncedAt", .datetime)
            }
        }

        migrator.registerMigration("v8_chat_transcript_pieces") { db in
            try db.alter(table: "chat_messages") { t in
                t.add(column: "transcriptPiecesJSON", .text)
            }
        }

        /// Discriminates provider-log conversations from the in-app CLI assistant thread.
        migrator.registerMigration("v9_source_type") { db in
            try db.alter(table: "conversations") { t in
                t.add(column: "sourceType", .text).notNull().defaults(to: "provider_log")
            }
        }

        /// Independent dirty-flag for full session-log (Markdown) cloud backup.
        migrator.registerMigration("v10_log_synced_at") { db in
            try db.alter(table: "conversations") { t in
                t.add(column: "logSyncedAt", .datetime)
            }
        }

        /// Auto-summary metadata and spend ledger for budget capping.
        migrator.registerMigration("v11_auto_summary_metadata") { db in
            try db.alter(table: "conversations") { t in
                t.add(column: "summaryTitle", .text)
                t.add(column: "summaryUpdatedAt", .datetime)
                t.add(column: "summaryProvider", .text)
                t.add(column: "summaryModel", .text)
            }

            try db.create(table: "summary_runs") { t in
                t.column("id", .text).primaryKey()
                t.column("conversationId", .text).notNull().indexed()
                t.column("provider", .text).notNull()
                t.column("model", .text).notNull()
                t.column("costUSD", .double).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull().indexed()
            }
        }

        /// Prevent duplicate usage rows across repeated scans.
        /// Keep the newest row per (provider, sessionId, model), then enforce uniqueness.
        migrator.registerMigration("v12_token_usage_dedupe_unique_session_model") { db in
            try db.execute(sql: """
                DELETE FROM token_usage
                WHERE rowid NOT IN (
                    SELECT MAX(rowid)
                    FROM token_usage
                    GROUP BY provider, sessionId, model
                )
                """)
            try db.execute(sql: """
                CREATE UNIQUE INDEX IF NOT EXISTS token_usage_unique_session_model_idx
                ON token_usage(provider, sessionId, model)
                """)
        }

        /// Backfill Claude usage timestamps from indexed conversations.
        /// Handles subagent session IDs by collapsing `root/agent-*` to `root`.
        migrator.registerMigration("v13_backfill_claude_usage_timestamps") { db in
            try db.execute(sql: """
                UPDATE token_usage
                SET
                    startTime = COALESCE(
                        (
                            SELECT c.startTime
                            FROM conversations c
                            WHERE c.provider = token_usage.provider
                              AND c.sessionId = CASE
                                  WHEN instr(token_usage.sessionId, '/') > 0
                                  THEN substr(token_usage.sessionId, 1, instr(token_usage.sessionId, '/') - 1)
                                  ELSE token_usage.sessionId
                              END
                            ORDER BY COALESCE(c.endTime, c.startTime, c.indexedAt) DESC
                            LIMIT 1
                        ),
                        token_usage.startTime
                    ),
                    endTime = COALESCE(
                        (
                            SELECT COALESCE(c.endTime, c.startTime)
                            FROM conversations c
                            WHERE c.provider = token_usage.provider
                              AND c.sessionId = CASE
                                  WHEN instr(token_usage.sessionId, '/') > 0
                                  THEN substr(token_usage.sessionId, 1, instr(token_usage.sessionId, '/') - 1)
                                  ELSE token_usage.sessionId
                              END
                            ORDER BY COALESCE(c.endTime, c.startTime, c.indexedAt) DESC
                            LIMIT 1
                        ),
                        token_usage.endTime
                    )
                WHERE token_usage.provider = 'Claude Code'
                """)
        }

        /// Derived local retrieval substrate for hybrid search, projection outbox,
        /// embedding/version lineage, and typed subsystem health.
        migrator.registerMigration("v14_local_search_substrate") { db in
            try db.create(table: "search_documents") { t in
                t.column("id", .text).primaryKey()
                t.column("sourceKind", .text).notNull().indexed()
                t.column("sourceID", .text).notNull()
                t.column("sourceVersionID", .text).notNull().defaults(to: "")
                t.column("provider", .text)
                t.column("projectName", .text)
                t.column("title", .text).notNull()
                t.column("subtitle", .text)
                t.column("bodyPreview", .text)
                t.column("sourceUpdatedAt", .datetime)
                t.column("indexedAt", .datetime).notNull().indexed()
                t.column("contentHash", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(
                index: "search_documents_source_lookup_idx",
                on: "search_documents",
                columns: ["sourceKind", "sourceID", "sourceVersionID"],
                unique: true
            )
            try db.create(
                index: "search_documents_project_provider_idx",
                on: "search_documents",
                columns: ["projectName", "provider", "indexedAt"]
            )

            try db.create(table: "search_chunks") { t in
                t.column("id", .text).primaryKey()
                t.column("documentID", .text)
                    .notNull()
                    .references("search_documents", column: "id", onDelete: .cascade)
                t.column("sourceKind", .text).notNull().indexed()
                t.column("sourceID", .text).notNull()
                t.column("sourceVersionID", .text).notNull().defaults(to: "")
                t.column("ordinal", .integer).notNull()
                t.column("startOffset", .integer).notNull()
                t.column("endOffset", .integer).notNull()
                t.column("messageStartOffset", .integer)
                t.column("messageEndOffset", .integer)
                t.column("sectionPath", .text)
                t.column("text", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(
                index: "search_chunks_unique_document_ordinal_idx",
                on: "search_chunks",
                columns: ["documentID", "ordinal"],
                unique: true
            )
            try db.create(
                index: "search_chunks_document_offset_idx",
                on: "search_chunks",
                columns: ["documentID", "startOffset", "endOffset"]
            )
            try db.create(
                index: "search_chunks_source_lookup_idx",
                on: "search_chunks",
                columns: ["sourceKind", "sourceID", "sourceVersionID"]
            )
            try db.execute(
                sql: """
                CREATE VIRTUAL TABLE search_chunks_fts USING fts5(
                    chunkID UNINDEXED,
                    documentID UNINDEXED,
                    title,
                    chunkText,
                    tokenize='porter unicode61'
                )
                """
            )

            try db.create(table: "projection_jobs") { t in
                t.column("id", .text).primaryKey()
                t.column("jobType", .text).notNull().indexed()
                t.column("sourceKind", .text)
                t.column("sourceID", .text)
                t.column("sourceVersionID", .text).notNull().defaults(to: "")
                t.column("status", .text).notNull().indexed()
                t.column("priority", .integer).notNull().defaults(to: 100)
                t.column("attempts", .integer).notNull().defaults(to: 0)
                t.column("maxAttempts", .integer).notNull().defaults(to: 5)
                t.column("payloadJSON", .text)
                t.column("lastErrorCode", .text)
                t.column("lastErrorMessage", .text)
                t.column("scheduledAt", .datetime).notNull()
                t.column("availableAt", .datetime).notNull().indexed()
                t.column("startedAt", .datetime)
                t.column("completedAt", .datetime)
                t.column("leaseOwner", .text)
                t.column("leaseExpiresAt", .datetime)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(
                index: "projection_jobs_poll_idx",
                on: "projection_jobs",
                columns: ["status", "availableAt", "priority", "createdAt"]
            )
            try db.create(
                index: "projection_jobs_source_lookup_idx",
                on: "projection_jobs",
                columns: ["sourceKind", "sourceID", "sourceVersionID"]
            )

            try db.create(table: "embedding_models") { t in
                t.column("id", .text).primaryKey()
                t.column("provider", .text).notNull()
                t.column("modelName", .text).notNull()
                t.column("dimensions", .integer).notNull()
                t.column("distanceMetric", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(
                index: "embedding_models_provider_model_idx",
                on: "embedding_models",
                columns: ["provider", "modelName"],
                unique: true
            )

            try db.create(table: "embedding_versions") { t in
                t.column("id", .text).primaryKey()
                t.column("modelID", .text)
                    .notNull()
                    .references("embedding_models", column: "id", onDelete: .cascade)
                t.column("versionTag", .text).notNull()
                t.column("chunkerVersion", .text).notNull()
                t.column("normalizationVersion", .text).notNull()
                t.column("promptVersion", .text).notNull()
                t.column("isActive", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(
                index: "embedding_versions_identity_idx",
                on: "embedding_versions",
                columns: ["modelID", "versionTag", "chunkerVersion", "normalizationVersion", "promptVersion"],
                unique: true
            )
            try db.create(
                index: "embedding_versions_active_idx",
                on: "embedding_versions",
                columns: ["modelID", "isActive"]
            )

            try db.create(table: "chunk_embeddings") { t in
                t.column("chunkID", .text)
                    .notNull()
                    .references("search_chunks", column: "id", onDelete: .cascade)
                t.column("embeddingVersionID", .text)
                    .notNull()
                    .references("embedding_versions", column: "id", onDelete: .cascade)
                t.column("vectorBlob", .blob).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.primaryKey(["chunkID", "embeddingVersionID"])
            }
            try db.create(
                index: "chunk_embeddings_version_lookup_idx",
                on: "chunk_embeddings",
                columns: ["embeddingVersionID"]
            )

            try db.create(table: "retrieval_health") { t in
                t.column("subsystem", .text).primaryKey()
                t.column("status", .text).notNull()
                t.column("errorCode", .text)
                t.column("errorMessage", .text)
                t.column("detailsJSON", .text)
                t.column("observedAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
        }

        migrator.registerMigration("v15_source_artifact_registry") { db in
            try db.create(table: "source_artifacts") { t in
                t.column("id", .text).primaryKey()
                t.column("sourceKind", .text).notNull().indexed()
                t.column("canonicalPath", .text).notNull()
                t.column("rootPath", .text).notNull().indexed()
                t.column("relativePath", .text).notNull()
                t.column("provenance", .text).notNull()
                t.column("title", .text).notNull()
                t.column("body", .text).notNull()
                t.column("contentHash", .text).notNull()
                t.column("fileSizeBytes", .integer).notNull().defaults(to: 0)
                t.column("fileModifiedAt", .datetime)
                t.column("status", .text).notNull().defaults(to: SourceArtifactStatus.active.rawValue).indexed()
                t.column("discoveredAt", .datetime).notNull()
                t.column("deletedAt", .datetime)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(
                index: "source_artifacts_canonical_path_idx",
                on: "source_artifacts",
                columns: ["canonicalPath"],
                unique: true
            )
            try db.create(
                index: "source_artifacts_root_relative_idx",
                on: "source_artifacts",
                columns: ["rootPath", "relativePath"],
                unique: true
            )
        }

        migrator.registerMigration("v16_shared_artifact_sync_state") { db in
            try db.create(table: "shared_artifact_sync_state") { t in
                t.column("sourceArtifactID", .text)
                    .primaryKey()
                    .references("source_artifacts", column: "id", onDelete: .cascade)
                t.column("remoteArtifactID", .text).notNull()
                t.column("workspaceID", .text).notNull()
                t.column("teamID", .text).notNull()
                t.column("ownerUserID", .text)
                t.column("revisionID", .text).notNull()
                t.column("remoteContentHash", .text)
                t.column("localContentHashAtSync", .text)
                t.column("remoteUpdatedAt", .datetime)
                t.column("lastPulledAt", .datetime)
                t.column("lastSyncedAt", .datetime)
                t.column("syncStatus", .text).notNull().defaults(to: SharedArtifactSyncStatus.pendingPull.rawValue)
                t.column("lastErrorCode", .text)
                t.column("lastErrorMessage", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(
                index: "shared_artifact_sync_remote_lookup_idx",
                on: "shared_artifact_sync_state",
                columns: ["remoteArtifactID"],
                unique: true
            )
            try db.create(
                index: "shared_artifact_sync_scope_idx",
                on: "shared_artifact_sync_state",
                columns: ["workspaceID", "teamID"]
            )
            try db.create(
                index: "shared_artifact_sync_status_idx",
                on: "shared_artifact_sync_state",
                columns: ["syncStatus"]
            )
        }

        migrator.registerMigration("v17_shared_artifact_permissions_and_audit") { db in
            try db.create(table: "artifact_permissions") { t in
                t.column("sourceArtifactID", .text)
                    .notNull()
                    .references("source_artifacts", column: "id", onDelete: .cascade)
                t.column("workspaceID", .text).notNull()
                t.column("teamID", .text).notNull()
                t.column("principalType", .text).notNull()
                t.column("principalID", .text).notNull()
                t.column("role", .text).notNull()
                t.column("visibility", .text).notNull()
                t.column("canRead", .boolean).notNull().defaults(to: true)
                t.column("canWrite", .boolean).notNull().defaults(to: false)
                t.column("canShare", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.primaryKey(["sourceArtifactID", "principalType", "principalID"])
            }
            try db.create(
                index: "artifact_permissions_principal_lookup_idx",
                on: "artifact_permissions",
                columns: ["workspaceID", "teamID", "principalType", "principalID", "canRead"]
            )
            try db.create(
                index: "artifact_permissions_source_lookup_idx",
                on: "artifact_permissions",
                columns: ["sourceArtifactID", "canRead", "visibility"]
            )

            try db.create(table: "audit_events") { t in
                t.column("id", .text).primaryKey()
                t.column("sourceArtifactID", .text)
                    .references("source_artifacts", column: "id", onDelete: .setNull)
                t.column("remoteArtifactID", .text)
                t.column("workspaceID", .text).notNull()
                t.column("teamID", .text).notNull()
                t.column("actorUserID", .text)
                t.column("actorRole", .text)
                t.column("action", .text).notNull()
                t.column("detailsJSON", .text)
                t.column("occurredAt", .datetime).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(
                index: "audit_events_source_time_idx",
                on: "audit_events",
                columns: ["sourceArtifactID", "occurredAt"]
            )
            try db.create(
                index: "audit_events_scope_time_idx",
                on: "audit_events",
                columns: ["workspaceID", "teamID", "occurredAt"]
            )
            try db.create(
                index: "audit_events_action_time_idx",
                on: "audit_events",
                columns: ["action", "occurredAt"]
            )
        }

        /// Tracks the most recent summary attempt (success or failure) to throttle retries.
        migrator.registerMigration("v18_summary_attempt_tracking") { db in
            try db.alter(table: "conversations") { t in
                t.add(column: "summaryAttemptedAt", .datetime)
            }
        }

        /// Fixes FTS update/delete triggers to use direct rowid deletes for standalone FTS.
        migrator.registerMigration("v19_conversation_fts_trigger_fix") { db in
            try db.execute(sql: "DROP TRIGGER IF EXISTS conversations_ad")
            try db.execute(sql: "DROP TRIGGER IF EXISTS conversations_au")

            try db.execute(
                sql: """
                CREATE TRIGGER conversations_ad AFTER DELETE ON conversations BEGIN
                    DELETE FROM conversations_fts WHERE rowid = old.rowid;
                END
                """
            )
            try db.execute(
                sql: """
                CREATE TRIGGER conversations_au AFTER UPDATE ON conversations BEGIN
                    DELETE FROM conversations_fts WHERE rowid = old.rowid;
                    INSERT INTO conversations_fts(rowid, inferredTaskTitle, fullText)
                    VALUES (new.rowid, new.inferredTaskTitle, new.fullText);
                END
                """
            )
        }

        /// Thread-aware storage for in-app Burn Bar chat history and scoped search.
        migrator.registerMigration("v20_chat_threads") { db in
            try db.create(table: "chat_threads") { t in
                t.column("id", .text).primaryKey()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull().indexed()
            }

            try db.alter(table: "chat_messages") { t in
                t.add(column: "threadId", .text).notNull().defaults(to: Self.legacyChatThreadID)
            }

            try db.create(
                index: "chat_messages_thread_time_idx",
                on: "chat_messages",
                columns: ["threadId", "timestamp"]
            )

            try db.execute(
                sql: """
                INSERT OR IGNORE INTO chat_threads (id, createdAt, updatedAt)
                VALUES (
                    ?,
                    COALESCE((SELECT MIN(timestamp) FROM chat_messages), CURRENT_TIMESTAMP),
                    COALESCE((SELECT MAX(timestamp) FROM chat_messages), CURRENT_TIMESTAMP)
                )
                """,
                arguments: [Self.legacyChatThreadID]
            )
        }

        /// Multi-field FTS5 for enhanced lexical retrieval:
        /// - Adds projectName and provider columns to the FTS virtual table for field-weighted search
        /// - Creates a separate search_documents_fts for document-level title/bodyPreview matching
        /// - Enables field-boosted queries (title:foo OR projectName:bar OR chunkText:baz)
        migrator.registerMigration("v21_multifield_fts") { db in
            // Step 1: Create new FTS5 table with additional columns
            try db.execute(sql: """
                CREATE VIRTUAL TABLE search_chunks_fts_new USING fts5(
                    chunkID UNINDEXED,
                    documentID UNINDEXED,
                    title,
                    chunkText,
                    projectName,
                    provider,
                    tokenize='porter unicode61'
                )
                """)

            // Step 2: Migrate data from old FTS to new FTS
            try db.execute(sql: """
                INSERT INTO search_chunks_fts_new (chunkID, documentID, title, chunkText, projectName, provider)
                SELECT
                    scf.chunkID,
                    scf.documentID,
                    COALESCE(scf.title, ''),
                    COALESCE(scf.chunkText, ''),
                    COALESCE(d.projectName, ''),
                    COALESCE(d.provider, '')
                FROM search_chunks_fts scf
                JOIN search_documents d ON d.id = scf.documentID
                """)

            // Step 3: Drop old FTS table and rename new one
            try db.execute(sql: "DROP TABLE search_chunks_fts")
            try db.execute(sql: "ALTER TABLE search_chunks_fts_new RENAME TO search_chunks_fts")

            // Step 4: Create document-level FTS for title/bodyPreview matching
            try db.execute(sql: """
                CREATE VIRTUAL TABLE search_documents_fts USING fts5(
                    documentID UNINDEXED,
                    title,
                    subtitle,
                    bodyPreview,
                    projectName,
                    provider,
                    tokenize='porter unicode61'
                )
                """)

            // Step 5: Populate document FTS from search_documents
            try db.execute(sql: """
                INSERT INTO search_documents_fts (documentID, title, subtitle, bodyPreview, projectName, provider)
                SELECT
                    id,
                    COALESCE(title, ''),
                    COALESCE(subtitle, ''),
                    COALESCE(bodyPreview, ''),
                    COALESCE(projectName, ''),
                    COALESCE(provider, '')
                FROM search_documents
                """)

            // Step 6: Create triggers to keep document FTS in sync
            try db.execute(sql: """
                CREATE TRIGGER search_documents_fts_ai AFTER INSERT ON search_documents BEGIN
                    INSERT INTO search_documents_fts(documentID, title, subtitle, bodyPreview, projectName, provider)
                    VALUES (
                        new.id,
                        COALESCE(new.title, ''),
                        COALESCE(new.subtitle, ''),
                        COALESCE(new.bodyPreview, ''),
                        COALESCE(new.projectName, ''),
                        COALESCE(new.provider, '')
                    );
                END
                """)

            try db.execute(sql: """
                CREATE TRIGGER search_documents_fts_ad AFTER DELETE ON search_documents BEGIN
                    DELETE FROM search_documents_fts WHERE documentID = old.id;
                END
                """)

            try db.execute(sql: """
                CREATE TRIGGER search_documents_fts_au AFTER UPDATE ON search_documents BEGIN
                    DELETE FROM search_documents_fts WHERE documentID = old.id;
                    INSERT INTO search_documents_fts(documentID, title, subtitle, bodyPreview, projectName, provider)
                    VALUES (
                        new.id,
                        COALESCE(new.title, ''),
                        COALESCE(new.subtitle, ''),
                        COALESCE(new.bodyPreview, ''),
                        COALESCE(new.projectName, ''),
                        COALESCE(new.provider, '')
                    );
                END
                """)
        }

        return migrator
    }
    
    // MARK: - CRUD Operations
    
    func insert(_ usage: TokenUsage) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO token_usage (
                        id, provider, sessionId, projectName, model,
                        inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens,
                        totalTokens, cost, startTime, endTime, createdAt
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(provider, sessionId, model) DO UPDATE SET
                        projectName = excluded.projectName,
                        inputTokens = excluded.inputTokens,
                        outputTokens = excluded.outputTokens,
                        cacheCreationTokens = excluded.cacheCreationTokens,
                        cacheReadTokens = excluded.cacheReadTokens,
                        totalTokens = excluded.totalTokens,
                        cost = excluded.cost,
                        startTime = excluded.startTime,
                        endTime = excluded.endTime,
                        createdAt = excluded.createdAt,
                        syncedAt = NULL
                    WHERE
                        token_usage.projectName != excluded.projectName
                        OR token_usage.inputTokens != excluded.inputTokens
                        OR token_usage.outputTokens != excluded.outputTokens
                        OR token_usage.cacheCreationTokens != excluded.cacheCreationTokens
                        OR token_usage.cacheReadTokens != excluded.cacheReadTokens
                        OR token_usage.totalTokens != excluded.totalTokens
                        OR token_usage.cost != excluded.cost
                        OR token_usage.startTime != excluded.startTime
                        OR token_usage.endTime != excluded.endTime
                    """,
                arguments: [
                    usage.id.uuidString,
                    usage.provider.rawValue,
                    usage.sessionId,
                    usage.projectName,
                    usage.model,
                    usage.inputTokens,
                    usage.outputTokens,
                    usage.cacheCreationTokens,
                    usage.cacheReadTokens,
                    usage.totalTokens,
                    usage.cost,
                    usage.startTime,
                    usage.endTime,
                    usage.createdAt
                ]
            )
        }
    }
    
    func insert(_ newUsages: [TokenUsage]) throws {
        for usage in newUsages {
            try insert(usage)
        }
    }
    
    func deleteAll() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM token_usage")
        }
        usages = []
        rollingDailyAverage = 0
    }

    func replaceUsages(_ newUsages: [TokenUsage]) {
        usages = newUsages.sorted { $0.startTime > $1.startTime }
        rollingDailyAverage = computeRollingAverage()
        lastRefresh = Date()
    }

    private func computeRollingAverage() -> Double {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var total: Double = 0
        for dayOffset in 1...7 {
            let day = calendar.date(byAdding: .day, value: -dayOffset, to: today)!
            let nextDay = calendar.date(byAdding: .day, value: 1, to: day)!
            let dayCost = usages
                .filter { $0.startTime >= day && $0.startTime < nextDay }
                .reduce(0) { $0 + $1.cost }
            total += dayCost
        }
        return total / 7
    }
    
    // MARK: - Refresh
    
    func refresh() {
        isLoading = true
        
        do {
            let records = try dbQueue.read { db -> [TokenUsage] in
                let rows = try Row.fetchAll(db, sql: "SELECT * FROM token_usage ORDER BY startTime DESC")
                return rows.compactMap { row -> TokenUsage? in
                    guard let idString = row["id"] as? String,
                          let id = UUID(uuidString: idString),
                          let providerString = row["provider"] as? String,
                          let provider = AgentProvider(rawValue: providerString),
                          let sessionId = row["sessionId"] as? String,
                          let projectName = row["projectName"] as? String,
                          let model = row["model"] as? String else {
                        return nil
                    }

                    let inputTokens = (row["inputTokens"] as? Int) ?? Int(row["inputTokens"] as? Int64 ?? 0)
                    let outputTokens = (row["outputTokens"] as? Int) ?? Int(row["outputTokens"] as? Int64 ?? 0)
                    let cacheCreationTokens = (row["cacheCreationTokens"] as? Int) ?? Int(row["cacheCreationTokens"] as? Int64 ?? 0)
                    let cacheReadTokens = (row["cacheReadTokens"] as? Int) ?? Int(row["cacheReadTokens"] as? Int64 ?? 0)

                    let cost = (row["cost"] as? Double)
                        ?? ((row["cost"] as? NSNumber)?.doubleValue)
                        ?? 0

                    let startTime = parseDate(row["startTime"])
                    let endTime = parseDate(row["endTime"])
                    guard let startTime, let endTime else { return nil }
                    
                    return TokenUsage(
                        id: id,
                        provider: provider,
                        sessionId: sessionId,
                        projectName: projectName,
                        model: model,
                        inputTokens: inputTokens,
                        outputTokens: outputTokens,
                        cacheCreationTokens: cacheCreationTokens,
                        cacheReadTokens: cacheReadTokens,
                        costUSD: cost,
                        startTime: startTime,
                        endTime: endTime
                    )
                }
            }
            replaceUsages(records)
        } catch {
            print("DataStore: Failed to refresh data: \(error)")
        }
        
        isLoading = false
    }

    private func parseDate(_ value: Any?) -> Date? {
        Self.parseDateValue(value)
    }

    private static func parseDateValue(_ value: Any?) -> Date? {
        if let date = value as? Date { return date }
        if let timeInterval = value as? TimeInterval {
            return Date(timeIntervalSince1970: timeInterval)
        }
        if let intValue = value as? Int {
            return Date(timeIntervalSince1970: TimeInterval(intValue))
        }
        if let int64Value = value as? Int64 {
            return Date(timeIntervalSince1970: TimeInterval(int64Value))
        }
        if let number = value as? NSNumber {
            return Date(timeIntervalSince1970: number.doubleValue)
        }
        if let string = value as? String {
            if let parsed = sqliteDateFormatterStatic.date(from: string) { return parsed }
            return ISO8601DateFormatter().date(from: string)
        }
        return nil
    }

    private static let sqliteDateFormatterStatic: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()
    
    // MARK: - Sync Helpers

    func fetchUnsynced() throws -> [TokenUsage] {
        try dbQueue.read { db -> [TokenUsage] in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM token_usage WHERE syncedAt IS NULL ORDER BY startTime ASC LIMIT 400"
            )
            return rows.compactMap { row -> TokenUsage? in
                guard let idString = row["id"] as? String,
                      let id = UUID(uuidString: idString),
                      let providerString = row["provider"] as? String,
                      let provider = AgentProvider(rawValue: providerString),
                      let sessionId = row["sessionId"] as? String,
                      let projectName = row["projectName"] as? String,
                      let model = row["model"] as? String else { return nil }

                let inputTokens = (row["inputTokens"] as? Int) ?? Int(row["inputTokens"] as? Int64 ?? 0)
                let outputTokens = (row["outputTokens"] as? Int) ?? Int(row["outputTokens"] as? Int64 ?? 0)
                let cacheCreationTokens = (row["cacheCreationTokens"] as? Int) ?? Int(row["cacheCreationTokens"] as? Int64 ?? 0)
                let cacheReadTokens = (row["cacheReadTokens"] as? Int) ?? Int(row["cacheReadTokens"] as? Int64 ?? 0)
                let cost = (row["cost"] as? Double) ?? ((row["cost"] as? NSNumber)?.doubleValue) ?? 0
                let startTime = parseDate(row["startTime"])
                let endTime = parseDate(row["endTime"])
                guard let startTime, let endTime else { return nil }

                return TokenUsage(
                    id: id,
                    provider: provider,
                    sessionId: sessionId,
                    projectName: projectName,
                    model: model,
                    inputTokens: inputTokens,
                    outputTokens: outputTokens,
                    cacheCreationTokens: cacheCreationTokens,
                    cacheReadTokens: cacheReadTokens,
                    costUSD: cost,
                    startTime: startTime,
                    endTime: endTime
                )
            }
        }
    }

    func markSynced(ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
        let idStrings: [String] = ids.map { $0.uuidString }
        try dbQueue.write { db in
            // Build arguments: first param is the syncedAt date, rest are UUIDs
            var args = StatementArguments([Date()])
            args += StatementArguments(idStrings)
            try db.execute(
                sql: "UPDATE token_usage SET syncedAt = ? WHERE id IN (\(placeholders))",
                arguments: args
            )
        }
    }

    /// Conversations whose metadata has not been uploaded to Firestore (or changed since last upload).
    func fetchUnsyncedConversations(limit: Int = 400) throws -> [ConversationRecord] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM conversations
                WHERE conversationSyncedAt IS NULL
                ORDER BY COALESCE(endTime, startTime) ASC
                LIMIT ?
                """,
                arguments: [limit]
            )
            return rows.compactMap { Self.conversation(from: $0) }
        }
    }

    func markConversationsSynced(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
        try dbQueue.write { db in
            var args = StatementArguments([Date()])
            args += StatementArguments(ids)
            try db.execute(
                sql: "UPDATE conversations SET conversationSyncedAt = ? WHERE id IN (\(placeholders))",
                arguments: args
            )
        }
    }

    // MARK: - Query Helpers
    
    func usages(for provider: AgentProvider) -> [TokenUsage] {
        usages.filter { $0.provider == provider }
    }
    
    func usages(for provider: AgentProvider, in dateRange: ClosedRange<Date>) -> [TokenUsage] {
        usages.filter { $0.provider == provider && $0.intersects(dateRange: dateRange) }
    }
    
    func topProviderToday() -> (provider: AgentProvider, cost: Double)? {
        let calendar = Calendar.current
        let todayUsages = usages.filter { calendar.isDateInToday($0.startTime) }
        
        var costs: [AgentProvider: Double] = [:]
        for usage in todayUsages {
            costs[usage.provider, default: 0] += usage.cost
        }
        
        return costs.max { $0.value < $1.value }.map { ($0.key, $0.value) }
    }

    // MARK: - Conversations (indexed)

    func upsertConversation(_ record: ConversationRecord) throws {
        let keyFilesJSON = try Self.encodeJSON(record.keyFiles)
        let keyCommandsJSON = try Self.encodeJSON(record.keyCommands)
        let keyToolsJSON = try Self.encodeJSON(record.keyTools)

        try dbQueue.write { db in
            let existing = try Self.fetchConversationRow(db, id: record.id)
            let priorSyncedAt: Date? = try Date.fetchOne(
                db,
                sql: "SELECT conversationSyncedAt FROM conversations WHERE id = ?",
                arguments: [record.id]
            )
            let priorLogSyncedAt: Date? = try Date.fetchOne(
                db,
                sql: "SELECT logSyncedAt FROM conversations WHERE id = ?",
                arguments: [record.id]
            )

            var summaryOut = record.summary
            if summaryOut == nil {
                summaryOut = try String.fetchOne(db, sql: "SELECT summary FROM conversations WHERE id = ?", arguments: [record.id])
            }
            var summaryTitleOut = record.summaryTitle
            if summaryTitleOut == nil {
                summaryTitleOut = try String.fetchOne(db, sql: "SELECT summaryTitle FROM conversations WHERE id = ?", arguments: [record.id])
            }
            var summaryUpdatedAtOut = record.summaryUpdatedAt
            if summaryUpdatedAtOut == nil {
                summaryUpdatedAtOut = try Date.fetchOne(db, sql: "SELECT summaryUpdatedAt FROM conversations WHERE id = ?", arguments: [record.id])
            }
            var summaryAttemptedAtOut: Date? = try Date.fetchOne(
                db,
                sql: "SELECT summaryAttemptedAt FROM conversations WHERE id = ?",
                arguments: [record.id]
            )
            if summaryUpdatedAtOut != nil, summaryAttemptedAtOut == nil {
                summaryAttemptedAtOut = summaryUpdatedAtOut
            }
            var summaryProviderOut = record.summaryProvider
            if summaryProviderOut == nil {
                summaryProviderOut = try String.fetchOne(db, sql: "SELECT summaryProvider FROM conversations WHERE id = ?", arguments: [record.id])
            }
            var summaryModelOut = record.summaryModel
            if summaryModelOut == nil {
                summaryModelOut = try String.fetchOne(db, sql: "SELECT summaryModel FROM conversations WHERE id = ?", arguments: [record.id])
            }

            let preserve = existing.map {
                Self.shouldPreserveConversationSyncedAt(
                    existing: $0,
                    incoming: record,
                    resolvedSummary: summaryOut,
                    resolvedSummaryTitle: summaryTitleOut,
                    resolvedSummaryUpdatedAt: summaryUpdatedAtOut,
                    resolvedSummaryProvider: summaryProviderOut,
                    resolvedSummaryModel: summaryModelOut
                )
            } ?? false

            let conversationSyncedAt: Date? = preserve ? priorSyncedAt : nil
            let logSyncedAt: Date? = preserve ? priorLogSyncedAt : nil

            try db.execute(
                sql: """
                INSERT OR REPLACE INTO conversations (
                    id, provider, sessionId, projectName, startTime, endTime,
                    messageCount, userWordCount, assistantWordCount,
                    keyFiles, keyCommands, keyTools,
                    inferredTaskTitle, lastAssistantMessage, fullText,
                    indexedAt, fileModifiedAt, summary, conversationSyncedAt,
                    sourceType, logSyncedAt, summaryTitle, summaryUpdatedAt, summaryAttemptedAt,
                    summaryProvider, summaryModel
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    record.id,
                    record.provider.rawValue,
                    record.sessionId,
                    record.projectName,
                    record.startTime,
                    record.endTime,
                    record.messageCount,
                    record.userWordCount,
                    record.assistantWordCount,
                    keyFilesJSON,
                    keyCommandsJSON,
                    keyToolsJSON,
                    record.inferredTaskTitle,
                    record.lastAssistantMessage,
                    record.fullText,
                    record.indexedAt,
                    record.fileModifiedAt,
                    summaryOut,
                    conversationSyncedAt,
                    record.sourceType.rawValue,
                    logSyncedAt,
                    summaryTitleOut,
                    summaryUpdatedAtOut,
                    summaryAttemptedAtOut,
                    summaryProviderOut,
                    summaryModelOut
                ]
            )
        }
    }

    func fileModifiedAtForConversation(id: String) throws -> Date? {
        try dbQueue.read { db in
            try Date.fetchOne(
                db,
                sql: "SELECT fileModifiedAt FROM conversations WHERE id = ?",
                arguments: [id]
            )
        }
    }

    func fetchConversation(id: String) throws -> ConversationRecord? {
        try dbQueue.read { db in
            try Self.fetchConversationRow(db, id: id)
        }
    }

    func fetchConversations(limit: Int = 500) throws -> [ConversationRecord] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM conversations ORDER BY COALESCE(endTime, startTime, indexedAt) DESC LIMIT ?",
                arguments: [limit]
            )
            return rows.compactMap { Self.conversation(from: $0) }
        }
    }

    func updateConversationSummary(
        id: String,
        title: String?,
        summary: String?,
        provider: String?,
        model: String?,
        updatedAt: Date = Date(),
        runCostUSD: Double = 0
    ) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE conversations
                SET summary = ?, summaryTitle = ?, summaryUpdatedAt = ?, summaryAttemptedAt = ?, summaryProvider = ?, summaryModel = ?,
                    indexedAt = ?, conversationSyncedAt = NULL, logSyncedAt = NULL
                WHERE id = ?
                """,
                arguments: [summary, title, updatedAt, updatedAt, provider, model, updatedAt, id]
            )

            try db.execute(
                sql: """
                INSERT INTO summary_runs (id, conversationId, provider, model, costUSD, createdAt)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    UUID().uuidString,
                    id,
                    provider ?? "unknown",
                    model ?? "unknown",
                    max(runCostUSD, 0),
                    updatedAt
                ]
            )
        }

        try enqueueConversationProjectionJob(conversationID: id, jobType: .reproject)
    }

    /// Records a failed summary attempt to throttle repeated retries for unchanged rows.
    func markConversationSummaryAttempt(id: String, attemptedAt: Date = Date()) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE conversations
                SET summaryAttemptedAt = ?
                WHERE id = ?
                """,
                arguments: [attemptedAt, id]
            )
        }
    }

    /// Candidate conversations for auto-summarization.
    /// - Missing summary/title metadata OR stale summary relative to latest indexed content.
    /// - Failed attempts are throttled by `retryCooldown` unless content changed since attempt.
    func fetchConversationsNeedingSummary(
        limit: Int = 25,
        now: Date = Date(),
        retryCooldown: TimeInterval = 60 * 60
    ) throws -> [ConversationRecord] {
        let cutoff = now.addingTimeInterval(-max(retryCooldown, 0))
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM conversations
                WHERE fullText <> ''
                AND (
                    summary IS NULL
                    OR summaryTitle IS NULL
                    OR summaryUpdatedAt IS NULL
                    OR summaryUpdatedAt < indexedAt
                )
                AND (
                    summaryAttemptedAt IS NULL
                    OR summaryAttemptedAt <= ?
                    OR indexedAt > summaryAttemptedAt
                )
                ORDER BY COALESCE(endTime, startTime, indexedAt) DESC
                LIMIT ?
                """,
                arguments: [cutoff, limit]
            )
            return rows.compactMap { Self.conversation(from: $0) }
        }
    }

    /// Sum of cloud summary cost (USD) for today's local day.
    func summarySpendToday(now: Date = Date()) throws -> Double {
        try dbQueue.read { db in
            let calendar = Calendar.current
            let start = calendar.startOfDay(for: now)
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? now
            return try Double.fetchOne(
                db,
                sql: """
                SELECT COALESCE(SUM(costUSD), 0)
                FROM summary_runs
                WHERE createdAt >= ? AND createdAt < ?
                """,
                arguments: [start, end]
            ) ?? 0
        }
    }

    func deleteAllIndexedConversations() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM conversations")
            try db.execute(sql: "DELETE FROM summary_runs")
        }
    }

    func approximateConversationStorageBytes() throws -> Int64 {
        try dbQueue.read { db in
            let text: Int64 = try Int64.fetchOne(
                db,
                sql: """
                SELECT COALESCE(SUM(LENGTH(fullText)), 0) + COALESCE(SUM(LENGTH(inferredTaskTitle)), 0)
                + COALESCE(SUM(LENGTH(lastAssistantMessage)), 0) FROM conversations
                """
            ) ?? 0
            return text
        }
    }

    // MARK: - Chat messages (persisted)

    func saveChatMessage(_ message: ChatMessageRecord) throws {
        try saveChatMessage(message, threadID: Self.legacyChatThreadID)
    }

    func saveChatMessage(_ message: ChatMessageRecord, threadID: String) throws {
        let piecesJSON: String?
        if message.transcriptPieces.isEmpty {
            piecesJSON = nil
        } else {
            piecesJSON = try Self.encodeTranscriptPieces(message.transcriptPieces)
        }

        try dbQueue.write { db in
            try upsertChatThread(threadID, at: message.timestamp, db: db)
            try db.execute(
                sql: """
                INSERT OR REPLACE INTO chat_messages (id, threadId, role, content, timestamp, cliUsed, transcriptPiecesJSON)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    message.id,
                    threadID,
                    message.role.rawValue,
                    message.content,
                    message.timestamp,
                    message.cliUsed,
                    piecesJSON
                ]
            )
        }
    }

    func createChatThread(id: String = UUID().uuidString, at date: Date = Date()) throws -> String {
        try dbQueue.write { db in
            try upsertChatThread(id, at: date, db: db)
        }
        return id
    }

    func chatThreadExists(id: String) throws -> Bool {
        try dbQueue.read { db in
            let count = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(1) FROM chat_threads WHERE id = ?",
                arguments: [id]
            ) ?? 0
            return count > 0
        }
    }

    func fetchMostRecentChatThreadID() throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(
                db,
                sql: """
                SELECT t.id
                FROM chat_threads t
                LEFT JOIN chat_messages m ON m.threadId = t.id
                GROUP BY t.id, t.createdAt, t.updatedAt
                ORDER BY COALESCE(MAX(m.timestamp), t.updatedAt, t.createdAt) DESC
                LIMIT 1
                """
            )
        }
    }

    func fetchChatThreadSummaries(searchQuery: String = "", limit: Int = 80) throws -> [ChatThreadSummary] {
        let normalizedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return try dbQueue.read { db in
            var sql = """
            SELECT
                t.id AS threadID,
                t.createdAt AS createdAt,
                t.updatedAt AS updatedAt,
                COUNT(m.id) AS messageCount,
                MAX(m.timestamp) AS lastMessageAt,
                (
                    SELECT um.content
                    FROM chat_messages um
                    WHERE um.threadId = t.id
                      AND um.role = 'user'
                      AND TRIM(um.content) != ''
                    ORDER BY um.timestamp ASC
                    LIMIT 1
                ) AS firstUserMessage,
                (
                    SELECT lm.content
                    FROM chat_messages lm
                    WHERE lm.threadId = t.id
                      AND TRIM(lm.content) != ''
                    ORDER BY lm.timestamp DESC
                    LIMIT 1
                ) AS lastMessageContent
            FROM chat_threads t
            LEFT JOIN chat_messages m ON m.threadId = t.id
            """
            var args: [any DatabaseValueConvertible] = []

            if !normalizedQuery.isEmpty {
                sql += """
                 WHERE EXISTS (
                    SELECT 1
                    FROM chat_messages sm
                    WHERE sm.threadId = t.id
                      AND lower(sm.content) LIKE ?
                )
                """
                args.append("%\(normalizedQuery)%")
            }

            sql += """
             GROUP BY t.id, t.createdAt, t.updatedAt
             HAVING COUNT(m.id) > 0
             ORDER BY COALESCE(MAX(m.timestamp), t.updatedAt, t.createdAt) DESC
             LIMIT ?
            """
            args.append(limit)

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return rows.compactMap { row -> ChatThreadSummary? in
                guard let id = row["threadID"] as? String,
                      let createdAt = parseDate(row["createdAt"]),
                      let updatedAt = parseDate(row["updatedAt"]) else {
                    return nil
                }

                let messageCount = row["messageCount"] as? Int
                    ?? Int((row["messageCount"] as? Int64) ?? 0)
                let lastMessageAt = parseDate(row["lastMessageAt"])
                let firstUserMessage = (row["firstUserMessage"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let lastMessageContent = (row["lastMessageContent"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                let titleSource = (firstUserMessage?.isEmpty == false) ? firstUserMessage! : "Burn Bar Chat"
                let previewSource = (lastMessageContent?.isEmpty == false) ? lastMessageContent! : titleSource

                return ChatThreadSummary(
                    id: id,
                    title: Self.compactChatSnippet(titleSource, limit: 84),
                    preview: Self.compactChatSnippet(previewSource, limit: 180),
                    messageCount: messageCount,
                    createdAt: createdAt,
                    updatedAt: updatedAt,
                    lastMessageAt: lastMessageAt
                )
            }
        }
    }

    func fetchChatMessages() throws -> [ChatMessageRecord] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM chat_messages ORDER BY timestamp ASC")
            return rows.compactMap { self.chatMessage(from: $0) }
        }
    }

    func fetchChatMessages(threadID: String) throws -> [ChatMessageRecord] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM chat_messages WHERE threadId = ? ORDER BY timestamp ASC",
                arguments: [threadID]
            )
            return rows.compactMap { self.chatMessage(from: $0) }
        }
    }

    func deleteAllChatMessages() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM chat_messages")
            try db.execute(sql: "DELETE FROM chat_threads")
            let now = Date()
            try db.execute(
                sql: "INSERT INTO chat_threads (id, createdAt, updatedAt) VALUES (?, ?, ?)",
                arguments: [Self.legacyChatThreadID, now, now]
            )
        }
    }

    private func chatMessage(from row: Row) -> ChatMessageRecord? {
        guard let id = row["id"] as? String,
              let roleRaw = row["role"] as? String,
              let role = ChatMessageRole(rawValue: roleRaw),
              let content = row["content"] as? String,
              let ts = parseDate(row["timestamp"]) else {
            return nil
        }

        let pieces = Self.decodeTranscriptPieces(row["transcriptPiecesJSON"] as? String) ?? []
        return ChatMessageRecord(
            id: id,
            role: role,
            content: content,
            timestamp: ts,
            cliUsed: row["cliUsed"] as? String,
            transcriptPieces: pieces
        )
    }

    private func upsertChatThread(_ threadID: String, at timestamp: Date, db: Database) throws {
        try db.execute(
            sql: """
            INSERT OR IGNORE INTO chat_threads (id, createdAt, updatedAt)
            VALUES (?, ?, ?)
            """,
            arguments: [threadID, timestamp, timestamp]
        )
        try db.execute(
            sql: """
            UPDATE chat_threads
            SET updatedAt = CASE WHEN updatedAt > ? THEN updatedAt ELSE ? END
            WHERE id = ?
            """,
            arguments: [timestamp, timestamp, threadID]
        )
    }

    // MARK: - Full-text search

    func searchConversationsFTS(
        query: String,
        provider: AgentProvider? = nil,
        projectName: String? = nil,
        dateRange: ClosedRange<Date>? = nil
    ) throws -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let ftsQuery = BurnBarFTSQueryBuilder.naturalLanguage(from: trimmed)
        guard !ftsQuery.isEmpty else { return [] }

        return try dbQueue.read { db -> [SearchResult] in
            var sql = """
            SELECT c.*, bm25(conversations_fts) AS rank,
            snippet(conversations_fts, 1, '<b>', '</b>', '…', 10) AS snip
            FROM conversations_fts
            JOIN conversations AS c ON c.rowid = conversations_fts.rowid
            WHERE conversations_fts MATCH ?
            """
            var args: [any DatabaseValueConvertible] = [ftsQuery]

            if let provider {
                sql += " AND c.provider = ?"
                args.append(provider.rawValue)
            }
            if let projectName {
                sql += " AND c.projectName = ?"
                args.append(projectName)
            }
            if let range = dateRange {
                sql += " AND c.startTime >= ? AND c.startTime <= ?"
                args.append(range.lowerBound)
                args.append(range.upperBound)
            }

            sql += " ORDER BY rank ASC LIMIT 50"

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            var results = rows.compactMap { row -> SearchResult? in
                guard let conv = Self.conversation(from: row) else { return nil }
                let rank = (row["rank"] as? Double) ?? Double(row["rank"] as? Int64 ?? 0)
                let snip = (row["snip"] as? String) ?? ""
                return SearchResult(conversation: conv, snippet: snip, rank: rank)
            }

            if results.count < 50 {
                var fallbackSQL = """
                SELECT c.*
                FROM conversations AS c
                WHERE (
                    LOWER(COALESCE(c.summaryTitle, '')) LIKE ?
                    OR LOWER(COALESCE(c.summary, '')) LIKE ?
                )
                """
                var fallbackArgs: [any DatabaseValueConvertible] = [
                    "%\(trimmed.lowercased())%",
                    "%\(trimmed.lowercased())%"
                ]

                if let provider {
                    fallbackSQL += " AND c.provider = ?"
                    fallbackArgs.append(provider.rawValue)
                }
                if let projectName {
                    fallbackSQL += " AND c.projectName = ?"
                    fallbackArgs.append(projectName)
                }
                if let range = dateRange {
                    fallbackSQL += " AND c.startTime >= ? AND c.startTime <= ?"
                    fallbackArgs.append(range.lowerBound)
                    fallbackArgs.append(range.upperBound)
                }

                fallbackSQL += " ORDER BY COALESCE(c.endTime, c.startTime, c.indexedAt) DESC LIMIT 50"
                let fallbackRows = try Row.fetchAll(db, sql: fallbackSQL, arguments: StatementArguments(fallbackArgs))
                var seen = Set(results.map { $0.conversation.id })
                for row in fallbackRows {
                    guard let conv = Self.conversation(from: row), !seen.contains(conv.id) else { continue }
                    seen.insert(conv.id)
                    let fallbackSnippet = conv.summary ?? conv.summaryTitle ?? conv.inferredTaskTitle
                    results.append(
                        SearchResult(
                            conversation: conv,
                            snippet: fallbackSnippet,
                            rank: (results.last?.rank ?? 0) + 100
                        )
                    )
                    if results.count >= 50 { break }
                }
            }

            return results
        }
    }

    // MARK: - Local search substrate (derived/rebuildable)

    func enqueueConversationProjectionJob(
        conversationID: String,
        jobType: ProjectionJobType = .reproject,
        priority: Int = 5,
        now: Date = Date()
    ) throws {
        guard let conversation = try fetchConversation(id: conversationID) else { return }
        let sourceVersionID = ProjectionIdentity.conversationSourceVersionID(for: conversation)
        try enqueueProjectionJob(
            ProjectionJobRecord(
                id: ProjectionIdentity.jobID(
                    jobType: jobType,
                    sourceKind: .conversation,
                    sourceID: conversation.id,
                    sourceVersionID: sourceVersionID
                ),
                jobType: jobType,
                sourceKind: .conversation,
                sourceID: conversation.id,
                sourceVersionID: sourceVersionID,
                status: .queued,
                priority: min(max(priority, 0), 10_000),
                attempts: 0,
                maxAttempts: 5,
                scheduledAt: now,
                availableAt: now,
                createdAt: now,
                updatedAt: now
            )
        )
    }

    func upsertSearchDocument(_ document: SearchDocumentRecord) throws {
        try localSearchStore.upsertDocument(document)
    }

    func fetchSearchDocuments(limit: Int = 500) throws -> [SearchDocumentRecord] {
        try localSearchStore.fetchDocuments(limit: limit)
    }

    func fetchSearchDocuments(
        limit: Int = 500,
        provider: AgentProvider? = nil,
        projectName: String? = nil,
        sourceKinds: [SearchSourceKind]? = nil,
        dateRange: ClosedRange<Date>? = nil
    ) throws -> [SearchDocumentRecord] {
        try localSearchStore.fetchDocuments(
            limit: limit,
            provider: provider?.rawValue,
            projectName: projectName,
            sourceKinds: sourceKinds,
            dateRange: dateRange
        )
    }

    func fetchSearchDocuments(ids: [String]) throws -> [SearchDocumentRecord] {
        try localSearchStore.fetchDocuments(ids: ids)
    }

    func fetchSearchDocument(id: String) throws -> SearchDocumentRecord? {
        try localSearchStore.fetchDocument(id: id)
    }

    func fetchSearchDocuments(sourceKind: SearchSourceKind, sourceID: String) throws -> [SearchDocumentRecord] {
        try localSearchStore.fetchDocuments(sourceKind: sourceKind, sourceID: sourceID)
    }

    func countSearchDocuments(
        provider: AgentProvider? = nil,
        projectName: String? = nil,
        sourceKinds: [SearchSourceKind]? = nil,
        dateRange: ClosedRange<Date>? = nil
    ) throws -> Int {
        try localSearchStore.countDocuments(
            provider: provider?.rawValue,
            projectName: projectName,
            sourceKinds: sourceKinds,
            dateRange: dateRange
        )
    }

    func countSearchChunks(
        sourceKinds: [SearchSourceKind]? = nil,
        dateRange: ClosedRange<Date>? = nil
    ) throws -> Int {
        try localSearchStore.countChunks(
            sourceKinds: sourceKinds,
            dateRange: dateRange
        )
    }

    func countSearchChunks(documentID: String) throws -> Int {
        try localSearchStore.countChunks(documentID: documentID)
    }

    func replaceSearchChunks(documentID: String, title: String, chunks: [SearchChunkRecord]) throws {
        try localSearchStore.replaceChunks(documentID: documentID, title: title, chunks: chunks)
    }

    func fetchSearchChunks(documentID: String) throws -> [SearchChunkRecord] {
        try localSearchStore.fetchChunks(documentID: documentID)
    }

    func fetchSearchChunks(ids: [String]) throws -> [SearchChunkRecord] {
        try localSearchStore.fetchChunks(ids: ids)
    }

    func fetchSearchChunks(sourceKind: SearchSourceKind, sourceID: String) throws -> [SearchChunkRecord] {
        try localSearchStore.fetchChunks(sourceKind: sourceKind, sourceID: sourceID)
    }

    func searchLexicalChunks(
        ftsQuery: String,
        provider: AgentProvider? = nil,
        projectName: String? = nil,
        sourceKinds: [SearchSourceKind]? = nil,
        dateRange: ClosedRange<Date>? = nil,
        visibility: SearchVisibilityScope = .all,
        sharedArtifactAccessContext: SharedArtifactAccessContext? = nil,
        sourceIDs: [String]? = nil,
        limit: Int = 120
    ) throws -> [SearchChunkLexicalMatch] {
        let trimmed = ftsQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        return try localSearchStore.searchLexicalChunks(
            ftsQuery: trimmed,
            provider: provider?.rawValue,
            projectName: projectName,
            sourceKinds: sourceKinds,
            dateRange: dateRange,
            visibility: visibility,
            sharedArtifactAccessContext: sharedArtifactAccessContext,
            sourceIDs: sourceIDs,
            limit: limit
        )
    }

    /// Sums non-overlapping substring occurrence counts of each pattern in `conversations.fullText` (case-insensitive).
    func countOccurrencesInConversationFullText(
        patterns: [String],
        provider: AgentProvider? = nil,
        projectName: String? = nil,
        dateRange: ClosedRange<Date>? = nil,
        conversationSources: Set<ConversationSourceType>? = nil
    ) throws -> Int {
        let cleaned = patterns
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return 0 }

        var total = 0
        for raw in cleaned {
            let pattern = raw.lowercased()
            guard pattern.isEmpty == false else { continue }
            let n = try dbQueue.read { db -> Int in
                var sql = """
                SELECT COALESCE(SUM(
                    (LENGTH(COALESCE(c.fullText,'')) - LENGTH(REPLACE(LOWER(COALESCE(c.fullText,'')), ?, ''))) / LENGTH(?)
                ), 0)
                FROM conversations AS c
                WHERE 1 = 1
                """
                var args: [any DatabaseValueConvertible] = [pattern, pattern, pattern]
                if let provider {
                    sql += " AND c.provider = ?"
                    args.append(provider.rawValue)
                }
                if let projectName {
                    sql += " AND c.projectName = ?"
                    args.append(projectName)
                }
                if let range = dateRange {
                    sql += " AND c.startTime >= ? AND c.startTime <= ?"
                    args.append(range.lowerBound)
                    args.append(range.upperBound)
                }
                if let sources = conversationSources, sources.isEmpty == false {
                    let rawVals = sources.map(\.rawValue)
                    let placeholders = Array(repeating: "?", count: rawVals.count).joined(separator: ", ")
                    sql += " AND c.sourceType IN (\(placeholders))"
                    args.append(contentsOf: rawVals)
                }
                let v = try Int64.fetchOne(db, sql: sql, arguments: StatementArguments(args)) ?? 0
                return Int(v)
            }
            total += n
        }
        return total
    }

    func upsertSourceArtifact(_ artifact: SourceArtifactRecord) throws -> SourceArtifactWriteDisposition {
        try localSearchStore.upsertSourceArtifact(artifact)
    }

    func fetchSourceArtifacts(
        includeDeleted: Bool = false,
        rootPaths: [String]? = nil,
        sourceKinds: [SearchSourceKind] = [.skillDoc, .agentDoc, .sharedArtifact]
    ) throws -> [SourceArtifactRecord] {
        try localSearchStore.fetchSourceArtifacts(
            includeDeleted: includeDeleted,
            rootPaths: rootPaths,
            sourceKinds: sourceKinds
        )
    }

    func countSourceArtifacts(
        includeDeleted: Bool = false,
        rootPaths: [String]? = nil,
        sourceKinds: [SearchSourceKind] = [.skillDoc, .agentDoc, .sharedArtifact]
    ) throws -> Int {
        try localSearchStore.countSourceArtifacts(
            includeDeleted: includeDeleted,
            rootPaths: rootPaths,
            sourceKinds: sourceKinds
        )
    }

    func fetchSourceArtifact(id: String, includeDeleted: Bool = false) throws -> SourceArtifactRecord? {
        try localSearchStore.fetchSourceArtifact(id: id, includeDeleted: includeDeleted)
    }

    @discardableResult
    func markSourceArtifactDeleted(id: String, deletedAt: Date = Date()) throws -> Bool {
        try localSearchStore.markSourceArtifactDeleted(id: id, deletedAt: deletedAt)
    }

    func upsertSharedArtifactSyncState(_ state: SharedArtifactSyncStateRecord) throws {
        try localSearchStore.upsertSharedArtifactSyncState(state)
    }

    func fetchSharedArtifactSyncState(sourceArtifactID: String) throws -> SharedArtifactSyncStateRecord? {
        try localSearchStore.fetchSharedArtifactSyncState(sourceArtifactID: sourceArtifactID)
    }

    func fetchSharedArtifactSyncState(remoteArtifactID: String) throws -> SharedArtifactSyncStateRecord? {
        try localSearchStore.fetchSharedArtifactSyncState(remoteArtifactID: remoteArtifactID)
    }

    func fetchSharedArtifactSyncStates(
        workspaceID: String? = nil,
        teamID: String? = nil,
        statuses: [SharedArtifactSyncStatus]? = nil,
        limit: Int = 500
    ) throws -> [SharedArtifactSyncStateRecord] {
        try localSearchStore.fetchSharedArtifactSyncStates(
            workspaceID: workspaceID,
            teamID: teamID,
            statuses: statuses,
            limit: limit
        )
    }

    func countSharedArtifactSyncStates(
        workspaceID: String? = nil,
        teamID: String? = nil,
        statuses: [SharedArtifactSyncStatus]? = nil
    ) throws -> Int {
        try localSearchStore.countSharedArtifactSyncStates(
            workspaceID: workspaceID,
            teamID: teamID,
            statuses: statuses
        )
    }

    func upsertSharedArtifactPermission(_ permission: SharedArtifactPermissionRecord) throws -> SharedArtifactPermissionWriteDisposition {
        try localSearchStore.upsertSharedArtifactPermission(permission)
    }

    func replaceSharedArtifactPermissions(
        sourceArtifactID: String,
        permissions: [SharedArtifactPermissionRecord]
    ) throws {
        try localSearchStore.replaceSharedArtifactPermissions(
            sourceArtifactID: sourceArtifactID,
            permissions: permissions
        )
    }

    func fetchSharedArtifactPermissions(
        sourceArtifactID: String? = nil,
        workspaceID: String? = nil,
        teamID: String? = nil,
        principalType: SharedArtifactPrincipalType? = nil,
        principalID: String? = nil,
        limit: Int = 500
    ) throws -> [SharedArtifactPermissionRecord] {
        try localSearchStore.fetchSharedArtifactPermissions(
            sourceArtifactID: sourceArtifactID,
            workspaceID: workspaceID,
            teamID: teamID,
            principalType: principalType,
            principalID: principalID,
            limit: limit
        )
    }

    func countSharedArtifactPermissions(
        sourceArtifactID: String? = nil,
        workspaceID: String? = nil,
        teamID: String? = nil,
        principalType: SharedArtifactPrincipalType? = nil,
        principalID: String? = nil
    ) throws -> Int {
        try localSearchStore.countSharedArtifactPermissions(
            sourceArtifactID: sourceArtifactID,
            workspaceID: workspaceID,
            teamID: teamID,
            principalType: principalType,
            principalID: principalID
        )
    }

    func fetchReadableSharedArtifactSourceIDs(
        accessContext: SharedArtifactAccessContext,
        limit: Int = 2_000
    ) throws -> Set<String> {
        Set(
            try localSearchStore.fetchReadableSharedArtifactSourceIDs(
                accessContext: accessContext,
                limit: limit
            )
        )
    }

    func appendSharedArtifactAuditEvent(_ event: SharedArtifactAuditEventRecord) throws {
        try localSearchStore.appendSharedArtifactAuditEvent(event)
    }

    func fetchSharedArtifactAuditEvents(
        sourceArtifactID: String? = nil,
        workspaceID: String? = nil,
        teamID: String? = nil,
        actions: [SharedArtifactAuditAction]? = nil,
        limit: Int = 500
    ) throws -> [SharedArtifactAuditEventRecord] {
        try localSearchStore.fetchSharedArtifactAuditEvents(
            sourceArtifactID: sourceArtifactID,
            workspaceID: workspaceID,
            teamID: teamID,
            actions: actions,
            limit: limit
        )
    }

    func countSharedArtifactAuditEvents(
        sourceArtifactID: String? = nil,
        workspaceID: String? = nil,
        teamID: String? = nil,
        actions: [SharedArtifactAuditAction]? = nil
    ) throws -> Int {
        try localSearchStore.countSharedArtifactAuditEvents(
            sourceArtifactID: sourceArtifactID,
            workspaceID: workspaceID,
            teamID: teamID,
            actions: actions
        )
    }

    func enqueueProjectionJob(_ job: ProjectionJobRecord) throws {
        try localSearchStore.enqueueProjectionJob(job)
    }

    func fetchProjectionJobs(
        statuses: [ProjectionJobStatus] = [.queued, .leased, .running, .failed],
        limit: Int = 100
    ) throws -> [ProjectionJobRecord] {
        try localSearchStore.fetchProjectionJobs(statuses: statuses, limit: limit)
    }

    func countProjectionJobs(statuses: [ProjectionJobStatus]? = nil) throws -> Int {
        try localSearchStore.countProjectionJobs(statuses: statuses)
    }

    func leaseNextProjectionJob(
        leaseOwner: String,
        leaseDuration: TimeInterval,
        now: Date = Date()
    ) throws -> ProjectionJobRecord? {
        try localSearchStore.leaseNextJob(
            leaseOwner: leaseOwner,
            leaseExpiresAt: now.addingTimeInterval(leaseDuration),
            now: now
        )
    }

    func markProjectionJobLeased(
        id: String,
        leaseOwner: String,
        leaseDuration: TimeInterval,
        now: Date = Date()
    ) throws {
        try localSearchStore.markJobLeased(
            id: id,
            leaseOwner: leaseOwner,
            leaseExpiresAt: now.addingTimeInterval(leaseDuration),
            updatedAt: now
        )
    }

    func markProjectionJobCompleted(id: String, completedAt: Date = Date()) throws {
        try localSearchStore.markJobCompleted(id: id, completedAt: completedAt)
    }

    func markProjectionJobFailed(
        id: String,
        errorCode: String?,
        errorMessage: String?,
        retryAt: Date? = nil,
        updatedAt: Date = Date()
    ) throws {
        try localSearchStore.markJobFailed(
            id: id,
            errorCode: errorCode,
            errorMessage: errorMessage,
            retryAt: retryAt,
            updatedAt: updatedAt
        )
    }

    func markProjectionJobCanceled(
        id: String,
        errorCode: String?,
        errorMessage: String?,
        updatedAt: Date = Date()
    ) throws {
        try localSearchStore.markJobCanceled(
            id: id,
            errorCode: errorCode,
            errorMessage: errorMessage,
            updatedAt: updatedAt
        )
    }

    func deleteSearchDocuments(sourceKind: SearchSourceKind, sourceID: String) throws {
        try localSearchStore.deleteDocuments(sourceKind: sourceKind, sourceID: sourceID)
    }

    func upsertEmbeddingModel(_ model: EmbeddingModelRecord) throws {
        try localSearchStore.upsertEmbeddingModel(model)
    }

    func fetchEmbeddingModels() throws -> [EmbeddingModelRecord] {
        try localSearchStore.fetchEmbeddingModels()
    }

    func countEmbeddingModels() throws -> Int {
        try localSearchStore.countEmbeddingModels()
    }

    func upsertEmbeddingVersion(_ version: EmbeddingVersionRecord) throws {
        try localSearchStore.upsertEmbeddingVersion(version)
    }

    func fetchEmbeddingVersions(modelID: String? = nil) throws -> [EmbeddingVersionRecord] {
        try localSearchStore.fetchEmbeddingVersions(modelID: modelID)
    }

    func countEmbeddingVersions(modelID: String? = nil) throws -> Int {
        try localSearchStore.countEmbeddingVersions(modelID: modelID)
    }

    func upsertChunkEmbedding(_ embedding: ChunkEmbeddingRecord) throws {
        try localSearchStore.upsertChunkEmbedding(embedding)
    }

    func fetchChunkEmbeddings(chunkID: String? = nil) throws -> [ChunkEmbeddingRecord] {
        try localSearchStore.fetchChunkEmbeddings(chunkID: chunkID)
    }

    func fetchChunkEmbeddings(embeddingVersionID: String) throws -> [ChunkEmbeddingRecord] {
        try localSearchStore.fetchChunkEmbeddings(embeddingVersionID: embeddingVersionID)
    }

    func countChunkEmbeddings(
        chunkID: String? = nil,
        embeddingVersionID: String? = nil
    ) throws -> Int {
        try localSearchStore.countChunkEmbeddings(
            chunkID: chunkID,
            embeddingVersionID: embeddingVersionID
        )
    }

    func countChunkEmbeddings(
        documentID: String,
        embeddingVersionID: String? = nil
    ) throws -> Int {
        try localSearchStore.countChunkEmbeddings(
            documentID: documentID,
            embeddingVersionID: embeddingVersionID
        )
    }

    func upsertRetrievalHealth(_ health: RetrievalHealthRecord) throws {
        try localSearchStore.upsertRetrievalHealth(health)
    }

    func fetchRetrievalHealth() throws -> [RetrievalHealthRecord] {
        try localSearchStore.fetchRetrievalHealth()
    }

    func localSearchSchemaInventory() throws -> LocalSearchSchemaInventory {
        try localSearchStore.schemaInventory()
    }

    func countConversations() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM conversations"
            ) ?? 0
        }
    }

    // MARK: - Conversation row mapping

    private static func fetchConversationRow(_ db: Database, id: String) throws -> ConversationRecord? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM conversations WHERE id = ?", arguments: [id]) else {
            return nil
        }
        return conversation(from: row)
    }

    private static func conversation(from row: Row) -> ConversationRecord? {
        guard let id = row["id"] as? String,
              let providerRaw = row["provider"] as? String,
              let provider = AgentProvider(rawValue: providerRaw),
              let sessionId = row["sessionId"] as? String,
              let projectName = row["projectName"] as? String else {
            return nil
        }
        let messageCount = (row["messageCount"] as? Int) ?? Int(row["messageCount"] as? Int64 ?? 0)
        let userWordCount = (row["userWordCount"] as? Int) ?? Int(row["userWordCount"] as? Int64 ?? 0)
        let assistantWordCount = (row["assistantWordCount"] as? Int) ?? Int(row["assistantWordCount"] as? Int64 ?? 0)
        let inferredTaskTitle = (row["inferredTaskTitle"] as? String) ?? ""
        let lastAssistantMessage = (row["lastAssistantMessage"] as? String) ?? ""
        let fullText = (row["fullText"] as? String) ?? ""

        let keyFiles = decodeJSONStringArray(row["keyFiles"] as? String)
        let keyCommands = decodeJSONStringArray(row["keyCommands"] as? String)
        let keyTools = decodeJSONStringArray(row["keyTools"] as? String)

        let startTime = Self.parseDateValue(row["startTime"])
        let endTime = Self.parseDateValue(row["endTime"])
        let indexedAt = Self.parseDateValue(row["indexedAt"]) ?? Date()
        let fileModifiedAt = Self.parseDateValue(row["fileModifiedAt"])

        let sourceTypeRaw = (row["sourceType"] as? String) ?? "provider_log"
        let sourceType = ConversationSourceType(rawValue: sourceTypeRaw) ?? .providerLog

        return ConversationRecord(
            id: id,
            provider: provider,
            sessionId: sessionId,
            projectName: projectName,
            startTime: startTime,
            endTime: endTime,
            messageCount: messageCount,
            userWordCount: userWordCount,
            assistantWordCount: assistantWordCount,
            keyFiles: keyFiles,
            keyCommands: keyCommands,
            keyTools: keyTools,
            inferredTaskTitle: inferredTaskTitle,
            lastAssistantMessage: lastAssistantMessage,
            fullText: fullText,
            indexedAt: indexedAt,
            fileModifiedAt: fileModifiedAt,
            summary: row["summary"] as? String,
            summaryTitle: row["summaryTitle"] as? String,
            summaryUpdatedAt: Self.parseDateValue(row["summaryUpdatedAt"]),
            summaryProvider: row["summaryProvider"] as? String,
            summaryModel: row["summaryModel"] as? String,
            sourceType: sourceType
        )
    }

    private static func decodeJSONStringArray(_ string: String?) -> [String] {
        guard let string, !string.isEmpty, let data = string.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return arr
    }

    private static func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private static func encodeTranscriptPieces(_ value: [ChatTranscriptPiece]) throws -> String {
        try encodeJSON(value)
    }

    private static func decodeTranscriptPieces(_ string: String?) -> [ChatTranscriptPiece]? {
        guard let string, !string.isEmpty, let data = string.data(using: .utf8),
              let arr = try? JSONDecoder().decode([ChatTranscriptPiece].self, from: data) else {
            return nil
        }
        return arr
    }

    private static func compactChatSnippet(_ source: String, limit: Int) -> String {
        let compact = source
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard compact.count > limit else { return compact }
        return String(compact.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    // MARK: - Session Logs

    /// All indexed conversations sorted by most-recent first, for the Session Logs center.
    func fetchAllSessionLogs(limit: Int = 1000) throws -> [ConversationRecord] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM conversations ORDER BY COALESCE(endTime, startTime, indexedAt) DESC LIMIT ?",
                arguments: [limit]
            )
            return rows.compactMap { Self.conversation(from: $0) }
        }
    }

    /// Conversations whose full Markdown log has not yet been uploaded to Firestore.
    func fetchUnsyncedSessionLogs(limit: Int = 100) throws -> [ConversationRecord] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM conversations
                WHERE logSyncedAt IS NULL
                ORDER BY COALESCE(endTime, startTime) ASC
                LIMIT ?
                """,
                arguments: [limit]
            )
            return rows.compactMap { Self.conversation(from: $0) }
        }
    }

    func markSessionLogsSynced(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
        try dbQueue.write { db in
            var args = StatementArguments([Date()])
            args += StatementArguments(ids)
            try db.execute(
                sql: "UPDATE conversations SET logSyncedAt = ? WHERE id IN (\(placeholders))",
                arguments: args
            )
        }
    }

    /// Synthesizes a single `cliAssistant` ConversationRecord from persisted chat messages
    /// and upserts it so the Session Logs center and cloud sync treat it like any other session.
    func upsertCLIConversation(from messages: [ChatMessageRecord]) throws {
        guard messages.isEmpty == false else { return }

        let start = messages.first?.timestamp
        let end   = messages.last?.timestamp

        let assistantWords = messages
            .filter { $0.role == .assistant }
            .reduce(0) { $0 + $1.content.split(separator: " ").count }
        let userWords = messages
            .filter { $0.role == .user }
            .reduce(0) { $0 + $1.content.split(separator: " ").count }

        let markdown = SessionLogMarkdownFormatter.cliMarkdown(from: messages)
        let lastAssistant = messages.last(where: { $0.role == .assistant })?.content ?? ""

        let record = ConversationRecord(
            id: ConversationRecord.cliAssistantId,
            provider: .claudeCode,
            sessionId: "cli-assistant-local",
            projectName: "BurnBar",
            startTime: start,
            endTime: end,
            messageCount: messages.count,
            userWordCount: userWords,
            assistantWordCount: assistantWords,
            keyFiles: [],
            keyCommands: [],
            keyTools: [],
            inferredTaskTitle: "BurnBar Assistant",
            lastAssistantMessage: String(lastAssistant.prefix(500)),
            fullText: markdown,
            indexedAt: Date(),
            fileModifiedAt: nil,
            summary: nil,
            sourceType: .cliAssistant
        )
        try upsertConversation(record)

        try enqueueConversationProjectionJob(conversationID: record.id, jobType: .reproject)
    }

    // MARK: - Sync Helpers (private)

    /// Returns true when every synced field is unchanged so the existing sync timestamps can be preserved.
    /// Checking `fullText` ensures transcript changes also reset the full-log dirty flag (`logSyncedAt`).
    private static func shouldPreserveConversationSyncedAt(
        existing: ConversationRecord,
        incoming: ConversationRecord,
        resolvedSummary: String?,
        resolvedSummaryTitle: String?,
        resolvedSummaryUpdatedAt: Date?,
        resolvedSummaryProvider: String?,
        resolvedSummaryModel: String?
    ) -> Bool {
        let coreUnchanged =
            existing.provider == incoming.provider
            && existing.sessionId == incoming.sessionId
            && existing.projectName == incoming.projectName
            && existing.startTime == incoming.startTime
            && existing.endTime == incoming.endTime
            && existing.messageCount == incoming.messageCount
            && existing.userWordCount == incoming.userWordCount
            && existing.assistantWordCount == incoming.assistantWordCount
            && existing.keyFiles == incoming.keyFiles
            && existing.keyCommands == incoming.keyCommands
            && existing.keyTools == incoming.keyTools
            && existing.inferredTaskTitle == incoming.inferredTaskTitle
            && existing.lastAssistantMessage == incoming.lastAssistantMessage
            && existing.fullText == incoming.fullText

        let summaryUnchanged =
            existing.summary == resolvedSummary
            && existing.summaryTitle == resolvedSummaryTitle
            && existing.summaryUpdatedAt == resolvedSummaryUpdatedAt
            && existing.summaryProvider == resolvedSummaryProvider
            && existing.summaryModel == resolvedSummaryModel

        return coreUnchanged && summaryUnchanged
    }

}

// MARK: - Local Search Store

private struct LocalSearchStore {
    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    func upsertDocument(_ document: SearchDocumentRecord) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO search_documents (
                    id, sourceKind, sourceID, sourceVersionID, provider, projectName, title, subtitle,
                    bodyPreview, sourceUpdatedAt, indexedAt, contentHash, createdAt, updatedAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    sourceKind = excluded.sourceKind,
                    sourceID = excluded.sourceID,
                    sourceVersionID = excluded.sourceVersionID,
                    provider = excluded.provider,
                    projectName = excluded.projectName,
                    title = excluded.title,
                    subtitle = excluded.subtitle,
                    bodyPreview = excluded.bodyPreview,
                    sourceUpdatedAt = excluded.sourceUpdatedAt,
                    indexedAt = excluded.indexedAt,
                    contentHash = excluded.contentHash,
                    updatedAt = excluded.updatedAt
                """,
                arguments: [
                    document.id,
                    document.sourceKind.rawValue,
                    document.sourceID,
                    document.sourceVersionID,
                    document.provider,
                    document.projectName,
                    document.title,
                    document.subtitle,
                    document.bodyPreview,
                    document.sourceUpdatedAt,
                    document.indexedAt,
                    document.contentHash,
                    document.createdAt,
                    document.updatedAt
                ]
            )
        }
    }

    func fetchDocuments(limit: Int) throws -> [SearchDocumentRecord] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM search_documents
                ORDER BY indexedAt DESC, createdAt DESC
                LIMIT ?
                """,
                arguments: [limit]
            )
            return rows.compactMap(Self.document(from:))
        }
    }

    func fetchDocuments(
        limit: Int,
        provider: String?,
        projectName: String?,
        sourceKinds: [SearchSourceKind]?,
        dateRange: ClosedRange<Date>?
    ) throws -> [SearchDocumentRecord] {
        let (whereSQL, args) = Self.filteredDocumentClause(
            provider: provider,
            projectName: projectName,
            sourceKinds: sourceKinds,
            dateRange: dateRange
        )
        var queryArgs = args
        queryArgs.append(max(1, limit))

        return try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM search_documents
                \(whereSQL)
                ORDER BY COALESCE(sourceUpdatedAt, indexedAt) DESC, indexedAt DESC, createdAt DESC
                LIMIT ?
                """,
                arguments: StatementArguments(queryArgs)
            )
            return rows.compactMap(Self.document(from:))
        }
    }

    func fetchDocuments(ids: [String]) throws -> [SearchDocumentRecord] {
        let uniqueIDs = Array(Set(ids)).sorted()
        guard uniqueIDs.isEmpty == false else { return [] }

        return try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM search_documents
                WHERE id IN (\(Self.sqlPlaceholders(count: uniqueIDs.count)))
                ORDER BY indexedAt DESC, createdAt DESC
                """,
                arguments: StatementArguments(uniqueIDs)
            )
            return rows.compactMap(Self.document(from:))
        }
    }

    func fetchDocument(id: String) throws -> SearchDocumentRecord? {
        try fetchDocuments(ids: [id]).first
    }

    func fetchDocuments(sourceKind: SearchSourceKind, sourceID: String) throws -> [SearchDocumentRecord] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM search_documents
                WHERE sourceKind = ? AND sourceID = ?
                ORDER BY indexedAt DESC, createdAt DESC
                """,
                arguments: [sourceKind.rawValue, sourceID]
            )
            return rows.compactMap(Self.document(from:))
        }
    }

    func countDocuments(
        provider: String?,
        projectName: String?,
        sourceKinds: [SearchSourceKind]?,
        dateRange: ClosedRange<Date>?
    ) throws -> Int {
        let (whereSQL, args) = Self.filteredDocumentClause(
            provider: provider,
            projectName: projectName,
            sourceKinds: sourceKinds,
            dateRange: dateRange
        )

        return try dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM search_documents
                \(whereSQL)
                """,
                arguments: StatementArguments(args)
            ) ?? 0
        }
    }

    func countChunks(
        sourceKinds: [SearchSourceKind]?,
        dateRange: ClosedRange<Date>?
    ) throws -> Int {
        let normalizedSourceKinds = Array(Set(sourceKinds ?? [])).sorted { $0.rawValue < $1.rawValue }
        var clauses: [String] = []
        var args: [any DatabaseValueConvertible] = []

        if normalizedSourceKinds.isEmpty == false {
            clauses.append("d.sourceKind IN (\(Self.sqlPlaceholders(count: normalizedSourceKinds.count)))")
            args.append(contentsOf: normalizedSourceKinds.map(\.rawValue))
        }

        if let dateRange {
            clauses.append("COALESCE(d.sourceUpdatedAt, d.indexedAt) >= ?")
            clauses.append("COALESCE(d.sourceUpdatedAt, d.indexedAt) <= ?")
            args.append(dateRange.lowerBound)
            args.append(dateRange.upperBound)
        }

        let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        return try dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM search_chunks AS c
                JOIN search_documents AS d ON d.id = c.documentID
                \(whereSQL)
                """,
                arguments: StatementArguments(args)
            ) ?? 0
        }
    }

    func countChunks(documentID: String) throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM search_chunks
                WHERE documentID = ?
                """,
                arguments: [documentID]
            ) ?? 0
        }
    }

    func replaceChunks(documentID: String, title: String, chunks: [SearchChunkRecord]) throws {
        try dbQueue.write { db in
            // Look up the document to get projectName and provider for FTS
            let documentRow = try Row.fetchOne(
                db,
                sql: "SELECT projectName, provider FROM search_documents WHERE id = ?",
                arguments: [documentID]
            )
            let projectName = documentRow?["projectName"] as? String ?? ""
            let provider = documentRow?["provider"] as? String ?? ""

            try db.execute(
                sql: "DELETE FROM search_chunks_fts WHERE documentID = ?",
                arguments: [documentID]
            )
            try db.execute(
                sql: "DELETE FROM search_chunks WHERE documentID = ?",
                arguments: [documentID]
            )

            for chunk in chunks.sorted(by: { $0.ordinal < $1.ordinal }) {
                try db.execute(
                    sql: """
                    INSERT INTO search_chunks (
                        id, documentID, sourceKind, sourceID, sourceVersionID, ordinal,
                        startOffset, endOffset, messageStartOffset, messageEndOffset,
                        sectionPath, text, createdAt, updatedAt
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        chunk.id,
                        chunk.documentID,
                        chunk.sourceKind.rawValue,
                        chunk.sourceID,
                        chunk.sourceVersionID,
                        chunk.ordinal,
                        chunk.startOffset,
                        chunk.endOffset,
                        chunk.messageStartOffset,
                        chunk.messageEndOffset,
                        chunk.sectionPath,
                        chunk.text,
                        chunk.createdAt,
                        chunk.updatedAt
                    ]
                )

                // Insert with new multi-field FTS columns (projectName, provider)
                try db.execute(
                    sql: """
                    INSERT INTO search_chunks_fts (chunkID, documentID, title, chunkText, projectName, provider)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [chunk.id, chunk.documentID, title, chunk.text, projectName, provider]
                )
            }
        }
    }

    func fetchChunks(documentID: String) throws -> [SearchChunkRecord] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM search_chunks
                WHERE documentID = ?
                ORDER BY ordinal ASC
                """,
                arguments: [documentID]
            )
            return rows.compactMap(Self.chunk(from:))
        }
    }

    func fetchChunks(ids: [String]) throws -> [SearchChunkRecord] {
        let uniqueIDs = Array(Set(ids)).sorted()
        guard uniqueIDs.isEmpty == false else { return [] }

        return try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM search_chunks
                WHERE id IN (\(Self.sqlPlaceholders(count: uniqueIDs.count)))
                ORDER BY documentID ASC, ordinal ASC
                """,
                arguments: StatementArguments(uniqueIDs)
            )
            return rows.compactMap(Self.chunk(from:))
        }
    }

    func fetchChunks(sourceKind: SearchSourceKind, sourceID: String) throws -> [SearchChunkRecord] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM search_chunks
                WHERE sourceKind = ? AND sourceID = ?
                ORDER BY documentID ASC, ordinal ASC
                """,
                arguments: [sourceKind.rawValue, sourceID]
            )
            return rows.compactMap(Self.chunk(from:))
        }
    }

    func searchLexicalChunks(
        ftsQuery: String,
        provider: String?,
        projectName: String?,
        sourceKinds: [SearchSourceKind]?,
        dateRange: ClosedRange<Date>?,
        visibility: SearchVisibilityScope,
        sharedArtifactAccessContext: SharedArtifactAccessContext?,
        sourceIDs: [String]?,
        limit: Int
    ) throws -> [SearchChunkLexicalMatch] {
        guard ftsQuery.isEmpty == false, limit > 0 else { return [] }

        let normalizedSourceKinds = Array(Set(sourceKinds ?? [])).sorted { $0.rawValue < $1.rawValue }
        let normalizedSourceIDs = Array(Set((sourceIDs ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
        let normalizedProject = projectName?.trimmingCharacters(in: .whitespacesAndNewlines)

        var clauses: [String] = ["search_chunks_fts MATCH ?"]
        var args: [any DatabaseValueConvertible] = [ftsQuery]

        if let provider, provider.isEmpty == false {
            clauses.append("d.provider = ?")
            args.append(provider)
        }

        if let normalizedProject, normalizedProject.isEmpty == false {
            clauses.append("d.projectName = ?")
            args.append(normalizedProject)
        }

        if normalizedSourceKinds.isEmpty == false {
            clauses.append("d.sourceKind IN (\(Self.sqlPlaceholders(count: normalizedSourceKinds.count)))")
            args.append(contentsOf: normalizedSourceKinds.map(\.rawValue))
        }

        if normalizedSourceIDs.isEmpty == false {
            clauses.append("d.sourceID IN (\(Self.sqlPlaceholders(count: normalizedSourceIDs.count)))")
            args.append(contentsOf: normalizedSourceIDs)
        }

        if let dateRange {
            clauses.append("COALESCE(d.sourceUpdatedAt, d.indexedAt) >= ?")
            clauses.append("COALESCE(d.sourceUpdatedAt, d.indexedAt) <= ?")
            args.append(dateRange.lowerBound)
            args.append(dateRange.upperBound)
        }

        switch visibility {
        case .all:
            break
        case .personalOnly:
            clauses.append("d.sourceKind != ?")
            args.append(SearchSourceKind.sharedArtifact.rawValue)
        case .sharedOnly:
            clauses.append("d.sourceKind = ?")
            args.append(SearchSourceKind.sharedArtifact.rawValue)
        }

        if visibility != .personalOnly {
            if let access = sharedArtifactAccessContext {
                clauses.append(
                    """
                    (
                        d.sourceKind != ?
                        OR EXISTS (
                            SELECT 1
                            FROM artifact_permissions AS ap
                            WHERE ap.sourceArtifactID = d.sourceID
                              AND ap.canRead = 1
                              AND ap.workspaceID = ?
                              AND (
                                  (ap.principalType = ? AND ap.principalID = ?)
                                  OR (ap.principalType = ? AND ap.principalID = ? AND ap.teamID = ?)
                                  OR (ap.principalType = ? AND ap.principalID = ?)
                              )
                        )
                        OR EXISTS (
                            SELECT 1
                            FROM shared_artifact_sync_state AS sas
                            WHERE sas.sourceArtifactID = d.sourceID
                              AND sas.workspaceID = ?
                              AND sas.teamID = ?
                              AND sas.ownerUserID = ?
                        )
                    )
                    """
                )
                args.append(SearchSourceKind.sharedArtifact.rawValue)
                args.append(access.workspaceID)
                args.append(SharedArtifactPrincipalType.user.rawValue)
                args.append(access.userID)
                args.append(SharedArtifactPrincipalType.team.rawValue)
                args.append(access.teamID)
                args.append(access.teamID)
                args.append(SharedArtifactPrincipalType.workspace.rawValue)
                args.append(access.workspaceID)
                args.append(access.workspaceID)
                args.append(access.teamID)
                args.append(access.userID)
            } else {
                clauses.append("d.sourceKind != ?")
                args.append(SearchSourceKind.sharedArtifact.rawValue)
            }
        }

        let whereSQL = clauses.joined(separator: " AND ")
        args.append(limit)

        return try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT
                    search_chunks_fts.chunkID AS chunkID,
                    search_chunks_fts.documentID AS documentID,
                    bm25(search_chunks_fts) AS lexicalRank,
                    snippet(search_chunks_fts, 3, '<b>', '</b>', '…', 16) AS snippet,
                    d.sourceKind AS sourceKind,
                    d.sourceID AS sourceID,
                    d.sourceVersionID AS sourceVersionID,
                    d.provider AS provider,
                    d.projectName AS projectName,
                    d.title AS title,
                    d.subtitle AS subtitle,
                    d.bodyPreview AS bodyPreview,
                    d.sourceUpdatedAt AS sourceUpdatedAt,
                    d.indexedAt AS indexedAt,
                    c.ordinal AS chunkOrdinal,
                    c.startOffset AS startOffset,
                    c.endOffset AS endOffset,
                    c.sectionPath AS sectionPath,
                    c.text AS chunkText
                FROM search_chunks_fts
                JOIN search_chunks AS c ON c.id = search_chunks_fts.chunkID
                JOIN search_documents AS d ON d.id = search_chunks_fts.documentID
                WHERE \(whereSQL)
                ORDER BY lexicalRank ASC, d.indexedAt DESC, c.ordinal ASC
                LIMIT ?
                """,
                arguments: StatementArguments(args)
            )
            return rows.compactMap(Self.lexicalMatch(from:))
        }
    }

    func upsertSourceArtifact(_ artifact: SourceArtifactRecord) throws -> SourceArtifactWriteDisposition {
        guard artifact.sourceKind != .conversation else {
            throw NSError(
                domain: "DataStore.SourceArtifact",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "source_artifacts cannot store conversation sourceKind"]
            )
        }

        return try dbQueue.write { db in
            let existingRow = try Row.fetchOne(
                db,
                sql: "SELECT * FROM source_artifacts WHERE id = ?",
                arguments: [artifact.id]
            )
            let existing = existingRow.flatMap(Self.sourceArtifact(from:))
            let disposition: SourceArtifactWriteDisposition

            if let existing {
                let isUnchanged =
                    existing.status == .active
                    && existing.sourceKind == artifact.sourceKind
                    && existing.canonicalPath == artifact.canonicalPath
                    && existing.rootPath == artifact.rootPath
                    && existing.relativePath == artifact.relativePath
                    && existing.provenance == artifact.provenance
                    && existing.title == artifact.title
                    && existing.body == artifact.body
                    && existing.contentHash == artifact.contentHash
                    && existing.fileSizeBytes == artifact.fileSizeBytes
                    && existing.fileModifiedAt == artifact.fileModifiedAt

                if isUnchanged {
                    try db.execute(
                        sql: """
                        UPDATE source_artifacts
                        SET discoveredAt = ?, updatedAt = ?
                        WHERE id = ?
                        """,
                        arguments: [artifact.discoveredAt, artifact.updatedAt, artifact.id]
                    )
                    return .unchanged
                }
                disposition = existing.status == .deleted ? .restored : .updated
            } else {
                disposition = .inserted
            }

            try db.execute(
                sql: """
                INSERT INTO source_artifacts (
                    id, sourceKind, canonicalPath, rootPath, relativePath, provenance,
                    title, body, contentHash, fileSizeBytes, fileModifiedAt, status,
                    discoveredAt, deletedAt, createdAt, updatedAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    sourceKind = excluded.sourceKind,
                    canonicalPath = excluded.canonicalPath,
                    rootPath = excluded.rootPath,
                    relativePath = excluded.relativePath,
                    provenance = excluded.provenance,
                    title = excluded.title,
                    body = excluded.body,
                    contentHash = excluded.contentHash,
                    fileSizeBytes = excluded.fileSizeBytes,
                    fileModifiedAt = excluded.fileModifiedAt,
                    status = excluded.status,
                    discoveredAt = excluded.discoveredAt,
                    deletedAt = excluded.deletedAt,
                    updatedAt = excluded.updatedAt
                """,
                arguments: [
                    artifact.id,
                    artifact.sourceKind.rawValue,
                    artifact.canonicalPath,
                    artifact.rootPath,
                    artifact.relativePath,
                    artifact.provenance,
                    artifact.title,
                    artifact.body,
                    artifact.contentHash,
                    artifact.fileSizeBytes,
                    artifact.fileModifiedAt,
                    SourceArtifactStatus.active.rawValue,
                    artifact.discoveredAt,
                    nil,
                    artifact.createdAt,
                    artifact.updatedAt
                ]
            )
            return disposition
        }
    }

    func fetchSourceArtifacts(
        includeDeleted: Bool,
        rootPaths: [String]?,
        sourceKinds: [SearchSourceKind]
    ) throws -> [SourceArtifactRecord] {
        guard sourceKinds.isEmpty == false else { return [] }
        let normalizedRoots = (rootPaths ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let kindValues = sourceKinds.map(\.rawValue)
        var clauses: [String] = []
        var args: [any DatabaseValueConvertible] = []

        if includeDeleted == false {
            clauses.append("status != ?")
            args.append(SourceArtifactStatus.deleted.rawValue)
        }

        clauses.append("sourceKind IN (\(Self.sqlPlaceholders(count: kindValues.count)))")
        args.append(contentsOf: kindValues)

        if normalizedRoots.isEmpty == false {
            clauses.append("rootPath IN (\(Self.sqlPlaceholders(count: normalizedRoots.count)))")
            args.append(contentsOf: normalizedRoots)
        }

        let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM source_artifacts
                \(whereSQL)
                ORDER BY rootPath ASC, relativePath ASC
                """,
                arguments: StatementArguments(args)
            )
            return rows.compactMap(Self.sourceArtifact(from:))
        }
    }

    func countSourceArtifacts(
        includeDeleted: Bool,
        rootPaths: [String]?,
        sourceKinds: [SearchSourceKind]
    ) throws -> Int {
        guard sourceKinds.isEmpty == false else { return 0 }
        let normalizedRoots = (rootPaths ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let kindValues = sourceKinds.map(\.rawValue)
        var clauses: [String] = []
        var args: [any DatabaseValueConvertible] = []

        if includeDeleted == false {
            clauses.append("status != ?")
            args.append(SourceArtifactStatus.deleted.rawValue)
        }

        clauses.append("sourceKind IN (\(Self.sqlPlaceholders(count: kindValues.count)))")
        args.append(contentsOf: kindValues)

        if normalizedRoots.isEmpty == false {
            clauses.append("rootPath IN (\(Self.sqlPlaceholders(count: normalizedRoots.count)))")
            args.append(contentsOf: normalizedRoots)
        }

        let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        return try dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM source_artifacts
                \(whereSQL)
                """,
                arguments: StatementArguments(args)
            ) ?? 0
        }
    }

    func fetchSourceArtifact(id: String, includeDeleted: Bool) throws -> SourceArtifactRecord? {
        try dbQueue.read { db in
            guard
                let row = try Row.fetchOne(
                    db,
                    sql: "SELECT * FROM source_artifacts WHERE id = ?",
                    arguments: [id]
                ),
                let artifact = Self.sourceArtifact(from: row)
            else {
                return nil
            }
            if includeDeleted == false, artifact.status == .deleted {
                return nil
            }
            return artifact
        }
    }

    @discardableResult
    func markSourceArtifactDeleted(id: String, deletedAt: Date) throws -> Bool {
        try dbQueue.write { db in
            guard
                let row = try Row.fetchOne(db, sql: "SELECT * FROM source_artifacts WHERE id = ?", arguments: [id]),
                let existing = Self.sourceArtifact(from: row),
                existing.status != .deleted
            else {
                return false
            }
            try db.execute(
                sql: """
                UPDATE source_artifacts
                SET status = ?, deletedAt = ?, updatedAt = ?
                WHERE id = ?
                """,
                arguments: [SourceArtifactStatus.deleted.rawValue, deletedAt, deletedAt, id]
            )
            return true
        }
    }

    func upsertSharedArtifactSyncState(_ state: SharedArtifactSyncStateRecord) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO shared_artifact_sync_state (
                    sourceArtifactID, remoteArtifactID, workspaceID, teamID, ownerUserID,
                    revisionID, remoteContentHash, localContentHashAtSync, remoteUpdatedAt,
                    lastPulledAt, lastSyncedAt, syncStatus, lastErrorCode, lastErrorMessage,
                    createdAt, updatedAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(sourceArtifactID) DO UPDATE SET
                    remoteArtifactID = excluded.remoteArtifactID,
                    workspaceID = excluded.workspaceID,
                    teamID = excluded.teamID,
                    ownerUserID = excluded.ownerUserID,
                    revisionID = excluded.revisionID,
                    remoteContentHash = excluded.remoteContentHash,
                    localContentHashAtSync = excluded.localContentHashAtSync,
                    remoteUpdatedAt = excluded.remoteUpdatedAt,
                    lastPulledAt = excluded.lastPulledAt,
                    lastSyncedAt = excluded.lastSyncedAt,
                    syncStatus = excluded.syncStatus,
                    lastErrorCode = excluded.lastErrorCode,
                    lastErrorMessage = excluded.lastErrorMessage,
                    updatedAt = excluded.updatedAt
                """,
                arguments: [
                    state.sourceArtifactID,
                    state.remoteArtifactID,
                    state.workspaceID,
                    state.teamID,
                    state.ownerUserID,
                    state.revisionID,
                    state.remoteContentHash,
                    state.localContentHashAtSync,
                    state.remoteUpdatedAt,
                    state.lastPulledAt,
                    state.lastSyncedAt,
                    state.syncStatus.rawValue,
                    state.lastErrorCode,
                    state.lastErrorMessage,
                    state.createdAt,
                    state.updatedAt
                ]
            )
        }
    }

    func fetchSharedArtifactSyncState(sourceArtifactID: String) throws -> SharedArtifactSyncStateRecord? {
        try dbQueue.read { db in
            guard
                let row = try Row.fetchOne(
                    db,
                    sql: "SELECT * FROM shared_artifact_sync_state WHERE sourceArtifactID = ?",
                    arguments: [sourceArtifactID]
                )
            else {
                return nil
            }
            return Self.sharedArtifactSyncState(from: row)
        }
    }

    func fetchSharedArtifactSyncState(remoteArtifactID: String) throws -> SharedArtifactSyncStateRecord? {
        try dbQueue.read { db in
            guard
                let row = try Row.fetchOne(
                    db,
                    sql: "SELECT * FROM shared_artifact_sync_state WHERE remoteArtifactID = ?",
                    arguments: [remoteArtifactID]
                )
            else {
                return nil
            }
            return Self.sharedArtifactSyncState(from: row)
        }
    }

    func fetchSharedArtifactSyncStates(
        workspaceID: String?,
        teamID: String?,
        statuses: [SharedArtifactSyncStatus]?,
        limit: Int
    ) throws -> [SharedArtifactSyncStateRecord] {
        if let statuses, statuses.isEmpty {
            return []
        }

        let normalizedWorkspaceID = workspaceID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTeamID = teamID?.trimmingCharacters(in: .whitespacesAndNewlines)

        var clauses: [String] = []
        var args: [any DatabaseValueConvertible] = []

        if let normalizedWorkspaceID, normalizedWorkspaceID.isEmpty == false {
            clauses.append("workspaceID = ?")
            args.append(normalizedWorkspaceID)
        }

        if let normalizedTeamID, normalizedTeamID.isEmpty == false {
            clauses.append("teamID = ?")
            args.append(normalizedTeamID)
        }

        if let statuses, statuses.isEmpty == false {
            clauses.append("syncStatus IN (\(Self.sqlPlaceholders(count: statuses.count)))")
            args.append(contentsOf: statuses.map(\.rawValue))
        }

        args.append(max(1, limit))
        let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")

        return try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM shared_artifact_sync_state
                \(whereSQL)
                ORDER BY updatedAt DESC, sourceArtifactID ASC
                LIMIT ?
                """,
                arguments: StatementArguments(args)
            )
            return rows.compactMap(Self.sharedArtifactSyncState(from:))
        }
    }

    func countSharedArtifactSyncStates(
        workspaceID: String?,
        teamID: String?,
        statuses: [SharedArtifactSyncStatus]?
    ) throws -> Int {
        if let statuses, statuses.isEmpty {
            return 0
        }

        let normalizedWorkspaceID = workspaceID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTeamID = teamID?.trimmingCharacters(in: .whitespacesAndNewlines)

        var clauses: [String] = []
        var args: [any DatabaseValueConvertible] = []

        if let normalizedWorkspaceID, normalizedWorkspaceID.isEmpty == false {
            clauses.append("workspaceID = ?")
            args.append(normalizedWorkspaceID)
        }

        if let normalizedTeamID, normalizedTeamID.isEmpty == false {
            clauses.append("teamID = ?")
            args.append(normalizedTeamID)
        }

        if let statuses, statuses.isEmpty == false {
            clauses.append("syncStatus IN (\(Self.sqlPlaceholders(count: statuses.count)))")
            args.append(contentsOf: statuses.map(\.rawValue))
        }

        let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        return try dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM shared_artifact_sync_state
                \(whereSQL)
                """,
                arguments: StatementArguments(args)
            ) ?? 0
        }
    }

    func upsertSharedArtifactPermission(_ permission: SharedArtifactPermissionRecord) throws -> SharedArtifactPermissionWriteDisposition {
        try dbQueue.write { db in
            let existingRow = try Row.fetchOne(
                db,
                sql: """
                SELECT * FROM artifact_permissions
                WHERE sourceArtifactID = ? AND principalType = ? AND principalID = ?
                """,
                arguments: [permission.sourceArtifactID, permission.principalType.rawValue, permission.principalID]
            )
            let existing = existingRow.flatMap(Self.sharedArtifactPermission(from:))
            if let existing, Self.permissionSemanticsEqual(existing, permission) {
                return .unchanged
            }

            let createdAt = existing?.createdAt ?? permission.createdAt
            try db.execute(
                sql: """
                INSERT INTO artifact_permissions (
                    sourceArtifactID, workspaceID, teamID, principalType, principalID,
                    role, visibility, canRead, canWrite, canShare, createdAt, updatedAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(sourceArtifactID, principalType, principalID) DO UPDATE SET
                    workspaceID = excluded.workspaceID,
                    teamID = excluded.teamID,
                    role = excluded.role,
                    visibility = excluded.visibility,
                    canRead = excluded.canRead,
                    canWrite = excluded.canWrite,
                    canShare = excluded.canShare,
                    updatedAt = excluded.updatedAt
                """,
                arguments: [
                    permission.sourceArtifactID,
                    permission.workspaceID,
                    permission.teamID,
                    permission.principalType.rawValue,
                    permission.principalID,
                    permission.role.rawValue,
                    permission.visibility.rawValue,
                    permission.canRead,
                    permission.canWrite,
                    permission.canShare,
                    createdAt,
                    permission.updatedAt
                ]
            )
            return existing == nil ? .inserted : .updated
        }
    }

    func replaceSharedArtifactPermissions(
        sourceArtifactID: String,
        permissions: [SharedArtifactPermissionRecord]
    ) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM artifact_permissions WHERE sourceArtifactID = ?",
                arguments: [sourceArtifactID]
            )
            guard permissions.isEmpty == false else { return }

            for permission in permissions {
                guard permission.sourceArtifactID == sourceArtifactID else { continue }
                try db.execute(
                    sql: """
                    INSERT INTO artifact_permissions (
                        sourceArtifactID, workspaceID, teamID, principalType, principalID,
                        role, visibility, canRead, canWrite, canShare, createdAt, updatedAt
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        permission.sourceArtifactID,
                        permission.workspaceID,
                        permission.teamID,
                        permission.principalType.rawValue,
                        permission.principalID,
                        permission.role.rawValue,
                        permission.visibility.rawValue,
                        permission.canRead,
                        permission.canWrite,
                        permission.canShare,
                        permission.createdAt,
                        permission.updatedAt
                    ]
                )
            }
        }
    }

    func fetchSharedArtifactPermissions(
        sourceArtifactID: String?,
        workspaceID: String?,
        teamID: String?,
        principalType: SharedArtifactPrincipalType?,
        principalID: String?,
        limit: Int
    ) throws -> [SharedArtifactPermissionRecord] {
        var clauses: [String] = []
        var args: [any DatabaseValueConvertible] = []

        if let sourceArtifactID = sourceArtifactID?.trimmingCharacters(in: .whitespacesAndNewlines), sourceArtifactID.isEmpty == false {
            clauses.append("sourceArtifactID = ?")
            args.append(sourceArtifactID)
        }
        if let workspaceID = workspaceID?.trimmingCharacters(in: .whitespacesAndNewlines), workspaceID.isEmpty == false {
            clauses.append("workspaceID = ?")
            args.append(workspaceID)
        }
        if let teamID = teamID?.trimmingCharacters(in: .whitespacesAndNewlines), teamID.isEmpty == false {
            clauses.append("teamID = ?")
            args.append(teamID)
        }
        if let principalType {
            clauses.append("principalType = ?")
            args.append(principalType.rawValue)
        }
        if let principalID = principalID?.trimmingCharacters(in: .whitespacesAndNewlines), principalID.isEmpty == false {
            clauses.append("principalID = ?")
            args.append(principalID)
        }

        args.append(max(1, limit))
        let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")

        return try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM artifact_permissions
                \(whereSQL)
                ORDER BY updatedAt DESC, sourceArtifactID ASC, principalType ASC, principalID ASC
                LIMIT ?
                """,
                arguments: StatementArguments(args)
            )
            return rows.compactMap(Self.sharedArtifactPermission(from:))
        }
    }

    func countSharedArtifactPermissions(
        sourceArtifactID: String?,
        workspaceID: String?,
        teamID: String?,
        principalType: SharedArtifactPrincipalType?,
        principalID: String?
    ) throws -> Int {
        var clauses: [String] = []
        var args: [any DatabaseValueConvertible] = []

        if let sourceArtifactID = sourceArtifactID?.trimmingCharacters(in: .whitespacesAndNewlines), sourceArtifactID.isEmpty == false {
            clauses.append("sourceArtifactID = ?")
            args.append(sourceArtifactID)
        }
        if let workspaceID = workspaceID?.trimmingCharacters(in: .whitespacesAndNewlines), workspaceID.isEmpty == false {
            clauses.append("workspaceID = ?")
            args.append(workspaceID)
        }
        if let teamID = teamID?.trimmingCharacters(in: .whitespacesAndNewlines), teamID.isEmpty == false {
            clauses.append("teamID = ?")
            args.append(teamID)
        }
        if let principalType {
            clauses.append("principalType = ?")
            args.append(principalType.rawValue)
        }
        if let principalID = principalID?.trimmingCharacters(in: .whitespacesAndNewlines), principalID.isEmpty == false {
            clauses.append("principalID = ?")
            args.append(principalID)
        }

        let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        return try dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM artifact_permissions
                \(whereSQL)
                """,
                arguments: StatementArguments(args)
            ) ?? 0
        }
    }

    func fetchReadableSharedArtifactSourceIDs(
        accessContext: SharedArtifactAccessContext,
        limit: Int
    ) throws -> [String] {
        guard limit > 0 else { return [] }

        return try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT DISTINCT s.id AS sourceArtifactID
                FROM source_artifacts AS s
                LEFT JOIN shared_artifact_sync_state AS sas
                    ON sas.sourceArtifactID = s.id
                WHERE s.sourceKind = ?
                  AND s.status = ?
                  AND (
                      EXISTS (
                          SELECT 1
                          FROM artifact_permissions AS ap
                          WHERE ap.sourceArtifactID = s.id
                            AND ap.canRead = 1
                            AND ap.workspaceID = ?
                            AND (
                                (ap.principalType = ? AND ap.principalID = ?)
                                OR (ap.principalType = ? AND ap.principalID = ? AND ap.teamID = ?)
                                OR (ap.principalType = ? AND ap.principalID = ?)
                            )
                      )
                      OR (
                          sas.workspaceID = ?
                          AND sas.teamID = ?
                          AND sas.ownerUserID = ?
                      )
                  )
                ORDER BY s.updatedAt DESC, s.id ASC
                LIMIT ?
                """,
                arguments: [
                    SearchSourceKind.sharedArtifact.rawValue,
                    SourceArtifactStatus.active.rawValue,
                    accessContext.workspaceID,
                    SharedArtifactPrincipalType.user.rawValue,
                    accessContext.userID,
                    SharedArtifactPrincipalType.team.rawValue,
                    accessContext.teamID,
                    accessContext.teamID,
                    SharedArtifactPrincipalType.workspace.rawValue,
                    accessContext.workspaceID,
                    accessContext.workspaceID,
                    accessContext.teamID,
                    accessContext.userID,
                    limit
                ]
            )
            return rows.compactMap { $0["sourceArtifactID"] as? String }
        }
    }

    func appendSharedArtifactAuditEvent(_ event: SharedArtifactAuditEventRecord) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO audit_events (
                    id, sourceArtifactID, remoteArtifactID, workspaceID, teamID,
                    actorUserID, actorRole, action, detailsJSON, occurredAt, createdAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO NOTHING
                """,
                arguments: [
                    event.id,
                    event.sourceArtifactID,
                    event.remoteArtifactID,
                    event.workspaceID,
                    event.teamID,
                    event.actorUserID,
                    event.actorRole?.rawValue,
                    event.action.rawValue,
                    event.detailsJSON,
                    event.occurredAt,
                    event.createdAt
                ]
            )
        }
    }

    func fetchSharedArtifactAuditEvents(
        sourceArtifactID: String?,
        workspaceID: String?,
        teamID: String?,
        actions: [SharedArtifactAuditAction]?,
        limit: Int
    ) throws -> [SharedArtifactAuditEventRecord] {
        if let actions, actions.isEmpty { return [] }

        var clauses: [String] = []
        var args: [any DatabaseValueConvertible] = []

        if let sourceArtifactID = sourceArtifactID?.trimmingCharacters(in: .whitespacesAndNewlines), sourceArtifactID.isEmpty == false {
            clauses.append("sourceArtifactID = ?")
            args.append(sourceArtifactID)
        }
        if let workspaceID = workspaceID?.trimmingCharacters(in: .whitespacesAndNewlines), workspaceID.isEmpty == false {
            clauses.append("workspaceID = ?")
            args.append(workspaceID)
        }
        if let teamID = teamID?.trimmingCharacters(in: .whitespacesAndNewlines), teamID.isEmpty == false {
            clauses.append("teamID = ?")
            args.append(teamID)
        }
        if let actions, actions.isEmpty == false {
            clauses.append("action IN (\(Self.sqlPlaceholders(count: actions.count)))")
            args.append(contentsOf: actions.map(\.rawValue))
        }

        args.append(max(1, limit))
        let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")

        return try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM audit_events
                \(whereSQL)
                ORDER BY occurredAt DESC, id ASC
                LIMIT ?
                """,
                arguments: StatementArguments(args)
            )
            return rows.compactMap(Self.sharedArtifactAuditEvent(from:))
        }
    }

    func countSharedArtifactAuditEvents(
        sourceArtifactID: String?,
        workspaceID: String?,
        teamID: String?,
        actions: [SharedArtifactAuditAction]?
    ) throws -> Int {
        if let actions, actions.isEmpty { return 0 }

        var clauses: [String] = []
        var args: [any DatabaseValueConvertible] = []

        if let sourceArtifactID = sourceArtifactID?.trimmingCharacters(in: .whitespacesAndNewlines), sourceArtifactID.isEmpty == false {
            clauses.append("sourceArtifactID = ?")
            args.append(sourceArtifactID)
        }
        if let workspaceID = workspaceID?.trimmingCharacters(in: .whitespacesAndNewlines), workspaceID.isEmpty == false {
            clauses.append("workspaceID = ?")
            args.append(workspaceID)
        }
        if let teamID = teamID?.trimmingCharacters(in: .whitespacesAndNewlines), teamID.isEmpty == false {
            clauses.append("teamID = ?")
            args.append(teamID)
        }
        if let actions, actions.isEmpty == false {
            clauses.append("action IN (\(Self.sqlPlaceholders(count: actions.count)))")
            args.append(contentsOf: actions.map(\.rawValue))
        }

        let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        return try dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM audit_events
                \(whereSQL)
                """,
                arguments: StatementArguments(args)
            ) ?? 0
        }
    }

    func enqueueProjectionJob(_ job: ProjectionJobRecord) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO projection_jobs (
                    id, jobType, sourceKind, sourceID, sourceVersionID, status, priority, attempts,
                    maxAttempts, payloadJSON, lastErrorCode, lastErrorMessage, scheduledAt, availableAt,
                    startedAt, completedAt, leaseOwner, leaseExpiresAt, createdAt, updatedAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    jobType = excluded.jobType,
                    sourceKind = excluded.sourceKind,
                    sourceID = excluded.sourceID,
                    sourceVersionID = excluded.sourceVersionID,
                    status = excluded.status,
                    priority = excluded.priority,
                    attempts = excluded.attempts,
                    maxAttempts = excluded.maxAttempts,
                    payloadJSON = excluded.payloadJSON,
                    lastErrorCode = excluded.lastErrorCode,
                    lastErrorMessage = excluded.lastErrorMessage,
                    scheduledAt = excluded.scheduledAt,
                    availableAt = excluded.availableAt,
                    startedAt = excluded.startedAt,
                    completedAt = excluded.completedAt,
                    leaseOwner = excluded.leaseOwner,
                    leaseExpiresAt = excluded.leaseExpiresAt,
                    updatedAt = excluded.updatedAt
                WHERE projection_jobs.status IN ('queued', 'failed', 'canceled')
                """,
                arguments: [
                    job.id,
                    job.jobType.rawValue,
                    job.sourceKind?.rawValue,
                    job.sourceID,
                    job.sourceVersionID,
                    job.status.rawValue,
                    job.priority,
                    job.attempts,
                    job.maxAttempts,
                    job.payloadJSON,
                    job.lastErrorCode,
                    job.lastErrorMessage,
                    job.scheduledAt,
                    job.availableAt,
                    job.startedAt,
                    job.completedAt,
                    job.leaseOwner,
                    job.leaseExpiresAt,
                    job.createdAt,
                    job.updatedAt
                ]
            )
        }
    }

    func fetchProjectionJobs(statuses: [ProjectionJobStatus], limit: Int) throws -> [ProjectionJobRecord] {
        guard statuses.isEmpty == false else { return [] }
        let placeholders = statuses.map { _ in "?" }.joined(separator: ", ")
        var args: [any DatabaseValueConvertible] = statuses.map { $0.rawValue }
        args.append(limit)
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM projection_jobs
                WHERE status IN (\(placeholders))
                ORDER BY priority ASC, availableAt ASC, createdAt ASC
                LIMIT ?
                """,
                arguments: StatementArguments(args)
            )
            return rows.compactMap(Self.projectionJob(from:))
        }
    }

    func countProjectionJobs(statuses: [ProjectionJobStatus]?) throws -> Int {
        let normalizedStatuses = statuses ?? ProjectionJobStatus.allCases
        guard normalizedStatuses.isEmpty == false else { return 0 }
        let placeholders = normalizedStatuses.map { _ in "?" }.joined(separator: ", ")
        let args: [any DatabaseValueConvertible] = normalizedStatuses.map(\.rawValue)

        return try dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM projection_jobs
                WHERE status IN (\(placeholders))
                """,
                arguments: StatementArguments(args)
            ) ?? 0
        }
    }

    func leaseNextJob(leaseOwner: String, leaseExpiresAt: Date, now: Date) throws -> ProjectionJobRecord? {
        try dbQueue.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT * FROM projection_jobs
                WHERE (
                    (
                        status IN (?, ?)
                        AND availableAt <= ?
                    )
                    OR (
                        status IN (?, ?)
                        AND leaseExpiresAt IS NOT NULL
                        AND leaseExpiresAt <= ?
                    )
                )
                AND attempts < maxAttempts
                ORDER BY priority ASC, availableAt ASC, createdAt ASC
                LIMIT 1
                """,
                arguments: [
                    ProjectionJobStatus.queued.rawValue,
                    ProjectionJobStatus.failed.rawValue,
                    now,
                    ProjectionJobStatus.leased.rawValue,
                    ProjectionJobStatus.running.rawValue,
                    now
                ]
            ) else {
                return nil
            }

            guard let job = Self.projectionJob(from: row) else { return nil }
            try db.execute(
                sql: """
                UPDATE projection_jobs
                SET status = ?, leaseOwner = ?, leaseExpiresAt = ?, startedAt = COALESCE(startedAt, ?), updatedAt = ?
                WHERE id = ?
                """,
                arguments: [
                    ProjectionJobStatus.running.rawValue,
                    leaseOwner,
                    leaseExpiresAt,
                    now,
                    now,
                    job.id
                ]
            )
            return try Row.fetchOne(
                db,
                sql: "SELECT * FROM projection_jobs WHERE id = ?",
                arguments: [job.id]
            ).flatMap(Self.projectionJob(from:))
        }
    }

    func markJobLeased(id: String, leaseOwner: String, leaseExpiresAt: Date, updatedAt: Date) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE projection_jobs
                SET status = ?, leaseOwner = ?, leaseExpiresAt = ?, startedAt = COALESCE(startedAt, ?), updatedAt = ?
                WHERE id = ?
                """,
                arguments: [ProjectionJobStatus.leased.rawValue, leaseOwner, leaseExpiresAt, updatedAt, updatedAt, id]
            )
        }
    }

    func markJobCompleted(id: String, completedAt: Date) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE projection_jobs
                SET status = ?, completedAt = ?, leaseOwner = NULL, leaseExpiresAt = NULL,
                    lastErrorCode = NULL, lastErrorMessage = NULL, updatedAt = ?
                WHERE id = ?
                """,
                arguments: [ProjectionJobStatus.completed.rawValue, completedAt, completedAt, id]
            )
        }
    }

    func markJobFailed(
        id: String,
        errorCode: String?,
        errorMessage: String?,
        retryAt: Date?,
        updatedAt: Date
    ) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE projection_jobs
                SET status = ?, attempts = attempts + 1, leaseOwner = NULL, leaseExpiresAt = NULL,
                    lastErrorCode = ?, lastErrorMessage = ?, availableAt = COALESCE(?, availableAt), updatedAt = ?
                WHERE id = ?
                """,
                arguments: [ProjectionJobStatus.failed.rawValue, errorCode, errorMessage, retryAt, updatedAt, id]
            )
        }
    }

    func markJobCanceled(
        id: String,
        errorCode: String?,
        errorMessage: String?,
        updatedAt: Date
    ) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE projection_jobs
                SET status = ?, leaseOwner = NULL, leaseExpiresAt = NULL,
                    lastErrorCode = ?, lastErrorMessage = ?, updatedAt = ?
                WHERE id = ?
                """,
                arguments: [ProjectionJobStatus.canceled.rawValue, errorCode, errorMessage, updatedAt, id]
            )
        }
    }

    func deleteDocuments(sourceKind: SearchSourceKind, sourceID: String) throws {
        try dbQueue.write { db in
            let documentIDs = try String.fetchAll(
                db,
                sql: """
                SELECT id
                FROM search_documents
                WHERE sourceKind = ? AND sourceID = ?
                """,
                arguments: [sourceKind.rawValue, sourceID]
            )

            for documentID in documentIDs {
                try db.execute(
                    sql: "DELETE FROM search_chunks_fts WHERE documentID = ?",
                    arguments: [documentID]
                )
            }

            try db.execute(
                sql: """
                DELETE FROM search_documents
                WHERE sourceKind = ? AND sourceID = ?
                """,
                arguments: [sourceKind.rawValue, sourceID]
            )
        }
    }

    func upsertEmbeddingModel(_ model: EmbeddingModelRecord) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO embedding_models (
                    id, provider, modelName, dimensions, distanceMetric, createdAt, updatedAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    provider = excluded.provider,
                    modelName = excluded.modelName,
                    dimensions = excluded.dimensions,
                    distanceMetric = excluded.distanceMetric,
                    updatedAt = excluded.updatedAt
                """,
                arguments: [
                    model.id,
                    model.provider,
                    model.modelName,
                    model.dimensions,
                    model.distanceMetric.rawValue,
                    model.createdAt,
                    model.updatedAt
                ]
            )
        }
    }

    func fetchEmbeddingModels() throws -> [EmbeddingModelRecord] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM embedding_models
                ORDER BY provider ASC, modelName ASC
                """
            )
            return rows.compactMap(Self.embeddingModel(from:))
        }
    }

    func countEmbeddingModels() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM embedding_models"
            ) ?? 0
        }
    }

    func upsertEmbeddingVersion(_ version: EmbeddingVersionRecord) throws {
        try dbQueue.write { db in
            if version.isActive {
                try db.execute(
                    sql: "UPDATE embedding_versions SET isActive = 0, updatedAt = ? WHERE modelID = ?",
                    arguments: [version.updatedAt, version.modelID]
                )
            }

            try db.execute(
                sql: """
                INSERT INTO embedding_versions (
                    id, modelID, versionTag, chunkerVersion, normalizationVersion,
                    promptVersion, isActive, createdAt, updatedAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    modelID = excluded.modelID,
                    versionTag = excluded.versionTag,
                    chunkerVersion = excluded.chunkerVersion,
                    normalizationVersion = excluded.normalizationVersion,
                    promptVersion = excluded.promptVersion,
                    isActive = excluded.isActive,
                    updatedAt = excluded.updatedAt
                """,
                arguments: [
                    version.id,
                    version.modelID,
                    version.versionTag,
                    version.chunkerVersion,
                    version.normalizationVersion,
                    version.promptVersion,
                    version.isActive,
                    version.createdAt,
                    version.updatedAt
                ]
            )
        }
    }

    func fetchEmbeddingVersions(modelID: String?) throws -> [EmbeddingVersionRecord] {
        try dbQueue.read { db in
            let rows: [Row]
            if let modelID {
                rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT * FROM embedding_versions
                    WHERE modelID = ?
                    ORDER BY isActive DESC, createdAt DESC
                    """,
                    arguments: [modelID]
                )
            } else {
                rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT * FROM embedding_versions
                    ORDER BY modelID ASC, isActive DESC, createdAt DESC
                    """
                )
            }
            return rows.compactMap(Self.embeddingVersion(from:))
        }
    }

    func countEmbeddingVersions(modelID: String?) throws -> Int {
        try dbQueue.read { db in
            if let modelID {
                return try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM embedding_versions WHERE modelID = ?",
                    arguments: [modelID]
                ) ?? 0
            }

            return try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM embedding_versions"
            ) ?? 0
        }
    }

    func upsertChunkEmbedding(_ embedding: ChunkEmbeddingRecord) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO chunk_embeddings (
                    chunkID, embeddingVersionID, vectorBlob, createdAt, updatedAt
                ) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(chunkID, embeddingVersionID) DO UPDATE SET
                    vectorBlob = excluded.vectorBlob,
                    updatedAt = excluded.updatedAt
                """,
                arguments: [
                    embedding.chunkID,
                    embedding.embeddingVersionID,
                    embedding.vectorBlob,
                    embedding.createdAt,
                    embedding.updatedAt
                ]
            )
        }
    }

    func fetchChunkEmbeddings(chunkID: String?) throws -> [ChunkEmbeddingRecord] {
        try dbQueue.read { db in
            let rows: [Row]
            if let chunkID {
                rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT * FROM chunk_embeddings
                    WHERE chunkID = ?
                    ORDER BY embeddingVersionID ASC
                    """,
                    arguments: [chunkID]
                )
            } else {
                rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT * FROM chunk_embeddings
                    ORDER BY chunkID ASC, embeddingVersionID ASC
                    """
                )
            }
            return rows.compactMap(Self.chunkEmbedding(from:))
        }
    }

    func fetchChunkEmbeddings(embeddingVersionID: String) throws -> [ChunkEmbeddingRecord] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM chunk_embeddings
                WHERE embeddingVersionID = ?
                ORDER BY chunkID ASC
                """,
                arguments: [embeddingVersionID]
            )
            return rows.compactMap(Self.chunkEmbedding(from:))
        }
    }

    func countChunkEmbeddings(
        chunkID: String?,
        embeddingVersionID: String?
    ) throws -> Int {
        var clauses: [String] = []
        var args: [any DatabaseValueConvertible] = []

        if let chunkID, chunkID.isEmpty == false {
            clauses.append("chunkID = ?")
            args.append(chunkID)
        }
        if let embeddingVersionID, embeddingVersionID.isEmpty == false {
            clauses.append("embeddingVersionID = ?")
            args.append(embeddingVersionID)
        }

        let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        return try dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM chunk_embeddings
                \(whereSQL)
                """,
                arguments: StatementArguments(args)
            ) ?? 0
        }
    }

    func countChunkEmbeddings(
        documentID: String,
        embeddingVersionID: String?
    ) throws -> Int {
        var clauses: [String] = ["c.documentID = ?"]
        var args: [any DatabaseValueConvertible] = [documentID]

        if let embeddingVersionID, embeddingVersionID.isEmpty == false {
            clauses.append("e.embeddingVersionID = ?")
            args.append(embeddingVersionID)
        }

        return try dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM chunk_embeddings AS e
                JOIN search_chunks AS c ON c.id = e.chunkID
                WHERE \(clauses.joined(separator: " AND "))
                """,
                arguments: StatementArguments(args)
            ) ?? 0
        }
    }

    func upsertRetrievalHealth(_ health: RetrievalHealthRecord) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO retrieval_health (
                    subsystem, status, errorCode, errorMessage, detailsJSON, observedAt, updatedAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(subsystem) DO UPDATE SET
                    status = excluded.status,
                    errorCode = excluded.errorCode,
                    errorMessage = excluded.errorMessage,
                    detailsJSON = excluded.detailsJSON,
                    observedAt = excluded.observedAt,
                    updatedAt = excluded.updatedAt
                """,
                arguments: [
                    health.subsystem.rawValue,
                    health.status.rawValue,
                    health.errorCode,
                    health.errorMessage,
                    health.detailsJSON,
                    health.observedAt,
                    health.updatedAt
                ]
            )
        }
    }

    func fetchRetrievalHealth() throws -> [RetrievalHealthRecord] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM retrieval_health
                ORDER BY subsystem ASC
                """
            )
            return rows.compactMap(Self.retrievalHealth(from:))
        }
    }

    func schemaInventory() throws -> LocalSearchSchemaInventory {
        let expectedTables = [
            "search_documents",
            "search_chunks",
            "search_chunks_fts",
            "search_documents_fts",
            "projection_jobs",
            "embedding_models",
            "embedding_versions",
            "chunk_embeddings",
            "retrieval_health",
            "artifact_permissions",
            "audit_events"
        ]
        let expectedIndexes = [
            "search_documents_source_lookup_idx",
            "search_documents_project_provider_idx",
            "search_chunks_unique_document_ordinal_idx",
            "search_chunks_document_offset_idx",
            "search_chunks_source_lookup_idx",
            "projection_jobs_poll_idx",
            "projection_jobs_source_lookup_idx",
            "embedding_models_provider_model_idx",
            "embedding_versions_identity_idx",
            "embedding_versions_active_idx",
            "chunk_embeddings_version_lookup_idx",
            "artifact_permissions_principal_lookup_idx",
            "artifact_permissions_source_lookup_idx",
            "audit_events_source_time_idx",
            "audit_events_scope_time_idx",
            "audit_events_action_time_idx"
        ]

        return try dbQueue.read { db in
            let tables = try String.fetchAll(
                db,
                sql: """
                SELECT name
                FROM sqlite_master
                WHERE type = 'table' AND name IN (\(Self.sqlPlaceholders(count: expectedTables.count)))
                ORDER BY name ASC
                """,
                arguments: StatementArguments(expectedTables)
            )
            let indexes = try String.fetchAll(
                db,
                sql: """
                SELECT name
                FROM sqlite_master
                WHERE type = 'index' AND name IN (\(Self.sqlPlaceholders(count: expectedIndexes.count)))
                ORDER BY name ASC
                """,
                arguments: StatementArguments(expectedIndexes)
            )
            return LocalSearchSchemaInventory(tables: tables, indexes: indexes)
        }
    }

    private static func document(from row: Row) -> SearchDocumentRecord? {
        guard
            let id = row["id"] as? String,
            let sourceKindRaw = row["sourceKind"] as? String,
            let sourceKind = SearchSourceKind(rawValue: sourceKindRaw),
            let sourceID = row["sourceID"] as? String,
            let title = row["title"] as? String
        else {
            return nil
        }
        let indexedAt = parseDateValue(row["indexedAt"]) ?? Date()
        let createdAt = parseDateValue(row["createdAt"]) ?? indexedAt
        let updatedAt = parseDateValue(row["updatedAt"]) ?? createdAt
        return SearchDocumentRecord(
            id: id,
            sourceKind: sourceKind,
            sourceID: sourceID,
            sourceVersionID: (row["sourceVersionID"] as? String) ?? "",
            provider: row["provider"] as? String,
            projectName: row["projectName"] as? String,
            title: title,
            subtitle: row["subtitle"] as? String,
            bodyPreview: row["bodyPreview"] as? String,
            sourceUpdatedAt: parseDateValue(row["sourceUpdatedAt"]),
            indexedAt: indexedAt,
            contentHash: row["contentHash"] as? String,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private static func filteredDocumentClause(
        provider: String?,
        projectName: String?,
        sourceKinds: [SearchSourceKind]?,
        dateRange: ClosedRange<Date>?
    ) -> (String, [any DatabaseValueConvertible]) {
        let trimmedProjectName = projectName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedProjectName = (trimmedProjectName?.isEmpty == false) ? trimmedProjectName : nil
        let normalizedSourceKinds = Array(Set(sourceKinds ?? []))
            .sorted { $0.rawValue < $1.rawValue }

        var clauses: [String] = []
        var args: [any DatabaseValueConvertible] = []

        if let provider, provider.isEmpty == false {
            clauses.append("provider = ?")
            args.append(provider)
        }

        if let normalizedProjectName {
            clauses.append("projectName = ?")
            args.append(normalizedProjectName)
        }

        if normalizedSourceKinds.isEmpty == false {
            clauses.append("sourceKind IN (\(Self.sqlPlaceholders(count: normalizedSourceKinds.count)))")
            args.append(contentsOf: normalizedSourceKinds.map(\.rawValue))
        }

        if let dateRange {
            clauses.append("COALESCE(sourceUpdatedAt, indexedAt) >= ?")
            clauses.append("COALESCE(sourceUpdatedAt, indexedAt) <= ?")
            args.append(dateRange.lowerBound)
            args.append(dateRange.upperBound)
        }

        let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        return (whereSQL, args)
    }

    private static func chunk(from row: Row) -> SearchChunkRecord? {
        guard
            let id = row["id"] as? String,
            let documentID = row["documentID"] as? String,
            let sourceKindRaw = row["sourceKind"] as? String,
            let sourceKind = SearchSourceKind(rawValue: sourceKindRaw),
            let sourceID = row["sourceID"] as? String
        else {
            return nil
        }

        let ordinal = (row["ordinal"] as? Int) ?? Int(row["ordinal"] as? Int64 ?? 0)
        let startOffset = (row["startOffset"] as? Int) ?? Int(row["startOffset"] as? Int64 ?? 0)
        let endOffset = (row["endOffset"] as? Int) ?? Int(row["endOffset"] as? Int64 ?? 0)
        let messageStartOffset = (row["messageStartOffset"] as? Int) ?? Int(row["messageStartOffset"] as? Int64 ?? -1)
        let messageEndOffset = (row["messageEndOffset"] as? Int) ?? Int(row["messageEndOffset"] as? Int64 ?? -1)
        let createdAt = parseDateValue(row["createdAt"]) ?? Date.distantPast
        let updatedAt = parseDateValue(row["updatedAt"]) ?? createdAt
        let text = (row["text"] as? String) ?? ""
        return SearchChunkRecord(
            id: id,
            documentID: documentID,
            sourceKind: sourceKind,
            sourceID: sourceID,
            sourceVersionID: (row["sourceVersionID"] as? String) ?? "",
            ordinal: ordinal,
            startOffset: startOffset,
            endOffset: endOffset,
            messageStartOffset: messageStartOffset >= 0 ? messageStartOffset : nil,
            messageEndOffset: messageEndOffset >= 0 ? messageEndOffset : nil,
            sectionPath: row["sectionPath"] as? String,
            text: text,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private static func lexicalMatch(from row: Row) -> SearchChunkLexicalMatch? {
        guard
            let chunkID = row["chunkID"] as? String,
            let documentID = row["documentID"] as? String,
            let sourceKindRaw = row["sourceKind"] as? String,
            let sourceKind = SearchSourceKind(rawValue: sourceKindRaw),
            let sourceID = row["sourceID"] as? String,
            let title = row["title"] as? String
        else {
            return nil
        }

        let lexicalRankRaw = (row["lexicalRank"] as? Double) ?? Double(row["lexicalRank"] as? Int64 ?? 0)
        let chunkOrdinal = (row["chunkOrdinal"] as? Int) ?? Int(row["chunkOrdinal"] as? Int64 ?? 0)
        let startOffset = (row["startOffset"] as? Int) ?? Int(row["startOffset"] as? Int64 ?? 0)
        let endOffset = (row["endOffset"] as? Int) ?? Int(row["endOffset"] as? Int64 ?? 0)

        return SearchChunkLexicalMatch(
            chunkID: chunkID,
            documentID: documentID,
            sourceKind: sourceKind,
            sourceID: sourceID,
            sourceVersionID: (row["sourceVersionID"] as? String) ?? "",
            provider: row["provider"] as? String,
            projectName: row["projectName"] as? String,
            title: title,
            subtitle: row["subtitle"] as? String,
            bodyPreview: row["bodyPreview"] as? String,
            sourceUpdatedAt: parseDateValue(row["sourceUpdatedAt"]),
            indexedAt: parseDateValue(row["indexedAt"]) ?? Date.distantPast,
            chunkOrdinal: chunkOrdinal,
            startOffset: startOffset,
            endOffset: endOffset,
            sectionPath: row["sectionPath"] as? String,
            chunkText: (row["chunkText"] as? String) ?? "",
            snippet: (row["snippet"] as? String) ?? "",
            lexicalRank: lexicalRankRaw
        )
    }

    private static func sourceArtifact(from row: Row) -> SourceArtifactRecord? {
        guard
            let id = row["id"] as? String,
            let sourceKindRaw = row["sourceKind"] as? String,
            let sourceKind = SearchSourceKind(rawValue: sourceKindRaw),
            let canonicalPath = row["canonicalPath"] as? String,
            let rootPath = row["rootPath"] as? String,
            let relativePath = row["relativePath"] as? String,
            let provenance = row["provenance"] as? String,
            let title = row["title"] as? String,
            let body = row["body"] as? String,
            let contentHash = row["contentHash"] as? String
        else {
            return nil
        }
        let fileSizeBytes = (row["fileSizeBytes"] as? Int) ?? Int(row["fileSizeBytes"] as? Int64 ?? 0)
        let discoveredAt = parseDateValue(row["discoveredAt"]) ?? Date()
        let createdAt = parseDateValue(row["createdAt"]) ?? discoveredAt
        let updatedAt = parseDateValue(row["updatedAt"]) ?? createdAt
        let deletedAt = parseDateValue(row["deletedAt"])
        let statusRaw = (row["status"] as? String) ?? SourceArtifactStatus.active.rawValue
        let status = SourceArtifactStatus(rawValue: statusRaw) ?? .active

        return SourceArtifactRecord(
            id: id,
            sourceKind: sourceKind,
            canonicalPath: canonicalPath,
            rootPath: rootPath,
            relativePath: relativePath,
            provenance: provenance,
            title: title,
            body: body,
            contentHash: contentHash,
            fileSizeBytes: fileSizeBytes,
            fileModifiedAt: parseDateValue(row["fileModifiedAt"]),
            status: status,
            discoveredAt: discoveredAt,
            deletedAt: deletedAt,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private static func sharedArtifactSyncState(from row: Row) -> SharedArtifactSyncStateRecord? {
        guard
            let sourceArtifactID = row["sourceArtifactID"] as? String,
            let remoteArtifactID = row["remoteArtifactID"] as? String,
            let workspaceID = row["workspaceID"] as? String,
            let teamID = row["teamID"] as? String,
            let revisionID = row["revisionID"] as? String
        else {
            return nil
        }

        let statusRaw = (row["syncStatus"] as? String) ?? SharedArtifactSyncStatus.pendingPull.rawValue
        let syncStatus = SharedArtifactSyncStatus(rawValue: statusRaw) ?? .pendingPull
        let createdAt = parseDateValue(row["createdAt"]) ?? Date()
        let updatedAt = parseDateValue(row["updatedAt"]) ?? createdAt

        return SharedArtifactSyncStateRecord(
            sourceArtifactID: sourceArtifactID,
            remoteArtifactID: remoteArtifactID,
            workspaceID: workspaceID,
            teamID: teamID,
            ownerUserID: row["ownerUserID"] as? String,
            revisionID: revisionID,
            remoteContentHash: row["remoteContentHash"] as? String,
            localContentHashAtSync: row["localContentHashAtSync"] as? String,
            remoteUpdatedAt: parseDateValue(row["remoteUpdatedAt"]),
            lastPulledAt: parseDateValue(row["lastPulledAt"]),
            lastSyncedAt: parseDateValue(row["lastSyncedAt"]),
            syncStatus: syncStatus,
            lastErrorCode: row["lastErrorCode"] as? String,
            lastErrorMessage: row["lastErrorMessage"] as? String,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private static func sharedArtifactPermission(from row: Row) -> SharedArtifactPermissionRecord? {
        guard
            let sourceArtifactID = row["sourceArtifactID"] as? String,
            let workspaceID = row["workspaceID"] as? String,
            let teamID = row["teamID"] as? String,
            let principalTypeRaw = row["principalType"] as? String,
            let principalType = SharedArtifactPrincipalType(rawValue: principalTypeRaw),
            let principalID = row["principalID"] as? String,
            let roleRaw = row["role"] as? String,
            let role = SharedArtifactRole(rawValue: roleRaw),
            let visibilityRaw = row["visibility"] as? String,
            let visibility = SharedArtifactVisibility(rawValue: visibilityRaw)
        else {
            return nil
        }

        let createdAt = parseDateValue(row["createdAt"]) ?? Date()
        let updatedAt = parseDateValue(row["updatedAt"]) ?? createdAt

        return SharedArtifactPermissionRecord(
            sourceArtifactID: sourceArtifactID,
            workspaceID: workspaceID,
            teamID: teamID,
            principalType: principalType,
            principalID: principalID,
            role: role,
            visibility: visibility,
            canRead: parseBoolValue(row["canRead"]) ?? true,
            canWrite: parseBoolValue(row["canWrite"]) ?? false,
            canShare: parseBoolValue(row["canShare"]) ?? false,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private static func sharedArtifactAuditEvent(from row: Row) -> SharedArtifactAuditEventRecord? {
        guard
            let id = row["id"] as? String,
            let workspaceID = row["workspaceID"] as? String,
            let teamID = row["teamID"] as? String,
            let actionRaw = row["action"] as? String,
            let action = SharedArtifactAuditAction(rawValue: actionRaw)
        else {
            return nil
        }
        let occurredAt = parseDateValue(row["occurredAt"]) ?? Date()
        let createdAt = parseDateValue(row["createdAt"]) ?? occurredAt
        let actorRole = (row["actorRole"] as? String).flatMap(SharedArtifactRole.init(rawValue:))

        return SharedArtifactAuditEventRecord(
            id: id,
            sourceArtifactID: row["sourceArtifactID"] as? String,
            remoteArtifactID: row["remoteArtifactID"] as? String,
            workspaceID: workspaceID,
            teamID: teamID,
            actorUserID: row["actorUserID"] as? String,
            actorRole: actorRole,
            action: action,
            detailsJSON: row["detailsJSON"] as? String,
            occurredAt: occurredAt,
            createdAt: createdAt
        )
    }

    private static func permissionSemanticsEqual(
        _ lhs: SharedArtifactPermissionRecord,
        _ rhs: SharedArtifactPermissionRecord
    ) -> Bool {
        lhs.sourceArtifactID == rhs.sourceArtifactID
            && lhs.workspaceID == rhs.workspaceID
            && lhs.teamID == rhs.teamID
            && lhs.principalType == rhs.principalType
            && lhs.principalID == rhs.principalID
            && lhs.role == rhs.role
            && lhs.visibility == rhs.visibility
            && lhs.canRead == rhs.canRead
            && lhs.canWrite == rhs.canWrite
            && lhs.canShare == rhs.canShare
    }

    private static func projectionJob(from row: Row) -> ProjectionJobRecord? {
        guard
            let id = row["id"] as? String,
            let jobTypeRaw = row["jobType"] as? String,
            let jobType = ProjectionJobType(rawValue: jobTypeRaw),
            let statusRaw = row["status"] as? String,
            let status = ProjectionJobStatus(rawValue: statusRaw)
        else {
            return nil
        }

        let priority = (row["priority"] as? Int) ?? Int(row["priority"] as? Int64 ?? 0)
        let attempts = (row["attempts"] as? Int) ?? Int(row["attempts"] as? Int64 ?? 0)
        let maxAttempts = (row["maxAttempts"] as? Int) ?? Int(row["maxAttempts"] as? Int64 ?? 0)
        let scheduledAt = parseDateValue(row["scheduledAt"]) ?? Date()
        let availableAt = parseDateValue(row["availableAt"]) ?? scheduledAt
        let createdAt = parseDateValue(row["createdAt"]) ?? scheduledAt
        let updatedAt = parseDateValue(row["updatedAt"]) ?? createdAt
        let sourceKind = (row["sourceKind"] as? String).flatMap(SearchSourceKind.init(rawValue:))

        return ProjectionJobRecord(
            id: id,
            jobType: jobType,
            sourceKind: sourceKind,
            sourceID: row["sourceID"] as? String,
            sourceVersionID: (row["sourceVersionID"] as? String) ?? "",
            status: status,
            priority: priority,
            attempts: attempts,
            maxAttempts: maxAttempts,
            payloadJSON: row["payloadJSON"] as? String,
            lastErrorCode: row["lastErrorCode"] as? String,
            lastErrorMessage: row["lastErrorMessage"] as? String,
            scheduledAt: scheduledAt,
            availableAt: availableAt,
            startedAt: parseDateValue(row["startedAt"]),
            completedAt: parseDateValue(row["completedAt"]),
            leaseOwner: row["leaseOwner"] as? String,
            leaseExpiresAt: parseDateValue(row["leaseExpiresAt"]),
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private static func embeddingModel(from row: Row) -> EmbeddingModelRecord? {
        guard
            let id = row["id"] as? String,
            let provider = row["provider"] as? String,
            let modelName = row["modelName"] as? String,
            let distanceMetricRaw = row["distanceMetric"] as? String,
            let distanceMetric = EmbeddingDistanceMetric(rawValue: distanceMetricRaw)
        else {
            return nil
        }
        let dimensions = (row["dimensions"] as? Int) ?? Int(row["dimensions"] as? Int64 ?? 0)
        let createdAt = parseDateValue(row["createdAt"]) ?? Date()
        let updatedAt = parseDateValue(row["updatedAt"]) ?? createdAt
        return EmbeddingModelRecord(
            id: id,
            provider: provider,
            modelName: modelName,
            dimensions: dimensions,
            distanceMetric: distanceMetric,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private static func embeddingVersion(from row: Row) -> EmbeddingVersionRecord? {
        guard
            let id = row["id"] as? String,
            let modelID = row["modelID"] as? String,
            let versionTag = row["versionTag"] as? String,
            let chunkerVersion = row["chunkerVersion"] as? String,
            let normalizationVersion = row["normalizationVersion"] as? String,
            let promptVersion = row["promptVersion"] as? String
        else {
            return nil
        }
        let isActiveRaw: Bool
        if let boolValue = row["isActive"] as? Bool {
            isActiveRaw = boolValue
        } else if let intValue = row["isActive"] as? Int {
            isActiveRaw = intValue == 1
        } else if let int64Value = row["isActive"] as? Int64 {
            isActiveRaw = int64Value == 1
        } else {
            isActiveRaw = false
        }
        let createdAt = parseDateValue(row["createdAt"]) ?? Date()
        let updatedAt = parseDateValue(row["updatedAt"]) ?? createdAt
        return EmbeddingVersionRecord(
            id: id,
            modelID: modelID,
            versionTag: versionTag,
            chunkerVersion: chunkerVersion,
            normalizationVersion: normalizationVersion,
            promptVersion: promptVersion,
            isActive: isActiveRaw,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private static func chunkEmbedding(from row: Row) -> ChunkEmbeddingRecord? {
        guard
            let chunkID = row["chunkID"] as? String,
            let embeddingVersionID = row["embeddingVersionID"] as? String,
            let vectorBlob = row["vectorBlob"] as? Data
        else {
            return nil
        }
        let createdAt = parseDateValue(row["createdAt"]) ?? Date()
        let updatedAt = parseDateValue(row["updatedAt"]) ?? createdAt
        return ChunkEmbeddingRecord(
            chunkID: chunkID,
            embeddingVersionID: embeddingVersionID,
            vectorBlob: vectorBlob,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private static func retrievalHealth(from row: Row) -> RetrievalHealthRecord? {
        guard
            let subsystemRaw = row["subsystem"] as? String,
            let subsystem = RetrievalSubsystem(rawValue: subsystemRaw),
            let statusRaw = row["status"] as? String,
            let status = RetrievalHealthStatus(rawValue: statusRaw)
        else {
            return nil
        }
        let observedAt = parseDateValue(row["observedAt"]) ?? Date()
        let updatedAt = parseDateValue(row["updatedAt"]) ?? observedAt
        return RetrievalHealthRecord(
            subsystem: subsystem,
            status: status,
            errorCode: row["errorCode"] as? String,
            errorMessage: row["errorMessage"] as? String,
            detailsJSON: row["detailsJSON"] as? String,
            observedAt: observedAt,
            updatedAt: updatedAt
        )
    }

    private static func sqlPlaceholders(count: Int) -> String {
        Array(repeating: "?", count: max(0, count)).joined(separator: ", ")
    }

    private static func parseDateValue(_ value: Any?) -> Date? {
        if let date = value as? Date { return date }
        if let timeInterval = value as? TimeInterval {
            return Date(timeIntervalSince1970: timeInterval)
        }
        if let intValue = value as? Int {
            return Date(timeIntervalSince1970: TimeInterval(intValue))
        }
        if let int64Value = value as? Int64 {
            return Date(timeIntervalSince1970: TimeInterval(int64Value))
        }
        if let number = value as? NSNumber {
            return Date(timeIntervalSince1970: number.doubleValue)
        }
        if let string = value as? String {
            if let parsed = sqliteDateFormatter.date(from: string) { return parsed }
            return ISO8601DateFormatter().date(from: string)
        }
        return nil
    }

    private static func parseBoolValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? Int { return value != 0 }
        if let value = value as? Int64 { return value != 0 }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String {
            switch value.lowercased() {
            case "1", "true", "yes":
                return true
            case "0", "false", "no":
                return false
            default:
                return nil
            }
        }
        return nil
    }

    private static let sqliteDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()
}
