import Foundation

/// A unified filter applied at either the canvas or the widget level.
///
/// Widget-level filters override the canvas-level filter when set. Both
/// are Codable so they survive cloud sync and template export.
public struct InsightFilter: Codable, Hashable, Sendable {
    public var window: InsightTimeWindow
    public var providers: Set<String>          // AgentProvider.rawValue
    public var models: Set<String>             // model identifiers
    public var projects: Set<String>           // canonical project names
    public var focuses: Set<String>            // taxonomy focuses
    public var useCases: Set<String>           // taxonomy use cases
    public var minCostUSD: Double?
    public var maxCostUSD: Double?

    public init(
        window: InsightTimeWindow = .last7d,
        providers: Set<String> = [],
        models: Set<String> = [],
        projects: Set<String> = [],
        focuses: Set<String> = [],
        useCases: Set<String> = [],
        minCostUSD: Double? = nil,
        maxCostUSD: Double? = nil
    ) {
        self.window = window
        self.providers = providers
        self.models = models
        self.projects = projects
        self.focuses = focuses
        self.useCases = useCases
        self.minCostUSD = minCostUSD
        self.maxCostUSD = maxCostUSD
    }

    /// Merge with a widget override: widget keys win when non-empty.
    public func overlaid(by widget: InsightFilter?) -> InsightFilter {
        guard let widget else { return self }
        return InsightFilter(
            window: widget.window,
            providers: widget.providers.isEmpty ? providers : widget.providers,
            models: widget.models.isEmpty ? models : widget.models,
            projects: widget.projects.isEmpty ? projects : widget.projects,
            focuses: widget.focuses.isEmpty ? focuses : widget.focuses,
            useCases: widget.useCases.isEmpty ? useCases : widget.useCases,
            minCostUSD: widget.minCostUSD ?? minCostUSD,
            maxCostUSD: widget.maxCostUSD ?? maxCostUSD
        )
    }
}

/// Time window the filter applies over.
public enum InsightTimeWindow: Codable, Hashable, Sendable, Identifiable {
    case today
    case last24h
    case last7d
    case last30d
    case last90d
    case last365d
    case allTime
    /// Inclusive-exclusive range in user-local time.
    case custom(start: Date, end: Date)

    public var id: String {
        switch self {
        case .today: return "today"
        case .last24h: return "last24h"
        case .last7d: return "last7d"
        case .last30d: return "last30d"
        case .last90d: return "last90d"
        case .last365d: return "last365d"
        case .allTime: return "allTime"
        case .custom(let start, let end):
            return "custom-\(start.timeIntervalSince1970)-\(end.timeIntervalSince1970)"
        }
    }

    public var displayName: String {
        switch self {
        case .today: return "Today"
        case .last24h: return "Last 24h"
        case .last7d: return "Last 7 days"
        case .last30d: return "Last 30 days"
        case .last90d: return "Last 90 days"
        case .last365d: return "Last year"
        case .allTime: return "All time"
        case .custom(let start, let end):
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .none
            return "\(f.string(from: start)) – \(f.string(from: end))"
        }
    }

    /// Snap to half-open `[start, end)` interval anchored at the user-local
    /// calendar, evaluated against `now`.
    public func interval(now: Date = Date(), calendar: Calendar = .current) -> DateInterval {
        let end: Date
        let start: Date
        switch self {
        case .today:
            start = calendar.startOfDay(for: now)
            end = calendar.date(byAdding: .day, value: 1, to: start) ?? now
        case .last24h:
            end = now
            start = calendar.date(byAdding: .hour, value: -24, to: now) ?? now
        case .last7d:
            end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
            start = calendar.date(byAdding: .day, value: -7, to: end) ?? now
        case .last30d:
            end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
            start = calendar.date(byAdding: .day, value: -30, to: end) ?? now
        case .last90d:
            end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
            start = calendar.date(byAdding: .day, value: -90, to: end) ?? now
        case .last365d:
            end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
            start = calendar.date(byAdding: .day, value: -365, to: end) ?? now
        case .allTime:
            // Represent "all time" as a very wide window for executor convenience.
            start = Date(timeIntervalSince1970: 0)
            end = calendar.date(byAdding: .year, value: 10, to: now) ?? now
        case .custom(let s, let e):
            start = min(s, e)
            end = max(s, e)
        }
        return DateInterval(start: start, end: max(end, start.addingTimeInterval(1)))
    }
}
