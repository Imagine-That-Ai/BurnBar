// Quarantined tests extracted from: UsageAggregatorTests.swift
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
import GRDB
@testable import OpenBurnBar

final class UsageAggregatorTests: XCTestCase {

    // MARK: - Quarantined Tests

    func test_refreshAll_storesUsagesInDataStore() async throws {
        try XCTSkipIf(true, "Stale contract — UsageAggregator refresh now scans live provider directories on host machine; needs hermetic FS sandbox.")
        let dataStore = try makeTestDataStore()
        let mockParser = MockParser(provider: .factory)
        let testUsage = TokenUsage(
            provider: .factory,
            sessionId: "test-session",
            projectName: "TestProject",
            model: "test-model",
            inputTokens: 1000,
            outputTokens: 500,
            costUSD: 0.05,
            startTime: Date(),
            endTime: Date()
        )
        mockParser.parseResult = ParseResult(usages: [testUsage], conversations: [])

        let aggregator = makeTestAggregator(dataStore: dataStore, parserOverrides: [.factory: mockParser])
        await aggregator.refreshAll()

        let storedUsages = dataStore.usages
        XCTAssertEqual(storedUsages.count, 1)
        XCTAssertEqual(storedUsages.first?.sessionId, "test-session")
    }


    func test_refresh_providerWithNoParser_doesNothing() async throws {
        try XCTSkipIf(true, "Stale contract — UsageAggregator refresh now scans live provider directories on host machine; needs hermetic FS sandbox.")
        let dataStore = try makeTestDataStore()
        let aggregator = makeTestAggregator(dataStore: dataStore)

        await aggregator.refresh(provider: .claudeCode)
        XCTAssertEqual(aggregator.parserHealth[.claudeCode], nil)
    }


}
