import Foundation
import OpenBurnBarInsights
import OpenBurnBarKernel

/// Shared formatting and phrasing for the deterministic copy every rule ships.
///
/// This copy is not a placeholder. When there is no LLM — no backend connected,
/// the toggle off, the request timed out — this *is* the recap, so it has to
/// read like a person wrote it, not like a template filled in.
public enum RecapRuleSupport {

    // MARK: - Numbers

    public static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    /// "a third", "half", "nearly two-thirds" — for copy where a bare
    /// percentage would read like a spreadsheet.
    public static func approximateFraction(_ fraction: Double) -> String {
        switch fraction {
        case ..<0.18: return "a sliver"
        case ..<0.29: return "about a quarter"
        case ..<0.38: return "about a third"
        case ..<0.46: return "over a third"
        case ..<0.55: return "about half"
        case ..<0.63: return "over half"
        case ..<0.71: return "nearly two-thirds"
        case ..<0.80: return "over two-thirds"
        case ..<0.92: return "the large majority"
        default: return "almost all"
        }
    }

    public static func money(_ value: Double) -> String {
        RecapMetric.format(value, .usd)
    }

    /// "up 43%" / "down 12%" / "flat".
    public static func deltaPhrase(_ fraction: Double?) -> String {
        guard let fraction, fraction.isFinite else { return "changed" }
        let magnitude = abs(fraction)
        if magnitude < 0.02 { return "flat" }
        return "\(fraction > 0 ? "up" : "down") \(percent(magnitude))"
    }

    /// Duration in the largest unit that stays readable.
    public static func duration(seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "no time at all" }
        let minutes = seconds / 60
        if minutes < 1 { return "under a minute" }
        if minutes < 90 {
            let whole = Int(minutes.rounded())
            return "\(whole) minute\(whole == 1 ? "" : "s")"
        }
        let hours = minutes / 60
        if hours < 10 { return String(format: "%.1f hours", hours) }
        let whole = Int(hours.rounded())
        return "\(whole) hours"
    }

    // MARK: - Calendar phrasing

    public static func weekdayName(
        _ index: Int,
        locale: Locale = .autoupdatingCurrent,
        calendar: Calendar = .current
    ) -> String {
        let symbols = weekdayNames(locale: locale, calendar: calendar)
        guard symbols.indices.contains(index) else { return "that day" }
        return symbols[index]
    }

    /// All seven names from one formatter.
    ///
    /// A `DateFormatter` costs roughly 190µs to build, so a loop that labels a
    /// weekday chart calls this once instead of seven times.
    public static func weekdayNames(
        locale: Locale = .autoupdatingCurrent,
        calendar: Calendar = .current
    ) -> [String] {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        return formatter.standaloneWeekdaySymbols ?? []
    }

    /// Oxford-comma list: "a, b, and c".
    public static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default:
            return items.dropLast().joined(separator: ", ") + ", and " + (items.last ?? "")
        }
    }

    /// Plural form for "a third of your sessions happened on **Tuesdays**".
    public static func weekdayPlural(
        _ index: Int,
        locale: Locale = .autoupdatingCurrent,
        calendar: Calendar = .current
    ) -> String {
        weekdayName(index, locale: locale, calendar: calendar) + "s"
    }

    /// "9 PM", "14:00" — whichever the locale uses.
    public static func hourName(
        _ hour: Int,
        locale: Locale = .autoupdatingCurrent,
        calendar: Calendar = .current
    ) -> String {
        var components = DateComponents()
        components.year = 2000
        components.month = 1
        components.day = 1
        components.hour = hour
        guard let date = calendar.date(from: components) else { return "\(hour):00" }
        var style = Date.FormatStyle(
            date: .omitted,
            time: .omitted,
            locale: locale,
            calendar: calendar,
            timeZone: calendar.timeZone
        )
        style = style.hour(.defaultDigits(amPM: .abbreviated))
        return date.formatted(style)
    }

    /// "August 8–14".
    public static func dayRange(
        from start: Date,
        to end: Date,
        locale: Locale = .autoupdatingCurrent,
        calendar: Calendar = .current
    ) -> String {
        var monthDay = Date.FormatStyle(
            date: .omitted,
            time: .omitted,
            locale: locale,
            calendar: calendar,
            timeZone: calendar.timeZone
        )
        monthDay = monthDay.month(.wide).day()
        let startText = start.formatted(monthDay)
        let endDay = calendar.component(.day, from: end)
        return "\(startText)–\(endDay)"
    }

    /// "August 14".
    public static func dayLabel(
        _ date: Date,
        locale: Locale = .autoupdatingCurrent,
        calendar: Calendar = .current
    ) -> String {
        var style = Date.FormatStyle(
            date: .omitted,
            time: .omitted,
            locale: locale,
            calendar: calendar,
            timeZone: calendar.timeZone
        )
        style = style.month(.wide).day()
        return date.formatted(style)
    }

    // MARK: - Ranked entries

    /// Builds ranked visual rows from a dimension, normalized against the top
    /// entry so the widest bar is always full.
    public static func ranked(
        _ shares: [RecapShare],
        limit: Int = 5,
        value: (RecapShare) -> Double = { $0.costUSD }
    ) -> [RecapRankedEntry] {
        let top = Array(shares.prefix(limit))
        let maximum = top.map(value).max() ?? 0
        guard maximum > 0 else { return [] }
        return top.map { share in
            RecapRankedEntry(
                key: share.key,
                label: share.label,
                value: value(share),
                fraction: value(share) / maximum,
                colorSeed: share.label
            )
        }
    }

    public static func rankedTools(_ tools: [RecapCount], limit: Int = 5) -> [RecapRankedEntry] {
        let top = Array(tools.prefix(limit))
        let maximum = Double(top.map(\.count).max() ?? 0)
        guard maximum > 0 else { return [] }
        return top.map { tool in
            RecapRankedEntry(
                key: tool.name,
                label: tool.name,
                value: Double(tool.count),
                fraction: Double(tool.count) / maximum,
                colorSeed: tool.name
            )
        }
    }
}
