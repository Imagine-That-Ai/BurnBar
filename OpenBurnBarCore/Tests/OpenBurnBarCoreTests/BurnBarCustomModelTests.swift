import XCTest
@testable import OpenBurnBarCore

/// Contract tests for `BurnBarCustomModel` and the `BurnBarProviderSettings`
/// custom-model surface. Custom models are the user escape hatch for
/// advertising a provider model the bundled catalog does not know about, so
/// their validation, normalization, mutation, and Codable shape are part of the
/// daemon's stored config contract.
final class BurnBarCustomModelTests: XCTestCase {
    func testIsValidModelID_acceptsProviderStyleIDsAndRejectsSpaces() {
        XCTAssertTrue(BurnBarCustomModel.isValidModelID("minimax-m3"))
        XCTAssertTrue(BurnBarCustomModel.isValidModelID("glm-5.1"))
        XCTAssertTrue(BurnBarCustomModel.isValidModelID("kimi-k2.6:cloud"))
        XCTAssertTrue(BurnBarCustomModel.isValidModelID("moonshotai/Kimi-K2.6"))
        XCTAssertFalse(BurnBarCustomModel.isValidModelID(""))
        XCTAssertFalse(BurnBarCustomModel.isValidModelID("   "))
        XCTAssertFalse(BurnBarCustomModel.isValidModelID("has space"))
        XCTAssertFalse(BurnBarCustomModel.isValidModelID("emoji-🤖"))
    }

    func testNormalizedDisplayName_fallsBackToModelID() {
        XCTAssertEqual(
            BurnBarCustomModel.normalizedDisplayName(modelID: "minimax-m3", displayName: "  "),
            "minimax-m3"
        )
        XCTAssertEqual(
            BurnBarCustomModel.normalizedDisplayName(modelID: "minimax-m3", displayName: " MiniMax M3 "),
            "MiniMax M3"
        )
    }

    func testUpsertCustomModel_insertsThenReplacesCaseInsensitivelyAndKeepsCreatedAt() {
        var settings = BurnBarProviderSettings(
            providerID: "minimax",
            baseURL: "https://api.minimax.io/v1",
            preferredModelIDs: ["minimax-m2.7-highspeed"]
        )
        settings.upsertCustomModel(BurnBarCustomModel(modelID: "minimax-m3", displayName: "MiniMax M3"))
        XCTAssertEqual(settings.customModels.count, 1)
        let created = settings.customModels[0].createdAt

        // Re-adding the same id (different casing) replaces in place, preserving createdAt.
        settings.upsertCustomModel(BurnBarCustomModel(modelID: "MINIMAX-M3", displayName: "Renamed"))
        XCTAssertEqual(settings.customModels.count, 1)
        XCTAssertEqual(settings.customModels[0].displayName, "Renamed")
        XCTAssertEqual(settings.customModels[0].createdAt, created)
    }

    func testRemoveCustomModel_isCaseInsensitiveAndReportsWhetherRemoved() {
        var settings = BurnBarProviderSettings(
            providerID: "zai",
            baseURL: "https://api.z.ai/api/coding/paas/v4",
            preferredModelIDs: ["glm-5"],
            customModels: [BurnBarCustomModel(modelID: "glm-5.1")]
        )
        XCTAssertNotNil(settings.customModel(forModelID: "GLM-5.1"))
        XCTAssertTrue(settings.removeCustomModel(modelID: "GLM-5.1"))
        XCTAssertNil(settings.customModel(forModelID: "glm-5.1"))
        XCTAssertFalse(settings.removeCustomModel(modelID: "glm-5.1"))
    }

    func testNormalization_dropsInvalidIDsAndDeduplicates() {
        let settings = BurnBarProviderSettings(
            providerID: "moonshot",
            baseURL: "https://api.moonshot.ai/v1",
            preferredModelIDs: [],
            customModels: [
                BurnBarCustomModel(modelID: "kimi-k2.6"),
                BurnBarCustomModel(modelID: "KIMI-K2.6"),   // dup (case-insensitive)
                BurnBarCustomModel(modelID: "bad id"),       // invalid (space)
                BurnBarCustomModel(modelID: "  ")            // invalid (empty)
            ]
        )
        XCTAssertEqual(settings.customModels.map(\.modelID), ["kimi-k2.6"])
    }

    func testCodable_roundTripsCustomModels() throws {
        let settings = BurnBarProviderSettings(
            providerID: "minimax",
            baseURL: "https://api.minimax.io/v1",
            preferredModelIDs: ["minimax-m2.7-highspeed"],
            customModels: [BurnBarCustomModel(modelID: "minimax-m3", displayName: "MiniMax M3")]
        )
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(BurnBarProviderSettings.self, from: data)
        XCTAssertEqual(decoded.customModels, settings.customModels)
    }

    func testDecode_isBackwardCompatibleWhenCustomModelsKeyAbsent() throws {
        // Config written by an older daemon has no `customModels` key; it must
        // decode to an empty list rather than failing.
        let legacy = Data(#"""
        {
          "providerID": "zai",
          "isEnabled": true,
          "baseURL": "https://api.z.ai/api/coding/paas/v4",
          "preferredModelIDs": ["glm-5"]
        }
        """#.utf8)
        let decoded = try JSONDecoder().decode(BurnBarProviderSettings.self, from: legacy)
        XCTAssertTrue(decoded.customModels.isEmpty)
    }
}
