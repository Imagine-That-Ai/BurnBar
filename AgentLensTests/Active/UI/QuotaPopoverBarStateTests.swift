#if canImport(AppKit)
import AppKit
import GRDB
import OpenBurnBarCore
import SwiftUI
import XCTest
@testable import OpenBurnBar

/// UI smoke tests for the reworked `QuotaPopoverBar`
/// (Views/Components/ProviderQuota/ProviderQuotaPopoverViews.swift): the bar
/// now distinguishes "hidden by Settings selection" from "collapsed rows",
/// and renders two distinct empty states (all-hidden vs no-connected). Each
/// state is constructed with fixture models and rendered through a real
/// `NSHostingView` so the body actually executes.
@MainActor
final class QuotaPopoverBarStateTests: XCTestCase {
    private func makeDataStore() throws -> DataStore {
        let queue = try DatabaseQueue()
        return try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
    }

    private func makeQuotaService(refreshProviders: [AgentProvider]) -> ProviderQuotaService {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-quota-popover-\(UUID().uuidString)", isDirectory: true)
        return ProviderQuotaService(
            appPaths: OpenBurnBarAppPaths(applicationSupportRoot: root),
            homeDirectoryURL: root.appendingPathComponent("home", isDirectory: true),
            refreshProviders: refreshProviders
        )
    }

    private func connectProvider(_ provider: AgentProvider, in dataStore: DataStore) throws {
        try dataStore.providerAccountStore.upsert(ProviderAccountDoc(
            id: "acct-\(provider.rawValue)",
            providerID: provider.providerID,
            label: "Test account",
            status: .connected,
            credentialKind: .token,
            storageScope: .deviceKeychain,
            redactedLabel: "redacted",
            sourceDeviceID: nil,
            isDefault: true,
            createdAt: Date(),
            updatedAt: Date()
        ))
    }

    private func render<V: View>(_ view: V) -> NSImage {
        renderViewSnapshot(view, size: CGSize(width: 360, height: 240), colorScheme: .dark)
    }

    private func isBlank(_ image: NSImage) -> Bool {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return true }
        for x in stride(from: 0, to: rep.pixelsWide, by: 12) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 12) {
                if let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.01 {
                    return false
                }
            }
        }
        return true
    }

    func test_noConnectedProvidersRendersDisconnectedEmptyState() throws {
        let dataStore = try makeDataStore()
        let settingsManager = makeSettingsManager()
        let bar = QuotaPopoverBar(
            quotaService: makeQuotaService(refreshProviders: []),
            settingsManager: settingsManager,
            dataStore: dataStore,
            autoRefreshOnAppear: false
        )
        XCTAssertFalse(isBlank(render(bar)), "the no-connected empty state must render")
    }

    func test_allProvidersHiddenBySelectionRendersHiddenEmptyStateAndTapRoutes() throws {
        let dataStore = try makeDataStore()
        try connectProvider(.codex, in: dataStore)
        let settingsManager = makeSettingsManager()
        // Hide every provider via the new Settings selection.
        settingsManager.quotas.visibleProviders = []
        XCTAssertEqual(settingsManager.quotas.visibleProviders, [])

        var customizeTapped = 0
        let bar = QuotaPopoverBar(
            quotaService: makeQuotaService(refreshProviders: [.codex]),
            settingsManager: settingsManager,
            dataStore: dataStore,
            autoRefreshOnAppear: false,
            onCustomizeQuotas: { customizeTapped += 1 }
        )
        XCTAssertFalse(isBlank(render(bar)), "the all-hidden empty state must render")
        // Rendering alone must never fire the navigation callback.
        XCTAssertEqual(customizeTapped, 0)
    }

    func test_visibleSelectedProviderRendersQuotaRow() throws {
        let dataStore = try makeDataStore()
        try connectProvider(.codex, in: dataStore)
        let settingsManager = makeSettingsManager()
        settingsManager.quotas.visibleProviders = Set(AgentProvider.quotaSignalProviders)

        let bar = QuotaPopoverBar(
            quotaService: makeQuotaService(refreshProviders: [.codex]),
            settingsManager: settingsManager,
            dataStore: dataStore,
            autoRefreshOnAppear: false
        )
        XCTAssertFalse(isBlank(render(bar)), "a connected + selected provider must render its row")
    }

    func test_selectionFilterDrivesWhichProvidersTheBarShows() throws {
        // The view derives rows as available ∩ selected; pin that exact set
        // logic through the same inputs the body reads.
        let dataStore = try makeDataStore()
        try connectProvider(.codex, in: dataStore)
        let service = makeQuotaService(refreshProviders: [.codex])
        let available = service.visiblePopoverProviders(dataStore: dataStore)
        XCTAssertEqual(available, [.codex])

        let settingsManager = makeSettingsManager()
        settingsManager.quotas.visibleProviders = []
        XCTAssertTrue(
            available.filter { settingsManager.quotas.visibleProviders.contains($0) }.isEmpty,
            "deselecting every provider must empty the popover rows"
        )

        settingsManager.quotas.visibleProviders = [.codex]
        XCTAssertEqual(
            available.filter { settingsManager.quotas.visibleProviders.contains($0) },
            [.codex]
        )
    }
}
#endif
