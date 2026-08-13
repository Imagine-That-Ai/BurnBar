import Foundation

// MARK: - Fleet Formatting

/// Deterministic formatting helpers for the fleet dashboard (M3). Every
/// function is pure and fixed-DTO testable: the same input always produces
/// the same string, with documented units and thresholds (VAL-DASH-011/022).
/// Absent values are handled by the view (rendered as "—"), never formatted
/// as zero or NaN here.
enum FleetFormatting {
    /// Bytes with units: B, KB, MB, GB, TB (decimal). Negative values clamp
    /// to 0 B (malformed input never renders as a negative size).
    static func formatBytes(_ bytes: Int) -> String {
        let clamped = max(0, bytes)
        let value = Double(clamped)
        switch clamped {
        case ..<1_000:
            return "\(clamped) B"
        case ..<1_000_000:
            return String(format: "%.1f KB", value / 1_000)
        case ..<1_000_000_000:
            return String(format: "%.1f MB", value / 1_000_000)
        case ..<1_000_000_000_000:
            return String(format: "%.1f GB", value / 1_000_000_000)
        default:
            return String(format: "%.2f TB", value / 1_000_000_000_000)
        }
    }

    /// CPU percent with one decimal, e.g. "12.3%".
    static func formatCPU(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }

    /// Load average: all three values, two decimals, joined with ", ".
    static func formatLoadAverage(_ values: [Double]) -> String {
        values.map { String(format: "%.2f", $0) }.joined(separator: ", ")
    }

    /// Disk free: MB below 1 GB, GB (one decimal) at or above 1 GB.
    static func formatDiskFree(_ bytes: Int) -> String {
        let clamped = max(0, bytes)
        if clamped < 1_000_000_000 {
            return String(format: "%.0f MB", Double(clamped) / 1_000_000)
        }
        return String(format: "%.1f GB", Double(clamped) / 1_000_000_000)
    }

    /// Memory used/total with consistent units: MB below 1 GB total, GB
    /// (one decimal) at or above.
    static func formatMemory(used: Int, total: Int) -> String {
        let usedClamped = max(0, used)
        let totalClamped = max(0, total)
        if totalClamped < 1_000_000_000 {
            return String(format: "%.0f MB / %.0f MB",
                          Double(usedClamped) / 1_000_000,
                          Double(totalClamped) / 1_000_000)
        }
        return String(format: "%.1f GB / %.1f GB",
                      Double(usedClamped) / 1_000_000_000,
                      Double(totalClamped) / 1_000_000_000)
    }

    /// Relative time: "just now" (< 60s), "Xm ago" (< 1h), "Xh ago" (< 24h),
    /// "Xd ago". Deterministic for a fixed `now`.
    static func formatRelativeTime(_ date: Date, now: Date = Date()) -> String {
        let interval = max(0, now.timeIntervalSince(date))
        if interval < 60 { return "just now" }
        let minutes = Int(interval / 60)
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }

    /// Age: "12s", "3m 5s", "1h 2m".
    static func formatAge(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes)m \(total % 60)s" }
        let hours = minutes / 60
        return "\(hours)h \(minutes % 60)m"
    }
}
