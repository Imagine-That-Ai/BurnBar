import Foundation
import OpenBurnBarCore
import SwiftUI
import FirebaseFirestore
import WidgetKit

@Observable
@MainActor
final class DashboardStore {
    private let firestore: FirestoreRepository
    private let functions: FunctionsRepository

    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var heroTotal: Double = 0
    private(set) var windowTotals: [RollupWindowKey: RollupTotals] = [:]
    private(set) var topProviders: [RollupProviderSummary] = []
    private(set) var topModels: [RollupModelSummary] = []
    private(set) var topDevices: [RollupDeviceSummary] = []
    private(set) var dailyPoints: [RollupDailyPoint] = []
    private(set) var displayMode: UsageDisplayMode = .currency
    private(set) var selectedWindow: RollupWindowKey = .today
    private(set) var rollupsByWindow: [RollupWindowKey: UsageRollupDoc] = [:]
    private(set) var isListening = false
    /// True once a load/refresh completed without error. Hoisted stores
    /// (`RootTabView`) use this so a tab-return remount only restarts the
    /// listener instead of re-fetching (`loadIfNeeded`).
    private(set) var hasLoadedOnce = false

    // MARK: - Swarm Color Driver

    /// A data-driven color driver for the swarm background, computed from today's
    /// usage rollup. Provider weights are proportional to cost; the mode reflects
    /// whether a Live Activity session is currently running.
    var swarmColorDriver: SwarmColorDriver {
        // Use today's rollup for provider weights, regardless of selected window.
        let todayRollup = rollupsByWindow[.today]
        let todaySummaries = todayRollup?.providerSummaries ?? []
        let todayCost = todayRollup?.totals.costUsd ?? 0

        let totalCost = todaySummaries.compactMap(\.totalCost).reduce(0, +)
        let weights: [SwarmColorDriver.ProviderWeight]
        if totalCost > 0 {
            weights = todaySummaries
                .prefix(5)  // Top 5 providers max for visual clarity
                .compactMap { summary -> SwarmColorDriver.ProviderWeight? in
                    let cost = summary.totalCost ?? 0
                    guard cost > 0 else { return nil }
                    let provider = AgentProvider.fromProviderID(summary.providerID)
                    guard let provider else { return nil }
                    return SwarmColorDriver.ProviderWeight(
                        provider: provider,
                        weight: cost / totalCost,
                        quotaPressure: 0  // Quota pressure injected separately if QuotaStore available
                    )
                }
        } else if !todaySummaries.isEmpty {
            // No cost data — weight by token count instead.
            let totalTokens = todaySummaries.reduce(0) { $0 + $1.totalTokens }
            weights = todaySummaries
                .prefix(5)
                .compactMap { summary -> SwarmColorDriver.ProviderWeight? in
                    guard summary.totalTokens > 0, totalTokens > 0 else { return nil }
                    let provider = AgentProvider.fromProviderID(summary.providerID)
                    guard let provider else { return nil }
                    return SwarmColorDriver.ProviderWeight(
                        provider: provider,
                        weight: Double(summary.totalTokens) / Double(totalTokens)
                    )
                }
        } else {
            weights = []
        }

        // Determine mode: active if there's a Live Activity running.
        let sessionActive: Bool
        if #available(iOS 16.1, *) {
            sessionActive = LiveActivityManager.shared.hasActiveActivity
        } else {
            sessionActive = false
        }

        return SwarmColorDriver(
            mode: sessionActive ? .active : .idle,
            providers: weights,
            totalBurnRateUSD: todayCost
        )
    }

    private var listener: ListenerRegistration?
    private var lastRebuildAttempt: Date = .distantPast

    /// Minimum interval between automatic rebuild attempts.
    private static let rebuildCooldown: TimeInterval = 60

    init(
        firestore: FirestoreRepository = FirestoreRepository(),
        functions: FunctionsRepository = FunctionsRepository(),
        initialRollups: [UsageRollupDoc] = []
    ) {
        self.firestore = firestore
        self.functions = functions
        if !initialRollups.isEmpty {
            applyRollups(initialRollups, publishSideEffects: false)
            // Seeded stores start warm: `loadIfNeeded` treats the seed as a
            // completed load (previews, tests, screenshot fixtures).
            hasLoadedOnce = true
        }
    }

    /// Initial load called on first view appear.
    func load() async {
        await refresh()
        startListening()
    }

    /// Idempotent variant of `load()` for stores hoisted above the owning
    /// view: a warm store (successful prior load) only restarts the
    /// listener that `onDisappear` tore down — zero refetches on a tab
    /// return. A store whose last load failed retries the full load.
    func loadIfNeeded() async {
        guard hasLoadedOnce else {
            await load()
            return
        }
        startListening()
    }

    /// Fetch the latest rollups and re-derive the published fields.
    ///
    /// Pass `publishSideEffects: false` for pure reads (App Intents): the
    /// fetched data then never touches WidgetCenter or ActivityKit.
    func refresh(publishSideEffects: Bool = true) async {
        await refresh(forceRebuild: false, publishSideEffects: publishSideEffects)
    }

    /// Force a full server-side rollup rebuild from raw usage events.
    func forceRebuild() async {
        await refresh(forceRebuild: true, publishSideEffects: true)
    }

    private func refresh(forceRebuild: Bool, publishSideEffects: Bool) async {
        if AppStoreScreenshotMode.isEnabled {
            applyRollups(AppStoreScreenshotData.usageRollups, publishSideEffects: publishSideEffects)
            error = nil
            isLoading = false
            hasLoadedOnce = true
            return
        }
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            var rollups = try await firestore.fetchRollups()

            var shouldRebuild = forceRebuild || rollups.isEmpty
            if !shouldRebuild {
                shouldRebuild = await hasUsageNewerThanRollups(rollups)
            }

            if shouldRebuild {
                let now = Date()
                guard now.timeIntervalSince(lastRebuildAttempt) >= Self.rebuildCooldown else {
                    applyRollups(rollups, publishSideEffects: publishSideEffects)
                    hasLoadedOnce = true
                    return
                }
                lastRebuildAttempt = now
                try await functions.rebuildUsageRollups(force: forceRebuild)
                rollups = try await firestore.fetchRollups()
            }
            applyRollups(rollups, publishSideEffects: publishSideEffects)
            hasLoadedOnce = true
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Returns true when a raw usage event is newer than the newest rollup's
    /// `computedAt` — i.e. the rollups are genuinely missing usage (worker
    /// stalled or not yet run). One limit-1 query; a failed read (offline)
    /// counts as fresh. Wall-clock age alone is NOT staleness: an idle user's
    /// rollups stay legitimately old, and treating them as stale fired a full
    /// server-side rollup rebuild on every app open.
    private func hasUsageNewerThanRollups(_ rollups: [UsageRollupDoc]) async -> Bool {
        let newestUsage = try? await firestore.fetchNewestUsageEndTime()
        return Self.rollupsAreStale(rollups, newestUsageEndTime: newestUsage)
    }

    /// Pure staleness rule shared by `refresh` and the rollup listener.
    nonisolated static func rollupsAreStale(_ rollups: [UsageRollupDoc], newestUsageEndTime: Date?) -> Bool {
        guard let newestUsageEndTime else { return false }
        let newestComputedAt = rollups.map(\.computedAt).max() ?? .distantPast
        return newestUsageEndTime > newestComputedAt
    }

    func startListening() {
        guard !AppStoreScreenshotMode.isEnabled else { return }
        guard !isListening else { return }
        isListening = true
        listener?.remove()
        listener = firestore.listenToRollups { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let rollups):
                    if rollups.isEmpty {
                        await self.refresh()
                        return
                    }
                    if await self.hasUsageNewerThanRollups(rollups) {
                        await self.refresh()
                        return
                    }
                    self.applyRollups(rollups)
                    self.error = nil
                case .failure(let err):
                    self.error = err.localizedDescription
                }
            }
        }
    }

    func stopListening() {
        isListening = false
        listener?.remove()
        listener = nil
        if #available(iOS 16.1, *) {
            LiveActivityManager.shared.endActivity()
        }
    }

    func setDisplayMode(_ mode: UsageDisplayMode) {
        displayMode = mode
        reapplyCachedRollups()
    }

    func setWindow(_ window: RollupWindowKey) {
        selectedWindow = window
        reapplyCachedRollups()
    }

    func rollup(for window: RollupWindowKey) -> UsageRollupDoc? {
        rollupsByWindow[window]
    }

    // MARK: - Private

    /// Re-derives every published field — and the widget snapshot / Live
    /// Activity side effects — for the current selection from the cached
    /// rollup docs, with zero network. `rollupsByWindow` already holds every
    /// window's doc and the snapshot listener keeps it fresh, so toggling
    /// display mode or window never needs a refetch. An empty cache (failed
    /// initial load) falls back to a full refresh so a toggle can still
    /// recover the dashboard.
    private func reapplyCachedRollups() {
        guard !rollupsByWindow.isEmpty else {
            Task { await refresh() }
            return
        }
        applyRollups(Array(rollupsByWindow.values))
    }

    private func applyRollups(_ rollups: [UsageRollupDoc], publishSideEffects: Bool = true) {
        let byKey = Dictionary(uniqueKeysWithValues: rollups.map { ($0.windowKey, $0) })
        rollupsByWindow = byKey
        if let selected = byKey[selectedWindow] {
            heroTotal = displayMode == .currency ? selected.totals.costUsd : Double(selected.totals.tokens)
            topProviders = selected.providerSummaries.sorted { $0.totalTokens > $1.totalTokens }
            topModels = selected.modelSummaries.sorted { $0.tokens > $1.tokens }
            topDevices = selected.deviceSummaries.sorted { $0.tokens > $1.tokens }
            dailyPoints = selected.dailyPoints
        } else {
            heroTotal = 0
            topProviders = []
            topModels = []
            topDevices = []
            dailyPoints = []
        }
        for key in RollupWindowKey.allCases {
            if let r = byKey[key] {
                windowTotals[key] = r.totals
            }
        }

        guard publishSideEffects else { return }

        // Persist a lightweight snapshot for the widget extension and trigger reload.
        writeWidgetSnapshot(from: byKey)
        updateLiveActivity(from: byKey)
    }

    private func writeWidgetSnapshot(from rollups: [RollupWindowKey: UsageRollupDoc]) {
        guard let selected = rollups[selectedWindow] else { return }

        let snapshot = BurnBarWidgetSnapshot(
            heroTotalCost: displayMode == .currency ? selected.totals.costUsd : Double(selected.totals.tokens),
            heroTotalTokens: selected.totals.tokens,
            heroTotalRequests: selected.totals.requests,
            topProviders: selected.providerSummaries.prefix(3).map(\.provider),
            topProviderTokens: selected.providerSummaries.prefix(3).map(\.totalTokens),
            topModels: selected.modelSummaries.prefix(3).map(\.model),
            dailyPoints: selected.dailyPoints.map(\.value),
            windowKey: selectedWindow.rawValue,
            lastSync: Date()
        )

        do {
            // Only reload timelines when the snapshot content actually changed
            // (or the on-disk copy went stale): every listener tick used to
            // rewrite an identical snapshot and burn the widget reload budget.
            if try BurnBarWidgetShared.writeSnapshotIfChanged(snapshot) {
                WidgetCenter.shared.reloadTimelines(ofKind: "com.openburnbar.app.widget")
            }
        } catch {
            // Silently fail — widget will show placeholder until next successful write.
            // Do NOT surface widget I/O errors to the user dashboard.
        }
    }

    private func updateLiveActivity(from rollups: [RollupWindowKey: UsageRollupDoc]) {
        guard #available(iOS 16.1, *) else { return }
        guard let today = rollups[.today] else { return }

        let topProvider = today.providerSummaries.first?.provider ?? "—"
        let isActive = today.totals.requests > 0

        if LiveActivityManager.shared.hasActiveActivity {
            LiveActivityManager.shared.updateActivity(
                cost: today.totals.costUsd,
                tokens: today.totals.tokens,
                provider: topProvider,
                sessionActive: isActive
            )
        } else {
            LiveActivityManager.shared.startActivity(
                cost: today.totals.costUsd,
                tokens: today.totals.tokens,
                provider: topProvider,
                sessionActive: isActive
            )
        }
    }
}

extension DashboardStore: BudgetSpendDataSource {}
