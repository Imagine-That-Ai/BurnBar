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
    private(set) var windowTotals: [RollupWindowKey: Double] = [:]
    private(set) var topProviders: [RollupProviderSummary] = []
    private(set) var topModels: [RollupModelSummary] = []
    private(set) var topDevices: [RollupDeviceSummary] = []
    private(set) var dailyPoints: [RollupDailyPoint] = []
    private(set) var displayMode: UsageDisplayMode = .currency
    private(set) var selectedWindow: RollupWindowKey = .today

    init(firestore: FirestoreRepository = FirestoreRepository()) {
        self.firestore = firestore
    }

    func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            let rollups = try await firestore.fetchUsageRollups()
            if let selected = rollups[selectedWindow] {
                heroTotal = displayMode == .currency ? selected.totals.costUsd : Double(selected.totals.tokens)
                topProviders = selected.providerSummaries.sorted { $0.totalTokens > $1.totalTokens }
                topModels = selected.modelSummaries.sorted { $0.tokens > $1.tokens }
                topDevices = selected.deviceSummaries.sorted { $0.tokens > $1.tokens }
                dailyPoints = selected.dailyPoints
            }
            for key in RollupWindowKey.allCases {
                if let r = rollups[key] {
                    windowTotals[key] = displayMode == .currency ? r.totals.costUsd : Double(r.totals.tokens)
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func setDisplayMode(_ mode: UsageDisplayMode) {
        displayMode = mode
        Task { await load() }
    }

    func setWindow(_ window: RollupWindowKey) {
        selectedWindow = window
        Task { await load() }
    }
}
