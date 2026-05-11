import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

@MainActor
final class SmartHubBridgeServerSerializationTests: XCTestCase {

    override func tearDown() async throws {
        // Reset shared state so subsequent tests start clean.
        SmartHubBridgeServer.shared.updateDisplayConfig(.default)
        SmartHubBridgeServer.shared.updateSnapshot(.empty)
        try await super.tearDown()
    }

    func test_stateJSONContainsDisplayBlockWithPaletteAndTheme() throws {
        var config = SmartHubDisplayConfig.default
        config.palette = .mercury
        config.theme = .botanicalCream
        config.brightness = 0.7
        config.refreshCadenceSeconds = 12
        config.audibleCue = true
        SmartHubBridgeServer.shared.updateDisplayConfig(config)

        let json = SmartHubBridgeServer.shared.renderStateJSONForTesting()
        XCTAssertTrue(json.contains("\"palette\": \"mercury\""))
        XCTAssertTrue(json.contains("\"theme\": \"botanicalCream\""))
        XCTAssertTrue(json.contains("\"brightness\": 0.7"))
        XCTAssertTrue(json.contains("\"refreshCadenceSeconds\": 12"))
        XCTAssertTrue(json.contains("\"audibleCue\": true"))
    }

    func test_providerFilterNarrowsProvidersArray() throws {
        SmartHubBridgeServer.shared.updateSnapshot(
            SmartHubBridgeSnapshot(
                totalSpend: "$10",
                headline: "Last 5h",
                subheadline: "Updated just now",
                providers: [
                    .init(name: "Claude Code", percent: 50, label: "x", tone: .success, windowLabel: "5h"),
                    .init(name: "Codex", percent: 50, label: "y", tone: .ember, windowLabel: "24h")
                ]
            )
        )

        var config = SmartHubDisplayConfig.default
        config.providerIDs = ["claudecode"] // matches the persistedToken form
        SmartHubBridgeServer.shared.updateDisplayConfig(config)

        let json = SmartHubBridgeServer.shared.renderStateJSONForTesting()
        XCTAssertTrue(json.contains("Claude Code"))
        XCTAssertFalse(json.contains("Codex"))
    }

    func test_emptyProviderFilterRetainsAllProviders() throws {
        SmartHubBridgeServer.shared.updateSnapshot(
            SmartHubBridgeSnapshot(
                totalSpend: "$0",
                headline: "Last 5h",
                subheadline: "",
                providers: [
                    .init(name: "Claude Code", percent: 50, label: "x", tone: .success, windowLabel: "5h"),
                    .init(name: "Codex", percent: 50, label: "y", tone: .ember, windowLabel: "24h")
                ]
            )
        )
        SmartHubBridgeServer.shared.updateDisplayConfig(.default)

        let json = SmartHubBridgeServer.shared.renderStateJSONForTesting()
        XCTAssertTrue(json.contains("Claude Code"))
        XCTAssertTrue(json.contains("Codex"))
    }

    // MARK: - Schema-v2 backward compat

    func test_legacySmartHubConfigDecodesWithoutDisplayConfig() throws {
        let raw = """
        {
          "enabled": true,
          "dashboardURL": "http://127.0.0.1:8787/render.html",
          "timePeriod": "rolling5h",
          "schemaVersion": 2
        }
        """
        let data = Data(raw.utf8)
        // `publishedAt` is omitted intentionally — the decoder falls
        // back to `Date.distantPast` and treats v2 docs as missing the
        // new fields.
        let decoded = try JSONDecoder().decode(SmartHubConfig.self, from: data)
        XCTAssertNil(decoded.displayConfig)
        XCTAssertNil(decoded.displayOrder)
        XCTAssertEqual(decoded.schemaVersion, 2)
    }
}
