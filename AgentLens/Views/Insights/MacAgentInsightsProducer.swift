import Foundation
import OpenBurnBarCore

/// macOS adapter that turns an `InsightsMacEnvironment` (canvas store +
/// analysis state) and a `MacInsightDataSource` into
/// `AgentInsightsBundle`s for the cross-platform per-agent Insights
/// surface. Mirrors the mobile producer.
@MainActor
final class MacAgentInsightsProducer: AgentInsightsBundleProducer {

    private let environment: InsightsMacEnvironment
    private let calendar: Calendar

    init(environment: InsightsMacEnvironment, calendar: Calendar = .current) {
        self.environment = environment
        self.calendar = calendar
    }

    nonisolated func bundle(for scope: AgentInsightsScope) async throws -> AgentInsightsBundle {
        try await assemble(scope: scope)
    }

    private func assemble(scope: AgentInsightsScope) async throws -> AgentInsightsBundle {
        let now = Date()
        let currentInterval = scope.window.interval(now: now, calendar: calendar)
        let previousInterval = Self.priorInterval(currentInterval)

        async let currentSnapshotResult = environment.dataSource.snapshot(window: currentInterval)
        async let previousSnapshotResult = environment.dataSource.snapshot(window: previousInterval)

        let current = (try? await currentSnapshotResult)
            ?? InsightDataSnapshot(window: currentInterval, generatedAt: now)
        let previous = (try? await previousSnapshotResult)
            ?? InsightDataSnapshot(window: previousInterval, generatedAt: now)

        let canvases = environment.canvases
        let analysis = environment.currentAnalysis

        return AgentInsightsBundleAssembler.assemble(
            scope: scope,
            snapshot: current,
            previousWindowSnapshot: previous,
            canvases: canvases,
            analysis: analysis,
            auditEntries: [],
            now: now
        )
    }

    private static func priorInterval(_ current: DateInterval) -> DateInterval {
        let duration = max(current.duration, 60)
        let end = current.start
        let start = end.addingTimeInterval(-duration)
        return DateInterval(start: start, end: end)
    }
}
