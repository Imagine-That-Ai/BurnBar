import Foundation

// MARK: - Calendar Selection Model
//
// Owns the day selection for the Calendar surface. Days are normalized to
// local start-of-day (`Calendar.current` by default) so a selection survives
// DST transitions and never depends on the time-of-day the click carried.
//
// Interaction semantics mirror Finder/Photos multi-select:
// - plain click selects exactly one day and moves the anchor,
// - ⇧-click replaces the selection with the contiguous anchor…day range,
// - ⌘-click toggles a single day in or out of the set,
// - drag paints a contiguous range from the day the press started on.
//
// The model is deliberately view-free (no SwiftUI, no AppKit): the grid reads
// the click's modifier flags and calls the matching verb, which keeps every
// branch unit-testable (see `CalendarSelectionModelTests`).

@Observable
final class CalendarSelectionModel {

    /// Calendar used to normalize days. Injected for tests; the app uses
    /// `.current` so bucketing follows the user's local timezone.
    let calendar: Calendar

    /// Selected days, normalized to local start-of-day.
    private(set) var selectedDays: Set<Date> = []

    /// The day range gestures extend from (plain click, ⌘-click, or drag
    /// start). Survives after the gesture ends so a later ⇧-click continues
    /// from the same anchor.
    private var anchor: Date?

    /// Anchor captured when the current drag began; cleared on drag end.
    private var dragAnchor: Date?

    private(set) var isDragging = false

    init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    // MARK: Derived state

    /// Selected days in ascending order.
    var orderedDays: [Date] {
        selectedDays.sorted()
    }

    var count: Int {
        selectedDays.count
    }

    var isEmpty: Bool {
        selectedDays.isEmpty
    }

    /// Earliest…latest selected day (both start-of-day), or nil when empty.
    /// Spans a non-contiguous ⌘ selection across its gaps.
    var span: ClosedRange<Date>? {
        guard let first = selectedDays.min(), let last = selectedDays.max() else { return nil }
        return first...last
    }

    func isSelected(_ day: Date) -> Bool {
        selectedDays.contains(normalized(day))
    }

    // MARK: Click verbs

    /// Plain click: reduce the selection to just this day.
    func select(_ day: Date) {
        let day = normalized(day)
        selectedDays = [day]
        anchor = day
    }

    /// ⌘-click: toggle this day in/out of the set without disturbing the rest.
    func toggle(_ day: Date) {
        let day = normalized(day)
        if selectedDays.contains(day) {
            selectedDays.remove(day)
        } else {
            selectedDays.insert(day)
        }
        anchor = day
    }

    /// ⇧-click: replace the selection with the contiguous range from the
    /// anchor to this day. With no anchor yet, behaves like a plain click.
    func extend(to day: Date) {
        let day = normalized(day)
        guard let anchor else {
            select(day)
            return
        }
        selectedDays = Self.contiguousDays(from: anchor, to: day, calendar: calendar)
    }

    // MARK: Drag verbs

    /// Press landed on `day`: start a fresh range there.
    func beginDrag(on day: Date) {
        let day = normalized(day)
        dragAnchor = day
        anchor = day
        selectedDays = [day]
        isDragging = true
    }

    /// Drag moved onto `day`: repaint the contiguous range from the drag's
    /// starting day. Ignored outside an active drag.
    func updateDrag(to day: Date) {
        guard isDragging, let dragAnchor else { return }
        selectedDays = Self.contiguousDays(from: dragAnchor, to: day, calendar: calendar)
    }

    func endDrag() {
        isDragging = false
        dragAnchor = nil
    }

    func clear() {
        selectedDays = []
        anchor = nil
        dragAnchor = nil
        isDragging = false
    }

    // MARK: Range math

    /// Every local calendar day from `a` to `b` inclusive, in either
    /// direction. Days are start-of-day normalized and produced by calendar
    /// arithmetic, so DST 23/25-hour days stay aligned.
    static func contiguousDays(from a: Date, to b: Date, calendar: Calendar) -> Set<Date> {
        let start = min(a, b)
        let end = max(a, b)
        var days: Set<Date> = [calendar.startOfDay(for: start)]
        var cursor = calendar.startOfDay(for: start)
        let endDay = calendar.startOfDay(for: end)
        // The grid only ever shows ~42 cells; the cap is a paranoia guard
        // against a malformed date pair, never a real limit.
        while cursor < endDay, days.count < 372 {
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = calendar.startOfDay(for: next)
            days.insert(cursor)
        }
        return days
    }

    private func normalized(_ day: Date) -> Date {
        calendar.startOfDay(for: day)
    }
}
