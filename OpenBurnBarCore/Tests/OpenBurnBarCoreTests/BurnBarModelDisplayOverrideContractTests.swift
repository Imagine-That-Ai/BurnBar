import XCTest
@testable import OpenBurnBarCore

/// Contract coverage for `BurnBarModelDisplayOverride` and the
/// `BurnBarProviderSettings` accessors that store verbatim model renames.
/// A display override relabels a model for humans while leaving its wire id
/// and routing untouched — the inverse of `BurnBarModelAlias`.
final class BurnBarModelDisplayOverrideContractTests: XCTestCase {

    private func anthropicSettings(
        overrides: [BurnBarModelDisplayOverride] = []
    ) -> BurnBarProviderSettings {
        BurnBarProviderSettings(
            providerID: "anthropic",
            isEnabled: true,
            baseURL: "https://api.anthropic.com",
            preferredModelIDs: ["claude-opus-4-7"],
            modelDisplayOverrides: overrides
        )
    }

    func testValidDisplayNameRejectsBlankInput() {
        XCTAssertTrue(BurnBarModelDisplayOverride.isValidDisplayName("Opus (work)"))
        XCTAssertTrue(BurnBarModelDisplayOverride.isValidDisplayName("  Opus  "))
        XCTAssertFalse(BurnBarModelDisplayOverride.isValidDisplayName(""))
        XCTAssertFalse(BurnBarModelDisplayOverride.isValidDisplayName("   \n\t"))
    }

    func testUpsertReplacesOverrideForSameModelCaseInsensitively() {
        var settings = anthropicSettings()
        settings.upsertModelDisplayOverride(
            BurnBarModelDisplayOverride(modelID: "claude-opus-4-7", displayName: "Smart")
        )
        XCTAssertEqual(settings.modelDisplayOverrides.count, 1)

        // Same model id with different casing must replace, not duplicate.
        settings.upsertModelDisplayOverride(
            BurnBarModelDisplayOverride(modelID: "CLAUDE-OPUS-4-7", displayName: "My Opus")
        )
        XCTAssertEqual(settings.modelDisplayOverrides.count, 1)
        XCTAssertEqual(settings.displayName(forModelID: "claude-opus-4-7"), "My Opus")
    }

    func testUpsertPreservesCreatedAtOnReplace() {
        var settings = anthropicSettings()
        let created = Date(timeIntervalSince1970: 1_000)
        settings.upsertModelDisplayOverride(
            BurnBarModelDisplayOverride(modelID: "claude-opus-4-7", displayName: "First", createdAt: created)
        )
        let firstCreatedAt = settings.modelDisplayOverrides.first?.createdAt
        settings.upsertModelDisplayOverride(
            BurnBarModelDisplayOverride(modelID: "claude-opus-4-7", displayName: "Second")
        )
        XCTAssertEqual(settings.modelDisplayOverrides.first?.createdAt, firstCreatedAt)
        XCTAssertEqual(settings.modelDisplayOverrides.first?.displayName, "Second")
    }

    func testRemoveOverrideClearsByModelID() {
        var settings = anthropicSettings(overrides: [
            BurnBarModelDisplayOverride(modelID: "claude-opus-4-7", displayName: "My Opus")
        ])
        XCTAssertEqual(settings.modelDisplayOverrides.count, 1)
        XCTAssertTrue(settings.removeModelDisplayOverride(modelID: "CLAUDE-OPUS-4-7"))
        XCTAssertEqual(settings.modelDisplayOverrides.count, 0)
        XCTAssertFalse(settings.removeModelDisplayOverride(modelID: "claude-opus-4-7"))
    }

    func testNormalizationDropsBlankAndTrimsValues() {
        let settings = anthropicSettings(overrides: [
            BurnBarModelDisplayOverride(modelID: "  claude-opus-4-7  ", displayName: "  My Opus  "),
            BurnBarModelDisplayOverride(modelID: "blank-name", displayName: "   "),
            BurnBarModelDisplayOverride(modelID: "", displayName: "no id")
        ])
        XCTAssertEqual(settings.modelDisplayOverrides.count, 1)
        let only = settings.modelDisplayOverrides.first
        XCTAssertEqual(only?.modelID, "claude-opus-4-7")
        XCTAssertEqual(only?.displayName, "My Opus")
    }

    func testDisplayNameLookupReturnsNilWhenAbsent() {
        let settings = anthropicSettings(overrides: [
            BurnBarModelDisplayOverride(modelID: "claude-opus-4-7", displayName: "My Opus")
        ])
        XCTAssertEqual(settings.displayName(forModelID: "claude-opus-4-7"), "My Opus")
        XCTAssertNil(settings.displayName(forModelID: "claude-sonnet-4-6"))
        XCTAssertNil(settings.displayName(forModelID: ""))
    }

    func testProviderSettingsCodableRoundTripIncludesOverrides() throws {
        let settings = anthropicSettings(overrides: [
            BurnBarModelDisplayOverride(modelID: "claude-opus-4-7", displayName: "My Opus")
        ])
        let data = try JSONEncoder().encode(settings)
        let restored = try JSONDecoder().decode(BurnBarProviderSettings.self, from: data)
        XCTAssertEqual(restored.modelDisplayOverrides.count, 1)
        XCTAssertEqual(restored.displayName(forModelID: "claude-opus-4-7"), "My Opus")
    }

    func testDecodingLegacyPayloadWithoutOverridesDefaultsToEmpty() throws {
        // A provider blob written before this feature shipped must still decode.
        let legacy = """
        {
            "providerID": "anthropic",
            "isEnabled": true,
            "baseURL": "https://api.anthropic.com",
            "preferredModelIDs": ["claude-opus-4-7"]
        }
        """.data(using: .utf8)!
        let restored = try JSONDecoder().decode(BurnBarProviderSettings.self, from: legacy)
        XCTAssertTrue(restored.modelDisplayOverrides.isEmpty)
    }
}
