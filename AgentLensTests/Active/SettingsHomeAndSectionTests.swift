import XCTest
@testable import OpenBurnBar

/// Tests for the new Settings information architecture: sectioned sidebar,
/// Home tab, Model Proxy tab, and legacy deep-link resolution.
@MainActor
final class SettingsHomeAndSectionTests: XCTestCase {

    // MARK: - Section structure

    func test_visibleSectionsExcludesHome() {
        let sections = SettingsSection.visibleSections
        XCTAssertFalse(sections.contains(.home), "Home section is handled separately and should not appear in visibleSections")
        XCTAssertTrue(sections.contains(.agentsAndModels))
        XCTAssertTrue(sections.contains(.lookAndFeel))
        XCTAssertTrue(sections.contains(.system))
    }

    func test_everyTabBelongsToASection() {
        for tab in SettingsTab.allCases {
            // Every tab should map to a section (compile-time exhaustive, but verify).
            let section = tab.section
            XCTAssertNotEqual(section.rawValue, "", "Tab \(tab.rawValue) must belong to a named section")
        }
    }

    func test_modelProxyIsInAgentsAndModelsSection() {
        XCTAssertEqual(SettingsTab.modelProxy.section, .agentsAndModels)
    }

    func test_homeIsInHomeSection() {
        XCTAssertEqual(SettingsTab.home.section, .home)
    }

    // MARK: - Tab visibility

    func test_visibleTabsIncludesHome() {
        XCTAssertTrue(SettingsTab.visibleTabs.contains(.home), "Home must be visible in the sidebar")
    }

    func test_visibleTabsIncludesModelProxy() {
        XCTAssertTrue(SettingsTab.visibleTabs.contains(.modelProxy), "Model Proxy must be visible in the sidebar")
    }

    // MARK: - Legacy resolution

    func test_legacyGatewayResolvesToModelProxy() {
        XCTAssertEqual(SettingsTab.resolving(legacyRawValue: "gateway"), .modelProxy)
        XCTAssertEqual(SettingsTab.resolving(legacyRawValue: "proxy"), .modelProxy)
        XCTAssertEqual(SettingsTab.resolving(legacyRawValue: "modelProxy"), .modelProxy)
    }

    func test_legacyProvidersStillResolvesToAgents() {
        XCTAssertEqual(SettingsTab.resolving(legacyRawValue: "providers"), .agents)
        XCTAssertEqual(SettingsTab.resolving(legacyRawValue: "connections"), .agents)
        XCTAssertEqual(SettingsTab.resolving(legacyRawValue: "hermes"), .agents)
    }

    func test_exactRawValueMatchTakesPrecedenceOverLegacy() {
        XCTAssertEqual(SettingsTab.resolving(legacyRawValue: "daemon"), .daemon)
        XCTAssertEqual(SettingsTab.resolving(legacyRawValue: "agents"), .agents)
    }

    // MARK: - Tab metadata

    func test_daemonTabTitleIsEngineRoom() {
        XCTAssertEqual(SettingsTab.daemon.title, "Engine Room")
    }

    func test_modelProxyTabHasDistinctIcon() {
        XCTAssertEqual(SettingsTab.modelProxy.icon, "network")
        XCTAssertNotEqual(SettingsTab.modelProxy.icon, SettingsTab.agents.icon,
                          "Model Proxy must have a distinct icon from Agents")
    }

    func test_modelProxyTabHasLogoProviders() {
        XCTAssertFalse(SettingsTab.modelProxy.logoProviders.isEmpty,
                       "Model Proxy should carry provider logos for visual identity")
    }

    // MARK: - Page routes

    func test_homeRootRouteExists() {
        // Verify the route is in the anchor index coverage
        XCTAssertNotNil(SettingsManifest.all.first { $0.pageRoute == .homeRoot })
    }

    func test_modelProxyRootRouteExists() {
        XCTAssertNotNil(SettingsManifest.all.first { $0.pageRoute == .modelProxyRoot })
    }
}
