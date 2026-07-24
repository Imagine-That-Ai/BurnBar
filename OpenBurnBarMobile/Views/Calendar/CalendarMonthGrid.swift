import SwiftUI

// MARK: - Calendar Month Grid Model
//
// Pure month-grid math: which days fill which cells, in what order the
// weekday header reads, and the exact fetch window the visible grid spans.
// Kept view-free so the whole layout is unit-testable
// (`CalendarMonthGridModelTests`) — including month boundaries and locales
// whose week starts on Monday. (Ported from the macOS Calendar.)

struct CalendarMonthGridModel: Equatable, Sendable {

    /// First day of the visible month, start-of-day.
    let monthStart: Date

    /// First displayed cell — up to 6 days into the previous month.
    let gridStart: Date

    /// Displayed days in row-major order, 7 per week, 4–6 weeks.
    let weeks: [[Date]]

    /// Weekday abbreviations ordered for the calendar's `firstWeekday`.
    let weekdaySymbols: [String]

    /// Fetch window covering every displayed cell:
    /// `gridStart … startOfDay(after: lastCell)`.
    let gridRange: ClosedRange<Date>

    /// All displayed days flattened, row-major (index = drag-gesture cell index).
    var allDays: [Date] {
        weeks.flatMap { $0 }
    }

    /// The month grid containing `month` (any date inside the month).
    static func make(for month: Date, calendar: Calendar = .current) -> CalendarMonthGridModel {
        let monthStart = self.monthStart(containing: month, calendar: calendar)
        let monthWeekday = calendar.component(.weekday, from: monthStart)
        let leading = (monthWeekday - calendar.firstWeekday + 7) % 7
        let gridStart = calendar.date(byAdding: .day, value: -leading, to: monthStart) ?? monthStart

        let daysInMonth = calendar.range(of: .day, in: .month, for: monthStart)?.count ?? 30
        let cellCount = Int(ceil(Double(leading + daysInMonth) / 7.0)) * 7

        var days: [Date] = []
        days.reserveCapacity(cellCount)
        var cursor = gridStart
        for _ in 0..<cellCount {
            days.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        let weeks = stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<min($0 + 7, days.count)]) }
        let gridEnd = calendar.date(byAdding: .day, value: 1, to: days.last ?? gridStart) ?? gridStart

        let symbols = calendar.veryShortWeekdaySymbols
        let first = calendar.firstWeekday - 1
        let ordered = Array(symbols[first...] + symbols[..<first])

        return CalendarMonthGridModel(
            monthStart: monthStart,
            gridStart: gridStart,
            weeks: weeks,
            weekdaySymbols: ordered,
            gridRange: gridStart...gridEnd
        )
    }

    /// Start-of-day of the first day of the month containing `date`.
    static func monthStart(containing date: Date, calendar: Calendar = .current) -> Date {
        if let interval = calendar.dateInterval(of: .month, for: date) {
            return interval.start
        }
        let comps = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: comps) ?? calendar.startOfDay(for: date)
    }

    /// The month `delta` months away from this one (for ‹ › navigation).
    func advanced(byMonths delta: Int, calendar: Calendar = .current) -> CalendarMonthGridModel {
        let shifted = calendar.date(byAdding: .month, value: delta, to: monthStart) ?? monthStart
        return Self.make(for: shifted, calendar: calendar)
    }

    // MARK: Drag-hit math

    static let cellSpacing: CGFloat = 4

    /// Maps a point inside the cells area to a row-major cell index
    /// (`allDays`). Columns are 7 across; rows are `cellHeight` tall with
    /// `cellSpacing` gutters. Gaps between cells resolve to the nearest cell
    /// so a drag never dies in the gutter; points outside the area return nil.
    static func dayIndex(
        at point: CGPoint,
        gridWidth: CGFloat,
        rows: Int,
        cellHeight: CGFloat,
        spacing: CGFloat = cellSpacing
    ) -> Int? {
        let cellWidth = (gridWidth - 6 * spacing) / 7
        guard cellWidth > 0, cellHeight > 0, point.x >= 0, point.y >= 0 else { return nil }
        let column = Int(point.x / (cellWidth + spacing))
        let row = Int(point.y / (cellHeight + spacing))
        guard row >= 0, row < rows else { return nil }
        let clampedColumn = min(6, column)
        return row * 7 + clampedColumn
    }
}

// MARK: - Calendar Month Grid
//
// The month surface: locale-ordered weekday header over 4–6 week rows of
// `CalendarDayCell`s. iOS gesture set (see `CalendarSelectionModel`):
// a tap toggles a day, and a long-press (0.3s) followed by a drag paints a
// contiguous range. The long-press gate keeps vertical scrolling inside the
// parent ScrollView working when a pan starts on the grid.

struct CalendarMonthGrid: View {
    let model: CalendarMonthGridModel
    let snapshot: CalendarMonthSnapshot?
    let selection: CalendarSelectionModel
    var accent: Color = MobileTheme.ember

    static let cellHeight: CGFloat = 46

    private let spacing = CalendarMonthGridModel.cellSpacing

    /// Set while a long-press-drag is (or just was) painting a range. Per-cell
    /// taps check it so the touch-up that ends a range drag can never also
    /// fire a spurious tap-toggle on the final cell.
    @State private var suppressCellTap = false

    var body: some View {
        VStack(spacing: MobileTheme.Spacing.sm) {
            weekdayHeader
            GeometryReader { proxy in
                cellsArea
                    .contentShape(Rectangle())
                    .gesture(rangeGesture(gridWidth: proxy.size.width))
            }
            .frame(height: gridHeight)
        }
        .accessibilityIdentifier("calendar.monthGrid")
    }

    private var gridHeight: CGFloat {
        CGFloat(model.weeks.count) * (Self.cellHeight + spacing) - spacing
    }

    // MARK: Weekday header

    private var weekdayHeader: some View {
        HStack(spacing: spacing) {
            ForEach(Array(model.weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                Text(symbol.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(0.8)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: Cells

    private var cellsArea: some View {
        VStack(spacing: spacing) {
            ForEach(Array(model.weeks.enumerated()), id: \.offset) { _, week in
                HStack(spacing: spacing) {
                    ForEach(week, id: \.self) { day in
                        cell(for: day)
                    }
                }
            }
        }
    }

    private func cell(for day: Date) -> some View {
        let dayCost = snapshot?.dayCosts[day] ?? 0
        return CalendarDayCell(
            date: day,
            cost: dayCost,
            peak: snapshot?.peakDayCost ?? 0,
            topProviders: snapshot?.dayProviders[day] ?? [],
            isInMonth: day >= model.monthStart
                && day < model.advanced(byMonths: 1, calendar: selection.calendar).monthStart,
            isToday: selection.calendar.isDateInToday(day),
            isSelected: selection.isSelected(day),
            accent: accent,
            onTap: { handleTap(on: day) }
        )
        .frame(maxWidth: .infinity)
        .frame(height: Self.cellHeight)
    }

    /// Tap toggles the day — unless a range drag just ended on this touch.
    private func handleTap(on day: Date) {
        guard !suppressCellTap else { return }
        selection.toggle(day)
        HapticBus.chipChange()
    }

    // MARK: Long-press-drag range selection

    /// Long-press (0.3s) arms the range drag; the sequenced drag then paints
    /// the contiguous range from the pressed day. Before the long-press
    /// completes the touch belongs to the parent ScrollView, so fast pans
    /// scroll normally.
    private func rangeGesture(gridWidth: CGFloat) -> some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
            .onChanged { value in
                switch value {
                case .first:
                    // Long-press in progress — nothing to paint yet.
                    break
                case .second(let isPressing, let drag):
                    guard isPressing, let drag else { return }
                    suppressCellTap = true
                    guard let day = day(at: drag.location, gridWidth: gridWidth)
                            ?? day(at: drag.startLocation, gridWidth: gridWidth) else { return }
                    if selection.isDragging {
                        selection.updateDrag(to: day)
                    } else {
                        selection.beginDrag(on: day)
                        HapticBus.tabChange()
                    }
                }
            }
            .onEnded { _ in
                selection.endDrag()
                // Delay clearing so a tap recognizer firing on this same
                // touch-up is still suppressed (it runs within this runloop).
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    suppressCellTap = false
                }
            }
    }

    private func day(at point: CGPoint, gridWidth: CGFloat) -> Date? {
        guard let index = CalendarMonthGridModel.dayIndex(
            at: point,
            gridWidth: gridWidth,
            rows: model.weeks.count,
            cellHeight: Self.cellHeight
        ), index < model.allDays.count else { return nil }
        return model.allDays[index]
    }
}
