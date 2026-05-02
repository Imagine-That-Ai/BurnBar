import Foundation
import OpenBurnBarCore
import SwiftUI

@Observable
@MainActor
final class DashboardStore {
    private let firestore: FirestoreRepository

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

    init(firestore: FirestoreRepository = FirestoreRepository()) {
        self.firestore = firestore
    }

    func load() async { await refresh() }

    func refresh() async {
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            let rollups = try await firestore.fetchRollups()
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
        } catch {
            self.error = error.localizedDescription
        }
    }

    func startListening() {
        // Live listener stub; full listener can be wired by ui worker
    }

    func stopListening() {
        // Listener cleanup stub
    }

    func setDisplayMode(_ mode: UsageDisplayMode) {
        displayMode = mode
        Task { await refresh() }
    }

    func setWindow(_ window: RollupWindowKey) {
        selectedWindow = window
        Task { await refresh() }
    }
}
