import XCTest
import SwiftUI
import ViewInspector
import GRDB
@testable import OpenBurnBar

// MARK: - DashboardToolbarTests
//
// Tests for live backdrop + rail-primitive components. The dead
// DashboardToolbar / DashboardNavigationModel types were removed in the
// Command Deck cleanup (Step 6).

@MainActor
final class DashboardToolbarTests: XCTestCase {

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

    func test_liveBackdropVisibilityIncludesKernelAndEditorialWithoutWebsiteToggle() {
        XCTAssertFalse(DashboardLiveBackdropVisibility.exposesContentBackdrop(
            appearanceSkin: .aurora,
            useWebsiteBackground: false,
            useKernelBackdrop: false
        ))

        XCTAssertTrue(DashboardLiveBackdropVisibility.exposesContentBackdrop(
            appearanceSkin: .aurora,
            useWebsiteBackground: false,
            useKernelBackdrop: true
        ))

        XCTAssertTrue(DashboardLiveBackdropVisibility.exposesContentBackdrop(
            appearanceSkin: .editorial,
            useWebsiteBackground: false,
            useKernelBackdrop: false
        ))
    }

    func test_kernelBackdropBundleKeepsStaticFallbackVisibleBeforeFirstPaint() throws {
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
        XCTAssertTrue(script.contains("__getReadability"))
        XCTAssertTrue(script.contains("backdropReadability"))
    }

    func test_kernelCatalogIncludesEveryBundledKernel() throws {
        let scriptURL = try XCTUnwrap(Bundle.main.url(
            forResource: "kernel-backdrop",
            withExtension: "js",
            subdirectory: "KernelBackdrop"
        ))
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        XCTAssertEqual(KernelCatalog.all.count, 32)
        XCTAssertEqual(Set(KernelCatalog.all.map(\.id)).count, KernelCatalog.all.count)
        for kernel in KernelCatalog.all {
            XCTAssertTrue(script.contains("id:\"\(kernel.id)\""), kernel.id)
        }
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

    // MARK: - Settings button extraction + Quick-Theme menu

    func test_burnRailActionsSectionRendersWithoutSettingsParameter() throws {
        let section = BurnRailActionsSection(
            isScanning: false,
            onImport: {},
            onRecount: {}
        )
        XCTAssertNoThrow(try section.inspect())
    }

    func test_burnRailSettingsButtonRendersStandalone() throws {
        let button = BurnRailSettingsButton(onSettings: {})
        XCTAssertNoThrow(try button.inspect())
    }

    func test_burnRailAppearanceQuickMenuRendersAndReflectsSettings() throws {
        let settings = makeSettingsManager()
        settings.useWebsiteBackground = true
        settings.useConstellationBackground = false

        let menu = BurnRailAppearanceQuickMenu(
            settingsManager: settings,
            onOpenAppearanceSettings: {}
        )
        XCTAssertNoThrow(try menu.inspect())
    }

    func test_appearancePreviewCardRendersForAuroraDark() throws {
        let settings = makeSettingsManager()
        settings.appearanceMode = .dark
        settings.appearanceSkin = .aurora
        settings.useWebsiteBackground = true

        let preview = AppearancePreviewCard(settingsManager: settings)
            .environment(settings)
        XCTAssertNoThrow(try preview.inspect())
    }

    func test_appearancePreviewCardRendersForEditorialLight() throws {
        let settings = makeSettingsManager()
        settings.appearanceMode = .light
        settings.appearanceSkin = .editorial
        settings.useWebsiteBackground = false

        let preview = AppearancePreviewCard(settingsManager: settings)
            .environment(settings)
        XCTAssertNoThrow(try preview.inspect())
    }
}
