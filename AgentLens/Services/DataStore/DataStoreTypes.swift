import Foundation
import OpenBurnBarCore

// MARK: - Rolling Average + Mood

enum MoodBand: Equatable {
    case light
    case onPace
    case heavy
    case baseline
    case quiet
}

struct OpenBurnBarLocalAuthoritySnapshot: Equatable, Sendable {
    let usageRowCount: Int
    let conversationRowCount: Int
    let sharedArtifactCount: Int
    let controllerRuntimeCached: Bool
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
    let contentHash: String?
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
        contentHash: String? = nil,
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
        self.contentHash = contentHash
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Result of an incremental chunk diff application.
/// Tracks how many chunks were unchanged, rekeyed (same contentHash, new ID),
/// added (new contentHash), or deleted (removed contentHash).
///
/// With stable chunk identity (m3-fix-unchanged-chunk-identity-stability):
/// - Rekeyed chunks (same contentHash, different chunkID) are treated as effectively unchanged
///   and do NOT cause delete+insert writes. The old chunks remain in place.
/// - Only truly added or deleted contentHashes cause writes.
struct ChunkDiffResult: Equatable, Sendable {
    /// Chunks with identical contentHash AND chunkID — no writes performed.
    let unchanged: Int
    /// Chunks with same contentHash but different chunkID (sourceVersionID rekey).
    /// With stable chunk identity, these are treated as unchanged and do NOT cause writes.
    /// Kept for reporting/classification purposes.
    let rekeyed: Int
    /// Chunks with new contentHash not present in existing set — inserted.
    let added: Int
    /// Chunks whose contentHash is not in new set — deleted.
    let deleted: Int
    /// Total existing chunks before diff.
    let existingTotal: Int
    /// Total new chunks after diff.
    let newTotal: Int

    /// Total number of write operations (inserts + deletes).
    /// Rekeyed chunks no longer cause writes with stable chunk identity.
    var writeCount: Int {
        return added + (deleted * 2)
    }

    /// Total number of chunks that were skipped (no writes at all).
    var skippedCount: Int {
        return unchanged + rekeyed
    }

    /// Whether this diff was a complete no-op (no writes needed).
    var isNoOp: Bool {
        return writeCount == 0
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

enum VectorIndexSnapshotState: String, Codable, CaseIterable, Sendable {
    case building
    case ready
    case stale
    case failed
}

struct VectorIndexSnapshotRecord: Equatable, Sendable {
    let embeddingVersionID: String
    let backendID: String
    let state: VectorIndexSnapshotState
    let fingerprint: String
    let dimensions: Int
    let distanceMetric: EmbeddingDistanceMetric
    let vectorCount: Int
    let storageRelativePath: String?
    let fileBytes: Int64
    let backendVersion: String
    let errorCode: String?
    let errorMessage: String?
    let createdAt: Date
    let updatedAt: Date
    let lastBuiltAt: Date?

    init(
        embeddingVersionID: String,
        backendID: String,
        state: VectorIndexSnapshotState,
        fingerprint: String,
        dimensions: Int,
        distanceMetric: EmbeddingDistanceMetric,
        vectorCount: Int,
        storageRelativePath: String? = nil,
        fileBytes: Int64 = 0,
        backendVersion: String,
        errorCode: String? = nil,
        errorMessage: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastBuiltAt: Date? = nil
    ) {
        self.embeddingVersionID = embeddingVersionID
        self.backendID = backendID
        self.state = state
        self.fingerprint = fingerprint
        self.dimensions = dimensions
        self.distanceMetric = distanceMetric
        self.vectorCount = vectorCount
        self.storageRelativePath = storageRelativePath
        self.fileBytes = fileBytes
        self.backendVersion = backendVersion
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastBuiltAt = lastBuiltAt
    }
}

struct ChunkEmbeddingVersionStats: Equatable, Sendable {
    let embeddingVersionID: String
    let vectorCount: Int
    let newestUpdatedAt: Date?

    init(embeddingVersionID: String, vectorCount: Int, newestUpdatedAt: Date?) {
        self.embeddingVersionID = embeddingVersionID
        self.vectorCount = vectorCount
        self.newestUpdatedAt = newestUpdatedAt
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

// MARK: - Source Artifacts

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

// MARK: - Shared Artifacts

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

// MARK: - Operating Actions

struct OpenBurnBarOperatingActionRecord: Identifiable, Equatable, Sendable {
    let id: String
    let projectName: String
    let missionFingerprint: String?
    let actionKind: OpenBurnBarActionKind
    let summary: String
    let detail: String?
    let overrideMode: OpenBurnBarDirectionOverrideModeKind?
    let forcedDirectionStatus: OpenBurnBarDirectionAssessment?
    let createdAt: Date

    init(
        id: String = UUID().uuidString,
        projectName: String,
        missionFingerprint: String? = nil,
        actionKind: OpenBurnBarActionKind,
        summary: String,
        detail: String? = nil,
        overrideMode: OpenBurnBarDirectionOverrideModeKind? = nil,
        forcedDirectionStatus: OpenBurnBarDirectionAssessment? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.projectName = projectName
        self.missionFingerprint = missionFingerprint
        self.actionKind = actionKind
        self.summary = summary
        self.detail = detail
        self.overrideMode = overrideMode
        self.forcedDirectionStatus = forcedDirectionStatus
        self.createdAt = createdAt
    }
}

// MARK: - Schema

struct LocalSearchSchemaInventory: Equatable, Sendable {
    let tables: [String]
    let indexes: [String]
}

// MARK: - Device Records

struct DeviceRecord: Identifiable, Equatable, Sendable {
    let deviceId: String
    let deviceName: String
    let isLocal: Bool
    let lastSeenAt: Date?
    let createdAt: Date
    /// Hardware model identifier from `sysctl hw.model`, e.g. "Mac16,11", "MacBookPro18,1"
    let hardwareModel: String?
    /// User-chosen SF Symbol override; when set, takes priority over hardware detection.
    let customIcon: String?

    var id: String { deviceId }

    /// SF Symbol name: user override > hardware detection > fallback.
    var sfSymbolName: String {
        customIcon ?? DeviceHardwareIcon.sfSymbol(for: hardwareModel)
    }
}

/// Per-device usage summary for the device breakdown card.
struct DeviceUsageSummary: Identifiable, Equatable, Sendable {
    let deviceId: String?
    let deviceName: String
    let isLocal: Bool
    let totalCost: Double
    let totalTokens: Int
    let sessionCount: Int
    let hardwareModel: String?
    let customIcon: String?

    var id: String { deviceId ?? "local" }

    var sfSymbolName: String {
        customIcon ?? DeviceHardwareIcon.sfSymbol(for: hardwareModel)
    }
}
