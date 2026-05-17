import XCTest
@testable import OpenBurnBarCore

final class BurnBarModelVariantContractTests: XCTestCase {

    func testThinkingLevelMappingsAreStable() {
        XCTAssertEqual(BurnBarThinkingLevel.low.anthropicBudgetTokens, 2048)
        XCTAssertEqual(BurnBarThinkingLevel.medium.anthropicBudgetTokens, 4096)
        XCTAssertEqual(BurnBarThinkingLevel.high.anthropicBudgetTokens, 8192)
        XCTAssertEqual(BurnBarThinkingLevel.xhigh.anthropicBudgetTokens, 16384)
        XCTAssertEqual(BurnBarThinkingLevel.max.anthropicBudgetTokens, 32768)

        XCTAssertEqual(BurnBarThinkingLevel.low.openAIEffort, "low")
        XCTAssertEqual(BurnBarThinkingLevel.medium.openAIEffort, "medium")
        XCTAssertEqual(BurnBarThinkingLevel.high.openAIEffort, "high")
        XCTAssertEqual(BurnBarThinkingLevel.xhigh.openAIEffort, "xhigh")
        XCTAssertEqual(BurnBarThinkingLevel.max.openAIEffort, "xhigh")
    }

    func testDefaultVariantIDFormat() {
        XCTAssertEqual(
            BurnBarModelVariant.defaultVariantID(baseModelID: "claude-opus-4-7", level: .xhigh),
            "claude-opus-4-7-xhigh"
        )
        XCTAssertEqual(
            BurnBarModelVariant.defaultVariantID(baseModelID: "gpt-5.3-codex", level: .high),
            "gpt-5.3-codex-high"
        )
    }

    func testUpsertReplacesExistingVariantWithSameID() {
        var settings = BurnBarProviderSettings(
            providerID: "anthropic",
            isEnabled: true,
            baseURL: "https://api.anthropic.com/v1",
            preferredModelIDs: []
        )

        let now = Date()
        let original = BurnBarModelVariant(
            variantID: "claude-opus-4-7-xhigh",
            label: BurnBarModelVariant.defaultLabel(for: .xhigh),
            baseModelID: "claude-opus-4-7",
            thinkingLevel: .xhigh,
            maxOutputTokens: nil,
            createdAt: now,
            updatedAt: now
        )
        settings.upsertModelVariant(original)
        XCTAssertEqual(settings.modelVariants.count, 1)

        let replacement = BurnBarModelVariant(
            variantID: "claude-opus-4-7-xhigh",
            label: "Custom label",
            baseModelID: "claude-opus-4-7",
            thinkingLevel: .xhigh,
            maxOutputTokens: 24_000,
            createdAt: now,
            updatedAt: now.addingTimeInterval(60)
        )
        settings.upsertModelVariant(replacement)
        XCTAssertEqual(settings.modelVariants.count, 1)
        XCTAssertEqual(settings.modelVariants.first?.maxOutputTokens, 24_000)
        XCTAssertEqual(settings.modelVariants.first?.label, "Custom label")
    }

    func testRemoveVariantClearsByID() {
        var settings = BurnBarProviderSettings(
            providerID: "openai",
            isEnabled: true,
            baseURL: "https://api.openai.com/v1",
            preferredModelIDs: []
        )
        let now = Date()
        let variant = BurnBarModelVariant(
            variantID: "gpt-5.3-codex-xhigh",
            label: BurnBarModelVariant.defaultLabel(for: .xhigh),
            baseModelID: "gpt-5.3-codex",
            thinkingLevel: .xhigh,
            maxOutputTokens: nil,
            createdAt: now,
            updatedAt: now
        )
        settings.upsertModelVariant(variant)
        XCTAssertEqual(settings.modelVariants.count, 1)

        let removed = settings.removeModelVariant(variantID: "gpt-5.3-codex-xhigh")
        XCTAssertTrue(removed)
        XCTAssertEqual(settings.modelVariants.count, 0)
    }

    func testProviderSettingsCodableRoundTripIncludesVariants() throws {
        var settings = BurnBarProviderSettings(
            providerID: "anthropic",
            isEnabled: true,
            baseURL: "https://api.anthropic.com/v1",
            preferredModelIDs: []
        )
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        settings.upsertModelVariant(BurnBarModelVariant(
            variantID: "claude-opus-4-7-max",
            label: "Max",
            baseModelID: "claude-opus-4-7",
            thinkingLevel: .max,
            maxOutputTokens: 16_000,
            createdAt: now,
            updatedAt: now
        ))

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(settings)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(BurnBarProviderSettings.self, from: data)
        XCTAssertEqual(restored.modelVariants.count, 1)
        XCTAssertEqual(restored.modelVariants.first?.thinkingLevel, .max)
        XCTAssertEqual(restored.modelVariants.first?.maxOutputTokens, 16_000)
    }

    func testProviderSettingsDecodingTreatsMissingVariantsAsEmpty() throws {
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
        XCTAssertEqual(settings.modelVariants.count, 0)
    }

    func testVariantsForBaseModelIDFiltersCaseInsensitively() {
        var settings = BurnBarProviderSettings(
            providerID: "openai",
            isEnabled: true,
            baseURL: "https://api.openai.com/v1",
            preferredModelIDs: []
        )
        let now = Date()
        for level in [BurnBarThinkingLevel.low, .high] {
            settings.upsertModelVariant(BurnBarModelVariant(
                variantID: BurnBarModelVariant.defaultVariantID(baseModelID: "gpt-5.3-codex", level: level),
                label: BurnBarModelVariant.defaultLabel(for: level),
                baseModelID: "gpt-5.3-codex",
                thinkingLevel: level,
                maxOutputTokens: nil,
                createdAt: now,
                updatedAt: now
            ))
        }

        XCTAssertEqual(settings.variants(forBaseModelID: "GPT-5.3-CODEX").count, 2)
        XCTAssertEqual(settings.variants(forBaseModelID: "claude-opus-4-7").count, 0)
    }
}
