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
    private(set) var isListening = false

    private var listener: ListenerRegistration?
    private var lastRebuildAttempt: Date = .distantPast

    /// Minimum interval between automatic rebuild attempts.
    private static let rebuildCooldown: TimeInterval = 60

    init(
        firestore: FirestoreRepository = FirestoreRepository(),
        functions: FunctionsRepository = FunctionsRepository()
    ) {
        self.firestore = firestore
        self.functions = functions
    }

    /// Initial load called on first view appear.
    func load() async {
        await refresh()
        startListening()
    }

    func refresh() async {
        await refresh(forceRebuild: false)
    }

    /// Force a full server-side rollup rebuild from raw usage events.
    func forceRebuild() async {
        await refresh(forceRebuild: true)
    }

    private func refresh(forceRebuild: Bool) async {
        if AppStoreScreenshotMode.isEnabled {
            applyRollups(AppStoreScreenshotData.usageRollups)
            error = nil
            isLoading = false
            return
        }
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            var rollups = try await firestore.fetchRollups()

            let shouldRebuild = forceRebuild
                || rollups.isEmpty
                || isRollupStale(rollups)

            if shouldRebuild {
                let now = Date()
                guard now.timeIntervalSince(lastRebuildAttempt) >= Self.rebuildCooldown else {
                    applyRollups(rollups)
                    return
                }
                lastRebuildAttempt = now
                try await functions.rebuildUsageRollups()
                rollups = try await firestore.fetchRollups()
            }
            applyRollups(rollups)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Returns true if the newest rollup's `computedAt` is older than 15 minutes,
    /// suggesting the scheduled rollup worker may be stalled.
    private func isRollupStale(_ rollups: [UsageRollupDoc]) -> Bool {
        let newestComputedAt = rollups.map(\.computedAt).max() ?? .distantPast
        return Date().timeIntervalSince(newestComputedAt) > 900 // 15 min
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
                    if rollups.isEmpty || self.isRollupStale(rollups) {
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
    }

    func setWindow(_ window: RollupWindowKey) {
        selectedWindow = window
    }

    // MARK: - Private

    private func applyRollups(_ rollups: [UsageRollupDoc]) {
        let byKey = Dictionary(uniqueKeysWithValues: rollups.map { ($0.windowKey, $0) })
        if let selected = byKey[selectedWindow] {
            heroTotal = displayMode == .currency ? selected.totals.costUsd : Double(selected.totals.tokens)
            topProviders = selected.providerSummaries.sorted { $0.totalTokens > $1.totalTokens }
            topModels = selected.modelSummaries.sorted { $0.tokens > $1.tokens }
            topDevices = selected.deviceSummaries.sorted { $0.tokens > $1.tokens }
            dailyPoints = selected.dailyPoints
        }
        for key in RollupWindowKey.allCases {
            if let r = byKey[key] {
                windowTotals[key] = r.totals
            }
        }

        // Persist a lightweight snapshot for the widget extension and trigger reload.
        writeWidgetSnapshot(from: byKey)

        // Update Live Activity with latest data.
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
            try BurnBarWidgetShared.writeSnapshot(snapshot)
            WidgetCenter.shared.reloadTimelines(ofKind: "com.openburnbar.app.widget")
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
