import Foundation
import OpenBurnBarCore

/// Heatmap, session outliers, and project entropy for the Charts page.
///
/// These three cards need per-session (or per-event) values rather than the
/// covering `GROUP BY` that feeds burn / provider / model totals. The fold is
/// calendar-local — SQLite `strftime` is UTC — so SQL loads a narrow column
/// projection and this type applies the same clamp + weekday/hour math as
/// `ChartsSnapshot.build`. Production Charts now builds the full snapshot from
/// `ChartFactRow`; this type remains the shared heatmap / outlier / entropy
/// fold and the dedicated SQL twin.
struct ChartSessionAnalytics: Equatable, Sendable {
    let hourWeekdayCost: [[Double]]
    let outlierSessions: [ChartsSnapshot.OutlierSession]
    let projectEntropy: Double

    struct Event: Sendable {
        let startTime: Date
        let cost: Double
        let sessionId: String
        let projectName: String
        let model: String
        let provider: AgentProvider
    }

    static func from(
        rows: [TokenUsage],
        range: ClosedRange<Date>,
        calendar: Calendar
    ) -> ChartSessionAnalytics {
        from(rows: rows.map(ChartFactRow.init), range: range, calendar: calendar)
    }

    static func from(
        rows: [ChartFactRow],
        range: ClosedRange<Date>,
        calendar: Calendar
    ) -> ChartSessionAnalytics {
        from(
            events: rows.map { row in
                Event(
                    startTime: row.startTime,
                    cost: row.cost,
                    sessionId: row.sessionId,
                    projectName: row.projectName,
                    model: row.model,
                    provider: row.provider
                )
            },
            range: range,
            calendar: calendar
        )
    }

    static func from(
        events: [Event],
        range: ClosedRange<Date>,
        calendar: Calendar
    ) -> ChartSessionAnalytics {
        let costEvents = events.map {
            (date: ChartsSnapshot.attributionDate(for: $0.startTime, in: range), value: $0.cost)
        }
        let matrix = ChartBucketing.hourWeekdayMatrix(events: costEvents, calendar: calendar)

        var sessionCosts: [String: Double] = [:]
        var sessionMeta: [String: (project: String, model: String, provider: AgentProvider)] = [:]
        var projectCosts: [String: Double] = [:]
        for event in events {
            sessionCosts[event.sessionId, default: 0] += event.cost
            if sessionMeta[event.sessionId] == nil {
                sessionMeta[event.sessionId] = (event.projectName, event.model, event.provider)
            }
            let project = event.projectName.isEmpty ? "Unassigned" : event.projectName
            projectCosts[project, default: 0] += event.cost
        }
        let outliers = sessionCosts
            .sorted { $0.value > $1.value }
            .prefix(5)
            .compactMap { entry -> ChartsSnapshot.OutlierSession? in
                guard let meta = sessionMeta[entry.key] else { return nil }
                return ChartsSnapshot.OutlierSession(
                    sessionId: entry.key,
                    projectName: meta.project,
                    model: meta.model,
                    provider: meta.provider,
                    cost: entry.value
                )
            }

        return ChartSessionAnalytics(
            hourWeekdayCost: matrix,
            outlierSessions: outliers,
            projectEntropy: ChartBucketing.entropyIndex(Array(projectCosts.values))
        )
    }
}
