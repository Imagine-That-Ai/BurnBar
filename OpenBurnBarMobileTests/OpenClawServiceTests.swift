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
}
