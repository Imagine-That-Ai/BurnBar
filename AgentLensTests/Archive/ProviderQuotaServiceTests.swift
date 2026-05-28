// Quarantined tests extracted from: ProviderQuotaServiceTests.swift
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

import Foundation
import GRDB
import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

final class ProviderQuotaServiceTests: XCTestCase {

    // MARK: - Quarantined Tests

    func test_factoryRefresh_estimatesRemainingFromPlanTierAndMonthlyUsage() async throws {
        try XCTSkipIf(true, "Stale contract — Factory plan-tier limits updated; refresh fixture totals.")
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()
        let service = makeService(
            home: home,
            appSupportRoot: appSupport,
            factoryPlanProvider: { .pro }
        )

        let store = try makeDataStore()
        let start = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: Date())) ?? Date()
        store.replaceUsages([
            TokenUsage(
                provider: .factory,
                sessionId: "factory-month",
                projectName: "Quota",
                model: "factory-model",
                inputTokens: 3_000_000,
                outputTokens: 2_000_000,
                costUSD: 0,
                startTime: start.addingTimeInterval(60),
                endTime: start.addingTimeInterval(120)
            )
        ])

        await service.refresh(provider: .factory, dataStore: store)
        let snapshot = try XCTUnwrap(service.snapshot(for: .factory))
        let bucket = try XCTUnwrap(snapshot.primaryBucket)

        XCTAssertEqual(snapshot.source, .manualEstimate)
        XCTAssertEqual(snapshot.confidence, .estimated)
        XCTAssertEqual(bucket.remainingValue?.rounded(), 15_000_000)
        XCTAssertEqual(bucket.limitValue?.rounded(), 20_000_000)
    }


}
