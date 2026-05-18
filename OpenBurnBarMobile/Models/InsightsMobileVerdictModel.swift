import Foundation
import SwiftUI
import OpenBurnBarCore

/// Owns the verdict pipeline state on the mobile (iOS/iPad) Insights tab.
///
/// Plan §4.2 / Phase A.10 — mirrors `InsightsMacVerdictModel` from the
/// macOS shell, but sources its digest through `InsightsStore`'s mobile
/// data source so iPad and iPhone consume the same verdict pipeline.
@Observable
@MainActor
final class InsightsMobileVerdictModel {

    /// The verdict currently rendered. `nil` only on first launch before
    /// hydration completes.
    var verdict: InsightVerdict?
    /// True when `verdict` is older than the window's cache TTL.
    var isStale: Bool = false
    /// True when the rendered verdict is the demo fixture.
    var isDemo: Bool = false
    /// Latest pipeline event for instrumentation.
    var lastEvent: String = "idle"
    /// True while a refresh is in flight (drives a subtle indicator
    /// in the hero header).
    var isRefreshing: Bool = false

    let window: VerdictWindow
    private let deviceID: String
    private let cache: VerdictCache
    private let composer: VerdictComposer
    private var refreshTask: Task<Void, Never>?

    /// Builds the model around the InsightsStore's shared data source +
    /// digest builder so it sees the same snapshots the canvas pipeline
    /// uses. Cache directory defaults to the app's caches folder.
    init(
        deviceID: String,
        window: VerdictWindow = .today,
        dataSource: InsightDataSource,
        digestBuilder: InsightDigestBuilder,
        cache: VerdictCache = VerdictCache(storage: .defaultUserCaches()),
        engine: RuleBasedVerdictEngine = RuleBasedVerdictEngine()
    ) {
        self.deviceID = deviceID
        self.window = window
        self.cache = cache

        let producer: VerdictComposer.DigestProducer = { window in
            let interval = Self.dateInterval(for: window)
            let snapshot = try await dataSource.snapshot(window: interval)
            return try digestBuilder.build(
                from: snapshot,
                filter: InsightFilter(window: .last7d)
            )
        }
        self.composer = VerdictComposer(
            deviceID: deviceID,
            cache: cache,
            engine: engine,
            postProcessor: InsightVoicePostProcessor(),
            digestProducer: producer,
            llmAuthor: nil // LLM upgrade lands in Phase B/C.
        )
    }

    /// Load any cached verdict and seed the demo fixture for first-run
    /// users. Always kicks a background refresh so the demo is replaced
    /// by a rule-based draft on first reachable digest.
    func bootstrap() async {
        let read = await composer.instant(window: window)
        if let read {
            verdict = read.verdict
            isStale = read.isStale
            isDemo = read.verdict.provenance.providerKey == "burnbar-demo"
        } else {
            await composer.seedDemoIfEmpty(window: window)
            let seeded = await composer.instant(window: window)
            verdict = seeded?.verdict
            isDemo = true
            isStale = false
        }
        refresh()
    }

    /// Refresh in the background. Safe to call from `onAppear` /
    /// pull-to-refresh.
    func refresh() {
        refreshTask?.cancel()
        isRefreshing = true
        refreshTask = Task { [composer, window] in
            for await event in await composer.refresh(window: window) {
                await handle(event)
            }
            await MainActor.run { self.isRefreshing = false }
        }
    }

    private func handle(_ event: VerdictComposer.Event) async {
        await MainActor.run {
            switch event {
            case .cached(let v, let stale):
                self.verdict = v
                self.isStale = stale
                self.isDemo = v.provenance.providerKey == "burnbar-demo"
                self.lastEvent = "cached (stale=\(stale))"
                writeWidgetSnapshot(v, isStale: stale)
            case .demo(let v):
                self.verdict = v
                self.isDemo = true
                self.lastEvent = "demo"
                writeWidgetSnapshot(v, isStale: false)
            case .ruleBasedUpgrade(let v):
                self.verdict = v
                self.isDemo = false
                self.isStale = false
                self.lastEvent = "rule-based"
                writeWidgetSnapshot(v, isStale: false)
                buildTraceFor(verdict: v)
            case .llmUpgrade(let v, let report):
                self.verdict = v
                self.isDemo = false
                self.isStale = false
                self.lastEvent = "llm-upgrade dropped=\(report.bulletsDropped)"
                writeWidgetSnapshot(v, isStale: false)
                buildTraceFor(verdict: v)
            case .llmRejected(let reason):
                self.lastEvent = "llm-rejected \(reason.rawValue)"
            case .failed(let error):
                self.lastEvent = "failed: \(error)"
            }
        }
    }

    private func buildTraceFor(verdict: InsightVerdict) {
        // Mobile trace building requires access to the data source;
        // implement when the mobile data source exposes snapshots.
    }

    private func writeWidgetSnapshot(_ verdict: InsightVerdict, isStale: Bool) {
        let spend = verdict.rings.first { $0.identity == .spend }
        let cache = verdict.rings.first { $0.identity == .cache }
        let sessions = verdict.rings.first { $0.identity == .sessions }
        let snapshot = InsightVerdictWidgetSnapshot(
            headline: verdict.headline,
            spendCurrent: spend?.current ?? 0,
            spendTarget: spend?.target ?? 1,
            cacheCurrent: cache?.current ?? 0,
            cacheTarget: cache?.target ?? 1,
            sessionsCurrent: Int(sessions?.current ?? 0),
            sessionsTarget: Int(sessions?.target ?? 1),
            windowLabel: verdict.window.displayLabel,
            isStale: isStale,
            lastSync: Date()
        )
        try? InsightWidgetShared.writeVerdictSnapshot(snapshot)
    }

    nonisolated private static func dateInterval(for window: VerdictWindow) -> DateInterval {
        let now = Date()
        let cal = Calendar.current
        switch window {
        case .today:
            let start = cal.startOfDay(for: now)
            return DateInterval(start: start, end: now)
        case .yesterday:
            let start = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: now)) ?? now
            let end = cal.startOfDay(for: now)
            return DateInterval(start: start, end: end)
        case .thisWeek:
            let start = cal.date(byAdding: .day, value: -7, to: now) ?? now
            return DateInterval(start: start, end: now)
        case .lastWeek:
            let end = cal.date(byAdding: .day, value: -7, to: now) ?? now
            let start = cal.date(byAdding: .day, value: -14, to: now) ?? end
            return DateInterval(start: start, end: end)
        case .thisMonth:
            let start = cal.date(byAdding: .month, value: -1, to: now) ?? now
            return DateInterval(start: start, end: now)
        case .lastMonth:
            let end = cal.date(byAdding: .month, value: -1, to: now) ?? now
            let start = cal.date(byAdding: .month, value: -2, to: now) ?? end
            return DateInterval(start: start, end: end)
        case .quarter:
            let start = cal.date(byAdding: .month, value: -3, to: now) ?? now
            return DateInterval(start: start, end: now)
        case .year:
            let start = cal.date(byAdding: .year, value: -1, to: now) ?? now
            return DateInterval(start: start, end: now)
        }
    }
}
