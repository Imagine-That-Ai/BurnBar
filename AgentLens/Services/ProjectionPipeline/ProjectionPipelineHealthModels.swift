import Foundation

struct ProjectionHealthDetails: Codable {
    let leaseOwner: String
    let projectorVersion: String
    let chunkerVersion: String
    let queueDepth: Int
    let failedJobs: Int
    let sweep: ProjectionSweepReport
    let performance: ProjectionSweepPerformanceDetails
    let latencySummary: ProjectionJobLatencySummary
}

struct ProjectionSweepPerformanceDetails: Codable {
    let sweepDurationMs: Double
    let throughputJobsPerSecond: Double
}

struct ProjectionJobLatencySummary: Codable {
    let sampledCompletedJobs: Int
    let queueWaitMs: ProjectionLatencyDistribution?
    let processingMs: ProjectionLatencyDistribution?
    let endToEndMs: ProjectionLatencyDistribution?
}

struct ProjectionLatencyDistribution: Codable {
    let count: Int
    let p50Ms: Double
    let p95Ms: Double
    let maxMs: Double
}

struct SemanticProjectionHealthDetails: Codable {
    let embeddingModelID: String
    let embeddingVersionID: String
    let provider: String
    let modelName: String
    let dimensions: Int
    let distanceMetric: String
    let sourceKind: String?
    let sourceID: String?
    let indexedChunkCount: Int
    let strictMode: Bool
}

struct RebuildHealthDetails: Codable {
    let projectorVersion: String
    let chunkerVersion: String
    let embeddingVersionID: String
    let enqueuedReprojects: Int
    let enqueuedPurges: Int
    let enqueuedReembedJobs: Int
}

struct ReembedProjectionPayload: Codable {
    let reason: String
    let targetEmbeddingVersionID: String
    let sourceKind: String?
    let sourceID: String?
}

enum ProjectionPipelineError: LocalizedError {
    case invalidJobPayload(String)
    case unsupportedJobType(ProjectionJobType)
    case embeddingFailure(String)

    static func code(for error: Error) -> String {
        if let pipelineError = error as? ProjectionPipelineError {
            return pipelineError.code
        }
        return "PROJECTION_RUNTIME_ERROR"
    }

    var code: String {
        switch self {
        case .invalidJobPayload:
            return "PROJECTION_INVALID_JOB_PAYLOAD"
        case .unsupportedJobType:
            return "PROJECTION_UNSUPPORTED_JOB_TYPE"
        case .embeddingFailure:
            return "SEMANTIC_EMBEDDING_FAILURE"
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidJobPayload(let message):
            return message
        case .unsupportedJobType(let type):
            return "Projection job type \(type.rawValue) is not supported by this pipeline."
        case .embeddingFailure(let message):
            return message
        }
    }
}
