import XCTest
import OpenBurnBarCore
@testable import OpenBurnBarMobile

@MainActor
final class OpenClawServiceTests: XCTestCase {

    func test_parsesOpenAIStyleModelsResponse() {
        let json = """
        {
          "object": "list",
          "data": [
            { "id": "qwen3-coder:30b", "object": "model", "owned_by": "ollama" },
            { "id": "llama3.3:70b",   "object": "model", "owned_by": "ollama" }
          ]
        }
        """.data(using: .utf8)!
        let parsed = OpenClawService.parseModels(data: json)
        XCTAssertEqual(parsed.map(\.modelID), ["qwen3-coder:30b", "llama3.3:70b"])
        XCTAssertEqual(parsed.first?.providerID, "ollama")
    }

    func test_emptyDataYieldsNoOptions() {
        let json = """
        { "object": "list", "data": [] }
        """.data(using: .utf8)!
        XCTAssertTrue(OpenClawService.parseModels(data: json).isEmpty)
    }

    func test_garbageJSONReturnsEmpty() {
        let body = Data("<<not json>>".utf8)
        XCTAssertTrue(OpenClawService.parseModels(data: body).isEmpty)
    }

    func test_dropsEntriesWithoutModelID() {
        let json = """
        {
          "data": [
            { "object": "model" },
            { "id": "", "object": "model" },
            { "id": "gemma3:27b", "object": "model" }
          ]
        }
        """.data(using: .utf8)!
        XCTAssertEqual(OpenClawService.parseModels(data: json).map(\.modelID),
                       ["gemma3:27b"])
    }

    func test_usesDisplayNameWhenProvided() {
        let json = """
        {
          "data": [
            { "id": "qwen3-coder:30b",
              "display_name": "Qwen 3 Coder 30B",
              "owned_by": "ollama" }
          ]
        }
        """.data(using: .utf8)!
        XCTAssertEqual(OpenClawService.parseModels(data: json).first?.displayName,
                       "Qwen 3 Coder 30B")
    }

    func test_selectModelPersistsToProvidedDefaults() {
        let defaults = UserDefaults(suiteName: "OpenClawServiceTests")!
        defaults.removePersistentDomain(forName: "OpenClawServiceTests")
        let service = OpenClawService(urlSession: .shared, defaults: defaults)
        let option = HermesRuntimeModelOption(
            providerID: "ollama",
            providerName: "Ollama",
            modelID: "qwen3-coder:30b",
            displayName: "Qwen 3 Coder 30B"
        )
        service.selectModel(option)
        XCTAssertEqual(service.selectedModelID, "qwen3-coder:30b")
        XCTAssertEqual(defaults.string(forKey: "openClaw.selectedModelID"),
                       "qwen3-coder:30b")
    }

    func test_selectModelResolvesLegacyCatalogAliasToLiveOpenClawModel() {
        let suiteName = "OpenClawServiceTests-alias-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let service = OpenClawService(urlSession: .shared, defaults: defaults)
        let live = HermesRuntimeModelOption(
            providerID: "openai",
            providerName: "OpenAI",
            modelID: "gpt-5.4-mini",
            displayName: "GPT-5.4 mini",
            routeEligible: true
        )
        service.modelOptions = [live]

        service.selectModel(HermesRuntimeModelOption(
            providerID: "openai",
            providerName: "OpenAI",
            modelID: "gpt-5-4-mini",
            displayName: "GPT-5.4 mini"
        ))

        XCTAssertEqual(service.selectedModelID, "gpt-5.4-mini")
        XCTAssertEqual(defaults.string(forKey: "openClaw.selectedModelID"), "gpt-5.4-mini")
    }

    func test_clearSelectedModelRemovesPersistedDefault() {
        let defaults = UserDefaults(suiteName: "OpenClawServiceTests-clear")!
        defaults.removePersistentDomain(forName: "OpenClawServiceTests-clear")
        let service = OpenClawService(urlSession: .shared, defaults: defaults)
        let option = HermesRuntimeModelOption(
            providerID: "ollama",
            providerName: "Ollama",
            modelID: "qwen3-coder:30b",
            displayName: "Qwen 3 Coder 30B"
        )

        service.selectModel(option)
        XCTAssertEqual(defaults.string(forKey: "openClaw.selectedModelID"),
                       "qwen3-coder:30b")

        service.clearSelectedModel()

        XCTAssertNil(service.selectedModelID)
        XCTAssertNil(defaults.string(forKey: "openClaw.selectedModelID"))
    }

    func test_validatedModelIDForMissionDispatchFailsWhenExplicitCatalogIsUnverified() {
        let defaults = UserDefaults(suiteName: "OpenClawServiceTests-unverified")!
        defaults.removePersistentDomain(forName: "OpenClawServiceTests-unverified")
        let service = OpenClawService(urlSession: .shared, defaults: defaults)
        let option = HermesRuntimeModelOption(
            providerID: "openai",
            providerName: "OpenAI",
            modelID: "gpt-5.5",
            displayName: "GPT-5.5"
        )

        service.modelOptions = [option]
        service.selectModel(option)
        service.modelOptions = []

        XCTAssertThrowsError(try service.validatedModelIDForMissionDispatch()) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Selected OpenClaw model 'gpt-5.5' has not been verified against this Mac OpenClaw harness catalog yet. Refresh the Mac OpenClaw gateway before sending, so the selected model is not silently rerouted."
            )
        }
    }

    func test_toggleFavoriteAddsAndRemoves() {
        let defaults = UserDefaults(suiteName: "OpenClawServiceTests-fav")!
        defaults.removePersistentDomain(forName: "OpenClawServiceTests-fav")
        let service = OpenClawService(urlSession: .shared, defaults: defaults)
        let option = HermesRuntimeModelOption(
            providerID: "ollama",
            providerName: "Ollama",
            modelID: "llama3.3:70b",
            displayName: "Llama 3.3 70B"
        )
        XCTAssertFalse(service.isFavoriteModel(option))
        service.toggleFavoriteModel(option)
        XCTAssertTrue(service.isFavoriteModel(option))
        service.toggleFavoriteModel(option)
        XCTAssertFalse(service.isFavoriteModel(option))
    }

    func test_cliAgentPreferredModelValidationReturnsSelectedCodexModelWhenCatalogStillAdvertisesIt() throws {
        let defaults = UserDefaults(suiteName: "CLIAgentPreferredModel-valid-\(UUID().uuidString)")!
        let option = AssistantModelOption(
            providerID: "openai",
            providerName: "OpenAI",
            modelID: "gpt-5.5",
            displayName: "GPT-5.5"
        )
        CLIAgentModelPreferences.setPreferredModelID("gpt-5-5", for: .codex, defaults: defaults)

        let modelID = try CLIAgentModelPreferences.validatedPreferredModelID(
            for: .codex,
            defaults: defaults,
            options: [option]
        )

        XCTAssertEqual(modelID, "gpt-5.5")
        XCTAssertEqual(
            CLIAgentModelPreferences.preferredModelID(for: .codex, defaults: defaults),
            "gpt-5.5"
        )
    }

    func test_cliAgentPreferredModelValidationFailsWhenSelectedCodexModelDisappears() {
        let defaults = UserDefaults(suiteName: "CLIAgentPreferredModel-missing-\(UUID().uuidString)")!
        let option = AssistantModelOption(
            providerID: "openai",
            providerName: "OpenAI",
            modelID: "gpt-5-4",
            displayName: "GPT-5.4"
        )
        CLIAgentModelPreferences.setPreferredModelID("glm-5-1", for: .codex, defaults: defaults)

        XCTAssertThrowsError(
            try CLIAgentModelPreferences.validatedPreferredModelID(
                for: .codex,
                defaults: defaults,
                options: [option]
            )
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Selected Codex model 'glm-5-1' is no longer advertised by this Mac Codex harness catalog. Pick an available model before sending, so the request is not silently rerouted."
            )
        }
    }

    func test_cliAgentPreferredModelValidationFailsWhenClaudeCatalogIsUnverified() {
        let defaults = UserDefaults(suiteName: "CLIAgentPreferredModel-unverified-\(UUID().uuidString)")!
        CLIAgentModelPreferences.setPreferredModelID("claude-opus-4-7", for: .claude, defaults: defaults)

        XCTAssertThrowsError(
            try CLIAgentModelPreferences.validatedPreferredModelID(
                for: .claude,
                defaults: defaults,
                options: []
            )
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Selected Claude model 'claude-opus-4-7' has not been verified against this Mac Claude harness catalog yet. Refresh the Mac Claude gateway before sending, so the selected model is not silently rerouted."
            )
        }
    }
}
