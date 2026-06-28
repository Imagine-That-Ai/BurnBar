import XCTest
import SwiftUI
import ViewInspector
import GRDB
@testable import OpenBurnBar

// MARK: - DashboardToolbarTests

@MainActor
final class DashboardToolbarTests: XCTestCase {

    private func makeToolbar(
        navigationModel: DashboardNavigationModel = DashboardNavigationModel(),
        isScanning: Bool = false,
        canRunRecount: Bool = true
    ) throws -> DashboardToolbar {
        let settingsManager = makeSettingsManager()
        let store = try XCTUnwrap(try? DataStoreCoordinator(databaseQueue: DatabaseQueue(), runMigrations: false))
        let chatController = ChatSessionController(dataStore: store, settingsManager: settingsManager)
        return DashboardToolbar(
            navigationModel: navigationModel,
            settingsManager: settingsManager,
            chatController: chatController,
            navigationCoordinator: NavigationCoordinator(),
            totalCost: 12.34,
            totalTokens: 5678,
            deltaPercent: nil,
            sparkline: [],
            isLive: false,
            isScanning: isScanning,
            canRunRecount: canRunRecount,
            onBack: {},
            onViewModeChange: { _ in },
            onScan: {},
            onRecount: {},
            onSettings: {}
        )
    }

    func test_rendersWithoutCrashing() throws {
        let toolbar = try makeToolbar()
        let wrapped = NavigationStack {
            Color.clear
                .toolbar { toolbar }
        }
        XCTAssertNoThrow(try wrapped.inspect())
    }

    func test_usageModeToolbarPickerRendersCurrencyAndTokenModes() throws {
        var selection: UsageDisplayMode = .currency
        let picker = UsageModeToolbarPicker(selection: Binding(
            get: { selection },
            set: { selection = $0 }
        ))
        XCTAssertNoThrow(try picker.inspect())

        selection = .tokens
        XCTAssertNoThrow(try picker.inspect())
    }

    func test_dashboardBackdropRendersFlatWebsiteAndConstellationBranches() throws {
        let flatSettings = makeSettingsManager()
        flatSettings.useWebsiteBackground = false
        flatSettings.useConstellationBackground = false
        XCTAssertNoThrow(try DashboardBackdrop(moodBand: .baseline)
            .environment(flatSettings)
            .inspect())

        let websiteSettings = makeSettingsManager()
        websiteSettings.useWebsiteBackground = true
        websiteSettings.useConstellationBackground = false
        XCTAssertNoThrow(try DashboardBackdrop(moodBand: .baseline)
            .environment(websiteSettings)
            .inspect())

        let constellationSettings = makeSettingsManager()
        constellationSettings.useWebsiteBackground = true
        constellationSettings.useConstellationBackground = true
        XCTAssertNoThrow(try DashboardBackdrop(moodBand: .baseline)
            .environment(constellationSettings)
            .inspect())
    }

    func test_dashboardBackdropKeepsCheapFallbackWhenKernelIsEnabled() throws {
        let defaults = UserDefaults.standard
        let previousKernelBackdrop = defaults.object(forKey: KernelBackdropPreferences.enabledKey)
        defer {
            if let previousKernelBackdrop {
                defaults.set(previousKernelBackdrop, forKey: KernelBackdropPreferences.enabledKey)
            } else {
                defaults.removeObject(forKey: KernelBackdropPreferences.enabledKey)
            }
        }

        defaults.set(true, forKey: KernelBackdropPreferences.enabledKey)

        let settings = makeSettingsManager()
        settings.useWebsiteBackground = false
        settings.useConstellationBackground = false

        XCTAssertNoThrow(try DashboardBackdrop(moodBand: .baseline)
            .environment(settings)
            .inspect())
        XCTAssertNoThrow(try DashboardDepthBackdrop(density: .full)
            .environment(settings)
            .frame(width: 640, height: 420)
            .inspect())
    }

    func test_kernelBackdropBundleKeepsNativeFallbackVisibleBeforeFirstPaint() throws {
        let htmlURL = try XCTUnwrap(Bundle.main.url(
            forResource: "index",
            withExtension: "html",
            subdirectory: "KernelBackdrop"
        ))
        let html = try String(contentsOf: htmlURL, encoding: .utf8)
        XCTAssertTrue(html.contains("background: transparent;"))
        XCTAssertFalse(html.contains("background: #000;"))

        let scriptURL = try XCTUnwrap(Bundle.main.url(
            forResource: "kernel-backdrop",
            withExtension: "js",
            subdirectory: "KernelBackdrop"
        ))
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        XCTAssertTrue(script.contains("getContext(\"webgl2\",{alpha:!0"))
        XCTAssertFalse(script.contains("getContext(\"webgl2\",{alpha:!1"))
    }

    func test_dashboardDepthBackdropRendersFlatAndDynamicBranches() throws {
        let flatSettings = makeSettingsManager()
        flatSettings.useWebsiteBackground = false
        flatSettings.useConstellationBackground = false
        XCTAssertNoThrow(try DashboardDepthBackdrop(density: .full)
            .environment(flatSettings)
            .frame(width: 640, height: 420)
            .inspect())

        let dynamicSettings = makeSettingsManager()
        dynamicSettings.useWebsiteBackground = true
        dynamicSettings.useConstellationBackground = true
        XCTAssertNoThrow(try DashboardDepthBackdrop(density: .subtle)
            .environment(dynamicSettings)
            .frame(width: 640, height: 420)
            .inspect())
    }

    func test_backButtonDisabledWhenOnOverview() {
        let nav = DashboardNavigationModel()
        XCTAssertFalse(nav.canGoBack)
    }

    func test_backButtonEnabledAfterNavigation() {
        let nav = DashboardNavigationModel()
        nav.navigate(to: .database)
        XCTAssertTrue(nav.canGoBack)
    }

    func test_viewModeChangeResetsRoute() {
        let nav = DashboardNavigationModel()
        nav.navigate(to: .database)
        nav.viewMode = .models
        nav.resetToOverview()
        XCTAssertEqual(nav.mainRoute, .overview)
        XCTAssertTrue(nav.routeHistory.isEmpty)
    }
}
