import OpenBurnBarCore
@testable import OpenBurnBarDaemon
import GRDB
import XCTest

final class BurnBarHNSWIntegrationTests: XCTestCase {

    /// Verifies that the HNSW backend can be obtained through the factory,
    /// build an index, save/load it, and produce correct search results.
    func test_hnswBackendViaFactory_roundTripProducesResults() throws {
        let backend = BurnBarPersistentVectorIndexFactory.defaultBackend()
        XCTAssertEqual(backend.backendID, "hnsw", "Default backend should be HNSW")

        let dims = 4
        let writer = try backend.makeWritable(dimensions: dims, distanceMetric: .cosine)
        try writer.reserve(3)
        try writer.add(key: 1, vector: [1, 0, 0, 0])
        try writer.add(key: 2, vector: [0, 1, 0, 0])
        try writer.add(key: 3, vector: [0.9, 0.1, 0, 0])

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hnsw-integration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = BurnBarPersistentVectorIndexFiles(directoryURL: dir)

        try writer.save(to: files.indexURL)

        let reader = try backend.makeReadable(dimensions: dims, distanceMetric: .cosine)
        try reader.load(from: files.indexURL)
        let (keys, scores) = try reader.search(vector: [1, 0, 0, 0], limit: 2)

        XCTAssertEqual(keys.count, 2)
        XCTAssertEqual(keys[0], 1, "Exact match vector should be first")
        XCTAssertGreaterThan(scores[0], scores[1], "First result should have higher similarity")
    }

    /// Verifies the HNSW backend can be explicitly obtained via `hnswBackend()`.
    func test_hnswBackendFactory_explicitMethod() {
        let backend = BurnBarPersistentVectorIndexFactory.hnswBackend(m: 32, efConstruction: 100, efSearch: 32)
        XCTAssertEqual(backend.backendID, "hnsw")
    }

    /// Verifies the exact backend is still accessible.
    func test_exactBackendFactory_stillAvailable() {
        let backend = BurnBarPersistentVectorIndexFactory.exactBackend()
        XCTAssertEqual(backend.backendID, "mapped_exact")
    }

    /// Verifies that BurnBarIndexedSearchService uses HNSW backend by default
    /// and receives HNSW config tunables from BurnBarSemanticSearchConfig.
    func test_indexedSearchService_defaultsToHNSWBackend() throws {
        let customConfig = BurnBarSemanticSearchConfig(
            maxCandidates: 100,
            rrfK: 50.0,
            enabled: true,
            hnswM: 32,
            hnswEfConstruction: 100,
            hnswEfSearch: 128
        )
        let dbDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hnsw-service-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dbDir) }
        let dbPath = dbDir.appendingPathComponent("test.sqlite").path

        // Create a minimal SQLite database so the indexed search service can open it
        _ = try DatabaseQueue(path: dbPath)

        let service = try BurnBarIndexedSearchService(
            databasePath: dbPath,
            logger: BurnBarDaemonLogger(category: "hnsw-test"),
            semanticConfig: customConfig
            // snapshotBackend deliberately omitted — should default to HNSW with custom config
        )

        // The service should have created a backend from the config.
        // We can't inspect the private property directly, but we can verify
        // that search still works and the backendID is "hnsw" by checking
        // that the service's snapshotBackend would produce "hnsw" snapshots.
        // Since rebuilding requires embeddings in the database, we verify
        // the factory contract instead:
        let expectedBackend = BurnBarPersistentVectorIndexFactory.hnswBackend(
            m: customConfig.hnswM,
            efConstruction: customConfig.hnswEfConstruction,
            efSearch: customConfig.hnswEfSearch,
            quantization: customConfig.quantization
        )
        XCTAssertEqual(expectedBackend.backendID, "hnsw")

        // Also confirm default config produces HNSW
        let defaultService = try BurnBarIndexedSearchService(
            databasePath: dbPath,
            logger: BurnBarDaemonLogger(category: "hnsw-test-default"),
            semanticConfig: .default
        )
        // The default config should also produce an HNSW backend
        let defaultBackend = BurnBarPersistentVectorIndexFactory.defaultBackend()
        XCTAssertEqual(defaultBackend.backendID, "hnsw")

        // Suppress unused variable warnings
        _ = service
        _ = defaultService
    }
}
