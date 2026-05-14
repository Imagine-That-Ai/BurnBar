import Foundation
import OpenBurnBarCore

/// Mobile adapter that turns an `InsightsStore` (the canvas/composer
/// shell) and a `MobileInsightDataSource` into `AgentInsightsBundle`s
/// for the cross-platform per-agent Insights surface.
///
/// One producer instance is reused for every scope the user navigates
/// to; the underlying snapshot/canvas fetches happen on demand inside
/// `bundle(for:)`.
@MainActor
final class MobileAgentInsightsProducer: AgentInsightsBundleProducer, @unchecked Sendable {

    private let store: InsightsStore
    private let dataSource: MobileInsightDataSource
    private let calendar: Calendar

    init(
        store: InsightsStore,
        dataSource: MobileInsightDataSource,
        calendar: Calendar = .current
    ) {
        self.store = store
        self.dataSource = dataSource
        self.calendar = calendar
    }

    nonisolated func bundle(for scope: AgentInsightsScope) async throws -> AgentInsightsBundle {
        try await assemble(scope: scope)
    }

    private func assemble(scope: AgentInsightsScope) async throws -> AgentInsightsBundle {
        let now = Date()
        let currentInterval = scope.window.interval(now: now, calendar: calendar)
        let previousInterval = Self.priorInterval(currentInterval, calendar: calendar, now: now)

        async let currentSnapshotResult = dataSource.snapshot(window: currentInterval)
        async let previousSnapshotResult = dataSource.snapshot(window: previousInterval)

        let current = (try? await currentSnapshotResult)
            ?? InsightDataSnapshot(window: currentInterval, generatedAt: now)
        let previous = (try? await previousSnapshotResult)
            ?? InsightDataSnapshot(window: previousInterval, generatedAt: now)

        let canvases = store.canvases
        // Surface the brief only when the user has previously generated
        // one for the current canvas — the per-agent page is read-mostly,
        // it never silently kicks off a new analysis.
        let analysis = store.currentAnalysis

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

    private static func priorInterval(
        _ current: DateInterval,
        calendar: Calendar,
        now: Date
    ) -> DateInterval {
        let duration = max(current.duration, 60)
        let end = current.start
        let start = end.addingTimeInterval(-duration)
        return DateInterval(start: start, end: end)
    }
}
