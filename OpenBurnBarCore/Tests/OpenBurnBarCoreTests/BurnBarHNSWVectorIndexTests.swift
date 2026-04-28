import Foundation
import XCTest
@testable import OpenBurnBarCore

final class BurnBarHNSWVectorIndexTests: XCTestCase {

    // MARK: - Helpers

    private func makeTempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hnsw-test-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Builds an HNSW index with the given vectors and returns the files reference.
    private func buildIndex(
        vectors: [(key: UInt64, vector: [Float])],
        dimensions: Int,
        metric: BurnBarEmbeddingDistanceMetric = .cosine,
        m: Int = 16,
        efConstruction: Int = 200,
        efSearch: Int = 64
    ) throws -> (BurnBarPersistentVectorIndexFiles, BurnBarHNSWVectorIndexBackend) {
        let dir = makeTempDirectory()
        let files = BurnBarPersistentVectorIndexFiles(directoryURL: dir)
        let backend = BurnBarHNSWVectorIndexBackend(m: m, efConstruction: efConstruction, efSearch: efSearch)
        let writer = try backend.makeWritable(dimensions: dimensions, distanceMetric: metric)
        try writer.reserve(vectors.count)
        for (key, vec) in vectors {
            try writer.add(key: key, vector: vec)
        }
        try writer.save(to: files.indexURL)
        return (files, backend)
    }

    // MARK: - Basic correctness

    func test_knownVectors_returnsCorrectNearestNeighbors() throws {
        // Three 3D vectors: A is close to B, C is far away
        let vectors: [(key: UInt64, vector: [Float])] = [
            (1, [1.0, 0.0, 0.0]),
            (2, [0.9, 0.1, 0.0]),
            (3, [0.0, 0.0, 1.0])
        ]
        let (files, backend) = try buildIndex(vectors: vectors, dimensions: 3)
        defer { try? FileManager.default.removeItem(at: files.directoryURL) }

        let reader = try backend.makeReadable(dimensions: 3, distanceMetric: .cosine)
        try reader.load(from: files.indexURL)

        let (keys, scores) = try reader.search(vector: [1.0, 0.0, 0.0], limit: 2)
        XCTAssertEqual(keys.count, 2)
        // key=1 should be first (exact match), key=2 should be second (close)
        XCTAssertEqual(keys[0], 1, "Exact match should be ranked first")
        XCTAssertEqual(keys[1], 2, "Close vector should be ranked second")
        XCTAssertEqual(scores[0], 1.0, accuracy: 0.01, "Exact match should have ~1.0 similarity")
        XCTAssertGreaterThan(scores[1], 0.5, "Close vector should have high similarity")
    }

    func test_emptyIndex_returnsEmptyResults() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = BurnBarPersistentVectorIndexFiles(directoryURL: dir)
        let backend = BurnBarHNSWVectorIndexBackend()
        let writer = try backend.makeWritable(dimensions: 4, distanceMetric: .cosine)
        try writer.save(to: files.indexURL)

        let reader = try backend.makeReadable(dimensions: 4, distanceMetric: .cosine)
        try reader.load(from: files.indexURL)

        let (keys, scores) = try reader.search(vector: [1, 0, 0, 0], limit: 10)
        XCTAssertTrue(keys.isEmpty)
        XCTAssertTrue(scores.isEmpty)
    }

    func test_dimensionMismatch_throws() throws {
        let vectors: [(key: UInt64, vector: [Float])] = [
            (1, [1.0, 0.0, 0.0])
        ]
        let (files, backend) = try buildIndex(vectors: vectors, dimensions: 3)
        defer { try? FileManager.default.removeItem(at: files.directoryURL) }

        // Create a reader expecting 4 dimensions but the index has 3
        // Dimension mismatch is detected at search time, not load time
        let reader = try backend.makeReadable(dimensions: 4, distanceMetric: .cosine)
        try reader.load(from: files.indexURL)

        XCTAssertThrowsError(try reader.search(vector: [1, 0, 0, 0], limit: 1)) { error in
            guard let indexError = error as? BurnBarPersistentVectorIndexError else {
                XCTFail("Expected BurnBarPersistentVectorIndexError, got \(error)")
                return
            }
            if case .invalidVectorDimensions(let expected, let actual) = indexError {
                XCTAssertEqual(expected, 4)
                XCTAssertEqual(actual, 3)
            } else {
                XCTFail("Expected invalidVectorDimensions, got \(indexError)")
            }
        }
    }

    func test_dimensionMismatch_atSearchTime_throws() throws {
        let vectors: [(key: UInt64, vector: [Float])] = [
            (1, [1.0, 0.0, 0.0])
        ]
        let (files, backend) = try buildIndex(vectors: vectors, dimensions: 3)
        defer { try? FileManager.default.removeItem(at: files.directoryURL) }

        let reader = try backend.makeReadable(dimensions: 5, distanceMetric: .cosine)
        try reader.load(from: files.indexURL)

        XCTAssertThrowsError(try reader.search(vector: [1, 0, 0, 0, 0], limit: 1)) { error in
            guard let indexError = error as? BurnBarPersistentVectorIndexError else {
                XCTFail("Expected BurnBarPersistentVectorIndexError, got \(error)")
                return
            }
            if case .invalidVectorDimensions(let expected, let actual) = indexError {
                XCTAssertEqual(expected, 5)
                XCTAssertEqual(actual, 3)
            } else {
                XCTFail("Expected invalidVectorDimensions, got \(indexError)")
            }
        }
    }

    func test_addVector_dimensionMismatch_throws() throws {
        let backend = BurnBarHNSWVectorIndexBackend()
        let writer = try backend.makeWritable(dimensions: 3, distanceMetric: .cosine)
        XCTAssertThrowsError(try writer.add(key: 1, vector: [1.0, 0.0])) { error in
            guard let indexError = error as? BurnBarPersistentVectorIndexError else {
                XCTFail("Expected BurnBarPersistentVectorIndexError")
                return
            }
            if case .invalidVectorDimensions(let expected, let actual) = indexError {
                XCTAssertEqual(expected, 3)
                XCTAssertEqual(actual, 2)
            } else {
                XCTFail("Expected invalidVectorDimensions")
            }
        }
    }

    // MARK: - Save/Load round-trip

    func test_saveLoadRoundTrip_preservesSearchResults() throws {
        let dims = 8
        var vectors: [(key: UInt64, vector: [Float])] = []
        for i in 0 ..< 50 {
            var v = [Float](repeating: 0, count: dims)
            v[i % dims] = 1.0
            v[(i + 1) % dims] = Float(i) * 0.01
            vectors.append((UInt64(i + 1), v))
        }

        let (files, backend) = try buildIndex(vectors: vectors, dimensions: dims)
        defer { try? FileManager.default.removeItem(at: files.directoryURL) }

        // Search with loaded data
        let readerLoad = try backend.makeReadable(dimensions: dims, distanceMetric: .cosine)
        try readerLoad.load(from: files.indexURL)
        let (keysLoad, scoresLoad) = try readerLoad.search(vector: vectors[0].vector, limit: 5)

        // Save again and search again
        let dir2 = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir2) }
        let files2 = BurnBarPersistentVectorIndexFiles(directoryURL: dir2)

        let writer2 = try backend.makeWritable(dimensions: dims, distanceMetric: .cosine)
        for (key, vec) in vectors {
            try writer2.add(key: key, vector: vec)
        }
        try writer2.save(to: files2.indexURL)

        let readerLoad2 = try backend.makeReadable(dimensions: dims, distanceMetric: .cosine)
        try readerLoad2.load(from: files2.indexURL)
        let (keysLoad2, scoresLoad2) = try readerLoad2.search(vector: vectors[0].vector, limit: 5)

        XCTAssertEqual(keysLoad, keysLoad2)
        for i in scoresLoad.indices {
            XCTAssertEqual(scoresLoad[i], scoresLoad2[i], accuracy: 0.001)
        }
    }

    // MARK: - Memory-mapped view produces same results as load

    func test_viewFromURL_producesSameResultsAsLoad() throws {
        let dims = 4
        let vectors: [(key: UInt64, vector: [Float])] = [
            (10, [1.0, 0.0, 0.0, 0.0]),
            (20, [0.0, 1.0, 0.0, 0.0]),
            (30, [0.0, 0.0, 1.0, 0.0]),
            (40, [0.0, 0.0, 0.0, 1.0]),
            (50, [0.5, 0.5, 0.0, 0.0])
        ]
        let (files, backend) = try buildIndex(vectors: vectors, dimensions: dims)
        defer { try? FileManager.default.removeItem(at: files.directoryURL) }

        let query: [Float] = [0.6, 0.4, 0.0, 0.0]

        let readerLoad = try backend.makeReadable(dimensions: dims, distanceMetric: .cosine)
        try readerLoad.load(from: files.indexURL)
        let (keysLoad, scoresLoad) = try readerLoad.search(vector: query, limit: 3)

        let readerView = try backend.makeReadable(dimensions: dims, distanceMetric: .cosine)
        try readerView.view(from: files.indexURL)
        let (keysView, scoresView) = try readerView.search(vector: query, limit: 3)

        XCTAssertEqual(keysLoad, keysView)
        for i in scoresLoad.indices {
            XCTAssertEqual(scoresLoad[i], scoresView[i], accuracy: 0.001)
        }
    }

    // MARK: - Recall test

    func test_hnswRecall_atLeast95Percent_comparedToExact() throws {
        let dims = 32
        let numVectors = 500
        let numQueries = 20
        let k = 10

        // Generate random vectors with a fixed seed for reproducibility
        var rng = SeededRNG(seed: 42)
        var vectors: [(key: UInt64, vector: [Float])] = []
        for i in 0 ..< numVectors {
            let v = (0 ..< dims).map { _ in Float.random(in: -1 ... 1, using: &rng) }
            vectors.append((UInt64(i + 1), v))
        }

        // Build HNSW index
        let (hnswFiles, hnswBackend) = try buildIndex(
            vectors: vectors,
            dimensions: dims,
            m: 16,
            efConstruction: 200,
            efSearch: 128  // Higher ef for better recall
        )
        defer { try? FileManager.default.removeItem(at: hnswFiles.directoryURL) }

        // Build exact index for ground truth
        let exactDir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: exactDir) }
        let exactFiles = BurnBarPersistentVectorIndexFiles(directoryURL: exactDir)
        let exactBackend = BurnBarMappedPersistentVectorIndexBackend()
        let exactWriter = try exactBackend.makeWritable(dimensions: dims, distanceMetric: .cosine)
        try exactWriter.reserve(numVectors)
        for (key, vec) in vectors {
            try exactWriter.add(key: key, vector: vec)
        }
        try exactWriter.save(to: exactFiles.indexURL)

        let hnswReader = try hnswBackend.makeReadable(dimensions: dims, distanceMetric: .cosine)
        try hnswReader.load(from: hnswFiles.indexURL)

        let exactReader = try exactBackend.makeReadable(dimensions: dims, distanceMetric: .cosine)
        try exactReader.load(from: exactFiles.indexURL)

        // Generate random queries and measure recall
        var totalRecall: Double = 0
        for _ in 0 ..< numQueries {
            let query = (0 ..< dims).map { _ in Float.random(in: -1 ... 1, using: &rng) }

            let (exactKeys, _) = try exactReader.search(vector: query, limit: k)
            let (hnswKeys, _) = try hnswReader.search(vector: query, limit: k)

            let exactSet = Set(exactKeys)
            let overlap = hnswKeys.filter { exactSet.contains($0) }.count
            totalRecall += Double(overlap) / Double(k)
        }

        let averageRecall = totalRecall / Double(numQueries)
        XCTAssertGreaterThanOrEqual(averageRecall, 0.95, "HNSW recall@\(k) should be >= 95%, got \(averageRecall * 100)%")
    }

    // MARK: - Large corpus test

    func test_largeCorpus_1000Vectors_producesResults() throws {
        let dims = 16
        let numVectors = 1000

        var rng = SeededRNG(seed: 123)
        var vectors: [(key: UInt64, vector: [Float])] = []
        for i in 0 ..< numVectors {
            let v = (0 ..< dims).map { _ in Float.random(in: -1 ... 1, using: &rng) }
            vectors.append((UInt64(i + 1), v))
        }

        let (files, backend) = try buildIndex(
            vectors: vectors,
            dimensions: dims,
            m: 16,
            efConstruction: 200,
            efSearch: 64
        )
        defer { try? FileManager.default.removeItem(at: files.directoryURL) }

        let reader = try backend.makeReadable(dimensions: dims, distanceMetric: .cosine)
        try reader.load(from: files.indexURL)

        let query = (0 ..< dims).map { _ in Float.random(in: -1 ... 1, using: &rng) }
        let (keys, scores) = try reader.search(vector: query, limit: 10)

        XCTAssertEqual(keys.count, 10)
        XCTAssertEqual(scores.count, 10)
        // Scores should be in descending order (higher = more similar)
        for i in 0 ..< scores.count - 1 {
            XCTAssertGreaterThanOrEqual(scores[i], scores[i + 1], "Scores should be descending")
        }
    }

    // MARK: - Single vector index

    func test_singleVector_returnsIt() throws {
        let vectors: [(key: UInt64, vector: [Float])] = [
            (42, [1.0, 0.0, 0.0])
        ]
        let (files, backend) = try buildIndex(vectors: vectors, dimensions: 3)
        defer { try? FileManager.default.removeItem(at: files.directoryURL) }

        let reader = try backend.makeReadable(dimensions: 3, distanceMetric: .cosine)
        try reader.load(from: files.indexURL)
        let (keys, scores) = try reader.search(vector: [1.0, 0.0, 0.0], limit: 5)
        XCTAssertEqual(keys, [42])
        XCTAssertEqual(scores.count, 1)
    }

    // MARK: - Backend identity

    func test_backendID() {
        let backend = BurnBarHNSWVectorIndexBackend()
        XCTAssertEqual(backend.backendID, "hnsw")
        XCTAssertEqual(backend.backendVersion, "1")
    }

    func test_factoryDefaultReturnsHNSW() {
        let backend = BurnBarPersistentVectorIndexFactory.defaultBackend()
        XCTAssertEqual(backend.backendID, "hnsw")
    }

    func test_factoryExactReturnsExact() {
        let backend = BurnBarPersistentVectorIndexFactory.exactBackend()
        XCTAssertEqual(backend.backendID, "mapped_exact")
    }

    func test_factoryHNSWReturnsHNSW() {
        let backend = BurnBarPersistentVectorIndexFactory.hnswBackend()
        XCTAssertEqual(backend.backendID, "hnsw")
    }

    // MARK: - Dot product and euclidean metrics

    func test_dotProduct_metric_searchWorks() throws {
        let vectors: [(key: UInt64, vector: [Float])] = [
            (1, [1.0, 0.0]),
            (2, [0.0, 1.0]),
            (3, [0.5, 0.5])
        ]
        let (files, backend) = try buildIndex(vectors: vectors, dimensions: 2, metric: .dotProduct)
        defer { try? FileManager.default.removeItem(at: files.directoryURL) }

        let reader = try backend.makeReadable(dimensions: 2, distanceMetric: .dotProduct)
        try reader.load(from: files.indexURL)
        let (keys, _) = try reader.search(vector: [1.0, 0.0], limit: 2)
        XCTAssertEqual(keys[0], 1, "Exact match should be first for dot product")
    }

    func test_euclidean_metric_searchWorks() throws {
        let vectors: [(key: UInt64, vector: [Float])] = [
            (1, [1.0, 0.0]),
            (2, [0.0, 1.0]),
            (3, [0.9, 0.1])
        ]
        let (files, backend) = try buildIndex(vectors: vectors, dimensions: 2, metric: .euclidean)
        defer { try? FileManager.default.removeItem(at: files.directoryURL) }

        let reader = try backend.makeReadable(dimensions: 2, distanceMetric: .euclidean)
        try reader.load(from: files.indexURL)
        let (keys, scores) = try reader.search(vector: [1.0, 0.0], limit: 2)
        XCTAssertEqual(keys[0], 1, "Exact match should be first for euclidean")
        XCTAssertEqual(scores[0], 0.0, accuracy: 0.01, "Exact match should have 0 euclidean distance -> -0 similarity")
    }

    // MARK: - Snapshot integration

    func test_snapshotOpenAndCandidates() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let files = BurnBarPersistentVectorIndexFiles(directoryURL: dir)
        let backend = BurnBarHNSWVectorIndexBackend()
        let chunkIDs = ["chunk-a", "chunk-b", "chunk-c"]
        let mapping = try BurnBarPersistentVectorIndexKeyCodec.makeMapping(chunkIDs: chunkIDs)

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
        XCTAssertEqual(candidates[0].chunkID, "chunk-a")
        XCTAssertEqual(candidates[1].chunkID, "chunk-b")
    }

    // MARK: - Config test

    func test_semanticSearchConfig_hnswDefaults() {
        let config = BurnBarSemanticSearchConfig.default
        XCTAssertEqual(config.hnswM, 16)
        XCTAssertEqual(config.hnswEfConstruction, 200)
        XCTAssertEqual(config.hnswEfSearch, 64)
    }

    func test_semanticSearchConfig_customHNSW() {
        let config = BurnBarSemanticSearchConfig(
            hnswM: 32,
            hnswEfConstruction: 400,
            hnswEfSearch: 128
        )
        XCTAssertEqual(config.hnswM, 32)
        XCTAssertEqual(config.hnswEfConstruction, 400)
        XCTAssertEqual(config.hnswEfSearch, 128)
    }

    // MARK: - SIMD Distance Accuracy

    func test_simdDotProduct_matchesScalarDotProduct() {
        let vector: [Float] = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0]
        let simdResult = BurnBarVectorMath.simdDotProductF(lhs: vector, rhs: vector)
        var scalarResult: Float = 0
        for i in vector.indices { scalarResult += vector[i] * vector[i] }
        XCTAssertEqual(simdResult, scalarResult, accuracy: 0.0001)
    }

    func test_simdEuclideanDistanceSq_matchesScalar() {
        let a: [Float] = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0]
        let b: [Float] = [8.0, 7.0, 6.0, 5.0, 4.0, 3.0, 2.0, 1.0]
        let simdResult = BurnBarVectorMath.simdEuclideanDistanceSqF(lhs: a, rhs: b)
        var scalarResult: Float = 0
        for i in a.indices {
            let d = a[i] - b[i]
            scalarResult += d * d
        }
        XCTAssertEqual(simdResult, scalarResult, accuracy: 0.0001)
    }

    func test_simdL2Normalized_producesUnitLength() {
        let vector: [Float] = [3.0, 4.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
        let normalized = BurnBarVectorMath.simdL2Normalized(vector)
        let lengthSq = normalized.map { $0 * $0 }.reduce(0, +)
        XCTAssertEqual(lengthSq, 1.0, accuracy: 0.0001)
    }

    func test_simdFallback_forSmallVectors() {
        // Vectors shorter than simdThreshold (8) should use scalar fallback
        let a: [Float] = [1.0, 2.0, 3.0]
        let b: [Float] = [4.0, 5.0, 6.0]
        let simdResult = BurnBarVectorMath.simdDotProductF(lhs: a, rhs: b)
        var scalarResult: Float = 0
        for i in a.indices { scalarResult += a[i] * b[i] }
        XCTAssertEqual(simdResult, scalarResult, accuracy: 0.0001)
    }

    // MARK: - Scalar Quantization

    func test_quantizedIndex_saveLoadSearch_producesResults() throws {
        let dims = 8
        let vectors: [(key: UInt64, vector: [Float])] = [
            (1, [1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]),
            (2, [0.9, 0.1, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]),
            (3, [0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0])
        ]
        let backend = BurnBarHNSWVectorIndexBackend(quantization: .scalarUInt8)
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = BurnBarPersistentVectorIndexFiles(directoryURL: dir)

        let writer = try backend.makeWritable(dimensions: dims, distanceMetric: .cosine)
        try writer.reserve(vectors.count)
        for (key, vec) in vectors {
            try writer.add(key: key, vector: vec)
        }
        try writer.save(to: files.indexURL)

        let reader = try backend.makeReadable(dimensions: dims, distanceMetric: .cosine)
        try reader.load(from: files.indexURL)
        let (keys, scores) = try reader.search(vector: [1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0], limit: 2)

        XCTAssertEqual(keys.count, 2)
        XCTAssertEqual(keys[0], 1, "Exact match should be first")
        XCTAssertGreaterThan(scores[0], scores[1], "First result should have higher similarity")
    }

    func test_quantizedIndex_recallAtLeast90Percent() throws {
        let dims = 128
        let numVectors = 1000
        let numQueries = 20
        let k = 10

        var rng = SeededRNG(seed: 42)
        var vectors: [(key: UInt64, vector: [Float])] = []
        for i in 0 ..< numVectors {
            let v = (0 ..< dims).map { _ in Float.random(in: -1 ... 1, using: &rng) }
            vectors.append((UInt64(i + 1), v))
        }

        let quantizedBackend = BurnBarHNSWVectorIndexBackend(efSearch: 200, quantization: .scalarUInt8)
        let exactBackend = BurnBarMappedPersistentVectorIndexBackend()

        let qDir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: qDir) }
        let qFiles = BurnBarPersistentVectorIndexFiles(directoryURL: qDir)
        let qWriter = try quantizedBackend.makeWritable(dimensions: dims, distanceMetric: .cosine)
        try qWriter.reserve(numVectors)
        for (key, vec) in vectors {
            try qWriter.add(key: key, vector: vec)
        }
        try qWriter.save(to: qFiles.indexURL)

        let eDir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: eDir) }
        let eFiles = BurnBarPersistentVectorIndexFiles(directoryURL: eDir)
        let eWriter = try exactBackend.makeWritable(dimensions: dims, distanceMetric: .cosine)
        try eWriter.reserve(numVectors)
        for (key, vec) in vectors {
            try eWriter.add(key: key, vector: vec)
        }
        try eWriter.save(to: eFiles.indexURL)

        let qReader = try quantizedBackend.makeReadable(dimensions: dims, distanceMetric: .cosine)
        try qReader.load(from: qFiles.indexURL)

        let eReader = try exactBackend.makeReadable(dimensions: dims, distanceMetric: .cosine)
        try eReader.load(from: eFiles.indexURL)

        var totalRecall: Double = 0
        for _ in 0 ..< numQueries {
            let query = (0 ..< dims).map { _ in Float.random(in: -1 ... 1, using: &rng) }

            let (exactKeys, _) = try eReader.search(vector: query, limit: k)
            let (quantizedKeys, _) = try qReader.search(vector: query, limit: k)

            let exactSet = Set(exactKeys)
            let overlap = quantizedKeys.filter { exactSet.contains($0) }.count
            totalRecall += Double(overlap) / Double(k)
        }

        let averageRecall = totalRecall / Double(numQueries)
        XCTAssertGreaterThanOrEqual(averageRecall, 0.90, "Quantized HNSW recall@\(k) should be >= 90%, got \(averageRecall * 100)%")
    }

    func test_quantizedIndex_fileSizeReducedByAtLeast3x() throws {
        // Use higher dimensions to dominate graph overhead and achieve >3x reduction
        let dims = 512
        let numVectors = 2000

        var rng = SeededRNG(seed: 123)
        var vectors: [(key: UInt64, vector: [Float])] = []
        for i in 0 ..< numVectors {
            let v = (0 ..< dims).map { _ in Float.random(in: -1 ... 1, using: &rng) }
            vectors.append((UInt64(i + 1), v))
        }

        let floatBackend = BurnBarHNSWVectorIndexBackend(quantization: .none)
        let quantizedBackend = BurnBarHNSWVectorIndexBackend(quantization: .scalarUInt8)

        let fDir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: fDir) }
        let fFiles = BurnBarPersistentVectorIndexFiles(directoryURL: fDir)
        let fWriter = try floatBackend.makeWritable(dimensions: dims, distanceMetric: .cosine)
        try fWriter.reserve(numVectors)
        for (key, vec) in vectors {
            try fWriter.add(key: key, vector: vec)
        }
        try fWriter.save(to: fFiles.indexURL)

        let qDir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: qDir) }
        let qFiles = BurnBarPersistentVectorIndexFiles(directoryURL: qDir)
        let qWriter = try quantizedBackend.makeWritable(dimensions: dims, distanceMetric: .cosine)
        try qWriter.reserve(numVectors)
        for (key, vec) in vectors {
            try qWriter.add(key: key, vector: vec)
        }
        try qWriter.save(to: qFiles.indexURL)

        let floatSize = BurnBarPersistentVectorIndexSnapshotIO.fileByteCount(at: fFiles.indexURL)
        let quantizedSize = BurnBarPersistentVectorIndexSnapshotIO.fileByteCount(at: qFiles.indexURL)

        let ratio = Double(floatSize) / Double(quantizedSize)
        XCTAssertGreaterThanOrEqual(ratio, 3.0, "Quantized index should be at least 3.0x smaller. Float: \(floatSize), Quantized: \(quantizedSize), ratio: \(ratio)")
    }

    func test_v1BackwardCompatibility_loadsAndSearches() throws {
        // Build a v1 index by using a backend with .none quantization (forces version 1)
        let vectors: [(key: UInt64, vector: [Float])] = [
            (1, [1.0, 0.0, 0.0]),
            (2, [0.9, 0.1, 0.0]),
            (3, [0.0, 1.0, 0.0])
        ]
        let backend = BurnBarHNSWVectorIndexBackend(quantization: .none)
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = BurnBarPersistentVectorIndexFiles(directoryURL: dir)

        let writer = try backend.makeWritable(dimensions: 3, distanceMetric: .cosine)
        try writer.reserve(vectors.count)
        for (key, vec) in vectors {
            try writer.add(key: key, vector: vec)
        }
        try writer.save(to: files.indexURL)

        // Verify it's v1 by checking header
        let data = try Data(contentsOf: files.indexURL)
        let header = try BurnBarHNSWIndexFormat.parseHeader(from: data)
        XCTAssertEqual(header.version, 1, "Non-quantized index should be v1")

        // Load and search with a backend that defaults to .none
        let reader = try backend.makeReadable(dimensions: 3, distanceMetric: .cosine)
        try reader.load(from: files.indexURL)
        let (keys, _) = try reader.search(vector: [1.0, 0.0, 0.0], limit: 2)

        XCTAssertEqual(keys.count, 2)
        XCTAssertEqual(keys[0], 1)
    }

    func test_v2Format_roundTrip() throws {
        let vectors: [(key: UInt64, vector: [Float])] = [
            (1, [1.0, 0.0, 0.0]),
            (2, [0.8, 0.2, 0.0]),
            (3, [0.0, 1.0, 0.0])
        ]
        let backend = BurnBarHNSWVectorIndexBackend(quantization: .scalarUInt8)
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = BurnBarPersistentVectorIndexFiles(directoryURL: dir)

        let writer = try backend.makeWritable(dimensions: 3, distanceMetric: .cosine)
        try writer.reserve(vectors.count)
        for (key, vec) in vectors {
            try writer.add(key: key, vector: vec)
        }
        try writer.save(to: files.indexURL)

        let data = try Data(contentsOf: files.indexURL)
        let header = try BurnBarHNSWIndexFormat.parseHeader(from: data)
        XCTAssertEqual(header.version, 2, "Quantized index should be v2")
        XCTAssertEqual(header.quantizationType, 1, "Quantization type should be 1 for scalarUInt8")

        let reader = try backend.makeReadable(dimensions: 3, distanceMetric: .cosine)
        try reader.load(from: files.indexURL)
        let (keys, scores) = try reader.search(vector: [1.0, 0.0, 0.0], limit: 2)

        XCTAssertEqual(keys.count, 2)
        XCTAssertEqual(keys[0], 1)
        XCTAssertGreaterThan(scores[0], scores[1])
    }

    func test_backendVersion_reflectsQuantization() {
        let noneBackend = BurnBarHNSWVectorIndexBackend(quantization: .none)
        let quantizedBackend = BurnBarHNSWVectorIndexBackend(quantization: .scalarUInt8)
        XCTAssertEqual(noneBackend.backendVersion, "1")
        XCTAssertEqual(quantizedBackend.backendVersion, "2")
    }
}

// MARK: - Seeded RNG for reproducible tests

private struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
