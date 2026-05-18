import Foundation

/// The time horizon a verdict summarizes.
///
/// Cache TTL and renderer chrome (`Today`, `This Week`…) are both driven by
/// the window — `VerdictCache` enforces a per-window staleness budget so
/// the today verdict refreshes on every appear while the annual recap is
/// effectively immutable for the year.
public enum VerdictWindow: String, Codable, Hashable, Sendable, CaseIterable {
    case today
    case yesterday
    case thisWeek
    case lastWeek
    case thisMonth
    case lastMonth
    case quarter
    case year

    /// User-facing chip label rendered above the verdict hero.
    public var displayLabel: String {
        switch self {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .thisWeek: return "This week"
        case .lastWeek: return "Last week"
        case .thisMonth: return "This month"
        case .lastMonth: return "Last month"
        case .quarter: return "This quarter"
        case .year: return "This year"
        }
    }

    /// Cache staleness budget. Reads older than this trigger a background
    /// refresh while still rendering the cached value immediately so the
    /// surface never blanks.
    public var cacheTTL: TimeInterval {
        switch self {
        case .today: return 2 * 60 * 60          // 2h
        case .yesterday: return 12 * 60 * 60     // 12h (yesterday rarely changes)
        case .thisWeek, .lastWeek: return 24 * 60 * 60          // 1d
        case .thisMonth, .lastMonth: return 7 * 24 * 60 * 60    // 7d
        case .quarter: return 14 * 24 * 60 * 60                  // 14d
        case .year: return 30 * 24 * 60 * 60                     // 30d
        }
    }

    /// The day-bucket key used for cache identity. Two reads on the same
    /// local-calendar bucket key resolve to the same cached entry; reads
    /// across the bucket boundary always trigger a re-compose.
    public func dayBucketKey(for date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        switch self {
        case .today, .yesterday:
            formatter.dateFormat = "yyyy-MM-dd"
        case .thisWeek, .lastWeek:
            formatter.dateFormat = "yyyy-'W'ww"
        case .thisMonth, .lastMonth:
            formatter.dateFormat = "yyyy-MM"
        case .quarter:
            let comps = calendar.dateComponents([.year, .month], from: date)
            let q = ((comps.month ?? 1) - 1) / 3 + 1
            return "\(comps.year ?? 0)-Q\(q)"
        case .year:
            formatter.dateFormat = "yyyy"
        }
        return formatter.string(from: date)
    }
}
