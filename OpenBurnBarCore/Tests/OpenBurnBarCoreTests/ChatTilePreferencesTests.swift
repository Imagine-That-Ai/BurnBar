import XCTest
@testable import OpenBurnBarCore

final class ChatTilePreferencesTests: XCTestCase {

    // MARK: - Defaults

    func testDefaultIncludesHermesAndPiTiles() {
        let prefs = ChatTilePreferences.default
        XCTAssertTrue(prefs.enabledTiles.contains(.hermes))
        XCTAssertTrue(prefs.enabledTiles.contains(.pi))
    }

    func testDefaultIncludesAllSixHermesSubProviders() {
        let prefs = ChatTilePreferences.default
        XCTAssertEqual(prefs.enabledHermesSubProviders.count, 6)
        for sub in HermesSubProvider.allCases {
            XCTAssertTrue(
                prefs.enabledHermesSubProviders.contains(sub),
                "Default visible set must include \(sub.rawValue)"
            )
        }
    }

    // MARK: - Round-trip

    func testJSONRoundTripIsLossless() {
        let original = ChatTilePreferences(
            enabledTiles: [.hermes, .codex, .openClaw],
            enabledHermesSubProviders: [.codex, .claude, .ollama]
        )
        let json = original.jsonString()
        let decoded = ChatTilePreferences.from(jsonString: json)
        XCTAssertEqual(decoded.enabledTiles, original.enabledTiles)
        XCTAssertEqual(decoded.enabledHermesSubProviders, original.enabledHermesSubProviders)
    }

    func testJSONShapeIsDeterministicAndSorted() {
        let prefs = ChatTilePreferences(
            enabledTiles: [.pi, .codex, .hermes],
            enabledHermesSubProviders: [.zai, .codex, .ollama]
        )
        let json = prefs.jsonString()
        // sortedKeys + value-sort means we know the exact shape.
        XCTAssertTrue(json.contains("\"hermesSubProviders\":[\"codex\",\"ollama\",\"zai\"]"))
        XCTAssertTrue(json.contains("\"tiles\":[\"codex\",\"hermes\",\"pi\"]"))
    }

    // MARK: - Decoder back-compat

    func testEmptyJSONDecodesToDefault() {
        let prefs = ChatTilePreferences.from(jsonString: "")
        XCTAssertEqual(prefs.enabledTiles, AssistantRuntimeID.defaultEnabledTiles)
        XCTAssertEqual(prefs.enabledHermesSubProviders, HermesSubProvider.defaultVisible)
    }

    func testGarbageJSONDecodesToDefault() {
        let prefs = ChatTilePreferences.from(jsonString: "{not json at all}")
        XCTAssertEqual(prefs.enabledTiles, AssistantRuntimeID.defaultEnabledTiles)
    }

    func testUnknownTileTokensAreDropped() {
        let json = #"{"tiles":["hermes","mystery"],"hermesSubProviders":["codex"]}"#
        let prefs = ChatTilePreferences.from(jsonString: json)
        XCTAssertEqual(prefs.enabledTiles, [.hermes])
        XCTAssertEqual(prefs.enabledHermesSubProviders, [.codex])
    }

    // MARK: - Sanitize guardrail

    func testSanitizeReturnsHermesWhenAllTilesDisabled() {
        let empty = ChatTilePreferences(enabledTiles: [], enabledHermesSubProviders: HermesSubProvider.defaultVisible)
        XCTAssertEqual(empty.sanitized().enabledTiles, [.hermes])
    }

    // MARK: - Ordering

    func testOrderedVisibleTilesMatchesCanonicalCaseOrder() {
        let prefs = ChatTilePreferences(
            enabledTiles: [.openClaw, .hermes, .codex],
            enabledHermesSubProviders: []
        )
        // AssistantRuntimeID.allCases order: hermes, pi, codex, claude, openClaw
        XCTAssertEqual(prefs.orderedVisibleTiles, [.hermes, .codex, .openClaw])
    }

    // MARK: - AssistantRuntimeID raw value stability (persistence contract)

    func testAssistantRuntimeIDRawValuesAreStable() {
        // These are persisted in UserDefaults / DataStore on every platform —
        // any change is a data migration.
        XCTAssertEqual(AssistantRuntimeID.hermes.rawValue, "hermes")
        XCTAssertEqual(AssistantRuntimeID.pi.rawValue, "pi")
        XCTAssertEqual(AssistantRuntimeID.codex.rawValue, "codex")
        XCTAssertEqual(AssistantRuntimeID.claude.rawValue, "claude")
        XCTAssertEqual(AssistantRuntimeID.openClaw.rawValue, "openclaw")
    }

    // MARK: - HermesSubProvider routing tokens

    func testFromProviderTokenIsCaseInsensitiveAndSpaceInsensitive() {
        XCTAssertEqual(HermesSubProvider.fromProviderToken("Codex"), .codex)
        XCTAssertEqual(HermesSubProvider.fromProviderToken("Z AI"), .zai)
        XCTAssertEqual(HermesSubProvider.fromProviderToken("MINIMAX"), .minimax)
        XCTAssertNil(HermesSubProvider.fromProviderToken("openai"))
    }
}
