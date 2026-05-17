import Foundation
import SwiftUI
import OpenBurnBarCore

/// Owns the verdict pipeline state on the macOS Insights tab.
///
/// Plan §4.2 / Phase A.9 — the verdict surface is the dominant frame
/// above the canvas. This model is a thin SwiftUI-facing wrapper around
/// the `VerdictCache` + `VerdictComposer` pair from the core. Keeping it
/// separate from `InsightsMacEnvironment` avoids growing the 500-line
/// environment file and lets the surface ship even when the canvas
/// pipeline is mid-refresh.
@Observable
@MainActor
final class InsightsMacVerdictModel {

    /// The verdict currently rendered. `nil` only on first launch before
    /// hydration completes (and `seedDemoIfEmpty` populates a demo).
    var verdict: InsightVerdict?
    /// True when `verdict` is older than the window's cache TTL.
    var isStale: Bool = false
    /// True when the rendered verdict is the demo fixture (first-run state).
    var isDemo: Bool = false
    /// Latest pipeline event for tracing/observability surfaces.
    var lastEvent: String = "idle"
    /// True while a refresh is in flight.
    var isRefreshing: Bool = false

    let window: VerdictWindow
    private let deviceID: String
    private let cache: VerdictCache
    private let composer: VerdictComposer
    private let dataSource: MacInsightDataSource
    private let digestBuilder: InsightDigestBuilder
    private var refreshTask: Task<Void, Never>?

    /// Build with the macOS environment's shared digest pipeline.
    init(
        deviceID: String,
        window: VerdictWindow = .today,
        dataSource: MacInsightDataSource,
        digestBuilder: InsightDigestBuilder,
        cache: VerdictCache = VerdictCache(storage: .defaultUserCaches()),
        engine: RuleBasedVerdictEngine = RuleBasedVerdictEngine()
    ) {
        self.deviceID = deviceID
        self.window = window
        self.cache = cache
        self.dataSource = dataSource
        self.digestBuilder = digestBuilder
        let producer: VerdictComposer.DigestProducer = { [dataSource, digestBuilder] window in
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
            llmAuthor: nil // LLM upgrade arrives in Phase B/C
        )
    }

    /// Load the cached verdict (if any) and decide whether to seed the
    /// demo fixture for first-run users.
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
        // Always queue a background refresh so the demo is replaced by
        // real data on subsequent appearances.
        refresh()
    }

    /// Kick a background refresh. Safe to call from `onAppear`.
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
            case .demo(let v):
                self.verdict = v
                self.isDemo = true
                self.lastEvent = "demo"
            case .ruleBasedUpgrade(let v):
                self.verdict = v
                self.isDemo = false
                self.isStale = false
                self.lastEvent = "rule-based"
            case .llmUpgrade(let v, let report):
                self.verdict = v
                self.isDemo = false
                self.isStale = false
                self.lastEvent = "llm-upgrade dropped=\(report.bulletsDropped)"
            case .llmRejected(let reason):
                self.lastEvent = "llm-rejected \(reason.rawValue)"
            case .failed(let error):
                self.lastEvent = "failed: \(error)"
            }
        }
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
