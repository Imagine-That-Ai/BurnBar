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

    func test_renderPageUsesBurnBarLogoInTopLeftBrandSlot() throws {
        XCTAssertTrue(SmartHubBridgePage.html.contains(#"class="brand-logo" src="/brand-logo.svg" alt="OpenBurnBar""#))
        XCTAssertFalse(SmartHubBridgePage.html.contains(#"class="mark" aria-hidden="true""#))
        XCTAssertTrue(SmartHubBridgePage.brandLogoSVG.contains("<svg"))
        XCTAssertTrue(SmartHubBridgePage.brandLogoSVG.contains("#FEA41C"))
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

    // MARK: - Rich card payload

    func test_stateJSONEmitsHeaderTimestampAndStatus() throws {
        SmartHubBridgeServer.shared.updateSnapshot(
            SmartHubBridgeSnapshot(
                totalSpend: "$182.40",
                headline: "Showing last 5 hours",
                subheadline: "Updated at 9:42 PM",
                providers: [],
                headerTimestamp: "Thu, May 7  10:43 PM",
                headerStatus: "live provider pressure"
            )
        )

        let json = SmartHubBridgeServer.shared.renderStateJSONForTesting()
        XCTAssertTrue(json.contains("\"headerTimestamp\": \"Thu, May 7  10:43 PM\""))
        XCTAssertTrue(json.contains("\"headerStatus\": \"live provider pressure\""))
    }

    func test_stateJSONEmitsRichCardFieldsPerProvider() throws {
        let provider = SmartHubBridgeSnapshot.Provider(
            name: "Claude Code",
            percent: 18,
            label: "$120 / $300",
            tone: .ember,
            windowLabel: "5h",
            slug: "claudecode",
            accentHex: "CC785C",
            logoSVG: "<svg/>",
            tokenTotal: "5.4B",
            tokenTotalLabel: "TOKENS",
            statusPill: "source 3h ago",
            statusTone: .whimsy,
            freshnessLabel: "updated 3h ago",
            fetchedAtLabel: "May 7, 6:58 PM",
            buckets: [
                .init(name: "5-hour limit", percent: 8, headlineValue: "8%", subLabel: "92% left", resetsLabel: "Resets in 2h 14m · May 8, 3:35 AM", tone: .success),
                .init(name: "Weekly limit", percent: 18, headlineValue: "18%", subLabel: "82% left", resetsLabel: "Resets in 5d 6h · May 12, 12:00 AM", tone: .success)
            ],
            accounts: [
                .init(label: "Work", badge: "MAIN", tone: .whimsy, isActive: false),
                .init(label: "alberto8793@g…", badge: "ACTIVE", tone: .success, isActive: true)
            ],
            runsLabel: "1,002 runs",
            costLabel: "$5,835.40"
        )
        SmartHubBridgeServer.shared.updateSnapshot(
            SmartHubBridgeSnapshot(
                totalSpend: "$5,835.40",
                headline: "Showing last 5 hours",
                subheadline: "Updated at 9:42 PM",
                providers: [provider]
            )
        )

        let json = SmartHubBridgeServer.shared.renderStateJSONForTesting()
        XCTAssertTrue(json.contains("\"slug\":\"claudecode\""))
        XCTAssertTrue(json.contains("\"accentHex\":\"CC785C\""))
        XCTAssertTrue(json.contains("\"tokenTotal\":\"5.4B\""))
        XCTAssertTrue(json.contains("\"statusPill\":\"source 3h ago\""))
        XCTAssertTrue(json.contains("\"statusTone\":\"whimsy\""))
        XCTAssertTrue(json.contains("\"freshnessLabel\":\"updated 3h ago\""))
        XCTAssertTrue(json.contains("\"fetchedAtLabel\":\"May 7, 6:58 PM\""))
        XCTAssertTrue(json.contains("\"runsLabel\":\"1,002 runs\""))
        XCTAssertTrue(json.contains("\"costLabel\":\"$5,835.40\""))
        // Two bucket rows + two account rows must be emitted under the
        // nested arrays so the device can render them as multi-bar /
        // chip rows on the card.
        XCTAssertTrue(json.contains("\"5-hour limit\""))
        XCTAssertTrue(json.contains("\"Weekly limit\""))
        XCTAssertTrue(json.contains("\"badge\":\"MAIN\""))
        XCTAssertTrue(json.contains("\"badge\":\"ACTIVE\""))
        XCTAssertTrue(json.contains("\"isActive\":true"))
        // Both buckets must surface their `resetsLabel` to the page so the
        // Nest Hub can render the reset row beneath each bucket bar.
        XCTAssertTrue(json.contains("\"resetsLabel\":\"Resets in 2h 14m · May 8, 3:35 AM\""))
        XCTAssertTrue(json.contains("\"resetsLabel\":\"Resets in 5d 6h · May 12, 12:00 AM\""))
    }

    func test_stateJSONEmitsEmptyResetsLabelForBucketsWithoutResetTime() throws {
        // KiloCode-style buckets carry `resetsAt: nil`. The pipeline must
        // emit an empty `resetsLabel` (the page hides the row when empty)
        // rather than dropping the field, so the JSON shape stays stable
        // for the page's renderBucket() to switch on.
        let provider = SmartHubBridgeSnapshot.Provider(
            name: "KiloCode",
            percent: 0, label: "", tone: .mercury,
            buckets: [
                .init(name: "Daily", percent: 0, headlineValue: "", subLabel: "", resetsLabel: "", tone: .mercury)
            ]
        )
        SmartHubBridgeServer.shared.updateSnapshot(
            SmartHubBridgeSnapshot(
                totalSpend: "$0", headline: "", subheadline: "",
                providers: [provider]
            )
        )

        let json = SmartHubBridgeServer.shared.renderStateJSONForTesting()
        XCTAssertTrue(json.contains("\"resetsLabel\":\"\""))
    }

    func test_stateJSONLeavesRichFieldsOutWhenSnapshotIsLegacyShape() throws {
        // Legacy callers (NestHubMiniPreview, older unit tests) construct
        // providers without the rich card fields. The bridge must still
        // emit a parseable JSON document where the rich fields are present
        // as empty strings / empty arrays.
        SmartHubBridgeServer.shared.updateSnapshot(
            SmartHubBridgeSnapshot(
                totalSpend: "$0",
                headline: "Last 5h",
                subheadline: "",
                providers: [
                    .init(name: "Codex", percent: 50, label: "y", tone: .ember, windowLabel: "24h")
                ]
            )
        )

        let json = SmartHubBridgeServer.shared.renderStateJSONForTesting()
        XCTAssertTrue(json.contains("\"name\":\"Codex\""))
        XCTAssertTrue(json.contains("\"buckets\":[]"))
        XCTAssertTrue(json.contains("\"accounts\":[]"))
        XCTAssertTrue(json.contains("\"tokenTotal\":\"\""))
        XCTAssertTrue(json.contains("\"runsLabel\":\"\""))
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
