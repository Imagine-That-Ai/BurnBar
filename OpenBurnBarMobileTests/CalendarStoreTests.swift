import XCTest
import OpenBurnBarCore
@testable import OpenBurnBarMobile

/// Unit tests for the Calendar store's pure aggregation builders
/// (`CalendarMonthSnapshot`, `CalendarSelectionSnapshot`) and the store's
/// apply/refreshSelection plumbing, driven by fixture `TokenUsage` events —
/// no Firestore involved.
@MainActor
final class CalendarStoreTests: XCTestCase {

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        cal.firstWeekday = 1
        return cal
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min)) ?? .distantPast
    }

    private func row(
        provider: AgentProvider = .claudeCode,
        sessionId: String = "s1",
        projectName: String = "OpenBurnBar",
        model: String = "claude-opus-4",
        inputTokens: Int = 100,
        outputTokens: Int = 40,
        cacheCreationTokens: Int = 0,
        cacheReadTokens: Int = 0,
        reasoningTokens: Int = 0,
        cost: Double,
        start: Date,
        end: Date? = nil
    ) -> TokenUsage {
        TokenUsage(
            provider: provider,
            sessionId: sessionId,
            projectName: projectName,
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens,
            reasoningTokens: reasoningTokens,
            costUSD: cost,
            startTime: start,
            endTime: end ?? start.addingTimeInterval(60)
        )
    }

    private func mayGrid() -> CalendarMonthGridModel {
        CalendarMonthGridModel.make(for: date(2026, 5, 15), calendar: calendar)
    }

    // MARK: Month snapshot — day costs & peak

    func test_monthSnapshot_sumsCostPerLocalDay_andTracksPeak() {
        let rows = [
            row(cost: 2, start: date(2026, 5, 1, 10)),
            row(cost: 3, start: date(2026, 5, 1, 18)),
            row(cost: 9, start: date(2026, 5, 2, 9)),
            row(cost: 1, start: date(2026, 5, 20, 12))
        ]
        let snapshot = CalendarMonthSnapshot.build(rows: rows, model: mayGrid(), calendar: calendar)
        XCTAssertEqual(snapshot.dayCosts[date(2026, 5, 1)] ?? -1, 5, accuracy: 0.0001)
        XCTAssertEqual(snapshot.dayCosts[date(2026, 5, 2)] ?? -1, 9, accuracy: 0.0001)
        XCTAssertEqual(snapshot.peakDayCost, 9, accuracy: 0.0001)
        XCTAssertEqual(snapshot.monthTotalCost, 15, accuracy: 0.0001)
    }

    func test_monthSnapshot_attributesCrossMidnightSessionToStartDay() {
        let rows = [
            row(cost: 4, start: date(2026, 5, 1, 23, 30), end: date(2026, 5, 2, 0, 30))
        ]
        let snapshot = CalendarMonthSnapshot.build(rows: rows, model: mayGrid(), calendar: calendar)
        XCTAssertEqual(snapshot.dayCosts[date(2026, 5, 1)] ?? -1, 4, accuracy: 0.0001)
        XCTAssertNil(snapshot.dayCosts[date(2026, 5, 2)])
    }

    func test_monthSnapshot_bucketsByLocalTimezone_notUTC() {
        // 2026-05-02 02:30 UTC is 2026-05-01 22:30 in America/New_York (EDT).
        // The same instant must land on different days depending on the
        // calendar's timezone — the grid follows the user's local day.
        let utcInstant = Date(timeIntervalSince1970: 1_777_689_000) // 2026-05-02T02:30:00Z
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!

        let rows = [row(cost: 6, start: utcInstant)]
        let local = CalendarMonthSnapshot.build(rows: rows, model: mayGrid(), calendar: calendar)
        XCTAssertEqual(local.dayCosts[date(2026, 5, 1)] ?? -1, 6, accuracy: 0.0001)
        XCTAssertNil(local.dayCosts[date(2026, 5, 2)])

        let utcMay2 = utcCalendar.date(from: DateComponents(year: 2026, month: 5, day: 2))!
        let utc = CalendarMonthSnapshot.build(rows: rows, model: mayGrid(), calendar: utcCalendar)
        XCTAssertEqual(utc.dayCosts[utcMay2] ?? -1, 6, accuracy: 0.0001)
    }

    func test_monthSnapshot_excludesRowsOutsideGrid_butKeepsOverflowCellsOutOfMonthTotal() {
        // The May grid displays Apr 26…Jun 6; a row on Apr 27 is in the grid
        // (heatmap + dots) but not in the calendar-month total, and a row past
        // the grid is dropped entirely.
        let rows = [
            row(cost: 7, start: date(2026, 4, 27, 12)),
            row(cost: 5, start: date(2026, 5, 15, 12)),
            row(cost: 100, start: date(2026, 6, 20, 12))
        ]
        let snapshot = CalendarMonthSnapshot.build(rows: rows, model: mayGrid(), calendar: calendar)
        XCTAssertEqual(snapshot.dayCosts[date(2026, 4, 27)] ?? -1, 7, accuracy: 0.0001)
        XCTAssertNil(snapshot.dayCosts[date(2026, 6, 20)])
        XCTAssertEqual(snapshot.monthTotalCost, 5, accuracy: 0.0001)
        XCTAssertEqual(snapshot.peakDayCost, 7, accuracy: 0.0001)
    }

    // MARK: Month snapshot — provider dots

    func test_monthSnapshot_ranksTopThreeProvidersPerDay() {
        let rows = [
            row(provider: .claudeCode, cost: 5, start: date(2026, 5, 3, 10)),
            row(provider: .codex, cost: 3, start: date(2026, 5, 3, 11)),
            row(provider: .geminiCLI, cost: 2, start: date(2026, 5, 3, 12)),
            row(provider: .kimi, cost: 1, start: date(2026, 5, 3, 13))
        ]
        let snapshot = CalendarMonthSnapshot.build(rows: rows, model: mayGrid(), calendar: calendar)
        XCTAssertEqual(
            snapshot.dayProviders[date(2026, 5, 3)],
            [.claudeCode, .codex, .geminiCLI]
        )
    }

    func test_monthSnapshot_providerTie_breaksByRawValue() {
        let rows = [
            row(provider: .codex, cost: 2, start: date(2026, 5, 3, 10)),
            row(provider: .claudeCode, cost: 2, start: date(2026, 5, 3, 11))
        ]
        let snapshot = CalendarMonthSnapshot.build(rows: rows, model: mayGrid(), calendar: calendar)
        // "Claude Code" < "Codex" lexicographically.
        XCTAssertEqual(snapshot.dayProviders[date(2026, 5, 3)], [.claudeCode, .codex])
    }

    // MARK: Selection snapshot — KPIs

    func test_selectionSnapshot_aggregatesAcrossMultipleDays() {
        let rows = [
            row(sessionId: "s1", cost: 2, start: date(2026, 5, 1, 9)),
            row(sessionId: "s1", cost: 3, start: date(2026, 5, 1, 10)),
            row(sessionId: "s2", cost: 5, start: date(2026, 5, 2, 9)),
            row(sessionId: "s3", cost: 1, start: date(2026, 5, 4, 9)),
            row(sessionId: "s9", cost: 50, start: date(2026, 5, 10, 9))
        ]
        let selection: Set<Date> = [
            date(2026, 5, 1), date(2026, 5, 2), date(2026, 5, 3), date(2026, 5, 4)
        ]
        let snapshot = CalendarSelectionSnapshot.build(rows: rows, selectedDays: selection, calendar: calendar)
        XCTAssertFalse(snapshot.isEmpty)
        XCTAssertEqual(snapshot.totalCost, 11, accuracy: 0.0001)
        // May 10 was not selected — its 50 is nowhere in the snapshot.
        XCTAssertEqual(snapshot.sessionCount, 3)
        XCTAssertEqual(snapshot.activeDays, 3)
        XCTAssertEqual(snapshot.averageCostPerDay, 2.75, accuracy: 0.0001)
        XCTAssertEqual(snapshot.selectedDays, [
            date(2026, 5, 1), date(2026, 5, 2), date(2026, 5, 3), date(2026, 5, 4)
        ])
        // Tokens: every fixture row is 100 input + 40 output = 140.
        XCTAssertEqual(snapshot.totalTokens, 4 * 140)
    }

    func test_selectionSnapshot_emptyWhenNoRowsOnSelectedDays() {
        let rows = [row(cost: 5, start: date(2026, 5, 1, 9))]
        let snapshot = CalendarSelectionSnapshot.build(
            rows: rows,
            selectedDays: [date(2026, 5, 8)],
            calendar: calendar
        )
        XCTAssertTrue(snapshot.isEmpty)
        XCTAssertEqual(snapshot.totalCost, 0, accuracy: 0.0001)
        XCTAssertEqual(snapshot.sessionCount, 0)
        XCTAssertEqual(snapshot.activeDays, 0)
        XCTAssertEqual(snapshot.dailyBurn.count, 1)
        XCTAssertEqual(snapshot.dailyBurn.first?.cost ?? -1, 0, accuracy: 0.0001)
    }

    // MARK: Selection snapshot — daily burn gap fill

    func test_dailyBurn_gapFillsSilentDaysAcrossSpan() {
        let rows = [
            row(cost: 2, start: date(2026, 5, 1, 9)),
            row(cost: 4, start: date(2026, 5, 4, 9))
        ]
        let selection: Set<Date> = [date(2026, 5, 1), date(2026, 5, 4)]
        let snapshot = CalendarSelectionSnapshot.build(rows: rows, selectedDays: selection, calendar: calendar)
        // The span May 1…4 is gap-filled even though May 2/3 aren't selected
        // and carry no usage — they draw as zero bars.
        XCTAssertEqual(snapshot.dailyBurn.map(\.day), [
            date(2026, 5, 1), date(2026, 5, 2), date(2026, 5, 3), date(2026, 5, 4)
        ])
        XCTAssertEqual(snapshot.dailyBurn.map(\.cost), [2, 0, 0, 4])
    }

    func test_dailyBurn_singleSelectedDay_isSingleBucket() {
        let rows = [row(cost: 3, start: date(2026, 5, 2, 9))]
        let snapshot = CalendarSelectionSnapshot.build(
            rows: rows,
            selectedDays: [date(2026, 5, 2, 18, 45)],
            calendar: calendar
        )
        XCTAssertEqual(snapshot.dailyBurn.count, 1)
        XCTAssertEqual(snapshot.dailyBurn.first?.day, date(2026, 5, 2))
    }

    // MARK: Selection snapshot — provider / model / project mixes

    func test_providerShares_rankedByCostWithTieBreak() {
        let rows = [
            row(provider: .codex, cost: 2, start: date(2026, 5, 1, 9)),
            row(provider: .claudeCode, cost: 5, start: date(2026, 5, 1, 10)),
            row(provider: .geminiCLI, cost: 2, start: date(2026, 5, 1, 11))
        ]
        let snapshot = CalendarSelectionSnapshot.build(
            rows: rows, selectedDays: [date(2026, 5, 1)], calendar: calendar
        )
        XCTAssertEqual(snapshot.providerShares.map(\.provider), [.claudeCode, .codex, .geminiCLI])
        XCTAssertEqual(snapshot.providerShares.map(\.cost), [5, 2, 2])
    }

    func test_topModels_groupedByModelWithDominantProvider() {
        let rows = [
            row(provider: .claudeCode, model: "claude-opus-4", cost: 4, start: date(2026, 5, 1, 9)),
            row(provider: .claudeCode, model: "claude-opus-4", cost: 2, start: date(2026, 5, 1, 10)),
            row(provider: .openCode, model: "claude-opus-4", cost: 1, start: date(2026, 5, 1, 11)),
            row(provider: .codex, model: "gpt-5.4-codex", cost: 3, start: date(2026, 5, 1, 12))
        ]
        let snapshot = CalendarSelectionSnapshot.build(
            rows: rows, selectedDays: [date(2026, 5, 1)], calendar: calendar
        )
        XCTAssertEqual(snapshot.topModels.map(\.model), ["claude-opus-4", "gpt-5.4-codex"])
        XCTAssertEqual(snapshot.topModels.map(\.cost), [7, 3])
        // The dominant provider for the model (6 of 7 dollars) drives the logo.
        XCTAssertEqual(snapshot.topModels.first?.provider, .claudeCode)
        // Display name runs through FriendlyModelName (no raw wire id).
        XCTAssertEqual(snapshot.topModels.first?.displayName, "Claude Opus 4")
    }

    func test_topModels_capsAtSix() {
        let rows = (0..<8).map { index in
            row(model: "model-\(index)", cost: Double(8 - index), start: date(2026, 5, 1, 9))
        }
        let snapshot = CalendarSelectionSnapshot.build(
            rows: rows, selectedDays: [date(2026, 5, 1)], calendar: calendar
        )
        XCTAssertEqual(snapshot.topModels.count, 6)
        XCTAssertEqual(snapshot.topModels.first?.model, "model-0")
    }

    func test_projectShares_topFiveAndBucketsUnnamedAsUnattributed() {
        let rows = [
            row(projectName: "BurnBar", cost: 5, start: date(2026, 5, 1, 9)),
            row(projectName: "Website", cost: 3, start: date(2026, 5, 1, 10)),
            row(projectName: "", cost: 100, start: date(2026, 5, 1, 11))
        ]
        let snapshot = CalendarSelectionSnapshot.build(
            rows: rows, selectedDays: [date(2026, 5, 1)], calendar: calendar
        )
        // Unnamed spend surfaces as "Unattributed" rather than vanishing from
        // the card — it is frequently the largest bucket, as here, so dropping
        // it would understate the breakdown against the KPI total
        // (UsageStore+Summaries.swift:256, the macOS oracle).
        XCTAssertEqual(snapshot.projectShares.map(\.name), ["Unattributed", "BurnBar", "Website"])
        XCTAssertEqual(snapshot.projectShares.map(\.cost), [100, 5, 3])
        XCTAssertEqual(snapshot.totalCost, 108, accuracy: 0.0001)
    }

    // MARK: Selection snapshot — hour-of-day matrix

    func test_hourWeekdayMatrix_placesCostByLocalWeekdayAndHour() {
        // 2026-05-03 is a Sunday (weekday 1 → matrix row 0).
        let rows = [
            row(cost: 2, start: date(2026, 5, 3, 14)),
            row(cost: 3, start: date(2026, 5, 3, 14, 45)),
            row(cost: 5, start: date(2026, 5, 4, 9))
        ]
        let snapshot = CalendarSelectionSnapshot.build(
            rows: rows, selectedDays: [date(2026, 5, 3), date(2026, 5, 4)], calendar: calendar
        )
        XCTAssertEqual(snapshot.hourWeekdayCost.count, 7)
        XCTAssertEqual(snapshot.hourWeekdayCost[0][14], 5, accuracy: 0.0001) // Sunday 2pm
        XCTAssertEqual(snapshot.hourWeekdayCost[1][9], 5, accuracy: 0.0001)  // Monday 9am
        XCTAssertEqual(snapshot.peakWeekdayIndex, 0)
        XCTAssertEqual(snapshot.peakHour, 14)
        // Tie (5 == 5) keeps the first peak found — Sunday scanned first.
    }

    // MARK: Selection snapshot — cache / reasoning

    func test_cacheAndReasoningMetrics() {
        let rows = [
            row(
                inputTokens: 100,
                outputTokens: 40,
                cacheCreationTokens: 60,
                cacheReadTokens: 240,
                reasoningTokens: 70,
                cost: 1,
                start: date(2026, 5, 1, 9)
            )
        ]
        let snapshot = CalendarSelectionSnapshot.build(
            rows: rows, selectedDays: [date(2026, 5, 1)], calendar: calendar
        )
        // total = 100 + 40 + 60 + 240 + 70 = 510
        XCTAssertEqual(snapshot.totalTokens, 510)
        // hit rate = cacheRead / (input + cacheCreation + cacheRead) = 240/400
        XCTAssertEqual(snapshot.cacheHitRate, 0.6, accuracy: 0.0001)
        XCTAssertEqual(snapshot.cacheReadTokens, 240)
        // savings = 0.9 * cacheRead * blendedRate; blendedRate = 1/510
        XCTAssertEqual(snapshot.cacheSavingsEstimate, 0.9 * 240 * (1.0 / 510.0), accuracy: 0.0001)
        XCTAssertEqual(snapshot.reasoningTokens, 70)
        XCTAssertEqual(snapshot.reasoningShare, 70.0 / 510.0, accuracy: 0.0001)
    }

    // MARK: Store plumbing

    func test_store_apply_buildsBothSnapshots() {
        let store = CalendarStore()
        let rows = [
            row(cost: 2, start: date(2026, 5, 1, 9)),
            row(cost: 6, start: date(2026, 5, 2, 9))
        ]
        store.apply(
            rows: rows,
            model: mayGrid(),
            selectedDays: [date(2026, 5, 2)],
            calendar: calendar
        )
        XCTAssertEqual(store.monthSnapshot?.peakDayCost ?? -1, 6, accuracy: 0.0001)
        XCTAssertEqual(store.monthSnapshot?.monthTotalCost ?? -1, 8, accuracy: 0.0001)
        XCTAssertEqual(store.selectionSnapshot?.totalCost ?? -1, 6, accuracy: 0.0001)
        XCTAssertEqual(store.selectionSnapshot?.activeDays, 1)
    }

    func test_store_refreshSelection_reaggregatesLoadedRowsWithoutNetwork() {
        let store = CalendarStore()
        let rows = [
            row(sessionId: "s1", cost: 2, start: date(2026, 5, 1, 9)),
            row(sessionId: "s2", cost: 6, start: date(2026, 5, 2, 9))
        ]
        store.apply(
            rows: rows,
            model: mayGrid(),
            selectedDays: [date(2026, 5, 1)],
            calendar: calendar
        )
        XCTAssertEqual(store.selectionSnapshot?.totalCost ?? -1, 2, accuracy: 0.0001)

        // Widening the selection reuses the same rows — no fetch involved.
        store.refreshSelection(
            selectedDays: [date(2026, 5, 1), date(2026, 5, 2)],
            calendar: calendar
        )
        XCTAssertEqual(store.selectionSnapshot?.totalCost ?? -1, 8, accuracy: 0.0001)
        XCTAssertEqual(store.selectionSnapshot?.sessionCount, 2)

        // Clearing the selection empties the snapshot but keeps the month.
        store.refreshSelection(selectedDays: [], calendar: calendar)
        XCTAssertEqual(store.selectionSnapshot?.isEmpty, true)
        XCTAssertEqual(store.monthSnapshot?.monthTotalCost ?? -1, 8, accuracy: 0.0001)
    }

    func test_store_refreshSelection_rowsOutsideSelectionAreExcluded() {
        let store = CalendarStore()
        let rows = [
            row(cost: 4, start: date(2026, 4, 27, 9)),   // grid overflow day
            row(cost: 8, start: date(2026, 5, 2, 9))     // in-month day
        ]
        store.apply(rows: rows, model: mayGrid(), selectedDays: [date(2026, 5, 2)], calendar: calendar)
        XCTAssertEqual(store.selectionSnapshot?.totalCost ?? -1, 8, accuracy: 0.0001)
        // Selecting the overflow day works too — the grid displays it.
        store.refreshSelection(selectedDays: [date(2026, 4, 27)], calendar: calendar)
        XCTAssertEqual(store.selectionSnapshot?.totalCost ?? -1, 4, accuracy: 0.0001)
    }
}
