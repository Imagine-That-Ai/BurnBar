import XCTest
import OpenBurnBarCore
@testable import OpenBurnBarMobile

final class PulseWindowMetricsTests: XCTestCase {
    func testMinuteHourAndDayUseDistinctRawUsageWindows() {
        let calendar = gregorianUTC()
        let now = calendar.date(from: DateComponents(year: 2026, month: 5, day: 13, hour: 12, minute: 0, second: 0))!
        let rollups: [RollupWindowKey: RollupTotals] = [
            .today: RollupTotals(requests: 99, tokens: 99_000, costUsd: 99),
            .sevenDays: RollupTotals(requests: 700, tokens: 700_000, costUsd: 700)
        ]
        let usages = [
            usage(id: 1, cost: 1.25, tokens: 125, at: now.addingTimeInterval(-30)),
            usage(id: 2, cost: 2.50, tokens: 250, at: now.addingTimeInterval(-30 * 60)),
            usage(id: 3, cost: 4.00, tokens: 400, at: now.addingTimeInterval(-2 * 60 * 60))
        ]

        let minute = PulseWindowMetricBuilder.metrics(scope: .minute, rollupTotals: rollups, liveUsages: usages, now: now, calendar: calendar)
        let hour = PulseWindowMetricBuilder.metrics(scope: .hour, rollupTotals: rollups, liveUsages: usages, now: now, calendar: calendar)
        let day = PulseWindowMetricBuilder.metrics(scope: .day, rollupTotals: rollups, liveUsages: usages, now: now, calendar: calendar)

        XCTAssertEqual(minute.total.costUsd, 1.25, accuracy: 0.001)
        XCTAssertEqual(minute.total.tokens, 125)
        XCTAssertEqual(minute.total.requests, 1)
        XCTAssertEqual(hour.total.costUsd, 3.75, accuracy: 0.001)
        XCTAssertEqual(hour.total.tokens, 375)
        XCTAssertEqual(hour.total.requests, 2)
        XCTAssertEqual(day.total.costUsd, 7.75, accuracy: 0.001)
        XCTAssertEqual(day.total.tokens, 775)
        XCTAssertEqual(day.total.requests, 3)
    }

    func testCalendarDayStartsAtLocalMidnight() {
        var calendar = gregorianUTC()
        calendar.timeZone = TimeZone(secondsFromGMT: -5 * 3_600)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 1, day: 13, hour: 0, minute: 20, second: 0))!
        let localStart = calendar.startOfDay(for: now)
        let justBeforeLocalMidnight = localStart.addingTimeInterval(-1)
        let justAfterLocalMidnight = localStart.addingTimeInterval(1)
        let rollups: [RollupWindowKey: RollupTotals] = [
            .sevenDays: RollupTotals(requests: 7, tokens: 700, costUsd: 7)
        ]

        let day = PulseWindowMetricBuilder.metrics(
            scope: .day,
            rollupTotals: rollups,
            liveUsages: [
                usage(id: 1, cost: 10, tokens: 1_000, at: justBeforeLocalMidnight),
                usage(id: 2, cost: 2, tokens: 200, at: justAfterLocalMidnight)
            ],
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(day.total.costUsd, 2, accuracy: 0.001)
        XCTAssertEqual(day.total.tokens, 200)
        XCTAssertEqual(day.total.requests, 1)
    }

    func testMinuteWindowAgesOutWithoutNewUsage() {
        let calendar = gregorianUTC()
        let now = calendar.date(from: DateComponents(year: 2026, month: 5, day: 13, hour: 12, minute: 0, second: 0))!
        let row = usage(id: 1, cost: 1, tokens: 100, at: now.addingTimeInterval(-30))

        let current = PulseWindowMetricBuilder.metrics(scope: .minute, rollupTotals: [:], liveUsages: [row], now: now, calendar: calendar)
        let aged = PulseWindowMetricBuilder.metrics(scope: .minute, rollupTotals: [:], liveUsages: [row], now: now.addingTimeInterval(31), calendar: calendar)

        XCTAssertEqual(current.total.requests, 1)
        XCTAssertEqual(aged.total.requests, 0)
        XCTAssertEqual(aged.total.costUsd, 0, accuracy: 0.001)
    }

    private func gregorianUTC() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func usage(id: Int, cost: Double, tokens: Int, at date: Date) -> TokenUsage {
        TokenUsage(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", id))!,
            provider: .codex,
            sessionId: "session-\(id)",
            projectName: "Pulse",
            model: "gpt",
            inputTokens: tokens,
            outputTokens: 0,
            costUSD: cost,
            startTime: date,
            endTime: date,
            createdAt: date
        )
    }
}
