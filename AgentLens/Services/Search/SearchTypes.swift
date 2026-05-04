import Foundation
import OpenBurnBarCore

// MARK: - Search Result

/// Represents a search result with conversation metadata and ranking information.
struct SearchResult: Identifiable {
    var id: String { conversation.id }
    let conversation: ConversationRecord
    let snippet: String
    let rank: Double
}

// MARK: - Retrieval Degraded Modes

/// Indicates a degraded mode affecting retrieval quality.
enum RetrievalDegradedMode: String, CaseIterable, Identifiable, Sendable {
    case indexStale
    case semanticUnavailable
    case rebuildInProgress
    case cloudSharedUnavailable

    var id: String { rawValue }
}

/// Represents a degraded state with title and message for user display.
struct RetrievalDegradedState: Identifiable, Equatable, Sendable {
    let mode: RetrievalDegradedMode
    let title: String
    let message: String

    var id: String { mode.id }
}

// MARK: - Parser Import Health

/// Health state for a single provider during import.
struct ParserImportHealthProviderState: Codable, Equatable, Sendable {
    let provider: String
    let status: String
    let sessionCount: Int
    let errorMessage: String?
}

/// Detailed health information for parser import subsystem.
struct ParserImportHealthDetails: Codable, Equatable, Sendable {
    let scannedProviders: Int
    let importedUsageCount: Int
    let healthyProviders: Int
    let emptyProviders: Int
    let degradedProviders: Int
    let failedProviders: Int
    let conversationIndexingEnabled: Bool
    let providerStates: [ParserImportHealthProviderState]
}

/// Summary health state for parser import subsystem.
struct ParserImportHealthState: Equatable, Sendable {
    let status: RetrievalHealthStatus
    let scannedProviders: Int
    let importedUsageCount: Int
    let healthyProviders: Int
    let emptyProviders: Int
    let degradedProviders: Int
    let failedProviders: Int
    let errorCode: String?
    let errorMessage: String?
}

// MARK: - Projection Queue Health

/// Health state for the projection queue subsystem.
struct ProjectionQueueHealthState: Equatable, Sendable {
    let status: RetrievalHealthStatus
    let queueDepth: Int
    let failedJobs: Int
    let errorCode: String?
    let errorMessage: String?
}

// MARK: - Semantic Pipeline Health

/// Health state for the semantic (vector) retrieval pipeline.
struct SemanticPipelineHealthState: Equatable, Sendable {
    let status: RetrievalHealthStatus
    let backend: String?
    let embeddingVersionID: String?
    let indexedVectorCount: Int
    let fallbackToExact: Bool
    let candidateCount: Int
    let snapshotState: String?
    let snapshotFileBytes: Int64?
    let snapshotBuiltAt: Date?
    let errorCode: String?
    let errorMessage: String?
}

// MARK: - Rebuild Pipeline Health

/// Health state for the index rebuild/re-embed pipeline.
struct RebuildPipelineHealthState: Equatable, Sendable {
    let status: RetrievalHealthStatus
    let inProgress: Bool
    let pendingRebuildJobs: Int
    let pendingReembedJobs: Int
    let errorCode: String?
    let errorMessage: String?
}

// MARK: - System Health Snapshot

/// Complete snapshot of retrieval system health across all subsystems.
struct RetrievalSystemHealthSnapshot: Equatable, Sendable {
    let parserImport: ParserImportHealthState
    let projectionQueue: ProjectionQueueHealthState
    let semanticPipeline: SemanticPipelineHealthState
    let rebuild: RebuildPipelineHealthState
    let collaborationStatus: RetrievalHealthStatus?
    let degradedModes: [RetrievalDegradedState]
    let observedAt: Date

    /// Empty snapshot representing an uninitialized system.
    static let empty = RetrievalSystemHealthSnapshot(
        parserImport: ParserImportHealthState(
            status: .healthy,
            scannedProviders: 0,
            importedUsageCount: 0,
            healthyProviders: 0,
            emptyProviders: 0,
            degradedProviders: 0,
            failedProviders: 0,
            errorCode: nil,
            errorMessage: nil
        ),
        projectionQueue: ProjectionQueueHealthState(
            status: .healthy,
            queueDepth: 0,
            failedJobs: 0,
            errorCode: nil,
            errorMessage: nil
        ),
        semanticPipeline: SemanticPipelineHealthState(
            status: .healthy,
            backend: nil,
            embeddingVersionID: nil,
            indexedVectorCount: 0,
            fallbackToExact: false,
            candidateCount: 0,
            snapshotState: nil,
            snapshotFileBytes: nil,
            snapshotBuiltAt: nil,
            errorCode: nil,
            errorMessage: nil
        ),
        rebuild: RebuildPipelineHealthState(
            status: .healthy,
            inProgress: false,
            pendingRebuildJobs: 0,
            pendingReembedJobs: 0,
            errorCode: nil,
            errorMessage: nil
        ),
        collaborationStatus: nil,
        degradedModes: [],
        observedAt: .distantPast
    )
}
