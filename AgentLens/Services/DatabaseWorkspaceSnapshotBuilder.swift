import Foundation

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

enum DatabaseWorkspaceMetric: String, Hashable, Sendable {
    case totalConversations
    case indexedDocuments
    case indexedChunks
    case sourceArtifacts
    case embeddingModels
    case embeddingVersions
    case embeddedChunks
    case sharedArtifacts
    case permissions
    case auditEvents
    case projectionJobs
    case retrievalHealth
}

struct DatabaseWorkspaceLoadIssue: Identifiable, Equatable, Sendable {
    let metric: DatabaseWorkspaceMetric
    let context: String
    let message: String

    var id: String { "\(metric.rawValue):\(context)" }
}

struct DatabaseWorkspaceProjectionCounts: Equatable, Sendable {
    var total: Int = 0
    var active: Int = 0
    var queued: Int = 0
    var failed: Int = 0
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
    var sourceArtifactRecords: [SourceArtifactRecord] = []
    var embeddingModels: Int = 0
    var embeddingVersions: Int = 0
    var embeddedChunks: Int = 0
    var indexingEnabled: Bool = false
    var embeddingModelRecords: [EmbeddingModelRecord] = []
    var embeddingVersionRecords: [EmbeddingVersionRecord] = []

    // Provider/model breakdown
    var providerSummaries: [ProviderSummary] = []
    var modelSummaries: [ModelSummary] = []

    // Shared/team
    var sharedArtifactCount: Int = 0
    var syncedArtifactCount: Int = 0
    var pendingArtifactCount: Int = 0
    var conflictedArtifactCount: Int = 0
    var failedArtifactCount: Int = 0
    var permissionCount: Int = 0
    var auditEventCount: Int = 0
    var syncStates: [SharedArtifactSyncStateRecord] = []
    var auditEvents: [SharedArtifactAuditEventRecord] = []
    var permissions: [SharedArtifactPermissionRecord] = []

    // System
    var projectionJobCounts = DatabaseWorkspaceProjectionCounts()
    var projectionJobs: [ProjectionJobRecord] = []
    var retrievalHealth: [RetrievalHealthRecord] = []
    var retrievalSystemHealth: RetrievalSystemHealthSnapshot = .empty

    // Recent sessions
    var recentSessions: [TokenUsage] = []

    // Freshness
    var lastRefresh: Date?
    var snapshotBuiltAt = Date()
    var contentVersion: String = ""
    var unavailableMetrics: Set<DatabaseWorkspaceMetric> = []
    var loadIssues: [DatabaseWorkspaceLoadIssue] = []
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
    case indexedDocument(String)
    case conversation(String)
    case artifact(String)
    case provider(AgentProvider)
    case model(String)
    case projectionJob(String)
    case auditEvent(String)
    case retrievalSubsystem(RetrievalSubsystem)
}

// MARK: - Snapshot Builder

final class DatabaseWorkspaceSnapshotBuilder {

@MainActor
    static func build(
        from dataStore: DataStore,
        settingsManager: SettingsManager,
        accountManager: AccountManager? = nil,
        cloudSyncService: CloudSyncService? = nil
    ) async -> DatabaseWorkspaceSnapshot {
        var snap = DatabaseWorkspaceSnapshot()

        // Corpus
        let usages = dataStore.usages
        let providerSummaries = dataStore.providerSummaries
        let modelSummaries = dataStore.modelSummaries(in: nil)
        let indexingEnabled = settingsManager.conversationIndexingEnabled
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
        snap.providerSummaries = providerSummaries
        snap.modelSummaries = modelSummaries

        // Indexing
        snap.indexingEnabled = indexingEnabled

        func resultOf<T>(_ work: () async throws -> T) async -> Result<T, Error> {
            do {
                return .success(try await work())
            } catch {
                return .failure(error)
            }
        }

        func take<T>(
            _ result: Result<T, Error>,
            metric: DatabaseWorkspaceMetric,
            context: String,
            assign: (T) -> Void
        ) {
            switch result {
            case .success(let value):
                assign(value)
            case .failure(let error):
                snap.unavailableMetrics.insert(metric)
                snap.loadIssues.append(
                    DatabaseWorkspaceLoadIssue(
                        metric: metric,
                        context: context,
                        message: error.localizedDescription
                    )
                )
            }
        }

        // Independent GRDB reads start together so pool readers overlap; we
        // assign into `snap` only after each Result lands.
        async let indexedDocuments = resultOf { try await dataStore.countSearchDocuments() }
        async let indexedChunks = resultOf { try await dataStore.countSearchChunks() }
        async let totalConversations = resultOf { try await dataStore.countConversations() }
        async let sourceArtifactCount = resultOf { try await dataStore.countSourceArtifacts() }
        async let sourceArtifactRecords = resultOf {
            try await dataStore.fetchSourceArtifacts(
                includeDeleted: true,
                rootPaths: nil,
                sourceKinds: [.skillDoc, .agentDoc, .sharedArtifact],
                limit: 100,
                offset: 0
            )
        }
        async let sharedSyncCounts = resultOf { try await dataStore.countSharedArtifactSyncStatesByStatus() }
        async let sharedSyncRecent = resultOf { try await dataStore.fetchSharedArtifactSyncStates(limit: 100) }
        async let permissionCount = resultOf { try await dataStore.countSharedArtifactPermissions() }
        async let permissionRecent = resultOf { try await dataStore.fetchSharedArtifactPermissions(limit: 100) }
        async let auditCount = resultOf { try await dataStore.countSharedArtifactAuditEvents() }
        async let auditRecent = resultOf { try await dataStore.fetchSharedArtifactAuditEvents(limit: 50) }
        async let projectionRecent = resultOf {
            try await dataStore.fetchProjectionJobs(
                statuses: ProjectionJobStatus.allCases,
                limit: 100
            )
        }
        async let projectionCounts = resultOf { try await dataStore.countProjectionJobsByStatus() }
        async let retrievalHealth = resultOf { try await dataStore.fetchRetrievalHealth() }
        async let embeddingModels = resultOf { try await dataStore.fetchEmbeddingModels() }
        async let embeddingModelCount = resultOf { try await dataStore.countEmbeddingModels() }
        async let embeddingVersions = resultOf { try await dataStore.fetchEmbeddingVersions() }
        async let embeddingVersionCount = resultOf { try await dataStore.countEmbeddingVersions() }
        async let embeddedChunks = resultOf { try await dataStore.countChunkEmbeddings() }

        take(await indexedDocuments, metric: .indexedDocuments, context: "document_count") {
            snap.indexedDocuments = $0
        }
        take(await indexedChunks, metric: .indexedChunks, context: "chunk_count") {
            snap.indexedChunks = $0
        }
        take(await totalConversations, metric: .totalConversations, context: "conversation_count") {
            snap.totalConversations = $0
        }
        take(await sourceArtifactCount, metric: .sourceArtifacts, context: "artifact_count") {
            snap.sourceArtifacts = $0
        }
        take(await sourceArtifactRecords, metric: .sourceArtifacts, context: "artifact_recent") {
            snap.sourceArtifactRecords = $0
        }
        take(await sharedSyncCounts, metric: .sharedArtifacts, context: "shared_sync_counts") { (counts: [SharedArtifactSyncStatus: Int]) in
            snap.sharedArtifactCount = counts.values.reduce(0, +)
            snap.syncedArtifactCount = counts[.synced] ?? 0
            snap.pendingArtifactCount = (counts[.pendingUpload] ?? 0) + (counts[.pendingPull] ?? 0)
            snap.conflictedArtifactCount = counts[.conflicted] ?? 0
            snap.failedArtifactCount = counts[.failed] ?? 0
        }
        take(await sharedSyncRecent, metric: .sharedArtifacts, context: "shared_sync_recent") {
            snap.syncStates = $0
        }
        take(await permissionCount, metric: .permissions, context: "permission_count") {
            snap.permissionCount = $0
        }
        take(await permissionRecent, metric: .permissions, context: "permission_recent") {
            snap.permissions = $0
        }
        take(await auditCount, metric: .auditEvents, context: "audit_count") {
            snap.auditEventCount = $0
        }
        take(await auditRecent, metric: .auditEvents, context: "audit_recent") {
            snap.auditEvents = $0
        }
        take(await projectionRecent, metric: .projectionJobs, context: "projection_recent") {
            snap.projectionJobs = $0
        }
        take(await projectionCounts, metric: .projectionJobs, context: "projection_counts") { (counts: [ProjectionJobStatus: Int]) in
            snap.projectionJobCounts.total = counts.values.reduce(0, +)
            snap.projectionJobCounts.active = (counts[.running] ?? 0) + (counts[.leased] ?? 0)
            snap.projectionJobCounts.queued = counts[.queued] ?? 0
            snap.projectionJobCounts.failed = counts[.failed] ?? 0
        }
        take(await retrievalHealth, metric: .retrievalHealth, context: "retrieval_health") {
            snap.retrievalHealth = $0
        }
        take(await embeddingModels, metric: .embeddingModels, context: "embedding_models") {
            snap.embeddingModelRecords = $0
        }
        take(await embeddingModelCount, metric: .embeddingModels, context: "embedding_model_count") {
            snap.embeddingModels = $0
        }
        take(await embeddingVersions, metric: .embeddingVersions, context: "embedding_versions") {
            snap.embeddingVersionRecords = $0
        }
        take(await embeddingVersionCount, metric: .embeddingVersions, context: "embedding_version_count") {
            snap.embeddingVersions = $0
        }
        take(await embeddedChunks, metric: .embeddedChunks, context: "embedding_chunk_count") {
            snap.embeddedChunks = $0
        }

        snap.retrievalSystemHealth = await RetrievalHealthService(dataStore: dataStore).snapshot(
            indexingEnabled: settingsManager.conversationIndexingEnabled,
            sharedFeaturesAvailable: accountManager?.isSignedIn ?? false
        )

        // Freshness
        snap.lastRefresh = dataStore.lastRefresh
        snap.snapshotBuiltAt = Date()
        snap.contentVersion = makeContentVersion(from: snap)

        return snap
    }

    private static func makeContentVersion(from snapshot: DatabaseWorkspaceSnapshot) -> String {
        let syncUpdatedAt = snapshot.syncStates.map(\.updatedAt).max()?.timeIntervalSince1970 ?? 0
        let auditOccurredAt = snapshot.auditEvents.map(\.occurredAt).max()?.timeIntervalSince1970 ?? 0
        let projectionUpdatedAt = snapshot.projectionJobs.map(\.updatedAt).max()?.timeIntervalSince1970 ?? 0
        let retrievalObservedAt = snapshot.retrievalHealth.map(\.observedAt).max()?.timeIntervalSince1970 ?? 0
        let embeddingModelUpdatedAt = snapshot.embeddingModelRecords.map(\.updatedAt).max()?.timeIntervalSince1970 ?? 0
        let embeddingVersionUpdatedAt = snapshot.embeddingVersionRecords.map(\.updatedAt).max()?.timeIntervalSince1970 ?? 0
        let lastRefresh = snapshot.lastRefresh?.timeIntervalSince1970 ?? 0

        return [
            "\(snapshot.totalSessions)",
            "\(snapshot.totalConversations)",
            "\(snapshot.indexedDocuments)",
            "\(snapshot.indexedChunks)",
            "\(snapshot.sourceArtifacts)",
            "\(snapshot.sharedArtifactCount)",
            "\(snapshot.syncedArtifactCount)",
            "\(snapshot.pendingArtifactCount)",
            "\(snapshot.conflictedArtifactCount)",
            "\(snapshot.failedArtifactCount)",
            "\(snapshot.permissionCount)",
            "\(snapshot.auditEventCount)",
            "\(snapshot.projectionJobCounts.total)",
            "\(syncUpdatedAt)",
            "\(auditOccurredAt)",
            "\(projectionUpdatedAt)",
            "\(retrievalObservedAt)",
            "\(snapshot.retrievalSystemHealth.observedAt.timeIntervalSince1970)",
            "\(embeddingModelUpdatedAt)",
            "\(embeddingVersionUpdatedAt)",
            "\(lastRefresh)",
            snapshot.unavailableMetrics.map(\.rawValue).sorted().joined(separator: ",")
        ].joined(separator: "|")
    }
}
