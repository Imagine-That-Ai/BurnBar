import SwiftUI
import AppKit

// MARK: - Calendar Month Grid Model
//
// Pure month-grid math: which days fill which cells, in what order the
// weekday header reads, and the exact fetch window the visible grid spans.
// Kept view-free so the whole layout is unit-testable
// (`CalendarMonthGridTests`) — including month boundaries and locales whose
// week starts on Monday.

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
// `CalendarDayCell`s. Clicks select (with ⌘/⇧ modifiers read from the current
// event); a drag across the grid paints a contiguous range.

struct CalendarMonthGrid: View {
    let model: CalendarMonthGridModel
    let snapshot: CalendarMonthSnapshot?
    let selection: CalendarSelectionModel
    var accent: Color = DesignSystem.Colors.ember

    static let cellHeight: CGFloat = 46

    private let spacing = CalendarMonthGridModel.cellSpacing

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.sm) {
            weekdayHeader
            GeometryReader { proxy in
                cellsArea
                    .contentShape(Rectangle())
                    .gesture(dragGesture(gridWidth: proxy.size.width))
            }
            .frame(height: gridHeight)
        }
        .accessibilityIdentifier(OBBAccessibilityID.calendarMonthGrid)
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
                    .foregroundStyle(DesignSystem.Colors.textMuted)
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

    /// Plain click selects, ⇧-click extends the anchor range, ⌘-click toggles.
    private func handleTap(on day: Date) {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        if flags.contains(.command) {
            selection.toggle(day)
        } else if flags.contains(.shift) {
            selection.extend(to: day)
        } else {
            selection.select(day)
        }
    }

    // MARK: Drag-to-select

    private func dragGesture(gridWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                guard let index = CalendarMonthGridModel.dayIndex(
                    at: value.location,
                    gridWidth: gridWidth,
                    rows: model.weeks.count,
                    cellHeight: Self.cellHeight
                ), index < model.allDays.count else { return }
                let day = model.allDays[index]
                if selection.isDragging {
                    selection.updateDrag(to: day)
                } else {
                    selection.beginDrag(on: day)
                }
            }
            .onEnded { _ in
                selection.endDrag()
            }
    }
}
