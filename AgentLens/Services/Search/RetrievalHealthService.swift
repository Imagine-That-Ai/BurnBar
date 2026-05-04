import Foundation
import OpenBurnBarCore

// MARK: - Retrieval Health Service

/// Service for aggregating and reporting health status of the retrieval pipeline.
/// Monitors parser import, projection queue, semantic pipeline, and rebuild subsystems.
@MainActor
final class RetrievalHealthService {
    private struct ProjectionHealthDetailsPayload: Decodable {
        let queueDepth: Int
        let failedJobs: Int
    }

    private let dataStore: DataStore
    private let nowProvider: () -> Date

    private(set) var lastSnapshotError: String?

    init(dataStore: DataStore, nowProvider: @escaping () -> Date = Date.init) {
        self.dataStore = dataStore
        self.nowProvider = nowProvider
    }

    /// Creates a comprehensive health snapshot across all retrieval subsystems.
    func snapshot(
        indexingEnabled: Bool,
        sharedFeaturesAvailable: Bool
    ) -> RetrievalSystemHealthSnapshot {
        lastSnapshotError = nil
        let observedAt = nowProvider()

        let rows: [RetrievalHealthRecord]
        do {
            rows = try dataStore.fetchRetrievalHealth()
        } catch {
            lastSnapshotError = error.localizedDescription
            return failedSnapshot(
                error: error,
                indexingEnabled: indexingEnabled,
                sharedFeaturesAvailable: sharedFeaturesAvailable,
                observedAt: observedAt
            )
        }

        let healthBySubsystem = Dictionary(uniqueKeysWithValues: rows.map { ($0.subsystem, $0) })
        let parserImport = parserImportState(from: healthBySubsystem[.parserImport])
        let projection = projectionQueueState(from: healthBySubsystem[.projection])
        let semantic = semanticPipelineState(from: healthBySubsystem[.semantic])
        let rebuildCounts = pendingRebuildCounts()
        let rebuild = rebuildState(
            from: healthBySubsystem[.rebuild],
            pendingRebuildJobs: rebuildCounts.rebuild,
            pendingReembedJobs: rebuildCounts.reembed
        )
        let collaborationStatus = healthBySubsystem[.collaboration]?.status

        return RetrievalSystemHealthSnapshot(
            parserImport: parserImport,
            projectionQueue: projection,
            semanticPipeline: semantic,
            rebuild: rebuild,
            collaborationStatus: collaborationStatus,
            degradedModes: degradedModes(
                indexingEnabled: indexingEnabled,
                sharedFeaturesAvailable: sharedFeaturesAvailable,
                projection: projection,
                semantic: semantic,
                rebuild: rebuild,
                collaborationStatus: collaborationStatus
            ),
            observedAt: observedAt
        )
    }

    private func failedSnapshot(
        error: Error,
        indexingEnabled: Bool,
        sharedFeaturesAvailable: Bool,
        observedAt: Date
    ) -> RetrievalSystemHealthSnapshot {
        let failedProjection = ProjectionQueueHealthState(
            status: .failed,
            queueDepth: 0,
            failedJobs: 0,
            errorCode: "RETRIEVAL_HEALTH_FETCH_FAILED",
            errorMessage: error.localizedDescription
        )
        let failedSemantic = SemanticPipelineHealthState(
            status: .failed,
            backend: nil,
            embeddingVersionID: nil,
            indexedVectorCount: 0,
            fallbackToExact: false,
            candidateCount: 0,
            snapshotState: nil,
            snapshotFileBytes: nil,
            snapshotBuiltAt: nil,
            errorCode: "RETRIEVAL_HEALTH_FETCH_FAILED",
            errorMessage: error.localizedDescription
        )
        let rebuildCounts = pendingRebuildCounts()
        let rebuild = RebuildPipelineHealthState(
            status: .failed,
            inProgress: rebuildCounts.rebuild > 0 || rebuildCounts.reembed > 0,
            pendingRebuildJobs: rebuildCounts.rebuild,
            pendingReembedJobs: rebuildCounts.reembed,
            errorCode: "RETRIEVAL_HEALTH_FETCH_FAILED",
            errorMessage: error.localizedDescription
        )
        return RetrievalSystemHealthSnapshot(
            parserImport: RetrievalSystemHealthSnapshot.empty.parserImport,
            projectionQueue: failedProjection,
            semanticPipeline: failedSemantic,
            rebuild: rebuild,
            collaborationStatus: nil,
            degradedModes: degradedModes(
                indexingEnabled: indexingEnabled,
                sharedFeaturesAvailable: sharedFeaturesAvailable,
                projection: failedProjection,
                semantic: failedSemantic,
                rebuild: rebuild,
                collaborationStatus: nil
            ),
            observedAt: observedAt
        )
    }

    private func parserImportState(from row: RetrievalHealthRecord?) -> ParserImportHealthState {
        guard let row else {
            return RetrievalSystemHealthSnapshot.empty.parserImport
        }

        let details: ParserImportHealthDetails?
        if let json = row.detailsJSON?.data(using: .utf8) {
            details = try? JSONDecoder().decode(ParserImportHealthDetails.self, from: json)
        } else {
            details = nil
        }

        return ParserImportHealthState(
            status: row.status,
            scannedProviders: details?.scannedProviders ?? 0,
            importedUsageCount: details?.importedUsageCount ?? 0,
            healthyProviders: details?.healthyProviders ?? 0,
            emptyProviders: details?.emptyProviders ?? 0,
            degradedProviders: details?.degradedProviders ?? 0,
            failedProviders: details?.failedProviders ?? 0,
            errorCode: row.errorCode,
            errorMessage: row.errorMessage
        )
    }

    private func projectionQueueState(from row: RetrievalHealthRecord?) -> ProjectionQueueHealthState {
        guard let row else {
            return RetrievalSystemHealthSnapshot.empty.projectionQueue
        }

        let details: ProjectionHealthDetailsPayload?
        if let json = row.detailsJSON?.data(using: .utf8) {
            details = try? JSONDecoder().decode(ProjectionHealthDetailsPayload.self, from: json)
        } else {
            details = nil
        }

        return ProjectionQueueHealthState(
            status: row.status,
            queueDepth: max(0, details?.queueDepth ?? 0),
            failedJobs: max(0, details?.failedJobs ?? 0),
            errorCode: row.errorCode,
            errorMessage: row.errorMessage
        )
    }

    private func semanticPipelineState(from row: RetrievalHealthRecord?) -> SemanticPipelineHealthState {
        guard let row else {
            return RetrievalSystemHealthSnapshot.empty.semanticPipeline
        }

        var backend: String?
        var embeddingVersionID: String?
        var indexedVectorCount = 0
        var fallbackToExact = false
        var candidateCount = 0
        var snapshotState: String?
        var snapshotFileBytes: Int64?
        var snapshotBuiltAt: Date?

        if let rawDetails = decodeJSONDictionary(from: row.detailsJSON) {
            backend = stringValue(from: rawDetails["backend"])
            embeddingVersionID = stringValue(from: rawDetails["embeddingVersionID"])
            indexedVectorCount = intValue(from: rawDetails["indexedVectorCount"])
                ?? intValue(from: rawDetails["indexedChunkCount"])
                ?? 0
            fallbackToExact = boolValue(from: rawDetails["fallbackToExact"]) ?? false
            candidateCount = intValue(from: rawDetails["candidateCount"]) ?? 0
            snapshotState = stringValue(from: rawDetails["snapshotState"])
            if let intValue = intValue(from: rawDetails["snapshotFileBytes"]) {
                snapshotFileBytes = Int64(intValue)
            } else if let stringValue = stringValue(from: rawDetails["snapshotFileBytes"]) {
                snapshotFileBytes = Int64(stringValue)
            }
            if let builtAtRaw = stringValue(from: rawDetails["snapshotBuiltAt"]) {
                snapshotBuiltAt = OpenBurnBarDatabase.parseDateValue(builtAtRaw)
            }
        }

        return SemanticPipelineHealthState(
            status: row.status,
            backend: backend,
            embeddingVersionID: embeddingVersionID,
            indexedVectorCount: max(0, indexedVectorCount),
            fallbackToExact: fallbackToExact,
            candidateCount: max(0, candidateCount),
            snapshotState: snapshotState,
            snapshotFileBytes: snapshotFileBytes,
            snapshotBuiltAt: snapshotBuiltAt,
            errorCode: row.errorCode,
            errorMessage: row.errorMessage
        )
    }

    private func rebuildState(
        from row: RetrievalHealthRecord?,
        pendingRebuildJobs: Int,
        pendingReembedJobs: Int
    ) -> RebuildPipelineHealthState {
        let status = row?.status ?? .healthy
        return RebuildPipelineHealthState(
            status: status,
            inProgress: pendingRebuildJobs > 0 || pendingReembedJobs > 0,
            pendingRebuildJobs: pendingRebuildJobs,
            pendingReembedJobs: pendingReembedJobs,
            errorCode: row?.errorCode,
            errorMessage: row?.errorMessage
        )
    }

    private func pendingRebuildCounts() -> (rebuild: Int, reembed: Int) {
        do {
            let pending = try dataStore.fetchProjectionJobs(statuses: [.queued, .leased, .running], limit: 2_000)
            let rebuild = pending.filter { $0.jobType == .rebuild }.count
            let reembed = pending.filter { $0.jobType == .reembed }.count
            return (rebuild, reembed)
        } catch {
            lastSnapshotError = error.localizedDescription
            return (0, 0)
        }
    }

    private func degradedModes(
        indexingEnabled: Bool,
        sharedFeaturesAvailable: Bool,
        projection: ProjectionQueueHealthState,
        semantic: SemanticPipelineHealthState,
        rebuild: RebuildPipelineHealthState,
        collaborationStatus: RetrievalHealthStatus?
    ) -> [RetrievalDegradedState] {
        var modes: [RetrievalDegradedState] = []

        if indexingEnabled {
            if rebuild.inProgress {
                let rebuildMessage: String
                if rebuild.pendingRebuildJobs > 0 {
                    rebuildMessage = "Search rebuild is in progress. Results may lag until projection and re-embedding complete."
                } else {
                    rebuildMessage = "Re-embedding is in progress. Semantic ranking may be temporarily incomplete."
                }
                modes.append(
                    RetrievalDegradedState(
                        mode: .rebuildInProgress,
                        title: "Rebuild in progress",
                        message: rebuildMessage
                    )
                )
            }

            let indexStale = projection.status != .healthy || projection.queueDepth > 0 || projection.failedJobs > 0
            if indexStale {
                let indexMessage: String
                if projection.failedJobs > 0 {
                    indexMessage = "Search index is stale: \(projection.failedJobs) projection job(s) are failing."
                } else if projection.queueDepth > 0 {
                    indexMessage = "Search index is catching up: \(projection.queueDepth) projection job(s) are pending."
                } else {
                    indexMessage = projection.errorMessage ?? "Search index health is degraded."
                }
                modes.append(
                    RetrievalDegradedState(
                        mode: .indexStale,
                        title: "Index stale",
                        message: indexMessage
                    )
                )
            }

            let semanticUnavailable = semantic.status != .healthy || semantic.indexedVectorCount == 0
            if semanticUnavailable {
                let semanticMessage: String
                if semantic.indexedVectorCount == 0 {
                    semanticMessage = "Semantic retrieval is unavailable until chunk embeddings are indexed."
                } else {
                    semanticMessage = semantic.errorMessage ?? "Semantic retrieval is temporarily unavailable; lexical fallback remains active."
                }
                modes.append(
                    RetrievalDegradedState(
                        mode: .semanticUnavailable,
                        title: "Semantic unavailable",
                        message: semanticMessage
                    )
                )
            }
        }

        if sharedFeaturesAvailable == false || collaborationStatus == .failed || collaborationStatus == .degraded {
            modes.append(
                RetrievalDegradedState(
                    mode: .cloudSharedUnavailable,
                    title: "Cloud/shared unavailable",
                    message: "Cloud and shared artifact features are unavailable. Local search continues to work."
                )
            )
        }

        return modes
    }

    private func decodeJSONDictionary(from json: String?) -> [String: Any]? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func stringValue(from raw: Any?) -> String? {
        guard let value = raw as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func intValue(from raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let value = raw as? Int64 { return Int(value) }
        if let value = raw as? Double { return Int(value) }
        if let value = raw as? NSNumber { return value.intValue }
        if let value = raw as? String, let parsed = Int(value) { return parsed }
        return nil
    }

    private func boolValue(from raw: Any?) -> Bool? {
        if let value = raw as? Bool { return value }
        if let value = raw as? NSNumber { return value.boolValue }
        if let value = raw as? String {
            switch value.lowercased() {
            case "true", "1", "yes":
                return true
            case "false", "0", "no":
                return false
            default:
                return nil
            }
        }
        return nil
    }
}
