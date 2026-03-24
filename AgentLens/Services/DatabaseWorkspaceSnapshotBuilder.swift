import Foundation
import SwiftUI

// MARK: - Database Workspace Types

enum DatabaseWorkspaceMode: String, CaseIterable, Identifiable {
    case story
    case atlas
    case system

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .story: return "Story"
        case .atlas: return "Atlas"
        case .system: return "System"
        }
    }

    var icon: String {
        switch self {
        case .story: return "book.pages"
        case .atlas: return "map"
        case .system: return "gearshape.2"
        }
    }
}

struct DatabaseWorkspaceSnapshot: Equatable, Sendable {
    // Corpus summary
    var totalSessions: Int = 0
    var totalConversations: Int = 0
    var totalCostAllTime: Double = 0
    var totalTokensAllTime: Int = 0
    var activeProviders: [AgentProvider] = []
    var activeModels: [String] = []
    var projectNames: [String] = []
    var oldestSession: Date?
    var newestSession: Date?

    // Search/index coverage
    var indexedDocuments: Int = 0
    var indexedChunks: Int = 0
    var sourceArtifacts: Int = 0
    var embeddingModels: Int = 0
    var embeddingVersions: Int = 0
    var embeddedChunks: Int = 0
    var indexingEnabled: Bool = false

    // Provider/model breakdown
    var providerSummaries: [ProviderSummary] = []
    var modelSummaries: [ModelSummary] = []

    // Shared/team
    var sharedArtifactCount: Int = 0
    var syncStates: [SharedArtifactSyncStateRecord] = []
    var auditEvents: [SharedArtifactAuditEventRecord] = []
    var permissions: [SharedArtifactPermissionRecord] = []

    // System
    var projectionJobs: [ProjectionJobRecord] = []
    var retrievalHealth: [RetrievalHealthRecord] = []

    // Recent sessions
    var recentSessions: [TokenUsage] = []

    // Freshness
    var lastRefresh: Date?
    var snapshotBuiltAt: Date = Date()
}

struct DatabaseWorkspaceFilterState: Equatable {
    var providerFilter: AgentProvider?
    var sourceKindFilter: SearchSourceKind?
    var projectFilter: String?
    var timeWindow: TimeRange = .allTime
    var searchQuery: String = ""
}

enum DatabaseWorkspaceSelection: Equatable, Hashable {
    case session(UUID)
    case conversation(String)
    case artifact(String)
    case provider(AgentProvider)
    case model(String)
    case projectionJob(String)
    case auditEvent(String)
    case retrievalSubsystem(RetrievalSubsystem)
}

// MARK: - Snapshot Builder

@MainActor
final class DatabaseWorkspaceSnapshotBuilder {

    static func build(
        from dataStore: DataStore,
        settingsManager: SettingsManager,
        accountManager: AccountManager? = nil,
        cloudSyncService: CloudSyncService? = nil
    ) -> DatabaseWorkspaceSnapshot {
        var snap = DatabaseWorkspaceSnapshot()

        // Corpus
        let usages = dataStore.usages
        snap.totalSessions = usages.count
        snap.totalCostAllTime = usages.reduce(0) { $0 + $1.cost }
        snap.totalTokensAllTime = usages.reduce(0) { $0 + $1.totalTokens }
        snap.activeProviders = Array(Set(usages.map(\.provider))).sorted { $0.rawValue < $1.rawValue }
        snap.activeModels = Array(Set(usages.map(\.model))).sorted()
        snap.projectNames = Array(Set(usages.map(\.projectName))).sorted()
        snap.oldestSession = usages.min(by: { $0.startTime < $1.startTime })?.startTime
        snap.newestSession = usages.max(by: { $0.startTime < $1.startTime })?.startTime
        snap.recentSessions = Array(usages.sorted { $0.startTime > $1.startTime }.prefix(20))

        // Provider/model summaries
        snap.providerSummaries = dataStore.providerSummaries
        snap.modelSummaries = dataStore.modelSummaries(in: nil)

        // Indexing
        snap.indexingEnabled = settingsManager.conversationIndexingEnabled

        // Search/index coverage
        if let docs = try? dataStore.fetchSearchDocuments(limit: 10_000) {
            snap.indexedDocuments = docs.count
        }

        // Conversations
        if let convs = try? dataStore.fetchConversations(limit: 10_000) {
            snap.totalConversations = convs.count
        }

        // Source artifacts
        if let artifacts = try? dataStore.fetchSourceArtifacts() {
            snap.sourceArtifacts = artifacts.count
        }

        // Shared state
        if let syncStates = try? dataStore.fetchSharedArtifactSyncStates() {
            snap.syncStates = syncStates
            snap.sharedArtifactCount = syncStates.count
        }
        if let perms = try? dataStore.fetchSharedArtifactPermissions() {
            snap.permissions = perms
        }
        if let events = try? dataStore.fetchSharedArtifactAuditEvents(limit: 50) {
            snap.auditEvents = events
        }

        // System: projection jobs
        if let jobs = try? dataStore.fetchProjectionJobs(
            statuses: ProjectionJobStatus.allCases,
            limit: 100
        ) {
            snap.projectionJobs = jobs
        }

        // System: retrieval health
        if let health = try? dataStore.fetchRetrievalHealth() {
            snap.retrievalHealth = health
        }

        // Embeddings
        if let models = try? dataStore.fetchEmbeddingModels() {
            snap.embeddingModels = models.count
        }
        if let versions = try? dataStore.fetchEmbeddingVersions() {
            snap.embeddingVersions = versions.count
        }
        if let embeddings = try? dataStore.fetchChunkEmbeddings() {
            snap.embeddedChunks = embeddings.count
        }

        // Freshness
        snap.lastRefresh = dataStore.lastRefresh
        snap.snapshotBuiltAt = Date()

        return snap
    }
}
