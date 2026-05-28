import XCTest
@testable import OpenBurnBarCore

final class BurnBarModelAliasContractTests: XCTestCase {

    func testValidAliasIDAcceptsGatewaySafeCharacters() {
        XCTAssertTrue(BurnBarModelAlias.isValidAliasID("my-fast-coder"))
        XCTAssertTrue(BurnBarModelAlias.isValidAliasID("gpt-5.4:preview"))
        XCTAssertTrue(BurnBarModelAlias.isValidAliasID("anthropic/claude-opus"))
        XCTAssertFalse(BurnBarModelAlias.isValidAliasID("has space"))
        XCTAssertFalse(BurnBarModelAlias.isValidAliasID(""))
    }

    func testUpsertReplacesExistingAliasWithSameID() {
        var settings = BurnBarProviderSettings(
            providerID: "anthropic",
            isEnabled: true,
            baseURL: "https://api.anthropic.com/v1",
            preferredModelIDs: []
        )

        let now = Date()
        let original = BurnBarModelAlias(
            aliasID: "my-opus",
            baseModelID: "claude-opus-4-7",
            displayName: "My Opus",
            hidesBaseModel: false,
            createdAt: now,
            updatedAt: now
        )
        settings.upsertModelAlias(original)
        XCTAssertEqual(settings.modelAliases.count, 1)

        let replacement = BurnBarModelAlias(
            aliasID: "my-opus",
            baseModelID: "claude-opus-4-7",
            displayName: "Renamed Opus",
            hidesBaseModel: true,
            createdAt: now,
            updatedAt: now.addingTimeInterval(60)
        )
        settings.upsertModelAlias(replacement)
        XCTAssertEqual(settings.modelAliases.count, 1)
        XCTAssertEqual(settings.modelAliases.first?.displayName, "Renamed Opus")
        XCTAssertTrue(settings.modelAliases.first?.hidesBaseModel ?? false)
    }

    func testRemoveAliasClearsByID() {
        var settings = BurnBarProviderSettings(
            providerID: "openai",
            isEnabled: true,
            baseURL: "https://api.openai.com/v1",
            preferredModelIDs: []
        )
        let now = Date()
        settings.upsertModelAlias(BurnBarModelAlias(
            aliasID: "my-codex",
            baseModelID: "gpt-5.3-codex",
            displayName: "My Codex",
            createdAt: now,
            updatedAt: now
        ))
        XCTAssertEqual(settings.modelAliases.count, 1)

        let removed = settings.removeModelAlias(aliasID: "my-codex")
        XCTAssertTrue(removed)
        XCTAssertEqual(settings.modelAliases.count, 0)
    }

    func testNormalizationDropsAliasEqualToBaseModelID() {
        var settings = BurnBarProviderSettings(
            providerID: "anthropic",
            isEnabled: true,
            baseURL: "https://api.anthropic.com/v1",
            preferredModelIDs: []
        )
        settings.upsertModelAlias(BurnBarModelAlias(
            aliasID: "claude-opus-4-7",
            baseModelID: "claude-opus-4-7"
        ))
        XCTAssertEqual(settings.modelAliases.count, 0)
    }

    func testProviderSettingsCodableRoundTripIncludesAliases() throws {
        var settings = BurnBarProviderSettings(
            providerID: "anthropic",
            isEnabled: true,
            baseURL: "https://api.anthropic.com/v1",
            preferredModelIDs: []
        )
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        settings.upsertModelAlias(BurnBarModelAlias(
            aliasID: "my-opus",
            baseModelID: "claude-opus-4-7",
            displayName: "My Opus",
            hidesBaseModel: true,
            createdAt: now,
            updatedAt: now
        ))

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(settings)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(BurnBarProviderSettings.self, from: data)
        XCTAssertEqual(restored.modelAliases.count, 1)
        XCTAssertEqual(restored.modelAliases.first?.aliasID, "my-opus")
        XCTAssertTrue(restored.modelAliases.first?.hidesBaseModel ?? false)
    }

    func testProviderSettingsDecodingTreatsMissingAliasesAsEmpty() throws {
        let legacyJSON = """
        {
            "providerID": "openai",
            "isEnabled": true,
            "baseURL": "https://api.openai.com/v1",
            "preferredModelIDs": [],
            "disabledAdvertisedModelIDs": [],
            "credentialSlots": []
        }
        """
        let data = Data(legacyJSON.utf8)
        let settings = try JSONDecoder().decode(BurnBarProviderSettings.self, from: data)
        XCTAssertEqual(settings.modelAliases.count, 0)
    }

    func testAliasesForBaseModelIDFiltersCaseInsensitively() {
        var settings = BurnBarProviderSettings(
            providerID: "openai",
            isEnabled: true,
            baseURL: "https://api.openai.com/v1",
            preferredModelIDs: []
        )
        settings.upsertModelAlias(BurnBarModelAlias(aliasID: "alias-a", baseModelID: "gpt-5.3-codex"))
        settings.upsertModelAlias(BurnBarModelAlias(aliasID: "alias-b", baseModelID: "gpt-5.3-codex"))

        XCTAssertEqual(settings.aliases(forBaseModelID: "GPT-5.3-CODEX").count, 2)
        XCTAssertEqual(settings.aliases(forBaseModelID: "claude-opus-4-7").count, 0)
    }
}
