import XCTest
@testable import OpenBurnBar

/// Tests for `SettingsActionRegistry`: the typed, whitelisted mutation system
/// that powers the Settings Copilot. Verifies:
/// - Every action in the catalog resolves to an `Action` descriptor
/// - Actions mutate the correct `SettingsManager` properties
/// - Unknown action IDs are rejected (whitelist enforcement)
/// - Secrets are NEVER writable through the registry
/// - Navigation-only actions change the router's selected tab
@MainActor
final class SettingsActionRegistryTests: XCTestCase {

    private var settings: SettingsManager!
    private var router: SettingsRouter!
    private var registry: SettingsActionRegistry!

    override func setUp() {
        super.setUp()
        settings = SettingsManager()
        router = SettingsRouter()
        registry = SettingsActionRegistry(settingsManager: settings, router: router)
    }

    // MARK: - Catalog coverage

    func test_everyCatalogEntryResolvesToAction() {
        for (id, description) in SettingsActionRegistry.actionCatalog {
            let action = registry.action(for: id)
            XCTAssertNotNil(action, "Catalog entry \(id) (\(description)) must resolve to an Action")
            XCTAssertEqual(action?.title.isEmpty, false, "Action \(id) must have a non-empty title")
            XCTAssertEqual(action?.detail.isEmpty, false, "Action \(id) must have a non-empty detail")
        }
    }

    func test_unknownActionIDReturnsNil() {
        XCTAssertNil(registry.action(for: "setMyPassword"))
        XCTAssertNil(registry.action(for: "deleteEverything"))
        XCTAssertNil(registry.action(for: ""))
    }

    // MARK: - Appearance mutations

    func test_setAppearanceDark() {
        settings.appearanceMode = .light
        registry.apply(actionID: "setAppearanceDark")
        XCTAssertEqual(settings.appearanceMode, .dark)
    }

    func test_setAppearanceLight() {
        settings.appearanceMode = .dark
        registry.apply(actionID: "setAppearanceLight")
        XCTAssertEqual(settings.appearanceMode, .light)
    }

    func test_setAppearanceSystem() {
        settings.appearanceMode = .dark
        registry.apply(actionID: "setAppearanceSystem")
        XCTAssertEqual(settings.appearanceMode, .system)
    }

    func test_setSkinAurora() {
        settings.appearanceSkin = .editorial
        registry.apply(actionID: "setSkinAurora")
        XCTAssertEqual(settings.appearanceSkin, .aurora)
    }

    func test_setSkinEditorial() {
        settings.appearanceSkin = .aurora
        registry.apply(actionID: "setSkinEditorial")
        XCTAssertEqual(settings.appearanceSkin, .editorial)
    }

    // MARK: - Toggle mutations

    func test_enableIndexing() {
        settings.conversationIndexingEnabled = false
        registry.apply(actionID: "enableIndexing")
        XCTAssertTrue(settings.conversationIndexingEnabled)
    }

    func test_enableModelProxy() {
        settings.gatewayEnabled = false
        registry.apply(actionID: "enableModelProxy")
        XCTAssertTrue(settings.gatewayEnabled)
    }

    func test_enableControllerRuntime() {
        settings.controllerRuntimeEnabled = false
        registry.apply(actionID: "enableControllerRuntime")
        XCTAssertTrue(settings.controllerRuntimeEnabled)
    }

    func test_enableAutoSummaries() {
        settings.autoSessionSummariesEnabled = false
        registry.apply(actionID: "enableAutoSummaries")
        XCTAssertTrue(settings.autoSessionSummariesEnabled)
    }

    func test_enableDailyDigest() {
        settings.dailyDigestEnabled = false
        registry.apply(actionID: "enableDailyDigest")
        XCTAssertTrue(settings.dailyDigestEnabled)
    }

    // MARK: - Interval mutations

    func test_setRefresh30s() {
        registry.apply(actionID: "setRefresh30s")
        XCTAssertEqual(settings.refreshInterval, 30)
    }

    func test_setRefresh1m() {
        registry.apply(actionID: "setRefresh1m")
        XCTAssertEqual(settings.refreshInterval, 60)
    }

    func test_setRefresh5m() {
        registry.apply(actionID: "setRefresh5m")
        XCTAssertEqual(settings.refreshInterval, 300)
    }

    // MARK: - Navigation

    func test_openAccountsNavigatesToAgentsTab() {
        router.selectedTab = .home
        registry.apply(actionID: "openAccounts")
        XCTAssertEqual(router.selectedTab, .agents)
    }

    func test_openModelProxyNavigatesToModelProxyTab() {
        router.selectedTab = .home
        registry.apply(actionID: "openModelProxy")
        XCTAssertEqual(router.selectedTab, .modelProxy)
    }

    func test_openAppearanceNavigatesToGeneralTab() {
        router.selectedTab = .home
        registry.apply(actionID: "openAppearance")
        XCTAssertEqual(router.selectedTab, .general)
    }

    // MARK: - Security: secrets are never writable

    func test_noSecretMutationActionsExist() {
        // Verify the catalog contains no actions that could set secrets.
        let secretPatterns = ["password", "token", "apiKey", "secret", "credential", "bearer"]
        for id in SettingsActionRegistry.actionCatalog.keys {
            for pattern in secretPatterns {
                XCTAssertFalse(
                    id.lowercased().contains(pattern),
                    "Action \(id) appears to reference a secret — secrets must never be writable through the registry"
                )
            }
        }
    }

    // MARK: - Settings snapshot

    func test_settingsSnapshotIncludesAllKeySettings() {
        let snapshot = registry.settingsSnapshot()
        XCTAssertTrue(snapshot.contains("Appearance mode:"), "Snapshot must include appearance mode")
        XCTAssertTrue(snapshot.contains("Skin:"), "Snapshot must include skin")
        XCTAssertTrue(snapshot.contains("Indexing:"), "Snapshot must include indexing")
        XCTAssertTrue(snapshot.contains("Model proxy:"), "Snapshot must include model proxy")
        XCTAssertTrue(snapshot.contains("Refresh interval:"), "Snapshot must include refresh interval")
    }
}
