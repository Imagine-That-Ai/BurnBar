import XCTest
@preconcurrency import OpenBurnBarCore
@testable import OpenBurnBar

@MainActor
final class HomeAssistantRecoveryWizardModelTests: XCTestCase {

    var session: URLSession!
    var configStore: InMemoryConfigStore!
    var tokenStore: InMemoryHomeAssistantTokenStore!

    override func setUp() async throws {
        try await super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HomeAssistantStubURLProtocol.self]
        session = URLSession(configuration: config)
        HomeAssistantStubURLProtocol.handler = nil
        configStore = InMemoryConfigStore()
        tokenStore = InMemoryHomeAssistantTokenStore()
    }

    // MARK: - Happy path

    func testHappyPath_probeTokenInstallTest() async throws {
        let dashURL = URL(string: "http://mac.local:8787/render.html")!
        let model = makeModel(dashboardURL: dashURL)

        // 1. start
        model.start()
        XCTAssertEqual(stepKey(model.step), "why")

        // 2. find instance
        model.goFindInstance()
        XCTAssertEqual(stepKey(model.step), "find")

        // 3. probe URL
        HomeAssistantStubURLProtocol.handler = { request in
            XCTAssertTrue(request.url?.absoluteString.hasSuffix("/api/") == true,
                          "expected probe to hit /api/, got \(request.url?.absoluteString ?? "nil")")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 401, httpVersion: nil,
                headerFields: ["X-HA-Version": "2026.5.0"]
            )!
            return (response, Data())
        }
        model.inputURLString = "homeassistant.local:8123"
        model.probeEnteredURL()
        await waitForStep(model, key: "connectToken")
        XCTAssertEqual(model.detectedVersion, "2026.5.0")

        // 4. validate token + load displays
        model.inputAccessToken = "access-token"
        HomeAssistantStubURLProtocol.handler = { request in
            let absolute = request.url?.absoluteString ?? ""
            if absolute.hasSuffix("/api/") {
                let r = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (r, "{\"message\":\"API running.\"}".data(using: .utf8)!)
            } else if absolute.hasSuffix("/api/states") {
                let r = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let json = """
                [
                  {"entity_id":"media_player.kitchen_display","state":"idle","attributes":{"friendly_name":"Kitchen Display","supported_features":512,"model_name":"Google Nest Hub"}}
                ]
                """
                return (r, json.data(using: .utf8)!)
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }
        model.validateToken()
        await waitForStep(model, key: "pickDisplay")

        // 5. pick the display
        guard case let .pickDisplay(_, players) = model.step else {
            return XCTFail("expected pickDisplay")
        }
        XCTAssertEqual(players.count, 1)
        model.pickDisplay(players[0])
        XCTAssertEqual(stepKey(model.step), "installRecovery")

        // 6. install
        HomeAssistantStubURLProtocol.handler = { request in
            if request.url?.path.hasPrefix("/api/config/automation/config/") == true {
                let r = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (r, "{\"result\":\"ok\"}".data(using: .utf8)!)
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }
        model.installRecovery()
        await waitForStep(model, key: "liveTest")

        // 7. live test
        HomeAssistantStubURLProtocol.handler = { request in
            if request.url?.path.hasPrefix("/api/webhook/") == true {
                let r = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (r, Data())
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }
        model.runLiveTest()
        await waitForStep(model, key: "done")

        guard case let .done(config) = model.step else { return XCTFail("expected done") }
        XCTAssertEqual(config.mediaPlayerEntityID, "media_player.kitchen_display")
        XCTAssertEqual(config.setupMode, .rest)
        XCTAssertTrue(config.lastTestPassed)
        XCTAssertNotNil(config.lastVerifiedAt)
        XCTAssertEqual(configStore.savedConfig?.mediaPlayerFriendlyName, "Kitchen Display")
    }

    // MARK: - Failure paths

    func testProbe_unreachable_movesToFailed() async throws {
        let model = makeModel()
        HomeAssistantStubURLProtocol.handler = { _ in throw URLError(.cannotFindHost) }
        model.inputURLString = "homeassistant.local:8123"
        model.probeEnteredURL()
        await waitForStep(model, key: "failed")
        guard case let .failed(message, _, previous) = model.step else { return XCTFail() }
        XCTAssertTrue(message.contains("Couldn't reach") || message.contains("not reach"))
        XCTAssertEqual(previous, .findInstance)
    }

    func testValidateToken_unauthorized_movesToFailed() async throws {
        let model = makeModel()
        HomeAssistantStubURLProtocol.handler = { request in
            let r = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (r, Data())
        }
        model.inputURLString = "homeassistant.local:8123"
        model.probeEnteredURL()
        await waitForStep(model, key: "connectToken")
        model.inputAccessToken = "bad"
        HomeAssistantStubURLProtocol.handler = { request in
            let r = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (r, Data())
        }
        model.validateToken()
        await waitForStep(model, key: "failed")
        guard case let .failed(message, _, previous) = model.step else { return XCTFail() }
        XCTAssertTrue(message.lowercased().contains("rejected"))
        XCTAssertEqual(previous, .connectToken)
    }

    func testInstallRecovery_404_jumpsToBlueprint() async throws {
        let model = makeModel()
        // Pre-stage state machine to .installRecovery
        HomeAssistantStubURLProtocol.handler = { request in
            if request.url?.absoluteString.hasSuffix("/api/") == true {
                let r = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
                return (r, Data())
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        model.inputURLString = "homeassistant.local:8123"
        model.probeEnteredURL()
        await waitForStep(model, key: "connectToken")
        HomeAssistantStubURLProtocol.handler = { request in
            let absolute = request.url?.absoluteString ?? ""
            if absolute.hasSuffix("/api/") {
                let r = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (r, "{}".data(using: .utf8)!)
            }
            if absolute.hasSuffix("/api/states") {
                let r = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let body = "[{\"entity_id\":\"media_player.k\",\"state\":\"idle\",\"attributes\":{\"friendly_name\":\"K\",\"supported_features\":512}}]"
                return (r, body.data(using: .utf8)!)
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }
        model.inputAccessToken = "tok"
        model.validateToken()
        await waitForStep(model, key: "pickDisplay")
        guard case let .pickDisplay(_, players) = model.step else { return XCTFail() }
        model.pickDisplay(players[0])

        // Now install fails with 404
        HomeAssistantStubURLProtocol.handler = { request in
            let r = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (r, Data())
        }
        model.installRecovery()
        await waitForStep(model, key: "blueprint")
    }

    // MARK: - Blueprint flow

    func testBlueprintFlow_savesConfig() async throws {
        let model = makeModel()
        model.inputURLString = "http://homeassistant.local:8123"
        // Manually bring model to blueprint step.
        model.chooseBlueprintFallback()
        guard case .blueprintIntro = model.step else { return XCTFail("expected blueprintIntro") }
        let config = model.saveBlueprintWebhook()
        XCTAssertNotNil(config)
        XCTAssertEqual(config?.setupMode, .blueprint)
        XCTAssertNotNil(config?.webhookURL)
        XCTAssertEqual(configStore.savedConfig?.setupMode, .blueprint)
    }

    // MARK: - Retry from failure

    func testRetryFromFailure_returnsToFindInstance() async throws {
        let model = makeModel()
        HomeAssistantStubURLProtocol.handler = { _ in throw URLError(.cannotFindHost) }
        model.inputURLString = "homeassistant.local"
        model.probeEnteredURL()
        await waitForStep(model, key: "failed")
        model.retryFromFailure()
        XCTAssertEqual(stepKey(model.step), "find")
    }

    // MARK: - Disconnect

    func testDisconnect_clearsTokenAndConfig() async throws {
        try tokenStore.saveAccessToken("abc")
        configStore.saveConfig(HomeAssistantConfig(
            baseURL: URL(string: "http://homeassistant.local:8123")!,
            webhookID: HomeAssistantWebhookID.generate()
        ))
        let model = makeModel()
        model.disconnect()
        XCTAssertNil(try tokenStore.loadAccessToken())
        XCTAssertNil(configStore.savedConfig)
    }

    // MARK: - Helpers

    private func makeModel(
        dashboardURL: URL = URL(string: "http://mac.local:8787/render.html")!
    ) -> HomeAssistantRecoveryWizardModel {
        let client = HomeAssistantClient(session: session)
        return HomeAssistantRecoveryWizardModel(
            client: client,
            tokenStore: tokenStore,
            configStore: configStore,
            suggestedFriendlyName: { "Kitchen Display" },
            dashboardURLProvider: { dashboardURL }
        )
    }

    private func waitForStep(
        _ model: HomeAssistantRecoveryWizardModel,
        key: String,
        timeout: TimeInterval = 3
    ) async {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if stepKey(model.step) == key { return }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTFail("timed out waiting for step \(key); current=\(stepKey(model.step))")
    }
}

// MARK: - In-memory config store

final class InMemoryConfigStore: HomeAssistantConfigStoring, @unchecked Sendable {
    private let queue = DispatchQueue(label: "openburnbar.ha.config-store.test")
    private var config: HomeAssistantConfig?
    private(set) var savedConfig: HomeAssistantConfig?
    private var legacyURL: String = ""

    func loadConfig() -> HomeAssistantConfig? { queue.sync { config } }

    func saveConfig(_ config: HomeAssistantConfig) {
        queue.sync {
            self.config = config
            self.savedConfig = config
            self.legacyURL = config.webhookURL?.absoluteString ?? ""
        }
    }

    func clear() {
        queue.sync {
            config = nil
            savedConfig = nil
            legacyURL = ""
        }
    }

    var legacyWebhookURLString: String { queue.sync { legacyURL } }
    func clearLegacyWebhookURL() { queue.sync { legacyURL = "" } }
}

// MARK: - Step key helper duplicated from view file

private func stepKey(_ step: HomeAssistantRecoveryWizardModel.Step) -> String {
    switch step {
    case .why: return "why"
    case .findInstance: return "find"
    case .probing: return "probing"
    case .connectToken: return "connectToken"
    case .validatingToken: return "validatingToken"
    case .pickDisplay: return "pickDisplay"
    case .loadingDisplays: return "loadingDisplays"
    case .installRecovery: return "installRecovery"
    case .installing: return "installing"
    case .liveTest: return "liveTest"
    case .testing: return "testing"
    case .done: return "done"
    case .blueprintIntro: return "blueprint"
    case .failed: return "failed"
    }
}
