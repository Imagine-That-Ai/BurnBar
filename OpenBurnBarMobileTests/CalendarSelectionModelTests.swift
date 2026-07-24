import XCTest
@testable import OpenBurnBarMobile

/// Unit tests for the Calendar day-selection model (iOS gesture set: tap =
/// toggle, long-press-drag = contiguous range paint).
final class CalendarSelectionModelTests: XCTestCase {

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        return cal
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min)) ?? .distantPast
    }

    private func makeModel() -> CalendarSelectionModel {
        CalendarSelectionModel(calendar: calendar)
    }

    // MARK: Select (single day)

    func test_select_normalizesToStartOfDay() {
        let model = makeModel()
        model.select(date(2026, 5, 14, 16, 45))
        XCTAssertEqual(model.selectedDays, [date(2026, 5, 14)])
        XCTAssertEqual(model.orderedDays, [date(2026, 5, 14)])
    }

    func test_select_replacesExistingSelection() {
        let model = makeModel()
        model.select(date(2026, 5, 1))
        model.toggle(date(2026, 5, 3))
        model.select(date(2026, 5, 10))
        XCTAssertEqual(model.selectedDays, [date(2026, 5, 10)])
    }

    // MARK: Tap toggle (multi-select)

    func test_toggle_buildsUpMultiSelection() {
        let model = makeModel()
        // First tap on a fresh model selects exactly one day.
        model.toggle(date(2026, 5, 1))
        // Additional taps toggle more days into the selection.
        model.toggle(date(2026, 5, 3))
        model.toggle(date(2026, 5, 7))
        XCTAssertEqual(model.selectedDays, [
            date(2026, 5, 1), date(2026, 5, 3), date(2026, 5, 7)
        ])
        // Tapping a selected day toggles it back out.
        model.toggle(date(2026, 5, 3))
        XCTAssertEqual(model.selectedDays, [date(2026, 5, 1), date(2026, 5, 7)])
    }

    func test_toggle_lastSelectedDay_clearsSelection() {
        let model = makeModel()
        model.toggle(date(2026, 5, 1))
        model.toggle(date(2026, 5, 1))
        XCTAssertTrue(model.isEmpty)
        XCTAssertNil(model.span)
    }

    func test_toggle_normalizesTimeOfDay() {
        let model = makeModel()
        model.toggle(date(2026, 5, 4, 23, 59))
        XCTAssertEqual(model.selectedDays, [date(2026, 5, 4)])
        XCTAssertTrue(model.isSelected(date(2026, 5, 4, 1, 15)))
    }

    // MARK: Extend (anchor range)

    func test_extend_withoutAnchor_behavesLikeSelect() {
        let model = makeModel()
        model.extend(to: date(2026, 5, 7, 9, 30))
        XCTAssertEqual(model.selectedDays, [date(2026, 5, 7)])
    }

    func test_extend_forwardAndBackward_producesContiguousRange() {
        let model = makeModel()
        model.select(date(2026, 5, 10))
        model.extend(to: date(2026, 5, 13))
        XCTAssertEqual(model.orderedDays, [
            date(2026, 5, 10), date(2026, 5, 11), date(2026, 5, 12), date(2026, 5, 13)
        ])
        model.extend(to: date(2026, 5, 8))
        XCTAssertEqual(model.orderedDays, [
            date(2026, 5, 8), date(2026, 5, 9), date(2026, 5, 10)
        ])
    }

    func test_extend_acrossDSTSpringForward_keepsEveryLocalDay() {
        // 2026-03-08 is the 23-hour day in America/New_York.
        let model = makeModel()
        model.select(date(2026, 3, 7))
        model.extend(to: date(2026, 3, 9))
        XCTAssertEqual(model.orderedDays, [
            date(2026, 3, 7), date(2026, 3, 8), date(2026, 3, 9)
        ])
        for day in model.orderedDays {
            XCTAssertEqual(day, calendar.startOfDay(for: day))
        }
    }

    // MARK: Long-press-drag

    func test_drag_paintsContiguousRangeFromPressDay() {
        let model = makeModel()
        model.beginDrag(on: date(2026, 5, 10, 15, 20))
        XCTAssertTrue(model.isDragging)
        XCTAssertEqual(model.selectedDays, [date(2026, 5, 10)])
        model.updateDrag(to: date(2026, 5, 12))
        XCTAssertEqual(model.orderedDays, [
            date(2026, 5, 10), date(2026, 5, 11), date(2026, 5, 12)
        ])
        // Dragging back across the press day repaints the range.
        model.updateDrag(to: date(2026, 5, 8))
        XCTAssertEqual(model.orderedDays, [
            date(2026, 5, 8), date(2026, 5, 9), date(2026, 5, 10)
        ])
        model.endDrag()
        XCTAssertFalse(model.isDragging)
    }

    func test_updateDrag_outsideActiveDrag_isIgnored() {
        let model = makeModel()
        model.select(date(2026, 5, 2))
        model.updateDrag(to: date(2026, 5, 9))
        XCTAssertEqual(model.selectedDays, [date(2026, 5, 2)])
    }

    func test_drag_replacesPriorTapSelection() {
        let model = makeModel()
        model.toggle(date(2026, 5, 1))
        model.toggle(date(2026, 5, 4))
        model.beginDrag(on: date(2026, 5, 10))
        model.updateDrag(to: date(2026, 5, 11))
        model.endDrag()
        XCTAssertEqual(model.orderedDays, [date(2026, 5, 10), date(2026, 5, 11)])
    }

    // MARK: Span / clear

    func test_span_coversNonContiguousSelection() {
        let model = makeModel()
        model.toggle(date(2026, 5, 2))
        model.toggle(date(2026, 5, 9))
        XCTAssertEqual(model.span, date(2026, 5, 2)...date(2026, 5, 9))
    }

    func test_clear_resetsEverything() {
        let model = makeModel()
        model.beginDrag(on: date(2026, 5, 10))
        model.updateDrag(to: date(2026, 5, 12))
        model.clear()
        XCTAssertTrue(model.isEmpty)
        XCTAssertFalse(model.isDragging)
        XCTAssertNil(model.span)
        // A later extend has no anchor to continue from.
        model.extend(to: date(2026, 5, 20))
        XCTAssertEqual(model.selectedDays, [date(2026, 5, 20)])
    }

    // MARK: Range math

    func test_contiguousDays_sameDay_returnsSingleDay() {
        let days = CalendarSelectionModel.contiguousDays(
            from: date(2026, 5, 10, 8),
            to: date(2026, 5, 10, 22),
            calendar: calendar
        )
        XCTAssertEqual(days, [date(2026, 5, 10)])
    }

    func test_contiguousDays_acrossMonthBoundary() {
        let days = CalendarSelectionModel.contiguousDays(
            from: date(2026, 4, 29),
            to: date(2026, 5, 2),
            calendar: calendar
        )
        XCTAssertEqual(days.sorted(), [
            date(2026, 4, 29), date(2026, 4, 30), date(2026, 5, 1), date(2026, 5, 2)
        ])
    }
}
