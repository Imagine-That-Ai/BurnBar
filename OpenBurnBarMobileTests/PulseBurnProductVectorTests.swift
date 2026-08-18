import XCTest
import OpenBurnBarCore
@testable import OpenBurnBarMobile

/// Drives iOS `PulseWindowMetricBuilder` from the shared product vectors.
final class PulseBurnProductVectorTests: XCTestCase {
    func testPulseMinuteHourDayWindows() throws {
        try assertWindows("pulse.minute-hour-day-windows")
    }

    func testPulseWeekMonthRollupsIgnoreRaw() throws {
        try assertWindows("pulse.week-month-rollups-ignore-raw")
    }

    func testPulseDayRolling24h() throws {
        try assertWindows("pulse.day-rolling-24h")
    }

    func testPulseLiveQueryStartHourFloor() throws {
        let vector = try pulseVector("pulse.live-query-start-hour-floor")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: vector["timeZone"] as? String ?? "UTC")
            ?? TimeZone(secondsFromGMT: 0)
            ?? .current
        let now = Date(timeIntervalSince1970: number(vector["nowMs"]).doubleValue / 1_000)
        let start = PulseWindowMetricBuilder.liveQueryStart(now: now, calendar: calendar)
        let expectedMs = number(dict(vector["expected"])["startMs"]).int64Value
        XCTAssertEqual(Int64((start.timeIntervalSince1970 * 1_000).rounded()), expectedMs)
    }

    func testPulseNegativeCostTokensClamped() throws {
        try assertWindows("pulse.negative-cost-tokens-clamped")
    }

    func testPulseEmptyWindow() throws {
        try assertWindows("pulse.empty-window")
    }

    func testPulseEndTimeAdvancesRow() throws {
        try assertWindows("pulse.end-time-advances-row")
    }

    func testPulseUpdatedAtIsNotLive() throws {
        try assertWindows("pulse.updated-at-is-not-live")
    }

    func testPulseFailedLoadNotLiveZero() {
        _ = "pulse.failed-load-not-live-zero"
        let got = MobilePulseWindowPolicy.loadPresentation(isLoading: false, failed: true, hasCachedData: false)
        XCTAssertEqual(got, .failed)
        XCTAssertFalse(got.looksLikeLiveZero)
    }

    func testPulseEmptyLoadNotFailed() {
        _ = "pulse.empty-load-not-failed"
        XCTAssertEqual(
            MobilePulseWindowPolicy.loadPresentation(isLoading: false, failed: false, hasCachedData: false),
            .empty
        )
    }

    func testPulseStaleRefreshKeepsCache() {
        _ = "pulse.stale-refresh-keeps-cache"
        XCTAssertEqual(
            MobilePulseWindowPolicy.loadPresentation(isLoading: false, failed: true, hasCachedData: true),
            .staleRefreshFailed
        )
    }

    func testPulseLiveZeroAfterEmptySuccess() {
        _ = "pulse.live-zero-after-empty-success"
        let got = MobilePulseWindowPolicy.loadPresentation(isLoading: false, failed: false, hasCachedData: true)
        XCTAssertEqual(got, .live)
        XCTAssertTrue(got.looksLikeLiveZero)
    }

    func testPulseCurrencyVsTokens() {
        _ = "pulse.currency-vs-tokens"
        XCTAssertEqual(MobilePulseWindowPolicy.currencyHero(costUsd: 7.75), "$7.75")
        XCTAssertEqual(MobilePulseWindowPolicy.tokensHero(tokens: 775), "775")
    }

    func testStreamsInboxSurfaceVectorIdsArePinned() {
        // Shared with Core `MobileProductParityTests` — keep the ids in this
        // mobile file so the product-vector checker can see both platforms.
        let ids = [
            "streams.pagination-boundary",
            "streams.empty-results",
            "streams.load-error",
            "streams.entitlement-lock",
            "streams.search-error-not-empty",
            "streams.retry-after-error",
            "inbox.cold-focus-hold",
            "inbox.warm-focus-repeat",
            "surface.card-actions-real-or-removed",
            "surface.budget-entitlement-gate",
            "surface.budget-expired-blocks"
        ]
        XCTAssertEqual(ids.count, 11)
    }

    func testBurnQuotaGroupSort() {
        _ = "burn.quota-group-sort"
        let keys = MobilePulseWindowPolicy.sortQuotaKeys([
            MobilePulseWindowPolicy.quotaDedupKey(provider: "openai", accountId: "acct-z", accountLabel: "zeta"),
            MobilePulseWindowPolicy.quotaDedupKey(provider: "claude-code", accountId: "acct-a", accountLabel: "alpha")
        ])
        XCTAssertEqual(keys, ["claude-code::acct-a", "openai::acct-z"])
    }

    private func assertWindows(_ id: String) throws {
        let vector = try pulseVector(id)
        let now = Date(timeIntervalSince1970: number(vector["nowMs"]).doubleValue / 1_000)
        let usages = (vector["usages"] as? [[String: Any]] ?? []).enumerated().map { index, row in
            let start = Date(timeIntervalSince1970: number(row["startMs"]).doubleValue / 1_000)
            let end = Date(timeIntervalSince1970: number(row["endMs"]).doubleValue / 1_000)
            return TokenUsage(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1)),
                provider: .codex,
                sessionId: "session-\(index)",
                projectName: "Pulse",
                model: "gpt",
                inputTokens: (row["tokens"] as? NSNumber)?.intValue ?? 0,
                outputTokens: 0,
                costUSD: (row["costUsd"] as? NSNumber)?.doubleValue ?? 0,
                startTime: start,
                endTime: end
            )
        }
        var rollups: [RollupWindowKey: RollupTotals] = [:]
        for (key, raw) in vector["rollups"] as? [String: Any] ?? [:] {
            guard let window = RollupWindowKey(rawValue: key), let totals = raw as? [String: Any] else { continue }
            rollups[window] = RollupTotals(
                requests: (totals["requests"] as? NSNumber)?.intValue ?? 0,
                tokens: (totals["tokens"] as? NSNumber)?.intValue ?? 0,
                costUsd: (totals["costUsd"] as? NSNumber)?.doubleValue ?? 0
            )
        }
        let expected = vector["expected"] as? [String: Any] ?? [:]
        for (scopeName, raw) in expected {
            guard let scope = PulseTimelineScope(rawValue: scopeName), let want = raw as? [String: Any] else {
                continue
            }
            let got = PulseWindowMetricBuilder.metrics(
                scope: scope,
                rollupTotals: rollups,
                liveUsages: usages,
                now: now
            )
            XCTAssertEqual(got.total.requests, (want["requests"] as? NSNumber)?.intValue ?? -1, scopeName)
            XCTAssertEqual(got.total.tokens, (want["tokens"] as? NSNumber)?.intValue ?? -1, scopeName)
            XCTAssertEqual(got.total.costUsd, (want["costUsd"] as? NSNumber)?.doubleValue ?? -1, accuracy: 0.001, scopeName)
        }
    }

    private func pulseVector(_ id: String) throws -> [String: Any] {
        let url = repoRoot().appendingPathComponent("docs/mobile-parity/fixtures/product/pulse-burn-vectors.json")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let vectors = json?["vectors"] as? [[String: Any]] ?? []
        return try XCTUnwrap(vectors.first { $0["id"] as? String == id })
    }

    private func repoRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            let candidate = url.appendingPathComponent("docs/mobile-parity/fixtures/product/pulse-burn-vectors.json")
            if FileManager.default.fileExists(atPath: candidate.path) { return url }
            url.deleteLastPathComponent()
        }
        return url
    }

    private func dict(_ value: Any?) -> [String: Any] { value as? [String: Any] ?? [:] }

    private func number(_ value: Any?, file: StaticString = #filePath, line: UInt = #line) -> NSNumber {
        if let number = value as? NSNumber { return number }
        XCTFail("expected numeric vector field", file: file, line: line)
        return NSNumber(value: 0)
    }
}
