import Foundation
import Dispatch
import BurnBarCore

// Retrieval flow (shared service path):
// query
//   -> lexical candidates from search_chunks_fts (always)
//   -> optional semantic candidates (ANN -> exact fallback)
//   -> bounded rerank + source hydration
//   -> RBAC/visibility filtering + snippets/context

private enum BurnBarPerformanceTimer {
    static func now() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    static func elapsedMilliseconds(since start: UInt64) -> Double {
        let end = DispatchTime.now().uptimeNanoseconds
        guard end >= start else { return 0 }
        return Double(end - start) / 1_000_000
    }
}

// #region agent log
private enum AgentDebugLog86435e {
    static let path = "/Users/albertonunez/Developer/AgentLens/.cursor/debug-86435e.log"
    static let sessionId = "86435e"

    static func append(hypothesisId: String, location: String, message: String, data: [String: Any]) {
        let payload: [String: Any] = [
            "sessionId": sessionId,
            "hypothesisId": hypothesisId,
            "location": location,
            "message": message,
            "data": data,
            "timestamp": Int(Date().timeIntervalSince1970 * 1000)
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let json = try? JSONSerialization.data(withJSONObject: payload),
              let line = String(data: json, encoding: .utf8) else { return }
        let url = URL(fileURLWithPath: path)
        let out = Data((line + "\n").utf8)
        if FileManager.default.fileExists(atPath: path),
           let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            try? h.seekToEnd()
            try? h.write(contentsOf: out)
        } else {
            try? out.write(to: url)
        }
    }
}
// #endregion

// MARK: - Search Result

struct SearchResult: Identifiable {
    var id: String { conversation.id }
    let conversation: ConversationRecord
    let snippet: String
    let rank: Double
}

enum RetrievalDegradedMode: String, CaseIterable, Identifiable, Sendable {
    case indexStale
    case semanticUnavailable
    case rebuildInProgress
    case cloudSharedUnavailable

    var id: String { rawValue }
}

struct RetrievalDegradedState: Identifiable, Equatable, Sendable {
    let mode: RetrievalDegradedMode
    let title: String
    let message: String

    var id: String { mode.id }
}

struct ParserImportHealthProviderState: Codable, Equatable, Sendable {
    let provider: String
    let status: String
    let sessionCount: Int
    let errorMessage: String?
}

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

struct ProjectionQueueHealthState: Equatable, Sendable {
    let status: RetrievalHealthStatus
    let queueDepth: Int
    let failedJobs: Int
    let errorCode: String?
    let errorMessage: String?
}

struct SemanticPipelineHealthState: Equatable, Sendable {
    let status: RetrievalHealthStatus
    let backend: String?
    let embeddingVersionID: String?
    let indexedVectorCount: Int
    let fallbackToExact: Bool
    let candidateCount: Int
    let errorCode: String?
    let errorMessage: String?
}

struct RebuildPipelineHealthState: Equatable, Sendable {
    let status: RetrievalHealthStatus
    let inProgress: Bool
    let pendingRebuildJobs: Int
    let pendingReembedJobs: Int
    let errorCode: String?
    let errorMessage: String?
}

struct RetrievalSystemHealthSnapshot: Equatable, Sendable {
    let parserImport: ParserImportHealthState
    let projectionQueue: ProjectionQueueHealthState
    let semanticPipeline: SemanticPipelineHealthState
    let rebuild: RebuildPipelineHealthState
    let collaborationStatus: RetrievalHealthStatus?
    let degradedModes: [RetrievalDegradedState]
    let observedAt: Date

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

        if let rawDetails = decodeJSONDictionary(from: row.detailsJSON) {
            backend = stringValue(from: rawDetails["backend"])
            embeddingVersionID = stringValue(from: rawDetails["embeddingVersionID"])
            indexedVectorCount = intValue(from: rawDetails["indexedVectorCount"])
                ?? intValue(from: rawDetails["indexedChunkCount"])
                ?? 0
            fallbackToExact = boolValue(from: rawDetails["fallbackToExact"]) ?? false
            candidateCount = intValue(from: rawDetails["candidateCount"]) ?? 0
        }

        return SemanticPipelineHealthState(
            status: row.status,
            backend: backend,
            embeddingVersionID: embeddingVersionID,
            indexedVectorCount: max(0, indexedVectorCount),
            fallbackToExact: fallbackToExact,
            candidateCount: max(0, candidateCount),
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

struct EmbeddingModelDescriptor: Equatable, Sendable {
    let provider: String
    let modelName: String
    let dimensions: Int
    let distanceMetric: EmbeddingDistanceMetric
    let versionTag: String
    let chunkerVersion: String
    let normalizationVersion: String
    let promptVersion: String

    init(
        provider: String,
        modelName: String,
        dimensions: Int,
        distanceMetric: EmbeddingDistanceMetric,
        versionTag: String,
        chunkerVersion: String,
        normalizationVersion: String,
        promptVersion: String
    ) {
        self.provider = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        self.modelName = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.dimensions = max(1, dimensions)
        self.distanceMetric = distanceMetric
        self.versionTag = versionTag.trimmingCharacters(in: .whitespacesAndNewlines)
        self.chunkerVersion = chunkerVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        self.normalizationVersion = normalizationVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        self.promptVersion = promptVersion.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum EmbeddingIdentity {
    static func modelID(for descriptor: EmbeddingModelDescriptor) -> String {
        let payload = [
            descriptor.provider.lowercased(),
            descriptor.modelName.lowercased(),
            String(descriptor.dimensions),
            descriptor.distanceMetric.rawValue
        ].joined(separator: "|")
        return "embedding-model-\(ProjectionIdentity.sha256Hex(payload))"
    }

    static func versionID(for descriptor: EmbeddingModelDescriptor) -> String {
        let payload = [
            modelID(for: descriptor),
            descriptor.versionTag.lowercased(),
            descriptor.chunkerVersion.lowercased(),
            descriptor.normalizationVersion.lowercased(),
            descriptor.promptVersion.lowercased()
        ].joined(separator: "|")
        return "embedding-version-\(ProjectionIdentity.sha256Hex(payload))"
    }
}

@MainActor
protocol ChunkEmbeddingProviding {
    var descriptor: EmbeddingModelDescriptor { get }
    func embedding(for text: String) async throws -> [Float]
}

extension ChunkEmbeddingProviding {
    func embeddings(for texts: [String]) async throws -> [[Float]] {
        var results: [[Float]] = []
        results.reserveCapacity(texts.count)
        for text in texts {
            results.append(try await embedding(for: text))
        }
        return results
    }
}

struct DeterministicFakeEmbeddingProvider: ChunkEmbeddingProviding, Sendable {
    let descriptor: EmbeddingModelDescriptor
    private let seed: String

    init(
        provider: String = "burnbar",
        modelName: String = "deterministic-fake-embedding",
        dimensions: Int = 96,
        distanceMetric: EmbeddingDistanceMetric = .cosine,
        versionTag: String = "ci-v1",
        chunkerVersion: String = "burnbar-chunker-v1",
        normalizationVersion: String = "unit-l2-v1",
        promptVersion: String = "plain-text-v1",
        seed: String = "burnbar-deterministic-embedding-seed-v1"
    ) {
        self.descriptor = EmbeddingModelDescriptor(
            provider: provider,
            modelName: modelName,
            dimensions: dimensions,
            distanceMetric: distanceMetric,
            versionTag: versionTag,
            chunkerVersion: chunkerVersion,
            normalizationVersion: normalizationVersion,
            promptVersion: promptVersion
        )
        self.seed = seed
    }

    func embedding(for text: String) async throws -> [Float] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        var vector = [Float](repeating: 0, count: descriptor.dimensions)
        let tokens = normalized
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline || $0.isPunctuation })
            .map(String.init)
            .filter { $0.isEmpty == false }

        let sourceTokens = tokens.isEmpty ? [normalized] : tokens
        for (position, token) in sourceTokens.enumerated() {
            let payload = "\(seed)|\(position)|\(token)"
            let digest = ProjectionIdentity.sha256Hex(payload)
            let bytes = digest.utf8.map { UInt8($0) }
            let weight = 1.0 / Float(max(1, position + 1))
            apply(bytes: bytes, weight: weight, into: &vector)
        }

        if sourceTokens.isEmpty {
            vector[0] = 1
        }
        return VectorMath.l2Normalized(vector)
    }

    private func apply(bytes: [UInt8], weight: Float, into vector: inout [Float]) {
        guard vector.isEmpty == false, bytes.isEmpty == false else { return }
        let width = min(16, bytes.count)
        for lane in 0..<width {
            let index = (Int(bytes[lane]) + lane * 131) % vector.count
            let sign: Float = (lane % 2 == 0) ? 1 : -1
            let magnitude = (Float(bytes[lane] % 31) / 30.0) + 0.15
            vector[index] += sign * magnitude * weight
        }
    }
}

@MainActor
final class DeterministicQueryEmbeddingProvider: QueryEmbeddingProviding {
    private let embedder: DeterministicFakeEmbeddingProvider

    init(embedder: DeterministicFakeEmbeddingProvider = DeterministicFakeEmbeddingProvider()) {
        self.embedder = embedder
    }

    var descriptor: EmbeddingModelDescriptor { embedder.descriptor }

    func embedding(for text: String) async throws -> [Float] {
        try await embedder.embedding(for: text)
    }
}

enum OpenAIEmbeddingProviderError: LocalizedError {
    case missingAPIKey
    case unsupportedModel(String)
    case invalidBaseURL
    case unexpectedResponse(statusCode: Int, message: String?)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "OpenAI indexing requires an API key."
        case .unsupportedModel(let model):
            return "Unsupported OpenAI embedding model: \(model)"
        case .invalidBaseURL:
            return "The OpenAI embeddings endpoint URL is invalid."
        case .unexpectedResponse(let statusCode, let message):
            if let message, message.isEmpty == false {
                return "OpenAI embeddings request failed (\(statusCode)): \(message)"
            }
            return "OpenAI embeddings request failed with status \(statusCode)."
        case .invalidResponse:
            return "OpenAI embeddings returned an invalid response."
        }
    }
}

@MainActor
final class OpenAIEmbeddingProvider: ChunkEmbeddingProviding, QueryEmbeddingProviding {
    private struct EmbeddingResponse: Decodable {
        struct Item: Decodable {
            let embedding: [Float]
        }

        struct APIError: Decodable {
            struct Details: Decodable {
                let message: String?
            }

            let error: Details?
        }

        let data: [Item]
    }

    static let supportedModels: [String] = [
        "text-embedding-3-small",
        "text-embedding-3-large",
        "text-embedding-ada-002",
    ]

    let descriptor: EmbeddingModelDescriptor
    private let apiKey: String
    private let baseURL: String
    private let session: URLSession

    init(
        apiKey: String,
        modelName: String,
        versionTag: String = "openai-v1",
        chunkerVersion: String = ProjectionIdentity.chunkerVersion,
        normalizationVersion: String = "unit-l2-v1",
        promptVersion: String = "plain-text-v1",
        baseURL: String = "https://api.openai.com/v1",
        session: URLSession = .shared
    ) throws {
        let dimensions = try Self.dimensions(for: modelName)
        self.descriptor = EmbeddingModelDescriptor(
            provider: "openai",
            modelName: modelName,
            dimensions: dimensions,
            distanceMetric: .cosine,
            versionTag: versionTag,
            chunkerVersion: chunkerVersion,
            normalizationVersion: normalizationVersion,
            promptVersion: promptVersion
        )
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
    }

    static func dimensions(for modelName: String) throws -> Int {
        switch modelName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "text-embedding-3-small":
            return 1536
        case "text-embedding-3-large":
            return 3072
        case "text-embedding-ada-002":
            return 1536
        default:
            throw OpenAIEmbeddingProviderError.unsupportedModel(modelName)
        }
    }

    func embedding(for text: String) async throws -> [Float] {
        let vectors = try await embeddings(for: [text])
        return vectors.first ?? []
    }

    func embeddings(for texts: [String]) async throws -> [[Float]] {
        let input = texts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
        guard input.isEmpty == false else { return [] }
        guard apiKey.isEmpty == false else { throw OpenAIEmbeddingProviderError.missingAPIKey }
        guard let url = URL(string: baseURL + "/embeddings") else {
            throw OpenAIEmbeddingProviderError.invalidBaseURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": descriptor.modelName,
            "input": input,
            "encoding_format": "float",
        ])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenAIEmbeddingProviderError.invalidResponse
        }

        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(EmbeddingResponse.APIError.self, from: data))?.error?.message
            throw OpenAIEmbeddingProviderError.unexpectedResponse(statusCode: http.statusCode, message: message)
        }

        let payload = try JSONDecoder().decode(EmbeddingResponse.self, from: data)
        let vectors = payload.data.map(\.embedding)
        guard vectors.count == input.count else {
            throw OpenAIEmbeddingProviderError.invalidResponse
        }
        return vectors
    }
}

enum VectorBlobCodec {
    static func encode(_ vector: [Float]) -> Data {
        guard vector.isEmpty == false else { return Data() }
        return vector.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
    }

    static func decode(_ data: Data) -> [Float]? {
        let stride = MemoryLayout<Float>.size
        guard data.isEmpty == false, data.count % stride == 0 else { return nil }
        let count = data.count / stride
        return data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.bindMemory(to: Float.self).baseAddress else { return nil }
            return Array(UnsafeBufferPointer(start: base, count: count))
        }
    }
}

enum VectorMath {
    static func similarity(lhs: [Float], rhs: [Float], metric: EmbeddingDistanceMetric) -> Double {
        switch metric {
        case .cosine:
            return cosineSimilarity(lhs: lhs, rhs: rhs)
        case .dotProduct:
            return dotProduct(lhs: lhs, rhs: rhs)
        case .euclidean:
            return -euclideanDistance(lhs: lhs, rhs: rhs)
        }
    }

    static func l2Normalized(_ vector: [Float]) -> [Float] {
        guard vector.isEmpty == false else { return vector }
        var sumSquares: Double = 0
        for value in vector {
            let cast = Double(value)
            sumSquares += cast * cast
        }
        guard sumSquares > 0 else { return vector }
        let norm = Float(sqrt(sumSquares))
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }

    private static func cosineSimilarity(lhs: [Float], rhs: [Float]) -> Double {
        guard lhs.count == rhs.count, lhs.isEmpty == false else { return 0 }
        var dot: Double = 0
        var lhsNorm: Double = 0
        var rhsNorm: Double = 0
        for index in lhs.indices {
            let l = Double(lhs[index])
            let r = Double(rhs[index])
            dot += l * r
            lhsNorm += l * l
            rhsNorm += r * r
        }
        guard lhsNorm > 0, rhsNorm > 0 else { return 0 }
        return dot / (sqrt(lhsNorm) * sqrt(rhsNorm))
    }

    private static func dotProduct(lhs: [Float], rhs: [Float]) -> Double {
        guard lhs.count == rhs.count, lhs.isEmpty == false else { return 0 }
        var dot: Double = 0
        for index in lhs.indices {
            dot += Double(lhs[index]) * Double(rhs[index])
        }
        return dot
    }

    private static func euclideanDistance(lhs: [Float], rhs: [Float]) -> Double {
        guard lhs.count == rhs.count, lhs.isEmpty == false else { return 0 }
        var sumSquares: Double = 0
        for index in lhs.indices {
            let diff = Double(lhs[index] - rhs[index])
            sumSquares += diff * diff
        }
        return sqrt(sumSquares)
    }
}

enum VectorBackendKind: String, Codable, CaseIterable, Sendable {
    case ann
    case exact
}

enum VectorIndexBackendError: LocalizedError {
    case dimensionMismatch(expected: Int, actual: Int)

    var errorDescription: String? {
        switch self {
        case .dimensionMismatch(let expected, let actual):
            return "Vector dimension mismatch. Expected \(expected), got \(actual)."
        }
    }
}

struct VectorIndexEntry: Sendable {
    let chunkID: String
    let vector: [Float]
}

struct VectorIndexCandidate: Sendable {
    let chunkID: String
    let score: Double
}

protocol VectorCandidateBackend: AnyObject {
    var id: String { get }
    func rebuild(entries: [VectorIndexEntry], distanceMetric: EmbeddingDistanceMetric) throws
    func candidates(for queryVector: [Float], limit: Int) throws -> [VectorIndexCandidate]
}

final class ExactVectorCandidateBackend: VectorCandidateBackend {
    let id = "exact_scan_v1"
    private var entries: [VectorIndexEntry] = []
    private var distanceMetric: EmbeddingDistanceMetric = .cosine
    private var dimensions = 0

    func rebuild(entries: [VectorIndexEntry], distanceMetric: EmbeddingDistanceMetric) throws {
        self.entries = entries
        self.distanceMetric = distanceMetric
        self.dimensions = entries.first?.vector.count ?? 0
    }

    func candidates(for queryVector: [Float], limit: Int) throws -> [VectorIndexCandidate] {
        guard limit > 0, entries.isEmpty == false else { return [] }
        guard dimensions == 0 || queryVector.count == dimensions else {
            throw VectorIndexBackendError.dimensionMismatch(expected: dimensions, actual: queryVector.count)
        }

        var scored: [VectorIndexCandidate] = []
        scored.reserveCapacity(entries.count)
        for entry in entries {
            let score = VectorMath.similarity(lhs: queryVector, rhs: entry.vector, metric: distanceMetric)
            guard score.isFinite else { continue }
            scored.append(VectorIndexCandidate(chunkID: entry.chunkID, score: score))
        }

        scored.sort {
            if $0.score == $1.score {
                return $0.chunkID < $1.chunkID
            }
            return $0.score > $1.score
        }

        if scored.count > limit {
            return Array(scored.prefix(limit))
        }
        return scored
    }
}

final class SignpostANNVectorCandidateBackend: VectorCandidateBackend {
    let id = "ann_signpost_v1"

    private let bucketBits: Int
    private let candidateMultiplier: Int
    private let maxHammingDistance: Int
    private var distanceMetric: EmbeddingDistanceMetric = .cosine
    private var dimensions = 0
    private var buckets: [UInt64: [VectorIndexEntry]] = [:]
    private var allEntries: [VectorIndexEntry] = []

    init(
        bucketBits: Int = 12,
        candidateMultiplier: Int = 6,
        maxHammingDistance: Int = 1
    ) {
        self.bucketBits = max(4, min(bucketBits, 24))
        self.candidateMultiplier = max(2, candidateMultiplier)
        self.maxHammingDistance = max(0, min(maxHammingDistance, 2))
    }

    func rebuild(entries: [VectorIndexEntry], distanceMetric: EmbeddingDistanceMetric) throws {
        self.distanceMetric = distanceMetric
        self.dimensions = entries.first?.vector.count ?? 0
        self.buckets.removeAll(keepingCapacity: true)
        self.allEntries = entries.sorted { $0.chunkID < $1.chunkID }

        for entry in allEntries {
            guard dimensions == 0 || entry.vector.count == dimensions else { continue }
            let signature = signature(for: entry.vector)
            buckets[signature, default: []].append(entry)
        }
    }

    func candidates(for queryVector: [Float], limit: Int) throws -> [VectorIndexCandidate] {
        guard limit > 0, allEntries.isEmpty == false else { return [] }
        guard dimensions == 0 || queryVector.count == dimensions else {
            throw VectorIndexBackendError.dimensionMismatch(expected: dimensions, actual: queryVector.count)
        }

        let signature = signature(for: queryVector)
        let targetCount = min(allEntries.count, max(limit * candidateMultiplier, limit))
        var selectedIDs: [String] = []
        selectedIDs.reserveCapacity(targetCount)
        var seen = Set<String>()

        func appendBucket(_ key: UInt64) {
            guard let entries = buckets[key], entries.isEmpty == false else { return }
            for entry in entries {
                guard seen.insert(entry.chunkID).inserted else { continue }
                selectedIDs.append(entry.chunkID)
                if selectedIDs.count >= targetCount { break }
            }
        }

        appendBucket(signature)

        if selectedIDs.count < targetCount, maxHammingDistance > 0 {
            for distance in 1...maxHammingDistance {
                for neighbor in neighbors(of: signature, distance: distance).sorted() {
                    appendBucket(neighbor)
                    if selectedIDs.count >= targetCount { break }
                }
                if selectedIDs.count >= targetCount { break }
            }
        }

        if selectedIDs.count < limit {
            for entry in allEntries {
                guard seen.insert(entry.chunkID).inserted else { continue }
                selectedIDs.append(entry.chunkID)
                if selectedIDs.count >= targetCount { break }
            }
        }

        let selectedEntries = Dictionary(uniqueKeysWithValues: allEntries.map { ($0.chunkID, $0) })
        var scored: [VectorIndexCandidate] = []
        scored.reserveCapacity(selectedIDs.count)
        for chunkID in selectedIDs {
            guard let entry = selectedEntries[chunkID] else { continue }
            let score = VectorMath.similarity(lhs: queryVector, rhs: entry.vector, metric: distanceMetric)
            guard score.isFinite else { continue }
            scored.append(VectorIndexCandidate(chunkID: entry.chunkID, score: score))
        }

        scored.sort {
            if $0.score == $1.score {
                return $0.chunkID < $1.chunkID
            }
            return $0.score > $1.score
        }
        if scored.count > limit {
            return Array(scored.prefix(limit))
        }
        return scored
    }

    private func signature(for vector: [Float]) -> UInt64 {
        guard vector.isEmpty == false else { return 0 }
        var signature: UInt64 = 0
        for bit in 0..<bucketBits {
            let index = dimension(forBit: bit, dimensions: vector.count)
            if vector[index] >= 0 {
                signature |= (UInt64(1) << UInt64(bit))
            }
        }
        return signature
    }

    private func dimension(forBit bit: Int, dimensions: Int) -> Int {
        let prime = 2_147_483_647
        let raw = (bit * 73_856_093 + 19_349_663) % prime
        return raw % max(1, dimensions)
    }

    private func neighbors(of signature: UInt64, distance: Int) -> [UInt64] {
        guard distance > 0 else { return [signature] }
        if distance == 1 {
            return (0..<bucketBits).map { bit in
                signature ^ (UInt64(1) << UInt64(bit))
            }
        }

        guard distance == 2 else { return [signature] }
        var values: [UInt64] = []
        values.reserveCapacity(bucketBits * max(0, bucketBits - 1) / 2)
        for first in 0..<bucketBits {
            for second in (first + 1)..<bucketBits {
                values.append(signature ^ (UInt64(1) << UInt64(first)) ^ (UInt64(1) << UInt64(second)))
            }
        }
        return values
    }
}

enum RetrievalOwnershipFilter: String, CaseIterable {
    case any
    case personal
    case shared

    var visibilityScope: SearchVisibilityScope {
        switch self {
        case .any:
            return .all
        case .personal:
            return .personalOnly
        case .shared:
            return .sharedOnly
        }
    }
}

/// How lexical (BM25/FTS) and dense vector hits are merged before hydration and final scoring.
enum HybridFusionStrategy: String, Codable, Sendable, CaseIterable {
    /// Prior weighted blend of normalized lexical rank and semantic similarity (legacy behavior).
    case legacyWeighted
    /// Reciprocal rank fusion across lexical and semantic ranked lists (robust across score scales).
    case reciprocalRankFusion
}

private enum HybridRetrievalConstants {
    /// Standard RRF smoothing constant (see Cormack et al. / Elasticsearch RRF).
    static let rrfK: Double = 60
}

struct RetrievalFilters {
    var provider: AgentProvider?
    var projectName: String?
    var artifactTypes: Set<SearchSourceKind>?
    var dateRange: ClosedRange<Date>?
    var ownership: RetrievalOwnershipFilter
    var sourceIDs: Set<String>?
    var conversationSources: Set<ConversationSourceType>?

    init(
        provider: AgentProvider? = nil,
        projectName: String? = nil,
        artifactTypes: Set<SearchSourceKind>? = nil,
        dateRange: ClosedRange<Date>? = nil,
        ownership: RetrievalOwnershipFilter = .any,
        sourceIDs: Set<String>? = nil,
        conversationSources: Set<ConversationSourceType>? = nil
    ) {
        self.provider = provider
        self.projectName = projectName
        self.artifactTypes = artifactTypes
        self.dateRange = dateRange
        self.ownership = ownership
        self.sourceIDs = sourceIDs
        self.conversationSources = conversationSources
    }
}

struct RetrievalQuery {
    var text: String
    /// When set, used as the FTS5 `MATCH` string for lexical chunk search instead of deriving from `text`.
    var lexicalFTSQuery: String?
    var filters: RetrievalFilters
    var lexicalCandidateLimit: Int
    var semanticCandidateLimit: Int
    var rerankCandidateLimit: Int
    var resultLimit: Int
    var hybridFusionStrategy: HybridFusionStrategy
    /// When true, enables cross-encoder reranking on hydrated candidates.
    /// Defaults to false. Bypassed if the SearchService has no reranker configured.
    var crossEncoderEnabled: Bool
    /// Maximum number of candidates to send to cross-encoder reranking.
    /// Helps cap latency and cost. Defaults to 40, capped at 64.
    var crossEncoderCandidateLimit: Int

    init(
        text: String,
        lexicalFTSQuery: String? = nil,
        filters: RetrievalFilters = RetrievalFilters(),
        lexicalCandidateLimit: Int = 120,
        semanticCandidateLimit: Int = 120,
        rerankCandidateLimit: Int = 200,
        resultLimit: Int = 50,
        hybridFusionStrategy: HybridFusionStrategy = .reciprocalRankFusion,
        crossEncoderEnabled: Bool = false,
        crossEncoderCandidateLimit: Int = 40
    ) {
        self.text = text
        self.lexicalFTSQuery = lexicalFTSQuery
        self.filters = filters
        self.lexicalCandidateLimit = lexicalCandidateLimit
        self.semanticCandidateLimit = semanticCandidateLimit
        self.rerankCandidateLimit = rerankCandidateLimit
        self.resultLimit = resultLimit
        self.hybridFusionStrategy = hybridFusionStrategy
        self.crossEncoderEnabled = crossEncoderEnabled
        self.crossEncoderCandidateLimit = max(5, min(crossEncoderCandidateLimit, 64))
    }
}

/// Result of `SearchService.runBurnBarQuery`: hybrid retrieval plus optional aggregate counts over transcripts.
struct BurnBarQueryRunResult: Sendable {
    let plan: BurnBarSearchPlan
    let retrievalResults: [RetrievalResult]
    /// Total substring occurrences summed across patterns in `conversations.fullText` (non-overlapping per pattern per row).
    let aggregateOccurrenceCount: Int?
    /// Human-readable note when a relative time phrase was turned into `dateRange` for the query.
    let aggregateWindowDescription: String?
}

struct RetrievalResult: Identifiable {
    let chunkID: String
    let documentID: String
    let sourceKind: SearchSourceKind
    let sourceID: String
    let provider: AgentProvider?
    let providerRawValue: String?
    let projectName: String?
    let title: String
    let subtitle: String?
    let snippet: String
    let sectionPath: String?
    let startOffset: Int
    let endOffset: Int
    let sourceUpdatedAt: Date?
    let indexedAt: Date
    let lexicalRank: Double?
    let semanticScore: Double?
    let rerankScore: Double
    let conversation: ConversationRecord?

    var id: String { chunkID }
}

struct SemanticCandidate {
    let chunkID: String
    let score: Double
}

@MainActor
protocol SemanticCandidateProviding {
    func semanticCandidates(for query: String, filters: RetrievalFilters, limit: Int) async throws -> [SemanticCandidate]
}

@MainActor
protocol QueryEmbeddingProviding {
    func embedding(for text: String) async throws -> [Float]
}

@MainActor
final class VectorSemanticCandidateProvider: SemanticCandidateProviding {
    private struct ActiveEmbeddingSelection {
        let model: EmbeddingModelRecord
        let version: EmbeddingVersionRecord
    }

    private struct CandidateGatherMetrics {
        var candidateGenerationLatencyMs: Double?
        var annCandidateGenerationLatencyMs: Double?
        var exactRerankLatencyMs: Double?
        var fallbackExactLatencyMs: Double?
    }

    private let dataStore: DataStore
    private let queryEmbedder: QueryEmbeddingProviding
    private let configuredEmbeddingVersionID: String?
    private let backend: VectorBackendKind
    private let exactRerankEnabled: Bool
    private let exactRerankLimit: Int
    private let nowProvider: () -> Date
    private let annBackend: SignpostANNVectorCandidateBackend
    private let exactBackend: ExactVectorCandidateBackend

    private var vectorsByChunkID: [String: [Float]] = [:]
    private var indexFingerprint: String?
    private var indexedEmbeddingVersionID: String?
    private var indexedDistanceMetric: EmbeddingDistanceMetric = .cosine
    private var indexedVectorCount = 0
    private var indexedDimensions = 0
    private(set) var lastHealthWriteError: String?

    init(
        dataStore: DataStore,
        queryEmbedder: QueryEmbeddingProviding,
        embeddingVersionID: String? = nil,
        backend: VectorBackendKind = .ann,
        exactRerankEnabled: Bool = true,
        exactRerankLimit: Int = 320,
        annCandidateMultiplier: Int = 6,
        nowProvider: @escaping () -> Date = Date.init
    ) {
        self.dataStore = dataStore
        self.queryEmbedder = queryEmbedder
        self.configuredEmbeddingVersionID = embeddingVersionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.backend = backend
        self.exactRerankEnabled = exactRerankEnabled
        self.exactRerankLimit = max(1, min(exactRerankLimit, 5_000))
        self.nowProvider = nowProvider
        self.annBackend = SignpostANNVectorCandidateBackend(candidateMultiplier: annCandidateMultiplier)
        self.exactBackend = ExactVectorCandidateBackend()
    }

    func semanticCandidates(for query: String, filters _: RetrievalFilters, limit: Int) async throws -> [SemanticCandidate] {
        guard limit > 0 else { return [] }
        let queryStartedAt = BurnBarPerformanceTimer.now()
        var queryEmbeddingLatencyMs: Double?
        var indexRefreshLatencyMs: Double?
        var gatherMetrics = CandidateGatherMetrics()

        let queryVector: [Float]
        let queryEmbeddingStartedAt = BurnBarPerformanceTimer.now()
        do {
            queryVector = try await queryEmbedder.embedding(for: query)
            queryEmbeddingLatencyMs = BurnBarPerformanceTimer.elapsedMilliseconds(since: queryEmbeddingStartedAt)
        } catch {
            persistSemanticHealth(
                status: .failed,
                backendUsed: backend.rawValue,
                embeddingVersionID: indexedEmbeddingVersionID,
                vectorCount: indexedVectorCount,
                queryDimensions: nil,
                candidateCount: 0,
                fallbackUsed: false,
                errorCode: "SEMANTIC_QUERY_EMBEDDING_FAILED",
                errorMessage: error.localizedDescription,
                performanceMetrics: SemanticQueryPerformanceMetrics(
                    queryEmbeddingLatencyMs: BurnBarPerformanceTimer.elapsedMilliseconds(since: queryEmbeddingStartedAt),
                    indexRefreshLatencyMs: indexRefreshLatencyMs,
                    candidateGenerationLatencyMs: gatherMetrics.candidateGenerationLatencyMs,
                    annCandidateGenerationLatencyMs: gatherMetrics.annCandidateGenerationLatencyMs,
                    exactRerankLatencyMs: gatherMetrics.exactRerankLatencyMs,
                    fallbackExactLatencyMs: gatherMetrics.fallbackExactLatencyMs,
                    totalQueryLatencyMs: BurnBarPerformanceTimer.elapsedMilliseconds(since: queryStartedAt)
                )
            )
            throw error
        }
        guard queryVector.isEmpty == false else { return [] }

        let indexRefreshStartedAt = BurnBarPerformanceTimer.now()
        do {
            try refreshIndexIfNeeded(queryDimensions: queryVector.count)
            indexRefreshLatencyMs = BurnBarPerformanceTimer.elapsedMilliseconds(since: indexRefreshStartedAt)
        } catch {
            persistSemanticHealth(
                status: .failed,
                backendUsed: backend.rawValue,
                embeddingVersionID: indexedEmbeddingVersionID,
                vectorCount: indexedVectorCount,
                queryDimensions: queryVector.count,
                candidateCount: 0,
                fallbackUsed: false,
                errorCode: "SEMANTIC_INDEX_BUILD_FAILED",
                errorMessage: error.localizedDescription,
                performanceMetrics: SemanticQueryPerformanceMetrics(
                    queryEmbeddingLatencyMs: queryEmbeddingLatencyMs,
                    indexRefreshLatencyMs: BurnBarPerformanceTimer.elapsedMilliseconds(since: indexRefreshStartedAt),
                    candidateGenerationLatencyMs: gatherMetrics.candidateGenerationLatencyMs,
                    annCandidateGenerationLatencyMs: gatherMetrics.annCandidateGenerationLatencyMs,
                    exactRerankLatencyMs: gatherMetrics.exactRerankLatencyMs,
                    fallbackExactLatencyMs: gatherMetrics.fallbackExactLatencyMs,
                    totalQueryLatencyMs: BurnBarPerformanceTimer.elapsedMilliseconds(since: queryStartedAt)
                )
            )
            throw error
        }

        guard indexedVectorCount > 0 else {
            persistSemanticHealth(
                status: .degraded,
                backendUsed: backend.rawValue,
                embeddingVersionID: indexedEmbeddingVersionID,
                vectorCount: indexedVectorCount,
                queryDimensions: queryVector.count,
                candidateCount: 0,
                fallbackUsed: false,
                errorCode: "SEMANTIC_NO_EMBEDDINGS",
                errorMessage: "No chunk embeddings are available for semantic retrieval.",
                performanceMetrics: SemanticQueryPerformanceMetrics(
                    queryEmbeddingLatencyMs: queryEmbeddingLatencyMs,
                    indexRefreshLatencyMs: indexRefreshLatencyMs,
                    candidateGenerationLatencyMs: gatherMetrics.candidateGenerationLatencyMs,
                    annCandidateGenerationLatencyMs: gatherMetrics.annCandidateGenerationLatencyMs,
                    exactRerankLatencyMs: gatherMetrics.exactRerankLatencyMs,
                    fallbackExactLatencyMs: gatherMetrics.fallbackExactLatencyMs,
                    totalQueryLatencyMs: BurnBarPerformanceTimer.elapsedMilliseconds(since: queryStartedAt)
                )
            )
            return []
        }

        do {
            let (candidates, fallbackUsed, metrics) = try gatherCandidates(queryVector: queryVector, limit: limit)
            gatherMetrics = metrics
            let semanticCandidates = candidates.map { SemanticCandidate(chunkID: $0.chunkID, score: $0.score) }
            persistSemanticHealth(
                status: fallbackUsed ? .degraded : .healthy,
                backendUsed: fallbackUsed ? VectorBackendKind.exact.rawValue : backend.rawValue,
                embeddingVersionID: indexedEmbeddingVersionID,
                vectorCount: indexedVectorCount,
                queryDimensions: queryVector.count,
                candidateCount: semanticCandidates.count,
                fallbackUsed: fallbackUsed,
                errorCode: fallbackUsed ? "SEMANTIC_ANN_FALLBACK_TO_EXACT" : nil,
                errorMessage: fallbackUsed ? "ANN candidate generation failed; exact fallback path served the query." : nil,
                performanceMetrics: SemanticQueryPerformanceMetrics(
                    queryEmbeddingLatencyMs: queryEmbeddingLatencyMs,
                    indexRefreshLatencyMs: indexRefreshLatencyMs,
                    candidateGenerationLatencyMs: metrics.candidateGenerationLatencyMs,
                    annCandidateGenerationLatencyMs: metrics.annCandidateGenerationLatencyMs,
                    exactRerankLatencyMs: metrics.exactRerankLatencyMs,
                    fallbackExactLatencyMs: metrics.fallbackExactLatencyMs,
                    totalQueryLatencyMs: BurnBarPerformanceTimer.elapsedMilliseconds(since: queryStartedAt)
                )
            )
            return semanticCandidates
        } catch {
            persistSemanticHealth(
                status: .failed,
                backendUsed: backend.rawValue,
                embeddingVersionID: indexedEmbeddingVersionID,
                vectorCount: indexedVectorCount,
                queryDimensions: queryVector.count,
                candidateCount: 0,
                fallbackUsed: false,
                errorCode: "SEMANTIC_BACKEND_QUERY_FAILED",
                errorMessage: error.localizedDescription,
                performanceMetrics: SemanticQueryPerformanceMetrics(
                    queryEmbeddingLatencyMs: queryEmbeddingLatencyMs,
                    indexRefreshLatencyMs: indexRefreshLatencyMs,
                    candidateGenerationLatencyMs: gatherMetrics.candidateGenerationLatencyMs,
                    annCandidateGenerationLatencyMs: gatherMetrics.annCandidateGenerationLatencyMs,
                    exactRerankLatencyMs: gatherMetrics.exactRerankLatencyMs,
                    fallbackExactLatencyMs: gatherMetrics.fallbackExactLatencyMs,
                    totalQueryLatencyMs: BurnBarPerformanceTimer.elapsedMilliseconds(since: queryStartedAt)
                )
            )
            throw error
        }
    }

    private func persistSemanticHealth(
        status: RetrievalHealthStatus,
        backendUsed: String,
        embeddingVersionID: String?,
        vectorCount: Int,
        queryDimensions: Int?,
        candidateCount: Int,
        fallbackUsed: Bool,
        errorCode: String?,
        errorMessage: String?,
        performanceMetrics: SemanticQueryPerformanceMetrics?
    ) {
        do {
            try upsertSemanticHealth(
                status: status,
                backendUsed: backendUsed,
                embeddingVersionID: embeddingVersionID,
                vectorCount: vectorCount,
                queryDimensions: queryDimensions,
                candidateCount: candidateCount,
                fallbackUsed: fallbackUsed,
                errorCode: errorCode,
                errorMessage: errorMessage,
                performanceMetrics: performanceMetrics
            )
            lastHealthWriteError = nil
        } catch {
            lastHealthWriteError = error.localizedDescription
        }
    }

    private func gatherCandidates(queryVector: [Float], limit: Int) throws -> ([VectorIndexCandidate], Bool, CandidateGatherMetrics) {
        let boundedLimit = min(limit, indexedVectorCount)
        var metrics = CandidateGatherMetrics()
        switch backend {
        case .exact:
            let exactStartedAt = BurnBarPerformanceTimer.now()
            let candidates = try exactBackend.candidates(for: queryVector, limit: boundedLimit)
            metrics.candidateGenerationLatencyMs = BurnBarPerformanceTimer.elapsedMilliseconds(since: exactStartedAt)
            return (candidates, false, metrics)
        case .ann:
            let annStartedAt = BurnBarPerformanceTimer.now()
            do {
                let candidateLimit = min(indexedVectorCount, max(boundedLimit, exactRerankEnabled ? exactRerankLimit : boundedLimit))
                let annCandidates = try annBackend.candidates(for: queryVector, limit: candidateLimit)
                let annLatencyMs = BurnBarPerformanceTimer.elapsedMilliseconds(since: annStartedAt)
                metrics.annCandidateGenerationLatencyMs = annLatencyMs
                metrics.candidateGenerationLatencyMs = annLatencyMs
                if exactRerankEnabled {
                    let rerankStartedAt = BurnBarPerformanceTimer.now()
                    let reranked = exactRerank(candidates: annCandidates, queryVector: queryVector, limit: boundedLimit)
                    metrics.exactRerankLatencyMs = BurnBarPerformanceTimer.elapsedMilliseconds(since: rerankStartedAt)
                    return (reranked, false, metrics)
                }
                return (Array(annCandidates.prefix(boundedLimit)), false, metrics)
            } catch {
                let annLatencyMs = BurnBarPerformanceTimer.elapsedMilliseconds(since: annStartedAt)
                metrics.annCandidateGenerationLatencyMs = annLatencyMs
                let fallbackStartedAt = BurnBarPerformanceTimer.now()
                let fallbackCandidates = try exactBackend.candidates(for: queryVector, limit: boundedLimit)
                let fallbackLatencyMs = BurnBarPerformanceTimer.elapsedMilliseconds(since: fallbackStartedAt)
                metrics.fallbackExactLatencyMs = fallbackLatencyMs
                metrics.candidateGenerationLatencyMs = annLatencyMs + fallbackLatencyMs
                return (fallbackCandidates, true, metrics)
            }
        }
    }

    private func exactRerank(candidates: [VectorIndexCandidate], queryVector: [Float], limit: Int) -> [VectorIndexCandidate] {
        guard candidates.isEmpty == false else { return [] }
        var reranked: [VectorIndexCandidate] = []
        reranked.reserveCapacity(candidates.count)

        for candidate in candidates {
            guard let vector = vectorsByChunkID[candidate.chunkID] else { continue }
            let exactScore = VectorMath.similarity(lhs: queryVector, rhs: vector, metric: indexedDistanceMetric)
            guard exactScore.isFinite else { continue }
            reranked.append(VectorIndexCandidate(chunkID: candidate.chunkID, score: exactScore))
        }

        reranked.sort {
            if $0.score == $1.score {
                return $0.chunkID < $1.chunkID
            }
            return $0.score > $1.score
        }
        if reranked.count > limit {
            return Array(reranked.prefix(limit))
        }
        return reranked
    }

    private func refreshIndexIfNeeded(queryDimensions: Int) throws {
        guard let selection = try resolveEmbeddingSelection() else {
            resetIndex()
            return
        }

        let embeddings = try dataStore.fetchChunkEmbeddings(embeddingVersionID: selection.version.id)
        let sortedEmbeddings = embeddings.sorted {
            if $0.chunkID == $1.chunkID {
                return $0.updatedAt < $1.updatedAt
            }
            return $0.chunkID < $1.chunkID
        }
        let newestEmbeddingEpoch = sortedEmbeddings.map(\.updatedAt.timeIntervalSince1970).max() ?? 0
        let fingerprint = [
            selection.version.id,
            selection.model.distanceMetric.rawValue,
            String(selection.model.dimensions),
            String(sortedEmbeddings.count),
            String(Int(newestEmbeddingEpoch))
        ].joined(separator: "|")

        if fingerprint == indexFingerprint,
           indexedDimensions == selection.model.dimensions,
           indexedEmbeddingVersionID == selection.version.id {
            if indexedDimensions != queryDimensions {
                throw VectorIndexBackendError.dimensionMismatch(expected: indexedDimensions, actual: queryDimensions)
            }
            return
        }

        var entries: [VectorIndexEntry] = []
        entries.reserveCapacity(sortedEmbeddings.count)
        var vectors: [String: [Float]] = [:]
        vectors.reserveCapacity(sortedEmbeddings.count)

        for embedding in sortedEmbeddings {
            guard let vector = VectorBlobCodec.decode(embedding.vectorBlob) else { continue }
            guard vector.count == selection.model.dimensions else { continue }
            entries.append(VectorIndexEntry(chunkID: embedding.chunkID, vector: vector))
            vectors[embedding.chunkID] = vector
        }

        guard entries.isEmpty == false else {
            resetIndex()
            indexedEmbeddingVersionID = selection.version.id
            indexedDistanceMetric = selection.model.distanceMetric
            indexedDimensions = selection.model.dimensions
            return
        }

        try annBackend.rebuild(entries: entries, distanceMetric: selection.model.distanceMetric)
        try exactBackend.rebuild(entries: entries, distanceMetric: selection.model.distanceMetric)

        vectorsByChunkID = vectors
        indexFingerprint = fingerprint
        indexedEmbeddingVersionID = selection.version.id
        indexedDistanceMetric = selection.model.distanceMetric
        indexedVectorCount = entries.count
        indexedDimensions = selection.model.dimensions

        if indexedDimensions != queryDimensions {
            throw VectorIndexBackendError.dimensionMismatch(expected: indexedDimensions, actual: queryDimensions)
        }
    }

    private func resolveEmbeddingSelection() throws -> ActiveEmbeddingSelection? {
        let models = try dataStore.fetchEmbeddingModels()
        guard models.isEmpty == false else { return nil }
        let modelByID = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })
        let versions = try dataStore.fetchEmbeddingVersions()
        guard versions.isEmpty == false else { return nil }

        let selectedVersion: EmbeddingVersionRecord?
        if let configuredEmbeddingVersionID, configuredEmbeddingVersionID.isEmpty == false {
            selectedVersion = versions.first(where: { $0.id == configuredEmbeddingVersionID })
        } else {
            selectedVersion = versions.first(where: { $0.isActive }) ?? versions.first
        }
        guard let version = selectedVersion, let model = modelByID[version.modelID] else {
            return nil
        }
        return ActiveEmbeddingSelection(model: model, version: version)
    }

    private func resetIndex() {
        vectorsByChunkID = [:]
        indexFingerprint = nil
        indexedEmbeddingVersionID = nil
        indexedDistanceMetric = .cosine
        indexedVectorCount = 0
        indexedDimensions = 0
    }

    private func upsertSemanticHealth(
        status: RetrievalHealthStatus,
        backendUsed: String,
        embeddingVersionID: String?,
        vectorCount: Int,
        queryDimensions: Int?,
        candidateCount: Int,
        fallbackUsed: Bool,
        errorCode: String?,
        errorMessage: String?,
        performanceMetrics: SemanticQueryPerformanceMetrics?
    ) throws {
        let now = nowProvider()
        let details = SemanticRetrievalHealthDetails(
            backend: backendUsed,
            configuredBackend: backend.rawValue,
            embeddingVersionID: embeddingVersionID,
            indexedVectorCount: vectorCount,
            indexedDimensions: indexedDimensions,
            queryDimensions: queryDimensions,
            candidateCount: candidateCount,
            fallbackToExact: fallbackUsed,
            exactRerankEnabled: exactRerankEnabled,
            queryEmbeddingLatencyMs: performanceMetrics?.queryEmbeddingLatencyMs,
            indexRefreshLatencyMs: performanceMetrics?.indexRefreshLatencyMs,
            candidateGenerationLatencyMs: performanceMetrics?.candidateGenerationLatencyMs,
            annCandidateGenerationLatencyMs: performanceMetrics?.annCandidateGenerationLatencyMs,
            exactRerankLatencyMs: performanceMetrics?.exactRerankLatencyMs,
            fallbackExactLatencyMs: performanceMetrics?.fallbackExactLatencyMs,
            totalQueryLatencyMs: performanceMetrics?.totalQueryLatencyMs
        )
        let detailsData = try JSONEncoder().encode(details)
        let detailsJSON = String(data: detailsData, encoding: .utf8)
        try dataStore.upsertRetrievalHealth(
            RetrievalHealthRecord(
                subsystem: .semantic,
                status: status,
                errorCode: errorCode,
                errorMessage: errorMessage,
                detailsJSON: detailsJSON,
                observedAt: now,
                updatedAt: now
            )
        )
    }
}

private struct SemanticQueryPerformanceMetrics: Codable {
    let queryEmbeddingLatencyMs: Double?
    let indexRefreshLatencyMs: Double?
    let candidateGenerationLatencyMs: Double?
    let annCandidateGenerationLatencyMs: Double?
    let exactRerankLatencyMs: Double?
    let fallbackExactLatencyMs: Double?
    let totalQueryLatencyMs: Double?
}

private struct SemanticRetrievalHealthDetails: Codable {
    let backend: String
    let configuredBackend: String
    let embeddingVersionID: String?
    let indexedVectorCount: Int
    let indexedDimensions: Int
    let queryDimensions: Int?
    let candidateCount: Int
    let fallbackToExact: Bool
    let exactRerankEnabled: Bool
    let queryEmbeddingLatencyMs: Double?
    let indexRefreshLatencyMs: Double?
    let candidateGenerationLatencyMs: Double?
    let annCandidateGenerationLatencyMs: Double?
    let exactRerankLatencyMs: Double?
    let fallbackExactLatencyMs: Double?
    let totalQueryLatencyMs: Double?
}

// MARK: - Search Service

@MainActor
final class SearchService {
    private let dataStore: DataStore
    private let semanticProvider: SemanticCandidateProviding?
    private let reranker: RetrievalRerankProviding?
    private let sharedArtifactAccessContextProvider: () -> SharedArtifactAccessContext?
    private let nowProvider: () -> Date
    private(set) var lastHealthWriteError: String?

    init(
        dataStore: DataStore,
        semanticProvider: SemanticCandidateProviding? = nil,
        reranker: RetrievalRerankProviding? = nil,
        sharedArtifactAccessContextProvider: @escaping () -> SharedArtifactAccessContext? = SearchService.defaultSharedArtifactAccessContext,
        nowProvider: @escaping () -> Date = Date.init
    ) {
        self.dataStore = dataStore
        self.semanticProvider = semanticProvider
        self.reranker = reranker
        self.sharedArtifactAccessContextProvider = sharedArtifactAccessContextProvider
        self.nowProvider = nowProvider
    }

    static func makeConversationSearchService(
        dataStore: DataStore,
        settingsManager: SettingsManager = .shared,
        providerAPIKeyStore: ProviderAPIKeyStore = .shared,
        nowProvider: @escaping () -> Date = Date.init
    ) -> SearchService {
        let selection = resolvedEmbeddingSelection(
            dataStore: dataStore,
            preferredEmbeddingVersionID: settingsManager.preferredIndexEmbeddingVersionIDValue
        )
        let preferredVersionID = selection?.version.id
        let queryEmbedder = makeQueryEmbedder(
            selection: selection,
            providerAPIKeyStore: providerAPIKeyStore
        )
        let semanticProvider = VectorSemanticCandidateProvider(
            dataStore: dataStore,
            queryEmbedder: queryEmbedder,
            embeddingVersionID: preferredVersionID
        )

        // Construct reranker if cross-encoder is enabled and API key is available
        let reranker: RetrievalRerankProviding? = Self.makeReranker(
            settingsManager: settingsManager,
            providerAPIKeyStore: providerAPIKeyStore
        )

        return SearchService(
            dataStore: dataStore,
            semanticProvider: semanticProvider,
            reranker: reranker,
            sharedArtifactAccessContextProvider: SearchService.defaultSharedArtifactAccessContext,
            nowProvider: nowProvider
        )
    }

    private static func makeReranker(
        settingsManager: SettingsManager,
        providerAPIKeyStore: ProviderAPIKeyStore
    ) -> RetrievalRerankProviding? {
        guard settingsManager.crossEncoderRerankEnabled else {
            return nil
        }

        guard let apiKey = providerAPIKeyStore.apiKey(for: "openai"),
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        return OpenAICrossEncoderReranker(
            apiKey: apiKey,
            modelName: settingsManager.crossEncoderModel,
            baseURL: settingsManager.crossEncoderBaseURL.isEmpty ? "https://api.openai.com/v1" : settingsManager.crossEncoderBaseURL,
            maxCharsPerCandidate: settingsManager.crossEncoderMaxCharsPerCandidate,
            maxCandidatesPerRequest: settingsManager.crossEncoderMaxCandidates
        )
    }

    private static func makeQueryEmbedder(
        selection: (model: EmbeddingModelRecord, version: EmbeddingVersionRecord)?,
        providerAPIKeyStore: ProviderAPIKeyStore
    ) -> any QueryEmbeddingProviding {
        guard let selection else {
            return DeterministicQueryEmbeddingProvider()
        }

        if selection.model.provider.caseInsensitiveCompare("openai") == .orderedSame {
            if let provider = try? OpenAIEmbeddingProvider(
                apiKey: providerAPIKeyStore.apiKey(for: "openai") ?? "",
                modelName: selection.model.modelName,
                versionTag: selection.version.versionTag,
                chunkerVersion: selection.version.chunkerVersion,
                normalizationVersion: selection.version.normalizationVersion,
                promptVersion: selection.version.promptVersion
            ) {
                return provider
            }
        }

        return DeterministicQueryEmbeddingProvider(
            embedder: DeterministicFakeEmbeddingProvider(
                provider: selection.model.provider,
                modelName: selection.model.modelName,
                dimensions: selection.model.dimensions,
                distanceMetric: selection.model.distanceMetric,
                versionTag: selection.version.versionTag,
                chunkerVersion: selection.version.chunkerVersion,
                normalizationVersion: selection.version.normalizationVersion,
                promptVersion: selection.version.promptVersion
            )
        )
    }

    private static func resolvedEmbeddingSelection(
        dataStore: DataStore,
        preferredEmbeddingVersionID: String?
    ) -> (model: EmbeddingModelRecord, version: EmbeddingVersionRecord)? {
        guard
            let models = try? dataStore.fetchEmbeddingModels(),
            models.isEmpty == false,
            let versions = try? dataStore.fetchEmbeddingVersions(),
            versions.isEmpty == false
        else {
            return nil
        }

        let modelByID = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })
        let preferred = preferredEmbeddingVersionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let version = versions.first(where: { $0.id == preferred })
            ?? versions.first(where: \.isActive)
            ?? versions.first

        guard let version, let model = modelByID[version.modelID] else {
            return nil
        }
        return (model, version)
    }

    private static func defaultSharedArtifactAccessContext() -> SharedArtifactAccessContext? {
        guard
            let userID = AccountManager.shared.userID?.trimmingCharacters(in: .whitespacesAndNewlines),
            userID.isEmpty == false
        else {
            return nil
        }
        return SharedArtifactAccessContext.defaultScope(for: userID)
    }

    func recentConversations(limit: Int = 80) -> [ConversationRecord] {
        let bounded = max(1, min(limit, 1_000))
        return (try? dataStore.fetchConversations(limit: bounded)) ?? []
    }

    func latestConversation(limit: Int = 200) -> ConversationRecord? {
        latestConversation(in: recentConversations(limit: limit))
    }

    func latestConversation(in conversations: [ConversationRecord]) -> ConversationRecord? {
        conversations.max(by: { a, b in
            let ad = a.endTime ?? a.startTime ?? .distantPast
            let bd = b.endTime ?? b.startTime ?? .distantPast
            return ad < bd
        })
    }

    func runBurnBarQuery(_ query: RetrievalQuery) async -> BurnBarQueryRunResult {
        let plan = BurnBarSearchPlan.plan(userText: query.text)
        let now = nowProvider()
        var filters = query.filters
        var aggregateWindowDescription: String?
        if filters.dateRange == nil,
           let inferred = BurnBarSearchTimeWindow.inferredDateRange(from: query.text, now: now, calendar: .current) {
            filters.dateRange = inferred
            let fmt = DateFormatter()
            fmt.dateStyle = .medium
            fmt.timeStyle = .short
            aggregateWindowDescription =
                "Counts and retrieval are limited to local time window: \(fmt.string(from: inferred.lowerBound)) – \(fmt.string(from: inferred.upperBound))."
        }

        var aggregateCount: Int?
        var aggregateCountError: String?
        if plan.mode == .mixed || plan.mode == .aggregate, !plan.aggregatePatterns.isEmpty {
            do {
                aggregateCount = try dataStore.countOccurrencesInConversationFullText(
                    patterns: plan.aggregatePatterns,
                    provider: filters.provider,
                    projectName: filters.projectName,
                    dateRange: filters.dateRange,
                    conversationSources: filters.conversationSources
                )
            } catch {
                aggregateCountError = String(describing: error)
                aggregateCount = 0
            }
        }
        // #region agent log
        let dr = filters.dateRange
        let drDesc: String = {
            guard let dr else { return "nil" }
            let f = ISO8601DateFormatter()
            return "\(f.string(from: dr.lowerBound))–\(f.string(from: dr.upperBound))"
        }()
        AgentDebugLog86435e.append(
            hypothesisId: "H1-H5",
            location: "SearchService.runBurnBarQuery",
            message: "aggregate_snapshot",
            data: [
                "queryCharCount": query.text.count,
                "planMode": String(describing: plan.mode),
                "planNote": plan.note ?? "",
                "aggregatePatterns": plan.aggregatePatterns,
                "dateRange": drDesc,
                "inferredWindowSet": aggregateWindowDescription != nil,
                "aggregateCount": aggregateCount ?? -1,
                "aggregateError": aggregateCountError ?? ""
            ]
        )
        // #endregion
        let lexicalTrimmed = plan.lexicalFTSQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let subQuery = RetrievalQuery(
            text: plan.semanticText,
            lexicalFTSQuery: lexicalTrimmed.isEmpty ? nil : lexicalTrimmed,
            filters: filters,
            lexicalCandidateLimit: query.lexicalCandidateLimit,
            semanticCandidateLimit: query.semanticCandidateLimit,
            rerankCandidateLimit: query.rerankCandidateLimit,
            resultLimit: query.resultLimit,
            hybridFusionStrategy: query.hybridFusionStrategy
        )
        let results = await retrieve(subQuery)
        return BurnBarQueryRunResult(
            plan: plan,
            retrievalResults: results,
            aggregateOccurrenceCount: aggregateCount,
            aggregateWindowDescription: aggregateWindowDescription
        )
    }

    func retrieve(_ query: RetrievalQuery) async -> [RetrievalResult] {
        let trimmed = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return [] }
        let queryStartedAt = BurnBarPerformanceTimer.now()

        let lexicalLimit = max(1, min(query.lexicalCandidateLimit, 1_000))
        let semanticLimit = max(0, min(query.semanticCandidateLimit, 1_000))
        let rerankLimit = max(1, min(query.rerankCandidateLimit, 1_000))
        let resultLimit = max(1, min(query.resultLimit, rerankLimit))

        let sourceKinds = normalizedSourceKinds(query.filters.artifactTypes)
        let sourceIDs = normalizedSourceIDs(query.filters.sourceIDs)
        let sharedArtifactAccessContext = sharedArtifactAccessContextProvider()
        var semanticFallbackUsed = false
        var semanticCandidateCount = 0
        var indexStale = false
        var indexStaleError: String?
        var lexicalQueryLatencyMs: Double?
        var semanticQueryLatencyMs: Double?
        var rerankLatencyMs: Double?
        var hydrationLatencyMs: Double?
        var crossEncoderLatencyMs: Double?
        var lexicalSkippedEmptyQuery = false

        func persistQueryHealth(
            status: RetrievalHealthStatus,
            lexicalCandidateCount: Int,
            resultCount: Int,
            indexStale: Bool,
            semanticFallbackUsed: Bool,
            errorCode: String?,
            errorMessage: String?
        ) {
            persistLexicalHealth(
                status: status,
                query: trimmed,
                lexicalCandidateCount: lexicalCandidateCount,
                semanticCandidateCount: semanticCandidateCount,
                resultCount: resultCount,
                indexStale: indexStale,
                semanticFallbackUsed: semanticFallbackUsed,
                errorCode: errorCode,
                errorMessage: errorMessage,
                totalQueryLatencyMs: BurnBarPerformanceTimer.elapsedMilliseconds(since: queryStartedAt),
                lexicalQueryLatencyMs: lexicalQueryLatencyMs,
                semanticQueryLatencyMs: semanticQueryLatencyMs,
                rerankLatencyMs: rerankLatencyMs,
                hydrationLatencyMs: hydrationLatencyMs,
                crossEncoderLatencyMs: crossEncoderLatencyMs
            )
        }

        let lexicalFTSInput: String = {
            if let o = query.lexicalFTSQuery?.trimmingCharacters(in: .whitespacesAndNewlines), !o.isEmpty {
                return o
            }
            return BurnBarFTSQueryBuilder.naturalLanguage(from: trimmed)
        }()

        let lexicalMatches: [SearchChunkLexicalMatch]
        let lexicalStartedAt = BurnBarPerformanceTimer.now()
        if lexicalFTSInput.isEmpty {
            lexicalSkippedEmptyQuery = true
            lexicalMatches = []
            lexicalQueryLatencyMs = 0
        } else {
            do {
                lexicalMatches = try dataStore.searchLexicalChunks(
                    ftsQuery: lexicalFTSInput,
                    provider: query.filters.provider,
                    projectName: query.filters.projectName,
                    sourceKinds: sourceKinds,
                    dateRange: query.filters.dateRange,
                    visibility: query.filters.ownership.visibilityScope,
                    sharedArtifactAccessContext: sharedArtifactAccessContext,
                    sourceIDs: sourceIDs,
                    limit: lexicalLimit
                )
                lexicalQueryLatencyMs = BurnBarPerformanceTimer.elapsedMilliseconds(since: lexicalStartedAt)
            } catch {
                lexicalQueryLatencyMs = BurnBarPerformanceTimer.elapsedMilliseconds(since: lexicalStartedAt)
                persistQueryHealth(
                    status: .failed,
                    lexicalCandidateCount: 0,
                    resultCount: 0,
                    indexStale: true,
                    semanticFallbackUsed: false,
                    errorCode: "LEXICAL_QUERY_FAILED",
                    errorMessage: error.localizedDescription
                )
                return []
            }
        }

        var candidates: [String: CandidateAccumulator] = [:]
        var lexicalChunkMap: [String: SearchChunkRecord] = [:]
        var lexicalDocumentMap: [String: SearchDocumentRecord] = [:]
        var lexicalRankByChunkID: [String: Int] = [:]
        var lexicalOrderCounter = 0
        for match in lexicalMatches {
            if lexicalRankByChunkID[match.chunkID] == nil {
                lexicalOrderCounter += 1
                lexicalRankByChunkID[match.chunkID] = lexicalOrderCounter
            }
            candidates[match.chunkID] = CandidateAccumulator(
                lexicalRank: match.lexicalRank,
                semanticScore: nil,
                lexicalSnippet: match.snippet
            )
            lexicalChunkMap[match.chunkID] = SearchChunkRecord(
                id: match.chunkID,
                documentID: match.documentID,
                sourceKind: match.sourceKind,
                sourceID: match.sourceID,
                sourceVersionID: match.sourceVersionID,
                ordinal: match.chunkOrdinal,
                startOffset: match.startOffset,
                endOffset: match.endOffset,
                messageStartOffset: nil,
                messageEndOffset: nil,
                sectionPath: match.sectionPath,
                text: match.chunkText,
                createdAt: match.indexedAt,
                updatedAt: match.indexedAt
            )
            lexicalDocumentMap[match.documentID] = SearchDocumentRecord(
                id: match.documentID,
                sourceKind: match.sourceKind,
                sourceID: match.sourceID,
                sourceVersionID: match.sourceVersionID,
                provider: match.provider,
                projectName: match.projectName,
                title: match.title,
                subtitle: match.subtitle,
                bodyPreview: match.bodyPreview,
                sourceUpdatedAt: match.sourceUpdatedAt,
                indexedAt: match.indexedAt,
                contentHash: nil,
                createdAt: match.indexedAt,
                updatedAt: match.indexedAt
            )
        }

        var semanticRankByChunkID: [String: Int] = [:]
        if semanticLimit > 0, let semanticProvider {
            let semanticStartedAt = BurnBarPerformanceTimer.now()
            do {
                let semanticCandidates = try await semanticProvider.semanticCandidates(
                    for: trimmed,
                    filters: query.filters,
                    limit: semanticLimit
                )
                semanticQueryLatencyMs = BurnBarPerformanceTimer.elapsedMilliseconds(since: semanticStartedAt)
                semanticCandidateCount = semanticCandidates.count
                var semanticOrderCounter = 0
                for semanticCandidate in semanticCandidates {
                    if semanticRankByChunkID[semanticCandidate.chunkID] == nil {
                        semanticOrderCounter += 1
                        semanticRankByChunkID[semanticCandidate.chunkID] = semanticOrderCounter
                    }
                    let normalizedScore = max(0, semanticCandidate.score)
                    if var existing = candidates[semanticCandidate.chunkID] {
                        if let semantic = existing.semanticScore {
                            existing.semanticScore = max(semantic, normalizedScore)
                        } else {
                            existing.semanticScore = normalizedScore
                        }
                        candidates[semanticCandidate.chunkID] = existing
                    } else {
                        candidates[semanticCandidate.chunkID] = CandidateAccumulator(
                            lexicalRank: nil,
                            semanticScore: normalizedScore,
                            lexicalSnippet: nil
                        )
                    }
                }
            } catch {
                semanticQueryLatencyMs = BurnBarPerformanceTimer.elapsedMilliseconds(since: semanticStartedAt)
                semanticFallbackUsed = true
                persistSemanticFallbackHealth(
                    query: trimmed,
                    lexicalCandidateCount: lexicalMatches.count,
                    error: error
                )
            }
        }

        // Only return early if we have no candidates AND semantic didn't produce any
        // (semantic-only path is allowed when FTS is empty but semanticLimit > 0)
        let hasSemanticCandidates = semanticCandidateCount > 0
        let semanticWasAvailable = semanticLimit > 0 && semanticProvider != nil
        let shouldReturnEmpty = candidates.isEmpty && (!semanticWasAvailable || !hasSemanticCandidates)

        if shouldReturnEmpty {
            let lexicalStatus = lexicalHealthStatus(indexStale: indexStale, semanticFallbackUsed: semanticFallbackUsed)
            let lexicalError = lexicalHealthError(
                indexStale: indexStale,
                semanticFallbackUsed: semanticFallbackUsed,
                lexicalSkippedEmptyQuery: lexicalSkippedEmptyQuery,
                indexStaleError: indexStaleError
            )
            persistQueryHealth(
                status: lexicalStatus,
                lexicalCandidateCount: lexicalMatches.count,
                resultCount: 0,
                indexStale: indexStale,
                semanticFallbackUsed: semanticFallbackUsed,
                errorCode: lexicalError.code,
                errorMessage: lexicalError.message
            )
            return []
        }

        let rerankStartedAt = BurnBarPerformanceTimer.now()
        let kRRF = HybridRetrievalConstants.rrfK
        let boundedChunkIDs: [String]
        switch query.hybridFusionStrategy {
        case .reciprocalRankFusion:
            boundedChunkIDs = Array(
                candidates.keys.sorted { a, b in
                    let ra = Self.reciprocalRankFusion(
                        lexicalRank: lexicalRankByChunkID[a],
                        semanticRank: semanticRankByChunkID[a],
                        k: kRRF
                    )
                    let rb = Self.reciprocalRankFusion(
                        lexicalRank: lexicalRankByChunkID[b],
                        semanticRank: semanticRankByChunkID[b],
                        k: kRRF
                    )
                    if ra == rb { return a < b }
                    return ra > rb
                }
                .prefix(rerankLimit)
            )
        case .legacyWeighted:
            boundedChunkIDs = Array(
                candidates
                    .sorted {
                        let lhs = preliminaryScore(for: $0.value)
                        let rhs = preliminaryScore(for: $1.value)
                        if lhs == rhs {
                            return $0.key < $1.key
                        }
                        return lhs > rhs
                    }
                    .prefix(rerankLimit)
                    .map(\.key)
            )
        }
        rerankLatencyMs = BurnBarPerformanceTimer.elapsedMilliseconds(since: rerankStartedAt)

        let hydrationStartedAt = BurnBarPerformanceTimer.now()

        let missingChunkIDs = boundedChunkIDs.filter { lexicalChunkMap[$0] == nil }
        let fetchedChunks: [SearchChunkRecord]
        if missingChunkIDs.isEmpty {
            fetchedChunks = []
        } else {
            do {
                fetchedChunks = try dataStore.fetchSearchChunks(ids: missingChunkIDs)
            } catch {
                fetchedChunks = []
                indexStale = true
                indexStaleError = indexStaleError ?? error.localizedDescription
            }
        }
        var chunkMap = lexicalChunkMap
        for chunk in fetchedChunks {
            chunkMap[chunk.id] = chunk
        }

        let allDocumentIDs = Set(
            boundedChunkIDs.compactMap { chunkID in
                chunkMap[chunkID]?.documentID
            }
        )
        let missingDocumentIDs = allDocumentIDs.filter { lexicalDocumentMap[$0] == nil }
        let fetchedDocuments: [SearchDocumentRecord]
        if missingDocumentIDs.isEmpty {
            fetchedDocuments = []
        } else {
            do {
                fetchedDocuments = try dataStore.fetchSearchDocuments(ids: Array(missingDocumentIDs))
            } catch {
                fetchedDocuments = []
                indexStale = true
                indexStaleError = indexStaleError ?? error.localizedDescription
            }
        }
        var documentMap = lexicalDocumentMap
        for document in fetchedDocuments {
            documentMap[document.id] = document
        }

        let readableSharedSourceIDs: Set<String>?
        if shouldEnforceSharedArtifactAccess(filters: query.filters, sourceKinds: sourceKinds) {
            if let sharedArtifactAccessContext {
                readableSharedSourceIDs = try? dataStore.fetchReadableSharedArtifactSourceIDs(
                    accessContext: sharedArtifactAccessContext
                )
            } else {
                readableSharedSourceIDs = Set<String>()
            }
        } else {
            readableSharedSourceIDs = nil
        }

        var conversationCache: [String: ConversationRecord?] = [:]
        var scoredResults: [RetrievalResult] = []
        scoredResults.reserveCapacity(boundedChunkIDs.count)

        let tokens = Self.queryTokens(from: trimmed)

        for chunkID in boundedChunkIDs {
            guard
                let candidate = candidates[chunkID],
                let chunk = chunkMap[chunkID],
                let document = documentMap[chunk.documentID]
            else {
                continue
            }

            let conversation: ConversationRecord?
            if document.sourceKind == .conversation {
                if let cached = conversationCache[document.sourceID] {
                    conversation = cached
                } else {
                    do {
                        let loaded = try dataStore.fetchConversation(id: document.sourceID)
                        conversationCache[document.sourceID] = loaded
                        conversation = loaded
                    } catch {
                        indexStale = true
                        indexStaleError = indexStaleError ?? error.localizedDescription
                        conversationCache[document.sourceID] = .some(nil)
                        conversation = nil
                    }
                }
            } else {
                conversation = nil
            }

            guard
                matchesFilters(
                    document: document,
                    conversation: conversation,
                    filters: query.filters,
                    readableSharedSourceIDs: readableSharedSourceIDs
                )
            else {
                continue
            }

            let exactScore = Self.exactTokenCoverageScore(tokens: tokens, title: document.title, chunkText: chunk.text)
            let recency = recencyScore(document.sourceUpdatedAt ?? document.indexedAt)
            let rerank: Double
            switch query.hybridFusionStrategy {
            case .reciprocalRankFusion:
                let rawRRF = Self.reciprocalRankFusion(
                    lexicalRank: lexicalRankByChunkID[chunkID],
                    semanticRank: semanticRankByChunkID[chunkID],
                    k: kRRF
                )
                let normRRF = Self.normalizedRRFForRerank(
                    rawRRF,
                    lexicalRank: lexicalRankByChunkID[chunkID],
                    semanticRank: semanticRankByChunkID[chunkID],
                    k: kRRF
                )
                rerank = (normRRF * 0.52) + (exactScore * 0.33) + (recency * 0.15)
            case .legacyWeighted:
                let lexicalScore = Self.normalizedLexicalScore(candidate.lexicalRank)
                let semanticScore = max(0, candidate.semanticScore ?? 0)
                rerank = (lexicalScore * 0.52) + (semanticScore * 0.33) + (exactScore * 0.10) + (recency * 0.05)
            }

            let snippet = Self.makeSnippet(
                lexicalSnippet: candidate.lexicalSnippet,
                chunkText: chunk.text,
                fallback: document.bodyPreview ?? document.title
            )

            scoredResults.append(
                RetrievalResult(
                    chunkID: chunk.id,
                    documentID: document.id,
                    sourceKind: document.sourceKind,
                    sourceID: document.sourceID,
                    provider: document.provider.flatMap(AgentProvider.init(rawValue:)),
                    providerRawValue: document.provider,
                    projectName: document.projectName,
                    title: document.title,
                    subtitle: document.subtitle,
                    snippet: snippet,
                    sectionPath: chunk.sectionPath,
                    startOffset: chunk.startOffset,
                    endOffset: chunk.endOffset,
                    sourceUpdatedAt: document.sourceUpdatedAt,
                    indexedAt: document.indexedAt,
                    lexicalRank: candidate.lexicalRank,
                    semanticScore: candidate.semanticScore,
                    rerankScore: rerank,
                    conversation: conversation
                )
            )
        }

        guard scoredResults.isEmpty == false else {
            hydrationLatencyMs = BurnBarPerformanceTimer.elapsedMilliseconds(since: hydrationStartedAt)
            let lexicalStatus = lexicalHealthStatus(indexStale: indexStale, semanticFallbackUsed: semanticFallbackUsed)
            let lexicalError = lexicalHealthError(
                indexStale: indexStale,
                semanticFallbackUsed: semanticFallbackUsed,
                lexicalSkippedEmptyQuery: lexicalSkippedEmptyQuery,
                indexStaleError: indexStaleError
            )
            persistQueryHealth(
                status: lexicalStatus,
                lexicalCandidateCount: lexicalMatches.count,
                resultCount: 0,
                indexStale: indexStale,
                semanticFallbackUsed: semanticFallbackUsed,
                errorCode: lexicalError.code,
                errorMessage: lexicalError.message
            )
            return []
        }

        // Cross-encoder reranking: take top N candidates, rerank them, merge back
        if query.crossEncoderEnabled, let reranker, reranker is NoOpRetrievalReranker == false {
            let crossEncoderStartedAt = BurnBarPerformanceTimer.now()
            let crossEncoderLimit = max(5, min(query.crossEncoderCandidateLimit, scoredResults.count))
            let candidatesToRerank = Array(scoredResults.prefix(crossEncoderLimit))

            do {
                let rerankedCandidates = try await reranker.rerank(
                    query: trimmed,
                    candidates: candidatesToRerank,
                    limit: crossEncoderLimit
                )

                // Build a set of reranked chunkIDs for quick lookup
                let rerankedIDs = Set(rerankedCandidates.map(\.chunkID))

                // Keep candidates not in the reranked set in their original relative order
                var remainingCandidates = scoredResults.filter { !rerankedIDs.contains($0.chunkID) }

                // Replace reranked section with the new order
                scoredResults = rerankedCandidates + remainingCandidates

                crossEncoderLatencyMs = BurnBarPerformanceTimer.elapsedMilliseconds(since: crossEncoderStartedAt)
            } catch {
                // Fall back to pre-rerank order on error; mark health as degraded
                crossEncoderLatencyMs = BurnBarPerformanceTimer.elapsedMilliseconds(since: crossEncoderStartedAt)
                lastHealthWriteError = "Cross-encoder reranking failed: \(error.localizedDescription)"
                // scoredResults remains unchanged — this is the graceful fallback
            }
        }

        scoredResults.sort { lhs, rhs in
            if lhs.rerankScore == rhs.rerankScore {
                if lhs.indexedAt == rhs.indexedAt {
                    return lhs.chunkID < rhs.chunkID
                }
                return lhs.indexedAt > rhs.indexedAt
            }
            return lhs.rerankScore > rhs.rerankScore
        }

        var seenDocuments: Set<String> = []
        var dedupedResults: [RetrievalResult] = []
        dedupedResults.reserveCapacity(min(resultLimit, scoredResults.count))
        for result in scoredResults {
            guard seenDocuments.insert(result.documentID).inserted else { continue }
            dedupedResults.append(result)
            if dedupedResults.count >= resultLimit { break }
        }

        hydrationLatencyMs = BurnBarPerformanceTimer.elapsedMilliseconds(since: hydrationStartedAt)
        let lexicalStatus = lexicalHealthStatus(indexStale: indexStale, semanticFallbackUsed: semanticFallbackUsed)
        let lexicalError = lexicalHealthError(
            indexStale: indexStale,
            semanticFallbackUsed: semanticFallbackUsed,
            lexicalSkippedEmptyQuery: lexicalSkippedEmptyQuery,
            indexStaleError: indexStaleError
        )
        persistQueryHealth(
            status: lexicalStatus,
            lexicalCandidateCount: lexicalMatches.count,
            resultCount: dedupedResults.count,
            indexStale: indexStale,
            semanticFallbackUsed: semanticFallbackUsed,
            errorCode: lexicalError.code,
            errorMessage: lexicalError.message
        )

        return dedupedResults
    }

    func search(
        query: String,
        provider: AgentProvider? = nil,
        projectName: String? = nil,
        dateRange: ClosedRange<Date>? = nil,
        conversationSources: Set<ConversationSourceType>? = nil,
        resultLimit: Int = 50
    ) async -> [SearchResult] {
        let boundedLimit = max(1, min(resultLimit, 200))
        let run = await runBurnBarQuery(
            RetrievalQuery(
                text: query,
                filters: RetrievalFilters(
                    provider: provider,
                    projectName: projectName,
                    artifactTypes: [.conversation],
                    dateRange: dateRange,
                    ownership: .personal,
                    conversationSources: conversationSources
                ),
                lexicalCandidateLimit: 120,
                semanticCandidateLimit: 120,
                rerankCandidateLimit: 200,
                resultLimit: boundedLimit
            )
        )

        return run.retrievalResults.compactMap { result in
            guard let conversation = result.conversation else { return nil }
            return SearchResult(
                conversation: conversation,
                snippet: result.snippet,
                rank: result.rerankScore
            )
        }
    }

    private func lexicalHealthStatus(indexStale: Bool, semanticFallbackUsed: Bool) -> RetrievalHealthStatus {
        if indexStale {
            return .degraded
        }
        if semanticFallbackUsed {
            return .degraded
        }
        return .healthy
    }

    private func lexicalHealthError(
        indexStale: Bool,
        semanticFallbackUsed: Bool,
        lexicalSkippedEmptyQuery: Bool = false,
        indexStaleError: String?
    ) -> (code: String?, message: String?) {
        if indexStale {
            return (
                "INDEX_STALE_PARTIAL_RESULTS",
                indexStaleError ?? "Search index metadata could not be fully loaded; partial results were returned."
            )
        }
        if semanticFallbackUsed {
            return (
                "SEMANTIC_FALLBACK_USED",
                "Semantic retrieval failed; lexical fallback served this query."
            )
        }
        if lexicalSkippedEmptyQuery {
            return (
                "LEXICAL_SKIPPED_EMPTY_QUERY",
                "Lexical FTS query was empty (stopwords-only input); semantic retrieval served this query."
            )
        }
        return (nil, nil)
    }

    private func persistLexicalHealth(
        status: RetrievalHealthStatus,
        query: String,
        lexicalCandidateCount: Int,
        semanticCandidateCount: Int,
        resultCount: Int,
        indexStale: Bool,
        semanticFallbackUsed: Bool,
        errorCode: String?,
        errorMessage: String?,
        totalQueryLatencyMs: Double?,
        lexicalQueryLatencyMs: Double?,
        semanticQueryLatencyMs: Double?,
        rerankLatencyMs: Double?,
        hydrationLatencyMs: Double?,
        crossEncoderLatencyMs: Double?
    ) {
        let now = nowProvider()
        let details = LexicalRetrievalHealthDetails(
            queryLength: query.count,
            lexicalCandidateCount: lexicalCandidateCount,
            semanticCandidateCount: semanticCandidateCount,
            resultCount: resultCount,
            indexStale: indexStale,
            semanticFallbackUsed: semanticFallbackUsed,
            totalQueryLatencyMs: totalQueryLatencyMs,
            lexicalQueryLatencyMs: lexicalQueryLatencyMs,
            semanticQueryLatencyMs: semanticQueryLatencyMs,
            rerankLatencyMs: rerankLatencyMs,
            hydrationLatencyMs: hydrationLatencyMs,
            crossEncoderLatencyMs: crossEncoderLatencyMs
        )
        do {
            let detailsData = try JSONEncoder().encode(details)
            let detailsJSON = String(data: detailsData, encoding: .utf8)
            try dataStore.upsertRetrievalHealth(
                RetrievalHealthRecord(
                    subsystem: .lexical,
                    status: status,
                    errorCode: errorCode,
                    errorMessage: errorMessage,
                    detailsJSON: detailsJSON,
                    observedAt: now,
                    updatedAt: now
                )
            )
            lastHealthWriteError = nil
        } catch {
            lastHealthWriteError = error.localizedDescription
        }
    }

    private func persistSemanticFallbackHealth(
        query: String,
        lexicalCandidateCount: Int,
        error: Error
    ) {
        let now = nowProvider()
        let details = SemanticFallbackHealthDetails(
            queryLength: query.count,
            lexicalCandidateCount: lexicalCandidateCount
        )
        do {
            let detailsData = try JSONEncoder().encode(details)
            let detailsJSON = String(data: detailsData, encoding: .utf8)
            try dataStore.upsertRetrievalHealth(
                RetrievalHealthRecord(
                    subsystem: .semantic,
                    status: .degraded,
                    errorCode: "SEMANTIC_PROVIDER_FALLBACK",
                    errorMessage: error.localizedDescription,
                    detailsJSON: detailsJSON,
                    observedAt: now,
                    updatedAt: now
                )
            )
            lastHealthWriteError = nil
        } catch {
            lastHealthWriteError = error.localizedDescription
        }
    }

    private func normalizedSourceKinds(_ kinds: Set<SearchSourceKind>?) -> [SearchSourceKind]? {
        guard let kinds, kinds.isEmpty == false else { return nil }
        return kinds.sorted { $0.rawValue < $1.rawValue }
    }

    private func normalizedSourceIDs(_ ids: Set<String>?) -> [String]? {
        guard let ids else { return nil }
        let cleaned = ids
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()
        return cleaned.isEmpty ? nil : cleaned
    }

    private func matchesFilters(
        document: SearchDocumentRecord,
        conversation: ConversationRecord?,
        filters: RetrievalFilters,
        readableSharedSourceIDs: Set<String>?
    ) -> Bool {
        if let provider = filters.provider, document.provider != provider.rawValue {
            return false
        }

        if let projectName = filters.projectName?.trimmingCharacters(in: .whitespacesAndNewlines), projectName.isEmpty == false {
            if (document.projectName ?? "").caseInsensitiveCompare(projectName) != .orderedSame {
                return false
            }
        }

        if let artifactTypes = filters.artifactTypes, artifactTypes.isEmpty == false, artifactTypes.contains(document.sourceKind) == false {
            return false
        }

        if let sourceIDs = filters.sourceIDs, sourceIDs.isEmpty == false, sourceIDs.contains(document.sourceID) == false {
            return false
        }

        if document.sourceKind == .sharedArtifact {
            guard
                let readableSharedSourceIDs,
                readableSharedSourceIDs.contains(document.sourceID)
            else {
                return false
            }
        }

        switch filters.ownership {
        case .any:
            break
        case .personal:
            if document.sourceKind == .sharedArtifact { return false }
        case .shared:
            if document.sourceKind != .sharedArtifact { return false }
        }

        if let dateRange = filters.dateRange {
            let date = document.sourceUpdatedAt ?? document.indexedAt
            if date < dateRange.lowerBound || date > dateRange.upperBound {
                return false
            }
        }

        if let conversationSources = filters.conversationSources, conversationSources.isEmpty == false {
            guard document.sourceKind == .conversation, let conversation else { return false }
            if conversationSources.contains(conversation.sourceType) == false {
                return false
            }
        }

        return true
    }

    private func shouldEnforceSharedArtifactAccess(
        filters: RetrievalFilters,
        sourceKinds: [SearchSourceKind]?
    ) -> Bool {
        if filters.ownership == .personal {
            return false
        }

        if let sourceKinds, sourceKinds.contains(.sharedArtifact) == false {
            return false
        }

        if let artifactTypes = filters.artifactTypes,
           artifactTypes.isEmpty == false,
           artifactTypes.contains(.sharedArtifact) == false {
            return false
        }

        return true
    }

    private func recencyScore(_ date: Date) -> Double {
        let ageSeconds = max(0, nowProvider().timeIntervalSince(date))
        let ageDays = ageSeconds / 86_400
        return 1.0 / (1.0 + (ageDays / 30.0))
    }

    private func preliminaryScore(for candidate: CandidateAccumulator) -> Double {
        (Self.normalizedLexicalScore(candidate.lexicalRank) * 0.7) + (max(0, candidate.semanticScore ?? 0) * 0.3)
    }

    /// Reciprocal rank fusion across sparse (lexical) and dense (semantic) orderings.
    private static func reciprocalRankFusion(
        lexicalRank: Int?,
        semanticRank: Int?,
        k: Double
    ) -> Double {
        var score = 0.0
        if let r = lexicalRank { score += 1.0 / (k + Double(r)) }
        if let r = semanticRank { score += 1.0 / (k + Double(r)) }
        return score
    }

    /// Maps RRF raw score to \[0, 1\] given how many retrievers matched this chunk (at rank 1 each would contribute `1/(k+1)`).
    private static func normalizedRRFForRerank(
        _ raw: Double,
        lexicalRank: Int?,
        semanticRank: Int?,
        k: Double
    ) -> Double {
        let lists = (lexicalRank != nil ? 1 : 0) + (semanticRank != nil ? 1 : 0)
        guard lists > 0 else { return 0 }
        let maxPossible = Double(lists) / (k + 1.0)
        guard maxPossible > 0 else { return 0 }
        return min(1.0, raw / maxPossible)
    }

    private static func normalizedLexicalScore(_ lexicalRank: Double?) -> Double {
        guard let lexicalRank else { return 0 }
        return 1.0 / (1.0 + abs(lexicalRank))
    }

    private static func queryTokens(from query: String) -> [String] {
        query
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline || $0.isPunctuation })
            .map(String.init)
            .filter { $0.count >= 2 }
    }

    private static func exactTokenCoverageScore(tokens: [String], title: String, chunkText: String) -> Double {
        guard tokens.isEmpty == false else { return 0 }
        let loweredTitle = title.lowercased()
        let loweredChunk = chunkText.lowercased()

        var weightedMatches = 0.0
        for token in tokens {
            if loweredTitle.contains(token) {
                weightedMatches += 2.0
            } else if loweredChunk.contains(token) {
                weightedMatches += 1.0
            }
        }

        let denominator = Double(tokens.count) * 2.0
        guard denominator > 0 else { return 0 }
        return min(1.0, weightedMatches / denominator)
    }

    private static func makeSnippet(lexicalSnippet: String?, chunkText: String, fallback: String) -> String {
        let cleanedLexical = lexicalSnippet?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if cleanedLexical.isEmpty == false {
            return cleanedLexical
        }

        let cleanedChunk = chunkText.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanedChunk.isEmpty == false {
            return String(cleanedChunk.prefix(220))
        }

        return String(fallback.trimmingCharacters(in: .whitespacesAndNewlines).prefix(220))
    }
}

private struct LexicalRetrievalHealthDetails: Codable {
    let queryLength: Int
    let lexicalCandidateCount: Int
    let semanticCandidateCount: Int
    let resultCount: Int
    let indexStale: Bool
    let semanticFallbackUsed: Bool
    let totalQueryLatencyMs: Double?
    let lexicalQueryLatencyMs: Double?
    let semanticQueryLatencyMs: Double?
    let rerankLatencyMs: Double?
    let hydrationLatencyMs: Double?
    let crossEncoderLatencyMs: Double?
}

private struct SemanticFallbackHealthDetails: Codable {
    let queryLength: Int
    let lexicalCandidateCount: Int
}

private struct CandidateAccumulator {
    var lexicalRank: Double?
    var semanticScore: Double?
    var lexicalSnippet: String?
}
