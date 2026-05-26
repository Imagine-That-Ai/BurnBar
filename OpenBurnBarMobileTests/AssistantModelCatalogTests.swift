import XCTest
import OpenBurnBarCore
@testable import OpenBurnBarMobile

@MainActor
final class AssistantModelCatalogTests: XCTestCase {
    func test_cliRuntimesDoNotExposeBundledCatalogs() {
        XCTAssertTrue(AssistantModelCatalog.options(for: .codex).isEmpty)
        XCTAssertTrue(AssistantModelCatalog.options(for: .claude).isEmpty)
        XCTAssertTrue(AssistantModelCatalog.options(for: .droid).isEmpty)
        XCTAssertTrue(AssistantModelCatalog.options(for: .forge).isEmpty)
    }

    func test_cliPreferencesPreserveDroidNativeModelIDsExactly() {
        let suiteName = "AssistantModelCatalogTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        CLIAgentModelPreferences.setPreferredModelID("glm-5", for: .droid, defaults: defaults)

        XCTAssertEqual(CLIAgentModelPreferences.preferredModelID(for: .droid, defaults: defaults), "glm-5")
        XCTAssertNil(CLIAgentModelPreferences.preferredOption(for: .droid, defaults: defaults))
        XCTAssertEqual(
            try CLIAgentModelPreferences.validatedPreferredModelID(
                for: .droid,
                defaults: defaults,
                options: [
                    AssistantModelOption(
                        providerID: "factory",
                        providerName: "Droid Core quota",
                        modelID: "glm-5",
                        displayName: "Droid Core (GLM-5)",
                        cliSource: .droidCoreQuota
                    )
                ]
            ),
            "glm-5"
        )
    }

    func test_cliPreferenceValidationMigratesAliasOnlyAfterLiveCatalogMatch() throws {
        let suiteName = "AssistantModelCatalogTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("gpt-5-5", forKey: "assistants.preferredModelID.codex")

        XCTAssertEqual(CLIAgentModelPreferences.preferredModelID(for: .codex, defaults: defaults), "gpt-5-5")
        XCTAssertEqual(
            try CLIAgentModelPreferences.validatedPreferredModelID(
                for: .codex,
                defaults: defaults,
                options: [
                    AssistantModelOption(
                        providerID: "openai",
                        providerName: "OpenAI",
                        modelID: "gpt-5.5",
                        displayName: "GPT-5.5",
                        cliSource: .cliProfile
                    )
                ]
            ),
            "gpt-5.5"
        )
        XCTAssertEqual(CLIAgentModelPreferences.preferredModelID(for: .codex, defaults: defaults), "gpt-5.5")
    }

    func test_staleCliPreferenceDoesNotMasqueradeAsDefaultModel() {
        let suiteName = "AssistantModelCatalogTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        CLIAgentModelPreferences.setPreferredModelID("droid-core-4", for: .droid, defaults: defaults)

        XCTAssertEqual(CLIAgentModelPreferences.preferredModelID(for: .droid, defaults: defaults), "droid-core-4")
        XCTAssertNil(CLIAgentModelPreferences.preferredOption(for: .droid, defaults: defaults))
        XCTAssertThrowsError(
            try CLIAgentModelPreferences.validatedPreferredModelID(
                for: .droid,
                defaults: defaults,
                options: [
                    AssistantModelOption(
                        providerID: "factory",
                        providerName: "Droid Core quota",
                        modelID: "glm-5",
                        displayName: "Droid Core (GLM-5)",
                        cliSource: .droidCoreQuota
                    )
                ]
            )
        )
    }

    func test_openClawCatalogIsLiveOnly() {
        XCTAssertTrue(AssistantModelCatalog.options(for: .openClaw).isEmpty)
    }
}
