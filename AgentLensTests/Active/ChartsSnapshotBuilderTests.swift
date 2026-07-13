import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

/// Deterministic fixture shared by the snapshot-builder and insight-parsing
/// suites: two providers, two sessions, cache + reasoning traffic, one remote
/// row, spread across the last three days. All timestamps are strictly in the
/// past regardless of the wall clock at test time (a 9am-today fixture is in
/// the future when CI runs at 3am).
enum ChartsSnapshotFixtures {
    static func sampleRows(now: Date = Date()) -> [TokenUsage] {
        func hoursAgo(_ hours: Double) -> Date {
            now.addingTimeInterval(-hours * 3_600)
        }
        return [
            TokenUsage(
                provider: .claudeCode, sessionId: "session-A", projectName: "SecretProject",
                model: "claude-opus-4-8", inputTokens: 1_000, outputTokens: 500,
                cacheCreationTokens: 200, cacheReadTokens: 800, reasoningTokens: 300,
                costUSD: 12.0, startTime: hoursAgo(1), endTime: hoursAgo(0.5),
                provenanceConfidence: .exact
            ),
            TokenUsage(
                provider: .claudeCode, sessionId: "session-A", projectName: "SecretProject",
                model: "claude-sonnet-4-6", inputTokens: 400, outputTokens: 200,
                costUSD: 3.0, startTime: hoursAgo(26), endTime: hoursAgo(25),
                provenanceConfidence: .exact
            ),
            TokenUsage(
                provider: .cursor, sessionId: "session-B", projectName: "",
                model: "gpt-5.6-sol", inputTokens: 2_000, outputTokens: 900,
                costUSD: 5.0, startTime: hoursAgo(50), endTime: hoursAgo(49),
                isRemote: true, provenanceConfidence: .lowConfidenceEstimate
            )
        ]
    }
}

final class ChartsSnapshotBuilderTests: XCTestCase {

    private func makeSnapshot(rows: [TokenUsage]? = nil, timeRange: TimeRange = .last7Days) -> ChartsSnapshot {
        let fixture = rows ?? ChartsSnapshotFixtures.sampleRows()
        return ChartsSnapshot.build(
            rows: fixture, recentRows: fixture, timeRange: timeRange, usagesVersion: 7
        )
    }

    // MARK: Identity & totals

    func test_build_totalsAndIdentity() {
        let snapshot = makeSnapshot()
        XCTAssertEqual(snapshot.usagesVersion, 7)
        XCTAssertEqual(snapshot.timeRange, .last7Days)
        XCTAssertFalse(snapshot.isEmpty)
        XCTAssertEqual(snapshot.totalCost, 20.0, accuracy: 1e-9)
        XCTAssertEqual(snapshot.sessionCount, 2)
    }

    func test_build_emptyRows_flagsEmpty() {
        let snapshot = makeSnapshot(rows: [])
        XCTAssertTrue(snapshot.isEmpty)
        XCTAssertEqual(snapshot.totalCost, 0)
        XCTAssertNil(snapshot.medianSessionCost)
        XCTAssertTrue(snapshot.outlierSessions.isEmpty)
    }

    // MARK: Mixes

    func test_build_providerAndModelMixesRankByCost() {
        let snapshot = makeSnapshot()
        XCTAssertEqual(snapshot.providerShares.first?.provider, .claudeCode)
        XCTAssertEqual(snapshot.providerShares.first?.cost ?? 0, 15.0, accuracy: 1e-9)
        XCTAssertEqual(snapshot.modelCosts.first?.label, "claude-opus-4-8")
    }

    // MARK: Cache & reasoning

    func test_build_cacheMetrics() {
        let snapshot = makeSnapshot()
        XCTAssertEqual(snapshot.cacheReadTokens, 800)
        // Prompt basis = inputs (1000+400+2000) + cacheCreation (200) + cacheRead (800).
        XCTAssertEqual(snapshot.cacheHitRate, 800.0 / 4_400.0, accuracy: 1e-9)
        XCTAssertGreaterThan(snapshot.cacheSavingsEstimate, 0)
    }

    func test_build_reasoningShare() {
        let snapshot = makeSnapshot()
        XCTAssertGreaterThan(snapshot.reasoningShare, 0)
        XCTAssertLessThan(snapshot.reasoningShare, 1)
    }

    // MARK: Sessions

    func test_build_sessionOutliers_rankedByCost() {
        let snapshot = makeSnapshot()
        XCTAssertEqual(snapshot.outlierSessions.first?.sessionId, "session-A")
        XCTAssertEqual(snapshot.outlierSessions.first?.cost ?? 0, 15.0, accuracy: 1e-9)
        XCTAssertEqual(snapshot.outlierSessions.count, 2)
    }

    func test_build_medianSessionCost() {
        let snapshot = makeSnapshot()
        // Session costs: A = 15, B = 5 → median 10.
        XCTAssertEqual(snapshot.medianSessionCost ?? 0, 10.0, accuracy: 1e-9)
    }

    // MARK: Projects

    func test_build_projectFocus_labelsUnassignedAndComputesEntropy() {
        let snapshot = makeSnapshot()
        let names = snapshot.projectSeries.map(\.projectName)
        XCTAssertTrue(names.contains("SecretProject"))
        XCTAssertTrue(names.contains("Unassigned"))
        XCTAssertGreaterThan(snapshot.projectEntropy, 0)
    }

    // MARK: Provenance / remote

    func test_build_provenanceShares() {
        let snapshot = makeSnapshot()
        XCTAssertEqual(snapshot.exactShare, 15.0 / 20.0, accuracy: 1e-9)
        XCTAssertEqual(snapshot.provenanceShares.first?.label, "Exact")
    }

    func test_build_remoteVsLocalSplit() {
        let snapshot = makeSnapshot()
        XCTAssertEqual(snapshot.remoteCost, 5.0, accuracy: 1e-9)
        XCTAssertEqual(snapshot.localCost, 15.0, accuracy: 1e-9)
    }

    // MARK: Series shape

    func test_build_burnSeries_coversSevenDays() {
        let snapshot = makeSnapshot()
        XCTAssertGreaterThanOrEqual(snapshot.burnSeries.count, 7)
        XCTAssertEqual(
            snapshot.burnSeries.reduce(0) { $0 + $1.value }, 20.0, accuracy: 1e-9
        )
    }

    func test_build_todayRange_usesHourlyBuckets() {
        let now = Date()
        let calendar = Calendar.current
        // Start of day is always in the past no matter when the test runs.
        let morning = calendar.startOfDay(for: now)
        let row = TokenUsage(
            provider: .claudeCode, sessionId: "s", projectName: "p",
            model: "m", inputTokens: 10, outputTokens: 10,
            costUSD: 1.0, startTime: morning, endTime: morning
        )
        let snapshot = ChartsSnapshot.build(
            rows: [row], recentRows: [row], timeRange: .today, usagesVersion: 0, now: now
        )
        // Hourly bucketing across today: more granular than a single bucket.
        XCTAssertGreaterThan(snapshot.burnSeries.count, 1)
        XCTAssertEqual(snapshot.burnSeries.reduce(0) { $0 + $1.value }, 1.0, accuracy: 1e-9)
    }

    // MARK: Forecast

    func test_build_forecast_projectsMonthEndAtOrAboveMonthToDate() throws {
        let snapshot = makeSnapshot()
        let forecast = try XCTUnwrap(snapshot.forecast)
        XCTAssertEqual(forecast.dailyCosts.count, 14)
        let monthToDateFloor = 0.0
        XCTAssertGreaterThanOrEqual(forecast.projectedMonthEndSpend, monthToDateFloor)
    }

    func test_build_forecast_nilWhenNoRecentSpend() {
        let snapshot = ChartsSnapshot.build(
            rows: ChartsSnapshotFixtures.sampleRows(), recentRows: [], timeRange: .last7Days, usagesVersion: 0
        )
        XCTAssertNil(snapshot.forecast)
    }
}
