import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

final class CalendarDataServiceTests: XCTestCase {

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
        let snapshot = CalendarMonthSnapshot.build(
            rows: rows, model: mayGrid(), calendar: calendar, usagesVersion: 42
        )
        XCTAssertEqual(snapshot.dayCosts[date(2026, 5, 1)] ?? -1, 5, accuracy: 0.0001)
        XCTAssertEqual(snapshot.dayCosts[date(2026, 5, 2)] ?? -1, 9, accuracy: 0.0001)
        XCTAssertEqual(snapshot.peakDayCost, 9, accuracy: 0.0001)
        XCTAssertEqual(snapshot.monthTotalCost, 15, accuracy: 0.0001)
        XCTAssertEqual(snapshot.usagesVersion, 42)
    }

    func test_monthSnapshot_attributesCrossMidnightSessionToStartDay() {
        let rows = [
            row(cost: 4, start: date(2026, 5, 1, 23, 30), end: date(2026, 5, 2, 0, 30))
        ]
        let snapshot = CalendarMonthSnapshot.build(
            rows: rows, model: mayGrid(), calendar: calendar, usagesVersion: 1
        )
        XCTAssertEqual(snapshot.dayCosts[date(2026, 5, 1)] ?? -1, 4, accuracy: 0.0001)
        XCTAssertNil(snapshot.dayCosts[date(2026, 5, 2)])
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
        let snapshot = CalendarMonthSnapshot.build(
            rows: rows, model: mayGrid(), calendar: calendar, usagesVersion: 1
        )
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
        let snapshot = CalendarMonthSnapshot.build(
            rows: rows, model: mayGrid(), calendar: calendar, usagesVersion: 1
        )
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
        let snapshot = CalendarMonthSnapshot.build(
            rows: rows, model: mayGrid(), calendar: calendar, usagesVersion: 1
        )
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
        let snapshot = CalendarSelectionSnapshot.build(
            rows: rows, selectedDays: selection, calendar: calendar
        )
        XCTAssertFalse(snapshot.isEmpty)
        XCTAssertEqual(snapshot.totalCost, 11, accuracy: 0.0001)
        // May 10 was not selected — its 50 is nowhere in the snapshot.
        XCTAssertEqual(snapshot.sessionCount, 3)
        XCTAssertEqual(snapshot.activeDays, 3)
        XCTAssertEqual(snapshot.averageCostPerDay, 2.75, accuracy: 0.0001)
        XCTAssertEqual(snapshot.selectedDays, [
            date(2026, 5, 1), date(2026, 5, 2), date(2026, 5, 3), date(2026, 5, 4)
        ])
    }

    func test_selectionSnapshot_countsDistinctSessionsAcrossDays() {
        let rows = [
            row(sessionId: "s1", cost: 1, start: date(2026, 5, 1, 9)),
            row(sessionId: "s1", cost: 1, start: date(2026, 5, 2, 9)),
            row(sessionId: "s2", cost: 1, start: date(2026, 5, 2, 10))
        ]
        let snapshot = CalendarSelectionSnapshot.build(
            rows: rows,
            selectedDays: [date(2026, 5, 1), date(2026, 5, 2)],
            calendar: calendar
        )
        XCTAssertEqual(snapshot.sessionCount, 2)
        XCTAssertEqual(snapshot.activeDays, 2)
    }

    func test_selectionSnapshot_singleDaySelection() {
        let rows = [
            row(sessionId: "s1", cost: 4, start: date(2026, 5, 1, 9))
        ]
        let snapshot = CalendarSelectionSnapshot.build(
            rows: rows, selectedDays: [date(2026, 5, 1)], calendar: calendar
        )
        XCTAssertEqual(snapshot.totalCost, 4, accuracy: 0.0001)
        XCTAssertEqual(snapshot.sessionCount, 1)
        XCTAssertEqual(snapshot.activeDays, 1)
        XCTAssertEqual(snapshot.dailyBurn.count, 1)
        XCTAssertEqual(snapshot.dailyBurn.first?.value ?? -1, 4, accuracy: 0.0001)
        XCTAssertEqual(snapshot.dailyBurn.first?.start, date(2026, 5, 1))
    }

    func test_selectionSnapshot_emptySelection_isEmpty() {
        let snapshot = CalendarSelectionSnapshot.build(
            rows: [row(cost: 4, start: date(2026, 5, 1, 9))],
            selectedDays: [],
            calendar: calendar
        )
        XCTAssertTrue(snapshot.isEmpty)
        XCTAssertEqual(snapshot.totalCost, 0, accuracy: 0.0001)
        XCTAssertEqual(snapshot.sessionCount, 0)
        XCTAssertEqual(snapshot.activeDays, 0)
        XCTAssertEqual(snapshot.averageCostPerDay, 0, accuracy: 0.0001)
        XCTAssertTrue(snapshot.dailyBurn.isEmpty)
        XCTAssertTrue(snapshot.providerShares.isEmpty)
        XCTAssertNil(snapshot.peakHour)
    }

    // MARK: Selection snapshot — daily burn gap fill

    func test_selectionSnapshot_dailyBurn_gapFillsSilentDays() {
        let rows = [
            row(cost: 5, start: date(2026, 5, 1, 9)),
            row(cost: 1, start: date(2026, 5, 4, 9))
        ]
        let snapshot = CalendarSelectionSnapshot.build(
            rows: rows,
            selectedDays: [date(2026, 5, 1), date(2026, 5, 2), date(2026, 5, 3), date(2026, 5, 4)],
            calendar: calendar
        )
        XCTAssertEqual(snapshot.dailyBurn.count, 4)
        XCTAssertEqual(snapshot.dailyBurn.map(\.value), [5, 0, 0, 1])
        XCTAssertEqual(snapshot.dailyBurn.map(\.start), [
            date(2026, 5, 1), date(2026, 5, 2), date(2026, 5, 3), date(2026, 5, 4)
        ])
    }

    func test_selectionSnapshot_nonContiguousSelection_spansGaps() {
        // ⌘-selected May 1 and May 3 only: the burn chart still spans the gap,
        // but the unselected May 2 row never enters the totals.
        let rows = [
            row(sessionId: "s1", cost: 2, start: date(2026, 5, 1, 9)),
            row(sessionId: "s2", cost: 99, start: date(2026, 5, 2, 9)),
            row(sessionId: "s3", cost: 4, start: date(2026, 5, 3, 9))
        ]
        let snapshot = CalendarSelectionSnapshot.build(
            rows: rows,
            selectedDays: [date(2026, 5, 1), date(2026, 5, 3)],
            calendar: calendar
        )
        XCTAssertEqual(snapshot.totalCost, 6, accuracy: 0.0001)
        XCTAssertEqual(snapshot.sessionCount, 2)
        XCTAssertEqual(snapshot.activeDays, 2)
        XCTAssertEqual(snapshot.dailyBurn.map(\.value), [2, 0, 4])
    }

    func test_selectionSnapshot_dstSpringForwardDay_bucketsCleanly() {
        // 2026-03-08 is the 23-hour day in America/New_York; bucket edges must
        // stay start-of-day aligned and the day's spend must land whole.
        let rows = [
            row(cost: 5, start: date(2026, 3, 8, 12)),
            row(cost: 7, start: date(2026, 3, 9, 1))
        ]
        let snapshot = CalendarSelectionSnapshot.build(
            rows: rows,
            selectedDays: [date(2026, 3, 7), date(2026, 3, 8), date(2026, 3, 9)],
            calendar: calendar
        )
        XCTAssertEqual(snapshot.dailyBurn.count, 3)
        XCTAssertEqual(snapshot.dailyBurn.map(\.value), [0, 5, 7])
        XCTAssertEqual(snapshot.dailyBurn[2].start, date(2026, 3, 9))
        for bucket in snapshot.dailyBurn {
            XCTAssertEqual(bucket.start, calendar.startOfDay(for: bucket.start))
        }
    }

    // MARK: Selection snapshot — mixes

    func test_selectionSnapshot_providerSharesSortedDescending() {
        let rows = [
            row(provider: .codex, cost: 3, start: date(2026, 5, 1, 9)),
            row(provider: .claudeCode, cost: 8, start: date(2026, 5, 1, 10)),
            row(provider: .claudeCode, cost: 1, start: date(2026, 5, 1, 11))
        ]
        let snapshot = CalendarSelectionSnapshot.build(
            rows: rows, selectedDays: [date(2026, 5, 1)], calendar: calendar
        )
        XCTAssertEqual(snapshot.providerShares.map(\.provider), [.claudeCode, .codex])
        XCTAssertEqual(snapshot.providerShares.first?.cost ?? -1, 9, accuracy: 0.0001)
    }

    func test_selectionSnapshot_topModelsAndProjects_sortedAndCapped() {
        // Model rows all belong to BurnBar; the extra project rows reuse
        // existing models so the model totals stay deterministic:
        // model-7 = 7 + 10 = 17, model-6 = 6 + 2 = 8, then 5…1 descending.
        let rows = (1...7).map { index in
            row(
                projectName: "BurnBar",
                model: "model-\(index)",
                cost: Double(index),
                start: date(2026, 5, 1, index)
            )
        } + [
            row(projectName: "BurnBar", model: "model-7", cost: 10, start: date(2026, 5, 1, 9)),
            row(projectName: "SideQuest", model: "model-6", cost: 2, start: date(2026, 5, 1, 10))
        ]
        let snapshot = CalendarSelectionSnapshot.build(
            rows: rows, selectedDays: [date(2026, 5, 1)], calendar: calendar
        )
        // Top 6 of 7 models, descending by cost.
        XCTAssertEqual(snapshot.topModels.count, 6)
        XCTAssertEqual(snapshot.topModels.first?.model, "model-7")
        XCTAssertEqual(snapshot.topModels.last?.model, "model-2")
        XCTAssertEqual(snapshot.projectShares.map(\.name), ["BurnBar", "SideQuest"])
    }

    // MARK: Selection snapshot — hour-of-day heatmap

    func test_selectionSnapshot_hourWeekdayMatrix_findsPeak() {
        // 2026-05-01 is a Friday → Gregorian weekday 6 → matrix row 5.
        let rows = [
            row(cost: 2, start: date(2026, 5, 1, 14)),
            row(cost: 3, start: date(2026, 5, 1, 14, 30)),
            row(cost: 1, start: date(2026, 5, 1, 9))
        ]
        let snapshot = CalendarSelectionSnapshot.build(
            rows: rows, selectedDays: [date(2026, 5, 1)], calendar: calendar
        )
        XCTAssertEqual(snapshot.hourWeekdayCost.count, 7)
        XCTAssertEqual(snapshot.hourWeekdayCost[5][14], 5, accuracy: 0.0001)
        XCTAssertEqual(snapshot.hourWeekdayCost[5][9], 1, accuracy: 0.0001)
        XCTAssertEqual(snapshot.peakWeekdayIndex, 5)
        XCTAssertEqual(snapshot.peakHour, 14)
    }

    // MARK: Selection snapshot — cache ROI & reasoning

    func test_selectionSnapshot_cacheAndReasoningShares() {
        let rows = [
            row(
                inputTokens: 100,
                outputTokens: 40,
                cacheCreationTokens: 50,
                cacheReadTokens: 150,
                reasoningTokens: 20,
                cost: 0.31,
                start: date(2026, 5, 1, 9)
            )
        ]
        let snapshot = CalendarSelectionSnapshot.build(
            rows: rows, selectedDays: [date(2026, 5, 1)], calendar: calendar
        )
        XCTAssertEqual(snapshot.totalTokens, 360)
        XCTAssertEqual(snapshot.cacheReadTokens, 150)
        // Hit rate = cache reads over the full prompt basis.
        XCTAssertEqual(snapshot.cacheHitRate, 0.5, accuracy: 0.0001)
        // Savings estimate = 90% of cache reads at the blended per-token rate.
        let expectedSavings = 0.9 * 150 * (0.31 / 360)
        XCTAssertEqual(snapshot.cacheSavingsEstimate, expectedSavings, accuracy: 0.000001)
        XCTAssertEqual(snapshot.reasoningTokens, 20)
        XCTAssertEqual(snapshot.reasoningShare, 20.0 / 360.0, accuracy: 0.0001)
    }
}
