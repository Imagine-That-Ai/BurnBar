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

    func dateRange() -> ClosedRange<Date>? {
        let calendar = Calendar.current
        let now = Date()

        switch self {
        case .today:
            let start = calendar.startOfDay(for: now)
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? now
            return start...end

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
