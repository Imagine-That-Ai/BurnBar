import CryptoKit
import Dispatch
import Foundation

enum OpenBurnBarProjectionPerformanceTimer {
    static func now() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    static func elapsedMilliseconds(since start: UInt64) -> Double {
        let end = DispatchTime.now().uptimeNanoseconds
        guard end >= start else { return 0 }
        return Double(end - start) / 1_000_000
    }
}

enum ProjectionPipelineRuntimeTuning {
    /// Keep per-pass work bounded so indexing remains low-impact.
    static let defaultSweepMaxJobs = 24
    /// Skip gap-repair corpus scans when there is already a large projection backlog.
    static let gapRepairQueueDepthThreshold = 120
    /// Batch chunk embedding/upsert to avoid large CPU and memory spikes.
    static let embeddingBatchSize = 24
    /// Yield periodically while persisting embeddings.
    static let embeddingWriteYieldInterval = 8
    /// Brief pause between embedding batches to reduce contention.
    static let interEmbeddingBatchPauseNanoseconds: UInt64 = 20_000_000
    /// Yield every N leased jobs during sweep processing.
    static let sweepYieldInterval = 4
    /// Yield every N enqueues during rebuild fan-out.
    static let rebuildEnqueueYieldInterval = 100
}

enum ProjectionIdentity {
    static let projectorVersion = "openburnbar-projector-v1"
    static let chunkerVersion = "openburnbar-chunker-v1"
    static let deletedSourceVersionID = "deleted:\(projectorVersion)"

    static func sourceVersion(contentVersion: String) -> String {
        "\(contentVersion):\(projectorVersion)"
    }

    static func conversationContentHash(for record: ConversationRecord) -> String {
        let payload = [
            record.provider.rawValue,
            record.sessionId,
            record.projectName,
            record.inferredTaskTitle,
            record.lastAssistantMessage,
            record.fullText,
            record.keyFiles.joined(separator: "\u{1F}"),
            record.keyCommands.joined(separator: "\u{1F}"),
            record.keyTools.joined(separator: "\u{1F}"),
            record.sourceType.rawValue,
            record.startTime?.timeIntervalSince1970.description ?? "",
            record.endTime?.timeIntervalSince1970.description ?? "",
            String(record.messageCount)
        ].joined(separator: "\u{1E}")
        return sha256Hex(payload)
    }

    static func conversationSourceVersionID(for record: ConversationRecord) -> String {
        sourceVersion(contentVersion: conversationContentHash(for: record))
    }

    static func artifactSourceVersionID(contentHash: String) -> String {
        sourceVersion(contentVersion: contentHash)
    }

    static func documentID(sourceKind: SearchSourceKind, sourceID: String) -> String {
        "doc-\(sourceKind.rawValue)-\(sha256Hex(sourceID.lowercased()))"
    }

    static func chunkID(
        documentID: String,
        sourceVersionID: String,
        ordinal: Int,
        startOffset: Int,
        endOffset: Int,
        sectionPath: String?
    ) -> String {
        let payload = "\(documentID)|\(sourceVersionID)|\(ordinal)|\(startOffset)|\(endOffset)|\(sectionPath ?? "")"
        return "chunk-\(sha256Hex(payload))"
    }

    static func jobID(jobType: ProjectionJobType, sourceKind: SearchSourceKind, sourceID: String, sourceVersionID: String) -> String {
        let payload = "\(jobType.rawValue)|\(sourceKind.rawValue)|\(sourceID)|\(sourceVersionID)"
        return "projection-\(sha256Hex(payload))"
    }

    static func rebuildJobID(seed: String) -> String {
        "projection-rebuild-\(sha256Hex(seed))"
    }

    static func reembedJobID(seed: String) -> String {
        "projection-reembed-\(sha256Hex(seed))"
    }

    static func sha256Hex(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Computes a content-based hash for a chunk that is stable across re-projections.
    /// Unlike the chunk ID (which includes sourceVersionID, ordinal, and offsets),
    /// this hash depends only on the chunk's text content and structural context (sectionPath).
    /// Used for incremental diffing: chunks with the same contentHash can skip re-embedding.
    static func chunkContentHash(
        text: String,
        sectionPath: String?,
        sourceKind: SearchSourceKind
    ) -> String {
        let payload = "\(sourceKind.rawValue)|\(sectionPath ?? "")|\(text)"
        return "cch-\(sha256Hex(payload))"
    }
}

struct ProjectionSweepReport: Equatable, Sendable, Codable {
    var leasedJobs: Int = 0
    var completedJobs: Int = 0
    var retriedJobs: Int = 0
    var canceledJobs: Int = 0
}
