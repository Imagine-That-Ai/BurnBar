import XCTest
@testable import OpenBurnBar

final class CalendarMonthGridTests: XCTestCase {

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        cal.firstWeekday = 1 // Sunday
        return cal
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h)) ?? .distantPast
    }

    // MARK: Month layout

    func test_make_february2026_fitsExactlyFourWeeks() {
        // 2026-02-01 is a Sunday: zero leading cells, 28 days → a 4-row grid.
        let model = CalendarMonthGridModel.make(for: date(2026, 2, 14, 9), calendar: calendar)
        XCTAssertEqual(model.monthStart, date(2026, 2, 1))
        XCTAssertEqual(model.gridStart, date(2026, 2, 1))
        XCTAssertEqual(model.weeks.count, 4)
        XCTAssertEqual(model.allDays.count, 28)
        XCTAssertEqual(model.gridRange, date(2026, 2, 1)...date(2026, 3, 1))
    }

    func test_make_may2026_spillsIntoSixWeeksWithLeadingCells() {
        // 2026-05-01 is a Friday: 5 leading April cells, 31 days → 42 cells.
        let model = CalendarMonthGridModel.make(for: date(2026, 5, 20), calendar: calendar)
        XCTAssertEqual(model.monthStart, date(2026, 5, 1))
        XCTAssertEqual(model.gridStart, date(2026, 4, 26))
        XCTAssertEqual(model.weeks.count, 6)
        XCTAssertEqual(model.allDays.count, 42)
        XCTAssertEqual(model.allDays.first, date(2026, 4, 26))
        XCTAssertEqual(model.allDays.last, date(2026, 6, 6))
        // Fetch window ends the day after the last displayed cell.
        XCTAssertEqual(model.gridRange.upperBound, date(2026, 6, 7))
    }

    func test_make_mondayFirstCalendar_shiftsLeadingCells() {
        var mondayFirst = calendar
        mondayFirst.firstWeekday = 2
        let model = CalendarMonthGridModel.make(for: date(2026, 5, 20), calendar: mondayFirst)
        XCTAssertEqual(model.gridStart, date(2026, 4, 27))
        XCTAssertEqual(model.weeks.count, 5)
        XCTAssertEqual(model.allDays.count, 35)
    }

    func test_weekdaySymbols_followFirstWeekday() {
        var mondayFirst = calendar
        mondayFirst.firstWeekday = 2
        let sunday = CalendarMonthGridModel.make(for: date(2026, 5, 1), calendar: calendar)
        let monday = CalendarMonthGridModel.make(for: date(2026, 5, 1), calendar: mondayFirst)
        XCTAssertEqual(sunday.weekdaySymbols.count, 7)
        XCTAssertEqual(monday.weekdaySymbols.count, 7)
        // Same symbols, rotated by one: Monday-first starts where Sunday-first
        // has its second symbol.
        XCTAssertEqual(
            monday.weekdaySymbols,
            Array(sunday.weekdaySymbols[1...] + sunday.weekdaySymbols[..<1])
        )
    }

    // MARK: monthStart / navigation

    func test_monthStart_normalizesAnyDateInsideMonth() {
        XCTAssertEqual(
            CalendarMonthGridModel.monthStart(containing: date(2026, 5, 31, 23), calendar: calendar),
            date(2026, 5, 1)
        )
    }

    func test_advanced_byMonths_navigatesAcrossYearBoundary() {
        let may = CalendarMonthGridModel.make(for: date(2026, 5, 10), calendar: calendar)
        XCTAssertEqual(may.advanced(byMonths: 1, calendar: calendar).monthStart, date(2026, 6, 1))
        let january = CalendarMonthGridModel.make(for: date(2026, 1, 10), calendar: calendar)
        XCTAssertEqual(january.advanced(byMonths: -1, calendar: calendar).monthStart, date(2025, 12, 1))
    }

    // MARK: Row-major ordering

    func test_allDays_isRowMajor() {
        let model = CalendarMonthGridModel.make(for: date(2026, 5, 1), calendar: calendar)
        for (rowIndex, week) in model.weeks.enumerated() {
            for (column, day) in week.enumerated() {
                XCTAssertEqual(model.allDays[rowIndex * 7 + column], day)
            }
        }
        // Consecutive days differ by exactly one calendar day.
        for pair in zip(model.allDays, model.allDays.dropFirst()) {
            XCTAssertEqual(
                calendar.dateComponents([.day], from: pair.0, to: pair.1).day, 1
            )
        }
    }

    // MARK: Drag-hit math

    func test_dayIndex_mapsPointsToRowMajorCells() {
        // 50pt cells + 4pt gutters → gridWidth 374 for 7 columns.
        let width: CGFloat = 7 * 50 + 6 * 4
        let rows = 4
        XCTAssertEqual(
            CalendarMonthGridModel.dayIndex(
                at: CGPoint(x: 0, y: 0), gridWidth: width, rows: rows, cellHeight: 46
            ),
            0
        )
        // Second column starts after one cell + one gutter.
        XCTAssertEqual(
            CalendarMonthGridModel.dayIndex(
                at: CGPoint(x: 55, y: 0), gridWidth: width, rows: rows, cellHeight: 46
            ),
            1
        )
        // Second row starts after one row + one gutter.
        XCTAssertEqual(
            CalendarMonthGridModel.dayIndex(
                at: CGPoint(x: 0, y: 51), gridWidth: width, rows: rows, cellHeight: 46
            ),
            7
        )
        // Gutters resolve to the nearest cell rather than dying.
        XCTAssertEqual(
            CalendarMonthGridModel.dayIndex(
                at: CGPoint(x: 52, y: 48), gridWidth: width, rows: rows, cellHeight: 46
            ),
            0
        )
        // Overshot x clamps to the last column of the row.
        XCTAssertEqual(
            CalendarMonthGridModel.dayIndex(
                at: CGPoint(x: 999, y: 0), gridWidth: width, rows: rows, cellHeight: 46
            ),
            6
        )
    }

    func test_dayIndex_outsideGrid_returnsNil() {
        let width: CGFloat = 7 * 50 + 6 * 4
        XCTAssertNil(
            CalendarMonthGridModel.dayIndex(
                at: CGPoint(x: -1, y: 0), gridWidth: width, rows: 4, cellHeight: 46
            )
        )
        XCTAssertNil(
            CalendarMonthGridModel.dayIndex(
                at: CGPoint(x: 0, y: -1), gridWidth: width, rows: 4, cellHeight: 46
            )
        )
        // One row below a 4-row grid.
        XCTAssertNil(
            CalendarMonthGridModel.dayIndex(
                at: CGPoint(x: 0, y: 4 * 50), gridWidth: width, rows: 4, cellHeight: 46
            )
        )
    }
}
