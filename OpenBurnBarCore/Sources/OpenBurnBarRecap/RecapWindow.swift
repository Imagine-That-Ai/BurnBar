import Foundation
import OpenBurnBarInsights
import OpenBurnBarKernel

/// Identity of one calendar month — the unit the monthly recap is built for.
///
/// Deliberately **not** `VerdictWindow.thisMonth`, which is a rolling 30-day
/// window. A recap that says "August" has to mean August: the same month must
/// resolve to the same rows in September as it did on the 1st, and two adjacent
/// months must never overlap.
public struct RecapWindow: Codable, Hashable, Sendable, Comparable, Identifiable {

    /// Gregorian year, e.g. 2026.
    public let year: Int
    /// 1…12.
    public let month: Int

    public init(year: Int, month: Int) {
        // Normalize out-of-range months so arithmetic helpers can stay simple.
        let zeroBased = (year * 12) + (month - 1)
        self.year = Int((Double(zeroBased) / 12).rounded(.down))
        self.month = zeroBased - (self.year * 12) + 1
    }

    /// The month `date` falls in, in `calendar`'s time zone.
    public init(containing date: Date, calendar: Calendar = .current) {
        let parts = calendar.dateComponents([.year, .month], from: date)
        self.init(year: parts.year ?? 1970, month: parts.month ?? 1)
    }

    /// Parses the `"2026-08"` storage key. Returns nil for anything else.
    public init?(key: String) {
        let parts = key.split(separator: "-")
        guard parts.count == 2,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              (1...12).contains(month) else { return nil }
        self.init(year: year, month: month)
    }

    // MARK: - Identity

    /// Sortable, filename-safe storage key: `"2026-08"`.
    public var key: String { String(format: "%04d-%02d", year, month) }

    public var id: String { key }

    /// Months since year 0 — the basis for ordering and arithmetic.
    public var ordinal: Int { (year * 12) + (month - 1) }

    public static func < (lhs: RecapWindow, rhs: RecapWindow) -> Bool {
        lhs.ordinal < rhs.ordinal
    }

    // MARK: - Arithmetic

    /// The month `months` later (negative goes back).
    public func advanced(by months: Int) -> RecapWindow {
        RecapWindow(year: year, month: month + months)
    }

    public var previous: RecapWindow { advanced(by: -1) }
    public var next: RecapWindow { advanced(by: 1) }

    /// The `count` months immediately before this one, newest first.
    public func priorMonths(_ count: Int) -> [RecapWindow] {
        guard count > 0 else { return [] }
        return (1...count).map { advanced(by: -$0) }
    }

    // MARK: - Dates

    /// Midnight on the 1st, in `calendar`'s time zone.
    public func start(calendar: Calendar = .current) -> Date {
        var parts = DateComponents()
        parts.year = year
        parts.month = month
        parts.day = 1
        return calendar.date(from: parts) ?? Date(timeIntervalSince1970: 0)
    }

    /// Midnight on the 1st of the *following* month — the exclusive upper bound.
    ///
    /// Derived by adding one month to the start rather than by adding 30×86400,
    /// so month length and DST transitions are the calendar's problem, not ours.
    public func end(calendar: Calendar = .current) -> Date {
        let from = start(calendar: calendar)
        return calendar.date(byAdding: .month, value: 1, to: from) ?? from
    }

    /// Half-open `[start, end)` interval covering the month.
    public func interval(calendar: Calendar = .current) -> DateInterval {
        let bounds = bounds(calendar: calendar)
        return DateInterval(start: bounds.start, end: bounds.end)
    }

    /// Both bounds from a single `start` construction.
    ///
    /// `contains` and `dayIndex` are called once per usage row, and each one
    /// otherwise rebuilds the month from `DateComponents` two or three times
    /// over. Hot loops hoist this and compare plain `Date`s instead.
    public func bounds(calendar: Calendar = .current) -> (start: Date, end: Date) {
        let from = start(calendar: calendar)
        return (from, calendar.date(byAdding: .month, value: 1, to: from) ?? from)
    }

    /// Number of days in the month (28–31).
    public func dayCount(calendar: Calendar = .current) -> Int {
        calendar.range(of: .day, in: .month, for: start(calendar: calendar))?.count ?? 30
    }

    /// Whether `date` falls inside this month.
    ///
    /// Per-row loops should hoist `bounds(calendar:)` and compare directly
    /// rather than calling this once per row.
    public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        let bounds = bounds(calendar: calendar)
        return date >= bounds.start && date < bounds.end
    }

    /// 0-based day index of `date` within the month, or nil if outside.
    public func dayIndex(of date: Date, calendar: Calendar = .current) -> Int? {
        guard contains(date, calendar: calendar) else { return nil }
        return calendar.component(.day, from: date) - 1
    }

    // MARK: - Completion

    /// True once the month is over — the precondition for sealing a recap.
    public func hasEnded(asOf now: Date = Date(), calendar: Calendar = .current) -> Bool {
        now >= end(calendar: calendar)
    }

    /// The month currently in progress.
    public static func current(asOf now: Date = Date(), calendar: Calendar = .current) -> RecapWindow {
        RecapWindow(containing: now, calendar: calendar)
    }

    /// The newest month that has fully ended — the recap's default subject.
    public static func mostRecentCompleted(
        asOf now: Date = Date(),
        calendar: Calendar = .current
    ) -> RecapWindow {
        current(asOf: now, calendar: calendar).previous
    }

    // MARK: - Display

    /// Locale-aware "August 2026".
    public func displayLabel(locale: Locale = .autoupdatingCurrent, calendar: Calendar = .current) -> String {
        formatted(includeYear: true, locale: locale, calendar: calendar)
    }

    /// Locale-aware "August" — for hero cards where the year is already implied.
    public func monthLabel(locale: Locale = .autoupdatingCurrent, calendar: Calendar = .current) -> String {
        formatted(includeYear: false, locale: locale, calendar: calendar)
    }

    private func formatted(includeYear: Bool, locale: Locale, calendar: Calendar) -> String {
        var style = Date.FormatStyle(
            date: .omitted,
            time: .omitted,
            locale: locale,
            calendar: calendar,
            timeZone: calendar.timeZone
        ).month(.wide)
        if includeYear { style = style.year() }
        return start(calendar: calendar).formatted(style)
    }
}
