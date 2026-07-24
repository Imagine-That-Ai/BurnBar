import XCTest
@testable import OpenBurnBar

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

    // MARK: Plain click

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

    // MARK: ⌘ toggle

    func test_toggle_addsAndRemovesIndividualDays() {
        let model = makeModel()
        model.select(date(2026, 5, 1))
        model.toggle(date(2026, 5, 3))
        XCTAssertEqual(model.selectedDays, [date(2026, 5, 1), date(2026, 5, 3)])
        model.toggle(date(2026, 5, 3))
        XCTAssertEqual(model.selectedDays, [date(2026, 5, 1)])
    }

    func test_toggle_thenShiftClick_extendsFromToggledAnchor() {
        let model = makeModel()
        model.select(date(2026, 5, 1))
        model.toggle(date(2026, 5, 4))
        model.extend(to: date(2026, 5, 6))
        // ⌘-click moved the anchor to May 4, so ⇧ replaces with May 4…6.
        XCTAssertEqual(model.selectedDays, [
            date(2026, 5, 4), date(2026, 5, 5), date(2026, 5, 6)
        ])
    }

    // MARK: ⇧ range

    func test_extend_withoutAnchor_behavesLikePlainClick() {
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
        // Days stay start-of-day aligned despite the 23-hour day.
        for day in model.orderedDays {
            XCTAssertEqual(day, calendar.startOfDay(for: day))
        }
    }

    // MARK: Drag

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

    func test_shiftClick_afterDrag_continuesFromDragStartAnchor() {
        let model = makeModel()
        model.beginDrag(on: date(2026, 5, 10))
        model.updateDrag(to: date(2026, 5, 12))
        model.endDrag()
        model.extend(to: date(2026, 5, 14))
        // The anchor is the drag's press day, not where the drag ended.
        XCTAssertEqual(model.orderedDays, [
            date(2026, 5, 10), date(2026, 5, 11), date(2026, 5, 12),
            date(2026, 5, 13), date(2026, 5, 14)
        ])
    }

    // MARK: Derived state

    func test_span_coversGapsOfNonContiguousSelection() {
        let model = makeModel()
        model.select(date(2026, 5, 2))
        model.toggle(date(2026, 5, 9))
        XCTAssertEqual(model.span, date(2026, 5, 2)...date(2026, 5, 9))
        model.clear()
        XCTAssertNil(model.span)
        XCTAssertTrue(model.isEmpty)
        XCTAssertEqual(model.count, 0)
    }

    func test_contiguousDays_sameDay_returnsSingleDay() {
        let days = CalendarSelectionModel.contiguousDays(
            from: date(2026, 5, 5, 8), to: date(2026, 5, 5, 22), calendar: calendar
        )
        XCTAssertEqual(days, [date(2026, 5, 5)])
    }
}
