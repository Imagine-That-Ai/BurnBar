import OpenBurnBarKernel
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
        var selection: OpenBurnBar.UsageDisplayMode = .currency
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

    func test_kernelBackdropFramePolicyCapsDashboardAndLeavesGateAt60() {
        XCTAssertEqual(
            KernelBackdropFramePolicy.maxFrameRate(isPerformanceGateLaunch: false),
            30
        )
        XCTAssertEqual(
            KernelBackdropFramePolicy.maxFrameRate(isPerformanceGateLaunch: true),
            60
        )
        XCTAssertEqual(
            KernelBackdropFramePolicy.maxFrameRate(isPerformanceGateLaunch: false, refreshHz: 120),
            30
        )
        XCTAssertEqual(
            KernelBackdropFramePolicy.cinematicPresentFrameRate(refreshHz: 144),
            36
        )
        XCTAssertNotEqual(
            KernelBackdropFramePolicy.cinematicPresentFrameRate(refreshHz: 144),
            30,
            "30 on 144 Hz strobes; present fps must divide refresh"
        )
        XCTAssertEqual(
            KernelBackdropFramePolicy.maxFrameRate(isPerformanceGateLaunch: true, refreshHz: 144),
            60,
            "performance-gate launches keep 60 even on 144 Hz"
        )
    }

    func test_kernelContentOcclusionFreezesWhenChromeCoversTheField() {
        XCTAssertTrue(KernelContentOcclusionPolicy.isKernelExposed(opaqueCoverage: 0))
        XCTAssertTrue(KernelContentOcclusionPolicy.isKernelExposed(opaqueCoverage: 0.5))
        XCTAssertFalse(KernelContentOcclusionPolicy.isKernelExposed(opaqueCoverage: 0.95))
        XCTAssertFalse(KernelContentOcclusionPolicy.isKernelExposed(opaqueCoverage: 1))

        XCTAssertTrue(
            KernelBackdropActivityPolicy.shouldBackdropBeActive(
                isVisible: true,
                isMiniaturized: false,
                occlusionState: .visible,
                opaqueCoverage: 0,
                windowHasSheet: false
            )
        )
        XCTAssertFalse(
            KernelBackdropActivityPolicy.shouldBackdropBeActive(
                isVisible: true,
                isMiniaturized: false,
                occlusionState: .visible,
                opaqueCoverage: 1,
                windowHasSheet: false
            ),
            "opaque chrome covering the kernel must freeze the living field"
        )
        XCTAssertFalse(
            KernelBackdropActivityPolicy.shouldBackdropBeActive(
                isVisible: true,
                isMiniaturized: false,
                occlusionState: .visible,
                opaqueCoverage: 0,
                windowHasSheet: true
            ),
            "an attached sheet is content occlusion"
        )
        XCTAssertTrue(
            KernelBackdropActivityPolicy.shouldBackdropBeActive(
                isVisible: true,
                isMiniaturized: false,
                occlusionState: [],
                opaqueCoverage: 1,
                windowHasSheet: true,
                performanceGateOverride: true
            ),
            "performance-gate override still wins"
        )
    }

    func test_kernelWebViewIsOpaqueWhenClarityIsZero() {
        XCTAssertTrue(KernelWebViewOpacityPolicy.isOpaque(clarity: 0))
        XCTAssertFalse(KernelWebViewOpacityPolicy.isOpaque(clarity: 0.01))
        XCTAssertFalse(KernelWebViewOpacityPolicy.isOpaque(clarity: 1))
    }

    func test_kernelSwarmOverlayIgnoresDefaultProviderGlyphRoster() {
        XCTAssertFalse(
            OpenBurnBarKernel.KernelSwarmOverlayPolicy.shouldMountCanvas(
                substrateEnabled: false,
                substrateID: "plain"
            ),
            "kernel mode must not mount SwarmCanvas for the default glyph roster"
        )
        XCTAssertTrue(
            OpenBurnBarKernel.KernelSwarmOverlayPolicy.shouldMountCanvas(
                substrateEnabled: true,
                substrateID: "constellation.starfire"
            )
        )
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

    func test_kernelCatalogCategoriesCoverAllKernels() {
        XCTAssertEqual(KernelCatalog.all.count, 32)
        XCTAssertFalse(KernelCatalog.curated.isEmpty)
        XCTAssertFalse(KernelCatalog.atmospheric.isEmpty)
        XCTAssertFalse(KernelCatalog.geometry.isEmpty)
        XCTAssertFalse(KernelCatalog.organic.isEmpty)

        let combined = Set(KernelCatalog.atmospheric.map(\.id))
            .union(KernelCatalog.geometry.map(\.id))
            .union(KernelCatalog.organic.map(\.id))
        XCTAssertEqual(combined.count, KernelCatalog.all.count, "All 32 kernels must be categorized into submenus")
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
