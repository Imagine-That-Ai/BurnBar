// Quarantined tests extracted from: LocalMetricsAggregatorTests.swift
//
// These tests were quarantined because they reference stale contracts,
// drifted schemas, or environmental preconditions not satisfied in CI.
// See QUARANTINE_MANIFEST.md for per-test owner, reason, and revival criteria.
//
// Revival workflow:
//   1. Update tests to compile against current public/@testable APIs.
//   2. Move this file to AgentLensTests/Active/ (matching subdirectory).
//   3. Remove the file from Quarantine.
//   4. Prove with: ./scripts/test-openburnbar-app.sh

import XCTest
@testable import OpenBurnBar

final class LocalMetricsAggregatorTests: XCTestCase {

    // MARK: - Quarantined Tests

    func test_compute_searchLatencies_computesPercentiles() async throws {
        // Skipped: the `retrieval_health` schema dedupes on `subsystem`, so
        // inserting 5 records with the same subsystem keeps only the last.
        // The aggregator currently surfaces percentiles across whatever rows
        // survive in `retrieval_health` (one per subsystem) — re-enable once
        // a dedicated `retrieval_health_history` table or mock store can hold
        // multiple latency observations per subsystem.
        try XCTSkipIf(true, "Stale contract — schema dedupes on subsystem.")
        let store = try makeDiscoveryInMemoryStore()

        // Insert 5 lexical health records with known latencies
        let latencies = [10.0, 20.0, 30.0, 40.0, 50.0]
        for (i, latency) in latencies.enumerated() {
            let details = LexicalRetrievalHealthDetails(
                queryLength: 10,
                lexicalCandidateCount: 5,
                semanticCandidateCount: 0,
                resultCount: 5,
                indexStale: false,
                semanticFallbackUsed: false,
                totalQueryLatencyMs: latency,
                lexicalQueryLatencyMs: latency,
                semanticQueryLatencyMs: nil,
                rerankLatencyMs: nil,
                hydrationLatencyMs: nil,
                crossEncoderLatencyMs: nil
            )
            let detailsJSON = String(data: try JSONEncoder().encode(details), encoding: .utf8)
            try store.upsertRetrievalHealth(
                RetrievalHealthRecord(
                    subsystem: .lexical,
                    status: .healthy,
                    errorCode: nil,
                    errorMessage: nil,
                    detailsJSON: detailsJSON,
                    observedAt: Date().addingTimeInterval(-Double(i) * 60),
                    updatedAt: Date().addingTimeInterval(-Double(i) * 60)
                )
            )
        }

        let aggregator = LocalMetricsAggregator(dataStore: store)
        await aggregator.compute()
        let snapshot = await aggregator.currentSnapshot

        XCTAssertEqual(snapshot?.searchP50Ms, 30.0)   // median of 10,20,30,40,50
        XCTAssertEqual(snapshot?.searchP95Ms, 48.0)   // 0.95 * 4 = 3.8 -> 40*0.2 + 50*0.8
        XCTAssertEqual(snapshot?.lexicalP50Ms, 30.0)
    }

    func test_compute_rerankSuccessRate() async throws {
        try XCTSkipIf(true, "Stale contract — schema dedupes on subsystem; only the last insert is observable.")
        let store = try makeDiscoveryInMemoryStore()

        // 3 successful reranks, 1 failed
        for i in 0..<4 {
            let details = LexicalRetrievalHealthDetails(
                queryLength: 10,
                lexicalCandidateCount: 5,
                semanticCandidateCount: 0,
                resultCount: 5,
                indexStale: false,
                semanticFallbackUsed: false,
                totalQueryLatencyMs: 100,
                lexicalQueryLatencyMs: 50,
                semanticQueryLatencyMs: nil,
                rerankLatencyMs: 20,
                hydrationLatencyMs: 10,
                crossEncoderLatencyMs: 25
            )
            let detailsJSON = String(data: try JSONEncoder().encode(details), encoding: .utf8)
            try store.upsertRetrievalHealth(
                RetrievalHealthRecord(
                    subsystem: .lexical,
                    status: i == 3 ? .failed : .healthy,
                    errorCode: i == 3 ? "RERANK_FAILED" : nil,
                    errorMessage: nil,
                    detailsJSON: detailsJSON,
                    observedAt: Date().addingTimeInterval(-Double(i) * 60),
                    updatedAt: Date().addingTimeInterval(-Double(i) * 60)
                )
            )
        }

        let aggregator = LocalMetricsAggregator(dataStore: store)
        await aggregator.compute()
        let snapshot = await aggregator.currentSnapshot

        XCTAssertEqual(snapshot?.rerankSuccessRate, 0.75)
    }

    func test_compute_semanticFallbackRate() async throws {
        try XCTSkipIf(true, "Stale contract — schema dedupes on subsystem; only the last insert is observable.")
        let store = try makeDiscoveryInMemoryStore()

        // 2 with semantic fallback, 3 without
        for i in 0..<5 {
            let details = LexicalRetrievalHealthDetails(
                queryLength: 10,
                lexicalCandidateCount: 5,
                semanticCandidateCount: 0,
                resultCount: 5,
                indexStale: false,
                semanticFallbackUsed: i < 2,
                totalQueryLatencyMs: 100,
                lexicalQueryLatencyMs: 50,
                semanticQueryLatencyMs: nil,
                rerankLatencyMs: nil,
                hydrationLatencyMs: nil,
                crossEncoderLatencyMs: nil
            )
            let detailsJSON = String(data: try JSONEncoder().encode(details), encoding: .utf8)
            try store.upsertRetrievalHealth(
                RetrievalHealthRecord(
                    subsystem: .lexical,
                    status: .healthy,
                    errorCode: nil,
                    errorMessage: nil,
                    detailsJSON: detailsJSON,
                    observedAt: Date().addingTimeInterval(-Double(i) * 60),
                    updatedAt: Date().addingTimeInterval(-Double(i) * 60)
                )
            )
        }

        let aggregator = LocalMetricsAggregator(dataStore: store)
        await aggregator.compute()
        let snapshot = await aggregator.currentSnapshot

        XCTAssertEqual(snapshot?.semanticFallbackRate, 0.4)
    }


}
