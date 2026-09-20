import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import XCTest

/// Pure routing-policy checks for the inbox fallback walk. No SQLite, no
/// executor, no five-dimension scorer — those are why a dead DeepSeek pin
/// used to take ~90s before the analyst moved on.
final class BurnBarAIInboxRouteResolverTests: XCTestCase {
    func test_attemptsPutsThePinFirstThenLivePreferredModels() {
        let zai = makeResolved(
            id: "zai",
            local: false,
            enabled: true,
            apiKey: "zai-key",
            models: ["glm-5-turbo"]
        )
        let attempts = BurnBarAIInboxRouteResolver.attempts(
            config: BurnBarInboxConfig(
                enabled: true,
                analystProviderID: "deepseek",
                analystModel: "deepseek-chat"
            ),
            configurations: [zai]
        )

        XCTAssertEqual(attempts.map(\.providerID), ["deepseek", "openai", "zai"])
        XCTAssertEqual(attempts.map(\.modelName), ["deepseek-chat", "gpt-5.6-luna", "glm-5-turbo"])
    }

    func test_attemptsDoesNotWorldSearchAnUnpinnedModelName() {
        let zai = makeResolved(
            id: "zai",
            local: false,
            enabled: true,
            apiKey: "zai-key",
            models: ["glm-5-turbo"]
        )
        let attempts = BurnBarAIInboxRouteResolver.attempts(
            config: BurnBarInboxConfig(
                enabled: true,
                analystProviderID: "deepseek",
                analystModel: "deepseek-chat"
            ),
            configurations: [zai]
        )

        XCTAssertFalse(
            attempts.contains { $0.providerID == nil },
            "An unpinned model name lets the scorer pick Codex for 'deepseek-chat'"
        )
    }

    func test_aDeadPinIsSkippedWhenTheProviderIsNotInTheStore() {
        let error = BurnBarAIInboxRouteResolver.skipReason(
            for: .init(providerID: "deepseek", modelName: "deepseek-chat"),
            configurations: [
                makeResolved(id: "zai", local: false, enabled: true, apiKey: "zai-key", models: ["glm-5-turbo"])
            ]
        )

        guard let routed = error as? BurnBarProviderRouterError,
              case .unsupportedProvider(let providerID) = routed else {
            XCTFail("Expected unsupportedProvider, got \(String(describing: error))")
            return
        }
        XCTAssertEqual(providerID, "deepseek")
    }

    func test_aLocalCLIProviderIsRoutableWithoutAnAPIKey() {
        let codex = makeResolved(
            id: "codex",
            local: true,
            enabled: true,
            apiKey: nil,
            models: ["gpt-5.6-luna"]
        )
        XCTAssertTrue(BurnBarAIInboxRouteResolver.isRoutable(codex))
        XCTAssertNil(
            BurnBarAIInboxRouteResolver.skipReason(
                for: .init(providerID: "codex", modelName: "gpt-5.6-luna"),
                configurations: [codex]
            )
        )
    }

    func test_aCloudProviderWithoutAKeyIsNotRoutable() {
        let deepseek = makeResolved(
            id: "deepseek",
            local: false,
            enabled: true,
            apiKey: nil,
            models: ["deepseek-chat"]
        )
        XCTAssertFalse(BurnBarAIInboxRouteResolver.isRoutable(deepseek))
        let error = BurnBarAIInboxRouteResolver.skipReason(
            for: .init(providerID: "deepseek", modelName: "deepseek-chat"),
            configurations: [deepseek]
        )
        guard let routed = error as? BurnBarProviderRouterError,
              case .missingCredential(let providerID) = routed else {
            XCTFail("Expected missingCredential, got \(String(describing: error))")
            return
        }
        XCTAssertEqual(providerID, "deepseek")
    }

    private func makeResolved(
        id: String,
        local: Bool,
        enabled: Bool,
        apiKey: String?,
        models: [String]
    ) -> BurnBarResolvedProviderConfiguration {
        let pricing = BurnBarModelPricing(inputPerMToken: 1, outputPerMToken: 2, cacheReadPerMToken: 0.1)
        let catalogModels = models.map {
            BurnBarCatalogModel(id: $0, displayName: $0, visibility: .public, pricing: pricing)
        }
        return BurnBarResolvedProviderConfiguration(
            provider: BurnBarCatalogProvider(
                id: id,
                displayName: id,
                baseURL: "https://example.test/\(id)",
                visibility: .public,
                capabilities: [.routing],
                models: catalogModels,
                local: local
            ),
            settings: BurnBarProviderSettings(
                providerID: id,
                isEnabled: enabled,
                baseURL: "https://example.test/\(id)",
                preferredModelIDs: models
            ),
            preferredModels: catalogModels,
            credentialSlots: [],
            apiKey: apiKey
        )
    }
}
