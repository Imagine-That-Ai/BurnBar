import Foundation

// MARK: - Time Range

enum TimeRange: String, CaseIterable, Identifiable {
    case today = "Today"
    case last7Days = "Last 7 Days"
    case last30Days = "Last 30 Days"
    case thisMonth = "This Month"
    case allTime = "All Time"

    var id: String { rawValue }

    var displayName: String { rawValue }

    /// Ultra-short label for compact UI surfaces (Command Deck hero, chips).
    var compactLabel: String {
        switch self {
        case .today: return "TODAY"
        case .last7Days: return "7D"
        case .last30Days: return "30D"
        case .thisMonth: return "MONTH"
        case .allTime: return "ALL"
        }
    }

    func dateRange(now: Date = Date()) -> ClosedRange<Date>? {
        let calendar = Calendar.current

        switch self {
        case .today:
            let start = calendar.startOfDay(for: now)
            return start...now

        case .last7Days:
            let start = calendar.date(byAdding: .day, value: -7, to: now) ?? now
            return start...now

        case .last30Days:
            let start = calendar.date(byAdding: .day, value: -30, to: now) ?? now
            return start...now

        case .thisMonth:
            let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
            return startOfMonth...now

        case .allTime:
            return nil // All time has no range
        }
    }
}
