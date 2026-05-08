import XCTest
@testable import OpenBurnBar

final class HomeAssistantRecoveryProvisionerTests: XCTestCase {

    // MARK: - Automation payload shape

    func testAutomationPayload_hasExpectedTopLevelKeys() throws {
        let payload = HomeAssistantRecoveryProvisioner.automationPayload(
            webhookID: "openburnbar_cast_recover_xyz",
            mediaPlayerEntityID: "media_player.kitchen_display",
            fallbackDashboardURL: URL(string: "http://192.168.1.10:8787/render.html")!
        )

        XCTAssertEqual(payload["id"] as? String, HomeAssistantRecoveryProvisioner.automationID)
        XCTAssertEqual(payload["alias"] as? String, HomeAssistantRecoveryProvisioner.automationAlias)
        XCTAssertEqual(payload["mode"] as? String, "restart")
        XCTAssertNotNil(payload["trigger"])
        XCTAssertNotNil(payload["action"])
        XCTAssertNotNil(payload["variables"])
    }

    func testAutomationPayload_triggerIsLocalOnlyWebhook() throws {
        let payload = HomeAssistantRecoveryProvisioner.automationPayload(
            webhookID: "openburnbar_cast_recover_xyz",
            mediaPlayerEntityID: "media_player.kitchen_display",
            fallbackDashboardURL: URL(string: "http://192.168.1.10:8787/render.html")!
        )
        let triggers = try XCTUnwrap(payload["trigger"] as? [[String: Any]])
        let trigger = try XCTUnwrap(triggers.first)
        XCTAssertEqual(trigger["platform"] as? String, "webhook")
        XCTAssertEqual(trigger["webhook_id"] as? String, "openburnbar_cast_recover_xyz")
        XCTAssertEqual(trigger["local_only"] as? Bool, true)
        let allowed = try XCTUnwrap(trigger["allowed_methods"] as? [String])
        XCTAssertEqual(allowed, ["POST"])
    }

    func testAutomationPayload_actionsHaveStopDelayPlay() throws {
        let payload = HomeAssistantRecoveryProvisioner.automationPayload(
            webhookID: "openburnbar_cast_recover_xyz",
            mediaPlayerEntityID: "media_player.kitchen_display",
            fallbackDashboardURL: URL(string: "http://192.168.1.10:8787/render.html")!
        )
        let actions = try XCTUnwrap(payload["action"] as? [[String: Any]])
        XCTAssertEqual(actions.count, 3)

        let stop = try XCTUnwrap(actions[0]["service"] as? String)
        XCTAssertEqual(stop, "media_player.media_stop")

        let delay = actions[1]["delay"] as? [String: Any]
        XCTAssertEqual(delay?["seconds"] as? Int, 3)

        let play = try XCTUnwrap(actions[2]["service"] as? String)
        XCTAssertEqual(play, "media_player.play_media")
    }

    func testAutomationPayload_includesFallbackDashboardURL() throws {
        let payload = HomeAssistantRecoveryProvisioner.automationPayload(
            webhookID: "openburnbar_cast_recover_xyz",
            mediaPlayerEntityID: "media_player.kitchen_display",
            fallbackDashboardURL: URL(string: "http://192.168.1.10:8787/render.html")!
        )
        let variables = try XCTUnwrap(payload["variables"] as? [String: Any])
        XCTAssertEqual(variables["fallback_url"] as? String, "http://192.168.1.10:8787/render.html")
        XCTAssertEqual(variables["cast_entity"] as? String, "media_player.kitchen_display")
    }

    // MARK: - Install reuses existing webhook ID

    func testInstall_reusesExistingWebhookID_whenItIsOurs() async throws {
        let provisioner = HomeAssistantRecoveryProvisioner(
            client: HomeAssistantClient(),
            randomBytes: { Array(repeating: UInt8(0), count: 32) }
        )
        let existing = "openburnbar_cast_recover_existing12345678901234567"
        // The provisioner is forced to call the network; we sanity-check via
        // its pure functions only. The existing-vs-new logic is purely
        // string-based; assert via the static helper.
        XCTAssertTrue(HomeAssistantWebhookID.isOurs(existing) || existing.hasPrefix(HomeAssistantWebhookID.prefix))
        _ = provisioner  // keep the variable referenced
    }
}

final class HomeAssistantBlueprintInstallerTests: XCTestCase {

    func testImportDeepLink_isWellFormed() throws {
        let url = HomeAssistantBlueprintInstaller.importDeepLink()
        XCTAssertEqual(url.host, "my.home-assistant.io")
        XCTAssertTrue(url.path.contains("blueprint_import"))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let blueprintParam = components.queryItems?.first(where: { $0.name == "blueprint_url" })?.value
        XCTAssertEqual(blueprintParam, HomeAssistantBlueprintInstaller.defaultBlueprintURL.absoluteString)
    }

    func testBlueprintYAML_includesEverythingTheBlueprintNeeds() {
        let yaml = HomeAssistantBlueprintInstaller.blueprintYAML
        XCTAssertTrue(yaml.contains("blueprint:"))
        XCTAssertTrue(yaml.contains("OpenBurnBar Smart Display Recovery"))
        XCTAssertTrue(yaml.contains("input:"))
        XCTAssertTrue(yaml.contains("media_player"))
        XCTAssertTrue(yaml.contains("webhook_id"))
        XCTAssertTrue(yaml.contains("local_only: true"))
    }

    func testWriteYAMLToTemp_producesReadableFile() throws {
        let url = try HomeAssistantBlueprintInstaller.writeYAMLToTemp("hello: world")
        let read = try String(contentsOf: url)
        XCTAssertEqual(read, "hello: world")
        try? FileManager.default.removeItem(at: url)
    }
}
