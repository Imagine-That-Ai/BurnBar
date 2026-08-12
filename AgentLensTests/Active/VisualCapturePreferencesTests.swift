import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

@MainActor
final class VisualCapturePreferencesTests: XCTestCase {
    private var defaults: UserDefaults!
    private var coordinator: SettingsPersistenceCoordinator!
    private var prefs: VisualCapturePreferences!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "VisualCapturePreferencesTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        coordinator = SettingsPersistenceCoordinator(defaults: defaults, flushDelayNanoseconds: 0)
        prefs = VisualCapturePreferences(persistence: coordinator)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        coordinator = nil
        prefs = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Defaults

    func test_defaultsToCliPTYOnFreshInstall() {
        XCTAssertEqual(prefs.visualCaptureGlobalDefault, .cliPTY)
        XCTAssertTrue(prefs.visualCapturePerProvider.isEmpty)
        // Eligible provider with no override falls back to global (cliPTY)
        XCTAssertEqual(prefs.visualCaptureSource(for: .codex), .cliPTY)
        XCTAssertEqual(prefs.visualCaptureSource(for: .claudeCode), .cliPTY)
    }

    func test_flagDefaultsToFalse() {
        XCTAssertFalse(prefs.visualCaptureSourceToggleEnabled)
        // Also via SettingsManager bridge — flag is false on fresh suite
        let manager = makeSettingsManagerForVisualCaptureTests(defaults: defaults)
        XCTAssertFalse(manager.visualCaptureSourceToggleEnabled)
    }

    func test_toggleEligibility_BothProvidersAreEligible() {
        let both: [AgentProvider] = [.codex, .claudeCode, .cursor, .cursorAgent, .factory, .minimax, .zai, .devin, .hermes, .warp, .openCode, .ollama]
        for provider in both {
            XCTAssertTrue(prefs.isToggleEligible(provider), "\(provider.rawValue) should be eligible")
        }
    }

    func test_toggleEligibility_cliOnlyIsNotEligible() {
        // Antigravity is CLI-only canonical example from spec
        XCTAssertFalse(prefs.isToggleEligible(.antigravity))
        XCTAssertEqual(prefs.visualCaptureSource(for: .antigravity), .cliPTY)
    }

    func test_toggleEligibility_pluginOnlyIsNotEligible() {
        let pluginOnly: [AgentProvider] = [.cline, .kiloCode, .rooCode, .augment, .junie]
        for provider in pluginOnly {
            XCTAssertFalse(prefs.isToggleEligible(provider), "\(provider.rawValue) plugin-only should not be eligible")
            XCTAssertEqual(prefs.visualCaptureSource(for: provider), .cliPTY, "\(provider.rawValue) should always return cliPTY")
        }
        // Legacy windsurf also not eligible (now devin-desktop)
        XCTAssertFalse(prefs.isToggleEligible(.windsurf))
        XCTAssertEqual(prefs.visualCaptureSource(for: .windsurf), .cliPTY)
    }

    func test_cliOnlyOverrideEvenIfPerProviderPrefSaysDesktop() {
        // Store desktop for a CLI-only provider — getter must still return cliPTY (migration safety)
        prefs.setVisualCaptureSource(.desktopApp, for: .antigravity)
        coordinator.flush()
        XCTAssertEqual(prefs.visualCaptureSource(for: .antigravity), .cliPTY)
        // Same for plugin-only
        prefs.setVisualCaptureSource(.desktopApp, for: .cline)
        XCTAssertEqual(prefs.visualCaptureSource(for: .cline), .cliPTY)
    }

    func test_pluginOnlyOverrideEvenIfPersistedJSONContainsDesktop() {
        // Simulate old JSON that contains cline -> desktopApp (legacy pref) — must be ignored
        let legacyJSON = #"{"cline":"desktop_app","antigravity":"desktop_app","codex":"desktop_app"}"#
        defaults.set(legacyJSON, forKey: VisualCapturePreferences.perProviderKey)
        let coord2 = SettingsPersistenceCoordinator(defaults: defaults, flushDelayNanoseconds: 0)
        let prefs2 = VisualCapturePreferences(persistence: coord2)
        XCTAssertEqual(prefs2.visualCaptureSource(for: .cline), .cliPTY, "plugin-only must ignore stored desktop")
        XCTAssertEqual(prefs2.visualCaptureSource(for: .antigravity), .cliPTY, "CLI-only must ignore stored desktop")
        XCTAssertEqual(prefs2.visualCaptureSource(for: .codex), .desktopApp, "Both provider should respect stored desktop")
    }

    // MARK: - Global fallback

    func test_globalDefaultFallback_nilPerProviderUsesGlobal() {
        prefs.visualCaptureGlobalDefault = .desktopApp
        coordinator.flush()
        // No per-provider override → should use global desktopApp for eligible provider
        XCTAssertEqual(prefs.visualCaptureSource(for: .codex), .desktopApp)
        XCTAssertEqual(prefs.visualCaptureSource(for: .factory), .desktopApp)
        // Override one provider to cliPTY
        prefs.setVisualCaptureSource(.cliPTY, for: .codex)
        XCTAssertEqual(prefs.visualCaptureSource(for: .codex), .cliPTY)
        XCTAssertEqual(prefs.visualCaptureSource(for: .factory), .desktopApp, "other provider still uses global")
        // Clear override → falls back to global again
        prefs.clearVisualCaptureSource(for: .codex)
        XCTAssertEqual(prefs.visualCaptureSource(for: .codex), .desktopApp)
    }

    // MARK: - Set/get round-trip

    func test_setGetPerProviderRoundTripViaUserDefaults() {
        prefs.setVisualCaptureSource(.desktopApp, for: .codex)
        prefs.setVisualCaptureSource(.desktopApp, for: .claudeCode)
        prefs.setVisualCaptureSource(.cliPTY, for: .factory)
        coordinator.flush()

        // Verify raw JSON persisted
        let json = defaults.string(forKey: VisualCapturePreferences.perProviderKey)
        XCTAssertNotNil(json)
        // Recreate from same defaults — simulates app relaunch
        let coord2 = SettingsPersistenceCoordinator(defaults: defaults, flushDelayNanoseconds: 0)
        let prefs2 = VisualCapturePreferences(persistence: coord2)
        XCTAssertEqual(prefs2.visualCaptureSource(for: .codex), .desktopApp)
        XCTAssertEqual(prefs2.visualCaptureSource(for: .claudeCode), .desktopApp)
        XCTAssertEqual(prefs2.visualCaptureSource(for: .factory), .cliPTY)
        // Provider without override falls back to global
        XCTAssertEqual(prefs2.visualCaptureSource(for: .zai), .cliPTY)
    }

    func test_globalDefaultPersistsAcrossRecreate() {
        prefs.visualCaptureGlobalDefault = .desktopApp
        coordinator.flush()
        let coord2 = SettingsPersistenceCoordinator(defaults: defaults, flushDelayNanoseconds: 0)
        let prefs2 = VisualCapturePreferences(persistence: coord2)
        XCTAssertEqual(prefs2.visualCaptureGlobalDefault, .desktopApp)
        XCTAssertEqual(prefs2.visualCaptureSource(for: .codex), .desktopApp)
    }

    func test_flagPersistsAcrossRecreate() {
        prefs.visualCaptureSourceToggleEnabled = true
        coordinator.flush()
        let coord2 = SettingsPersistenceCoordinator(defaults: defaults, flushDelayNanoseconds: 0)
        let prefs2 = VisualCapturePreferences(persistence: coord2)
        XCTAssertTrue(prefs2.visualCaptureSourceToggleEnabled)
        prefs2.visualCaptureSourceToggleEnabled = false
        coord2.flush()
        let coord3 = SettingsPersistenceCoordinator(defaults: defaults, flushDelayNanoseconds: 0)
        let prefs3 = VisualCapturePreferences(persistence: coord3)
        XCTAssertFalse(prefs3.visualCaptureSourceToggleEnabled)
    }

    func test_clearAllPerProviderPreferences() {
        prefs.setVisualCaptureSource(.desktopApp, for: .codex)
        prefs.setVisualCaptureSource(.desktopApp, for: .claudeCode)
        coordinator.flush()
        XCTAssertEqual(prefs.visualCapturePerProvider.count, 2)
        prefs.clearAllPerProviderPreferences()
        coordinator.flush()
        XCTAssertTrue(prefs.visualCapturePerProvider.isEmpty)
        XCTAssertNil(defaults.string(forKey: VisualCapturePreferences.perProviderKey), "empty map should remove key")
        let coord2 = SettingsPersistenceCoordinator(defaults: defaults, flushDelayNanoseconds: 0)
        let prefs2 = VisualCapturePreferences(persistence: coord2)
        XCTAssertTrue(prefs2.visualCapturePerProvider.isEmpty)
    }

    func test_overwritePerProviderPref() {
        prefs.setVisualCaptureSource(.desktopApp, for: .codex)
        XCTAssertEqual(prefs.visualCaptureSource(for: .codex), .desktopApp)
        prefs.setVisualCaptureSource(.cliPTY, for: .codex)
        XCTAssertEqual(prefs.visualCaptureSource(for: .codex), .cliPTY)
        coordinator.flush()
        let coord2 = SettingsPersistenceCoordinator(defaults: defaults, flushDelayNanoseconds: 0)
        let prefs2 = VisualCapturePreferences(persistence: coord2)
        XCTAssertEqual(prefs2.visualCaptureSource(for: .codex), .cliPTY)
    }

    func test_settingsManagerBridgeRoundTrip() {
        // Verify SettingsManager visualCapture bridges read/write same UserDefaults
        let manager = makeSettingsManagerForVisualCaptureTests(defaults: defaults)
        manager.visualCaptureSourceToggleEnabled = true
        manager.visualCaptureGlobalDefault = .desktopApp
        manager.setVisualCaptureSource(.desktopApp, for: .codex)
        manager.persistence.flush()
        XCTAssertTrue(defaults.bool(forKey: VisualCapturePreferences.toggleEnabledKey))
        XCTAssertEqual(defaults.string(forKey: VisualCapturePreferences.globalDefaultKey), VisualCaptureSource.desktopApp.rawValue)
        // New manager sees same
        let manager2 = makeSettingsManagerForVisualCaptureTests(defaults: defaults)
        XCTAssertTrue(manager2.visualCaptureSourceToggleEnabled)
        XCTAssertEqual(manager2.visualCaptureGlobalDefault, .desktopApp)
        XCTAssertEqual(manager2.visualCaptureSource(for: .codex), .desktopApp)
        XCTAssertFalse(manager2.isToggleEligible(.antigravity))
    }

    // MARK: - Helpers

    private func makeSettingsManagerForVisualCaptureTests(defaults: UserDefaults) -> SettingsManager {
        SettingsManager(
            defaults: defaults,
            controllerRuntimeSecrets: KeychainStore(
                service: "tests.controller.\(UUID().uuidString)",
                legacyServices: [],
                backend: VisualCapturePreferencesTestsKeychainBackend()
            ),
            chatGatewaySecrets: KeychainStore(
                service: "tests.gateway.\(UUID().uuidString)",
                legacyServices: [],
                backend: VisualCapturePreferencesTestsKeychainBackend()
            ),
            flushDelayNanoseconds: 0
        )
    }
}

private final class VisualCapturePreferencesTestsKeychainBackend: KeychainStoreBackend {
    private var storage: [String: [String: Data]] = [:]
    func set(_ value: Data, service: String, account: String) throws { storage[service, default: [:]][account] = value }
    func data(for service: String, account: String, allowUserInteraction _: Bool) throws -> Data? { storage[service]?[account] }
    func delete(service: String, account: String) throws { storage[service]?[account] = nil }
}
