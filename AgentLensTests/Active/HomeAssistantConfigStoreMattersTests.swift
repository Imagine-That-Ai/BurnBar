import XCTest
@testable import OpenBurnBar

/// Behavioral coverage for the `try?` error-swallow that was judged to MATTER
/// in `HomeAssistantConfigStore.saveConfig`.
///
/// `saveConfig` is a persistence WRITE, not a best-effort read. The original
/// `guard let data = try? encoder.encode(config) ... else { return }` meant a
/// silent encode failure dropped the user's recovery configuration with no
/// signal — and the persisted value feeds later behavior (the recovery webhook
/// URL is mirrored into settings, last-verified state drives the wizard). The
/// fix converts the silent guard into a do/catch that logs the fault while
/// still skipping the dangerous partial write.
///
/// These tests assert:
///  - the happy path still round-trips every field (regression guard for the
///    refactor) and mirrors the webhook URL into the legacy field;
///  - a config without a webhook ID does NOT mirror a URL;
///  - an encode FAILURE does not corrupt previously-persisted state and does
///    not clobber the legacy webhook URL (the failed save is skipped, not
///    silently applied as an empty value).
@MainActor
final class HomeAssistantConfigStoreMattersTests: XCTestCase {

    private var settingsManager: SettingsManager!

    override func setUp() async throws {
        try await super.setUp()
        settingsManager = makeSettingsManager()
    }

    override func tearDown() async throws {
        settingsManager = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeConfig(webhookID: String = "openburnbar_cast_recover_abc123") -> HomeAssistantConfig {
        HomeAssistantConfig(
            baseURL: URL(string: "http://homeassistant.local:8123")!,
            mediaPlayerEntityID: "media_player.kitchen_display",
            mediaPlayerFriendlyName: "Kitchen Display",
            webhookID: webhookID,
            automationEntityID: "automation.openburnbar_smart_display_recovery",
            automationInstalled: true,
            lastTestPassed: true,
            lastVerifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            setupMode: .rest
        )
    }

    /// Config encoder that always throws, to drive the failure branch.
    private struct ThrowingConfigEncoder: HomeAssistantConfigEncoding {
        struct Boom: Error {}
        func encode(_ config: HomeAssistantConfig) throws -> Data {
            throw Boom()
        }
    }

    // MARK: - Happy path (refactor regression guard)

    func testSaveConfig_roundTripsAllFields() throws {
        let store = HomeAssistantConfigStore(settingsManager: settingsManager)
        let config = makeConfig()

        store.saveConfig(config)

        let loaded = try XCTUnwrap(store.loadConfig(), "A healthy save must persist and reload")
        XCTAssertEqual(loaded, config)
    }

    func testSaveConfig_mirrorsWebhookURLToLegacyField() {
        let store = HomeAssistantConfigStore(settingsManager: settingsManager)
        let config = makeConfig()

        store.saveConfig(config)

        XCTAssertEqual(
            store.legacyWebhookURLString,
            "http://homeassistant.local:8123/api/webhook/openburnbar_cast_recover_abc123",
            "A healthy save must mirror the webhook URL so legacy call sites keep working"
        )
    }

    func testSaveConfig_withoutWebhookID_doesNotMirrorURL() {
        let store = HomeAssistantConfigStore(settingsManager: settingsManager)

        store.saveConfig(makeConfig(webhookID: ""))

        XCTAssertEqual(store.legacyWebhookURLString, "", "No webhook ID means nothing to mirror")
    }

    // MARK: - Encode failure must be observable, not silently destructive

    func testSaveConfig_encodeFailure_doesNotCorruptPreviouslyPersistedConfig() throws {
        // First, persist a healthy config with a production store.
        let healthyStore = HomeAssistantConfigStore(settingsManager: settingsManager)
        let good = makeConfig()
        healthyStore.saveConfig(good)
        XCTAssertEqual(try XCTUnwrap(healthyStore.loadConfig()), good)

        // Now attempt a save through a store whose encoder always throws.
        let failingStore = HomeAssistantConfigStore(
            settingsManager: settingsManager,
            encoder: ThrowingConfigEncoder()
        )
        let attempted = makeConfig(webhookID: "openburnbar_cast_recover_REPLACEMENT")
        failingStore.saveConfig(attempted)

        // The failed save must be SKIPPED, not silently applied — the prior
        // persisted config and its mirrored webhook URL must be intact.
        let stillLoaded = try XCTUnwrap(
            failingStore.loadConfig(),
            "An encode failure must not erase the previously persisted config"
        )
        XCTAssertEqual(stillLoaded, good, "An encode failure must not partially overwrite the persisted config")
        XCTAssertEqual(
            failingStore.legacyWebhookURLString,
            "http://homeassistant.local:8123/api/webhook/openburnbar_cast_recover_abc123",
            "An encode failure must not clobber the previously mirrored webhook URL"
        )
    }

    func testSaveConfig_encodeFailureOnFreshStore_persistsNothing() {
        // No prior state: an encode failure must leave the store empty rather
        // than writing a partial/garbage value.
        let failingStore = HomeAssistantConfigStore(
            settingsManager: settingsManager,
            encoder: ThrowingConfigEncoder()
        )

        failingStore.saveConfig(makeConfig())

        XCTAssertNil(failingStore.loadConfig(), "A failed encode on a fresh store must persist nothing")
        XCTAssertEqual(
            failingStore.legacyWebhookURLString,
            "",
            "A failed encode must not mirror any webhook URL"
        )
    }

    // MARK: - clear()

    func testClear_resetsConfigAndLegacyURL() throws {
        let store = HomeAssistantConfigStore(settingsManager: settingsManager)
        store.saveConfig(makeConfig())
        XCTAssertNotNil(store.loadConfig())

        store.clear()

        XCTAssertNil(store.loadConfig(), "clear() must drop the persisted config")
        XCTAssertEqual(store.legacyWebhookURLString, "", "clear() must reset the legacy webhook URL")
    }
}
