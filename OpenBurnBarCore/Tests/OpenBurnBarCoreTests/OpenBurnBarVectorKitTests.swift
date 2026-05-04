import Foundation
import XCTest
@testable import OpenBurnBarCore

final class BurnBarVectorKitTests: XCTestCase {
    // MARK: - VectorBlobCodec Tests

    func test_encodeDecode_roundTrips() {
        let original = [1.0, 2.0, 3.0, 4.0, 5.0] as [Float]
        let encoded = BurnBarVectorBlobCodec.encode(original)
        let decoded = BurnBarVectorBlobCodec.decode(encoded)
        XCTAssertEqual(decoded, original)
    }

    func test_encode_emptyVector_returnsEmptyData() {
        let empty: [Float] = []
        let encoded = BurnBarVectorBlobCodec.encode(empty)
        XCTAssertTrue(encoded.isEmpty)
    }

    func test_decode_emptyData_returnsNil() {
        let emptyData = Data()
        let decoded = BurnBarVectorBlobCodec.decode(emptyData)
        XCTAssertNil(decoded)
    }

    func test_decode_invalidSizeData_returnsNil() {
        // Data with size not divisible by Float size
        let invalidData = Data([0x01, 0x02, 0x03])
        let decoded = BurnBarVectorBlobCodec.decode(invalidData)
        XCTAssertNil(decoded)
    }

    func test_decode_validData_returnsFloats() {
        let original: [Float] = [1.5, 2.5, 3.5]
        let encoded = BurnBarVectorBlobCodec.encode(original)
        let decoded = BurnBarVectorBlobCodec.decode(encoded)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.count, 3)
    }

    // MARK: - VectorMath Tests

    func test_cosineSimilarity_identicalVectors() {
        let v1: [Float] = [1.0, 0.0, 0.0]
        let v2: [Float] = [1.0, 0.0, 0.0]
        let similarity = BurnBarVectorMath.similarity(lhs: v1, rhs: v2, metric: .cosine)
        XCTAssertEqual(similarity, 1.0, accuracy: 0.0001)
    }

    func test_cosineSimilarity_orthogonalVectors() {
        let v1: [Float] = [1.0, 0.0, 0.0]
        let v2: [Float] = [0.0, 1.0, 0.0]
        let similarity = BurnBarVectorMath.similarity(lhs: v1, rhs: v2, metric: .cosine)
        XCTAssertEqual(similarity, 0.0, accuracy: 0.0001)
    }

    func test_cosineSimilarity_oppositeVectors() {
        let v1: [Float] = [1.0, 0.0, 0.0]
        let v2: [Float] = [-1.0, 0.0, 0.0]
        let similarity = BurnBarVectorMath.similarity(lhs: v1, rhs: v2, metric: .cosine)
        XCTAssertEqual(similarity, -1.0, accuracy: 0.0001)
    }

    func test_cosineSimilarity_differentDimensionCounts_returnsZero() {
        let v1: [Float] = [1.0, 0.0, 0.0]
        let v2: [Float] = [1.0, 0.0]
        let similarity = BurnBarVectorMath.similarity(lhs: v1, rhs: v2, metric: .cosine)
        XCTAssertEqual(similarity, 0.0)
    }

    func test_dotProduct_basic() {
        let v1: [Float] = [1.0, 2.0, 3.0]
        let v2: [Float] = [4.0, 5.0, 6.0]
        let dot = BurnBarVectorMath.similarity(lhs: v1, rhs: v2, metric: .dotProduct)
        // 1*4 + 2*5 + 3*6 = 4 + 10 + 18 = 32
        XCTAssertEqual(dot, 32.0, accuracy: 0.0001)
    }

    func test_euclideanDistance_zeroDistance() {
        let v1: [Float] = [1.0, 2.0, 3.0]
        let v2: [Float] = [1.0, 2.0, 3.0]
        let dist = BurnBarVectorMath.similarity(lhs: v1, rhs: v2, metric: .euclidean)
        XCTAssertEqual(dist, 0.0, accuracy: 0.0001)
    }

    func test_euclideanDistance_basic() {
        let v1: [Float] = [0.0, 0.0]
        let v2: [Float] = [3.0, 4.0]
        let dist = BurnBarVectorMath.similarity(lhs: v1, rhs: v2, metric: .euclidean)
        // sqrt(9 + 16) = 5, so -euclidean = -5
        XCTAssertEqual(dist, -5.0, accuracy: 0.0001)
    }

    func test_l2Normalized_unitVector() {
        let v: [Float] = [3.0, 4.0]
        let normalized = BurnBarVectorMath.l2Normalized(v)
        // Expected: [3/5, 4/5] = [0.6, 0.8]
        XCTAssertEqual(normalized[0], 0.6, accuracy: 0.0001)
        XCTAssertEqual(normalized[1], 0.8, accuracy: 0.0001)
    }

    func test_l2Normalized_emptyVector_returnsEmpty() {
        let empty: [Float] = []
        let normalized = BurnBarVectorMath.l2Normalized(empty)
        XCTAssertTrue(normalized.isEmpty)
    }

    func test_l2Normalized_zeroVector_returnsZero() {
        let zero: [Float] = [0.0, 0.0, 0.0]
        let normalized = BurnBarVectorMath.l2Normalized(zero)
        // Should return original zero vector (no division by zero)
        XCTAssertEqual(normalized, [0.0, 0.0, 0.0])
    }

    // MARK: - HybridRankFusion Tests

    func test_reciprocalRankFusion_bothRanks() {
        let score = BurnBarHybridRankFusion.reciprocalRankFusion(
            lexicalRank: 1,
            semanticRank: 2,
            k: 60.0
        )
        // 1/(60+1) + 1/(60+2) = 1/61 + 1/62 ≈ 0.01639 + 0.01613 = 0.03252
        XCTAssertEqual(score, 1.0 / 61.0 + 1.0 / 62.0, accuracy: 0.0001)
    }

    func test_reciprocalRankFusion_lexicalOnly() {
        let score = BurnBarHybridRankFusion.reciprocalRankFusion(
            lexicalRank: 5,
            semanticRank: nil,
            k: 60.0
        )
        // 1/(60+5) = 1/65 ≈ 0.01538
        XCTAssertEqual(score, 1.0 / 65.0, accuracy: 0.0001)
    }

    func test_reciprocalRankFusion_semanticOnly() {
        let score = BurnBarHybridRankFusion.reciprocalRankFusion(
            lexicalRank: nil,
            semanticRank: 3,
            k: 60.0
        )
        // 1/(60+3) = 1/63 ≈ 0.01587
        XCTAssertEqual(score, 1.0 / 63.0, accuracy: 0.0001)
    }

    func test_reciprocalRankFusion_neitherRank() {
        let score = BurnBarHybridRankFusion.reciprocalRankFusion(
            lexicalRank: nil,
            semanticRank: nil,
            k: 60.0
        )
        XCTAssertEqual(score, 0.0)
    }

    func test_normalizedScore_singleSource() {
        let raw = 1.0 / 61.0
        let normalized = BurnBarHybridRankFusion.normalizedScore(
            rawScore: raw,
            hasLexical: true,
            hasSemantic: false,
            k: 60.0
        )
        // maxPossible = 1 / (60 + 1) = 1/61
        // normalized = raw / maxPossible = 1
        XCTAssertEqual(normalized, 1.0, accuracy: 0.0001)
    }

    func test_normalizedScore_bothSources() {
        let raw = 1.0 / 61.0 + 1.0 / 62.0
        let normalized = BurnBarHybridRankFusion.normalizedScore(
            rawScore: raw,
            hasLexical: true,
            hasSemantic: true,
            k: 60.0
        )
        // maxPossible = 2 / (60 + 1) = 2/61
        // normalized = raw / maxPossible ≈ 0.95
        let expected = (1.0 / 61.0 + 1.0 / 62.0) / (2.0 / 61.0)
        XCTAssertEqual(normalized, expected, accuracy: 0.0001)
    }

    func test_fusedScore_hybridHit() {
        let score = BurnBarHybridRankFusion.fusedScore(
            lexicalRank: 1,
            semanticRank: 1,
            k: 60.0
        )
        // Both at rank 1: 2/(60+1) = 2/61, maxPossible = 2/61, normalized = 1.0
        XCTAssertEqual(score, 1.0, accuracy: 0.0001)
    }

    func test_fusedScore_lexicalOnly() {
        let score = BurnBarHybridRankFusion.fusedScore(
            lexicalRank: 10,
            semanticRank: nil,
            k: 60.0
        )
        // 1/(60+10) / (1/(60+1)) = 61/70 ≈ 0.8714
        let expected = (1.0 / 70.0) / (1.0 / 61.0)
        XCTAssertEqual(score, expected, accuracy: 0.0001)
    }

    // MARK: - BurnBarSemanticCandidate Tests

    func test_semanticCandidate_creation() {
        let candidate = BurnBarSemanticCandidate(
            chunkID: "chunk-123",
            score: 0.95,
            rank: 1
        )
        XCTAssertEqual(candidate.chunkID, "chunk-123")
        XCTAssertEqual(candidate.score, 0.95)
        XCTAssertEqual(candidate.rank, 1)
    }

    func test_semanticCandidate_equality() {
        let c1 = BurnBarSemanticCandidate(chunkID: "chunk-1", score: 0.9, rank: 1)
        let c2 = BurnBarSemanticCandidate(chunkID: "chunk-1", score: 0.9, rank: 1)
        let c3 = BurnBarSemanticCandidate(chunkID: "chunk-2", score: 0.9, rank: 1)
        XCTAssertEqual(c1, c2)
        XCTAssertNotEqual(c1, c3)
    }

    func test_persistentVectorIndexKeyCodec_generatesStableUniqueKeys() throws {
        let first = try BurnBarPersistentVectorIndexKeyCodec.makeMapping(chunkIDs: ["chunk-b", "chunk-a", "chunk-c"])
        let second = try BurnBarPersistentVectorIndexKeyCodec.makeMapping(chunkIDs: ["chunk-c", "chunk-a", "chunk-b"])

        XCTAssertEqual(first, second)
        XCTAssertEqual(Set(first.values).count, 3)
    }

    func test_persistentVectorIndexSnapshot_roundTripsAndSearches() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)

        let files = BurnBarPersistentVectorIndexFiles(directoryURL: directoryURL)
        let backend = BurnBarMappedPersistentVectorIndexBackend()
        let mapping = try BurnBarPersistentVectorIndexKeyCodec.makeMapping(chunkIDs: ["chunk-a", "chunk-b", "chunk-c"])
        let writer = try backend.makeWritable(dimensions: 2, distanceMetric: .cosine)
        try writer.reserve(3)
        try writer.add(key: mapping["chunk-a"]!, vector: [1, 0])
        try writer.add(key: mapping["chunk-b"]!, vector: [0.8, 0.2])
        try writer.add(key: mapping["chunk-c"]!, vector: [0, 1])
        try writer.save(to: files.indexURL)

        let manifest = BurnBarPersistentVectorIndexManifest(
            backendID: backend.backendID,
            backendVersion: backend.backendVersion,
            embeddingVersionID: "version-1",
            fingerprint: "version-1|3|100",
            dimensions: 2,
            distanceMetric: .cosine,
            vectorCount: 3,
            builtAt: Date(timeIntervalSince1970: 1_742_000_000)
        )
        try BurnBarPersistentVectorIndexSnapshotIO.writeManifest(manifest, to: files.manifestURL)
        try BurnBarPersistentVectorIndexSnapshotIO.writeKeyMapping(mapping, to: files.keyMappingURL)

        let snapshot = try BurnBarPersistentVectorIndexSnapshot.open(files: files, backend: backend)
        let candidates = try snapshot.candidates(for: [1, 0], limit: 2)

        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates.map(\.chunkID), ["chunk-a", "chunk-b"])
    }

    // MARK: - BurnBarSemanticSearchConfig Tests

    func test_defaultConfig_hasReasonableDefaults() {
        let config = BurnBarSemanticSearchConfig.default
        XCTAssertEqual(config.maxCandidates, 200)
        XCTAssertEqual(config.rrfK, 60.0)
        XCTAssertTrue(config.enabled)
    }

    func test_conservativeConfig_hasLimitedCandidates() {
        let config = BurnBarSemanticSearchConfig.conservative
        XCTAssertEqual(config.maxCandidates, 50)
        XCTAssertEqual(config.rrfK, 60.0)
        XCTAssertTrue(config.enabled)
    }

    func test_customConfig() {
        let config = BurnBarSemanticSearchConfig(
            maxCandidates: 100,
            rrfK: 30.0,
            enabled: false
        )
        XCTAssertEqual(config.maxCandidates, 100)
        XCTAssertEqual(config.rrfK, 30.0)
        XCTAssertFalse(config.enabled)
    }

    // MARK: - BurnBarEmbeddingDistanceMetric Tests

    func test_distanceMetric_rawValues() {
        XCTAssertEqual(BurnBarEmbeddingDistanceMetric.cosine.rawValue, "cosine")
        XCTAssertEqual(BurnBarEmbeddingDistanceMetric.dotProduct.rawValue, "dotProduct")
        XCTAssertEqual(BurnBarEmbeddingDistanceMetric.euclidean.rawValue, "euclidean")
    }

    func test_distanceMetric_isCodable() throws {
        let encoder = JSONEncoder()
        let cosine = try encoder.encode(BurnBarEmbeddingDistanceMetric.cosine)
        XCTAssertEqual(String(data: cosine, encoding: .utf8), "\"cosine\"")

        let dot = try encoder.encode(BurnBarEmbeddingDistanceMetric.dotProduct)
        XCTAssertEqual(String(data: dot, encoding: .utf8), "\"dotProduct\"")

        let euclidean = try encoder.encode(BurnBarEmbeddingDistanceMetric.euclidean)
        XCTAssertEqual(String(data: euclidean, encoding: .utf8), "\"euclidean\"")
    }

    func test_distanceMetric_isDecodable() throws {
        let decoder = JSONDecoder()
        let cosine = try decoder.decode(BurnBarEmbeddingDistanceMetric.self, from: "\"cosine\"".data(using: .utf8)!)
        XCTAssertEqual(cosine, .cosine)

        let dot = try decoder.decode(BurnBarEmbeddingDistanceMetric.self, from: "\"dotProduct\"".data(using: .utf8)!)
        XCTAssertEqual(dot, .dotProduct)

        let euclidean = try decoder.decode(BurnBarEmbeddingDistanceMetric.self, from: "\"euclidean\"".data(using: .utf8)!)
        XCTAssertEqual(euclidean, .euclidean)
    }
}
