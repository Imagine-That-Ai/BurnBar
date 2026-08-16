import BurnBarCore
@testable import BurnBarDaemon
import Foundation
import XCTest

/// M6 direct-builder gates. These tests deliberately do not use the RPC
/// surface for their primary metric: the internal timing hook surrounds the
/// builder itself.
final class BurnBarFleetBuildPerfTests: M6FleetHardeningTestCase {
    private let runCount = 40

    func testTimingStats_evenSampleMedianAveragesMiddleSamples() {
        let stats = M6TimingStats(values: [1, 2, 100, 101])

        XCTAssertEqual(stats.medianMilliseconds, 51)
    }

    func testDirectBuilder_fixedFixture_meetsBudget() async throws {
        let collector = M6TimingCollector()
        let builder = m6Fixture.makeDefaultBuilder(
            cadenceSeconds: BurnBarFleetCadencePolicy.defaultCadenceSeconds,
            timingHook: collector.hook()
        )

        _ = try await builder.build()
        collector.reset()
        for _ in 0..<runCount {
            _ = try await builder.build()
        }

        let stats = M6TimingStats(values: collector.values())
        XCTAssertGreaterThanOrEqual(stats.count, 30)
        assertBudget(stats)
        try writePerfEvidence(
            stats: stats,
            historyRows: nil,
            fixtureDescription: m6Fixture.description
        )
    }

    func testDirectBuilder_withFullFleetSQLiteHistory_meetsBudgetAndPrunes() async throws {
        let (store, databasePath) = try makeHistoryStore()
        defer { store.close() }

        let seedBuilder = m6Fixture.makeDefaultBuilder(cadenceSeconds: 15)
        let seed = try await seedBuilder.build()
        let oldTransitionAt = try seedHistory(store: store, seed: seed)
        let seededRows = try M6SQLiteInspection.rowCounts(databasePath: databasePath)
        XCTAssertEqual(seededRows.snapshots, BurnBarFleetPersistenceConstants.defaultSnapshotRetentionCount)
        XCTAssertGreaterThan(seededRows.events, 0)
        let seededEvents = try store.events(for: .claudeCode)
        XCTAssertFalse(
            seededEvents.contains {
                abs($0.at.timeIntervalSince(oldTransitionAt)) < 0.001
            },
            "the event seeded outside the 24-hour retention window must be absent"
        )

        let collector = M6TimingCollector()
        let builder = m6Fixture.makeDefaultBuilder(cadenceSeconds: 15, timingHook: collector.hook())
        _ = try await builder.build()
        collector.reset()
        for _ in 0..<runCount {
            _ = try await builder.build()
        }

        let stats = M6TimingStats(values: collector.values())
        XCTAssertGreaterThanOrEqual(stats.count, 30)
        assertBudget(stats)
        let finalRows = try M6SQLiteInspection.rowCounts(databasePath: databasePath)
        XCTAssertEqual(finalRows.snapshots, BurnBarFleetPersistenceConstants.defaultSnapshotRetentionCount)
        XCTAssertGreaterThan(finalRows.events, 0)
        try writePerfEvidence(
            stats: stats,
            historyRows: finalRows,
            fixtureDescription: m6Fixture.description
        )
    }

    private func makeHistoryStore() throws -> (BurnBarFleetStore, String) {
        let storeURL = tempRoots.appendingPathComponent("history", isDirectory: true)
        let databasePath = storeURL.appendingPathComponent("fleet.sqlite").path
        let store = BurnBarFleetStore(
            databasePath: databasePath,
            eventRetentionSeconds: BurnBarFleetPersistenceConstants.defaultEventRetentionSeconds,
            snapshotRetentionCount: BurnBarFleetPersistenceConstants.defaultSnapshotRetentionCount
        )
        _ = try store.open()
        return (store, databasePath)
    }

    private func seedHistory(
        store: BurnBarFleetStore,
        seed: BurnBarFleetSnapshot
    ) throws -> Date {
        let oldTransitionAt = Date().addingTimeInterval(
            -BurnBarFleetPersistenceConstants.defaultEventRetentionSeconds - 1
        )
        try store.persistSnapshotAndTransitions(
            seed.m6ReplacingGeneratedAt(oldTransitionAt),
            transitions: [makeTransition(at: oldTransitionAt)]
        )
        for index in 0..<260 {
            let historical = seed.m6ReplacingGeneratedAt(
                Date().addingTimeInterval(-Double(index))
            )
            try store.persistSnapshotAndTransitions(
                historical,
                transitions: [makeTransition(at: historical.generatedAt)]
            )
        }
        return oldTransitionAt
    }

    private func makeTransition(at date: Date) -> BurnBarFleetTransition {
        BurnBarFleetTransition(
            agentID: .claudeCode,
            fromStatus: .idle,
            toStatus: .running,
            fromConfidence: .logHeartbeat,
            toConfidence: .exactProcess,
            at: date
        )
    }

    private func assertBudget(_ stats: M6TimingStats, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThan(
            stats.medianMilliseconds,
            100,
            "direct-builder median \(stats.medianMilliseconds)ms must be <100ms",
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            stats.maxMilliseconds,
            200,
            "direct-builder max \(stats.maxMilliseconds)ms must be <=200ms",
            file: file,
            line: line
        )
    }

    private func writePerfEvidence(
        stats: M6TimingStats,
        historyRows: (snapshots: Int, events: Int)?,
        fixtureDescription: String
    ) throws {
        let history = historyRows.map {
            "fleet.sqlite_history_rows=\($0.snapshots)\nfleet.sqlite_event_rows=\($0.events)\n"
        } ?? "fleet.sqlite_history_rows=not-seeded\n"
        let retention = historyRows == nil
            ? ""
            : "pruned_event_seed=older_than_24h;old_event_query_matches=0\n"
        let output = """
        metric=direct-builder
        fixture=\(fixtureDescription)
        runs=\(stats.count)
        min_ms=\(String(format: "%.3f", stats.minMilliseconds))
        median_ms=\(String(format: "%.3f", stats.medianMilliseconds))
        p95_ms=\(String(format: "%.3f", stats.p95Milliseconds))
        max_ms=\(String(format: "%.3f", stats.maxMilliseconds))
        budget=median<100ms,max<=200ms
        \(history)\(retention)
        raw_distribution_ms=min,median,p95,max only; see XCTest hook samples for the full run
        samples_ms=\(stats.distributionLine)
        """
        let fileName = historyRows == nil ? "build-perf.txt" : "build-perf-with-history.txt"
        try M6EvidenceWriter.write(output, fileName: fileName)
        print(output)
    }
}
