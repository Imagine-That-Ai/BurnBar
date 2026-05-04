import XCTest
@testable import OpenBurnBar

// MARK: - LocalMetricsAggregatorTests

@MainActor
final class LocalMetricsAggregatorTests: XCTestCase {

    func test_compute_emptyHealthRecords_returnsEmptySnapshot() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let aggregator = LocalMetricsAggregator(dataStore: store)
        await aggregator.compute()
        let snapshot = await aggregator.currentSnapshot
        XCTAssertNotNil(snapshot)
        XCTAssertTrue(snapshot?.isEmpty ?? false)
    }

    func test_compute_windowExcludesOldRecords() async throws {
        let store = try makeDiscoveryInMemoryStore()

        // Old record (2 hours ago)
        let oldDetails = LexicalRetrievalHealthDetails(
            queryLength: 10, lexicalCandidateCount: 5, semanticCandidateCount: 0,
            resultCount: 5, indexStale: false, semanticFallbackUsed: false,
            totalQueryLatencyMs: 9999, lexicalQueryLatencyMs: 9999,
            semanticQueryLatencyMs: nil, rerankLatencyMs: nil,
            hydrationLatencyMs: nil, crossEncoderLatencyMs: nil
        )
        let oldJSON = String(data: try JSONEncoder().encode(oldDetails), encoding: .utf8)
        try store.upsertRetrievalHealth(
            RetrievalHealthRecord(
                subsystem: .lexical, status: .healthy,
                errorCode: nil, errorMessage: nil, detailsJSON: oldJSON,
                observedAt: Date().addingTimeInterval(-7200),
                updatedAt: Date().addingTimeInterval(-7200)
            )
        )

        // Recent record
        let newDetails = LexicalRetrievalHealthDetails(
            queryLength: 10, lexicalCandidateCount: 5, semanticCandidateCount: 0,
            resultCount: 5, indexStale: false, semanticFallbackUsed: false,
            totalQueryLatencyMs: 100, lexicalQueryLatencyMs: 100,
            semanticQueryLatencyMs: nil, rerankLatencyMs: nil,
            hydrationLatencyMs: nil, crossEncoderLatencyMs: nil
        )
        let newJSON = String(data: try JSONEncoder().encode(newDetails), encoding: .utf8)
        try store.upsertRetrievalHealth(
            RetrievalHealthRecord(
                subsystem: .lexical, status: .healthy,
                errorCode: nil, errorMessage: nil, detailsJSON: newJSON,
                observedAt: Date().addingTimeInterval(-60),
                updatedAt: Date().addingTimeInterval(-60)
            )
        )

        let aggregator = LocalMetricsAggregator(dataStore: store)
        await aggregator.compute(window: 3600) // 1 hour window
        let snapshot = await aggregator.currentSnapshot

        // The 9999 ms old record should be excluded
        XCTAssertEqual(snapshot?.searchP50Ms, 100.0)
    }
}
