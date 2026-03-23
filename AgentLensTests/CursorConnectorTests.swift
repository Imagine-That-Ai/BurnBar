import XCTest
@testable import BurnBar

@MainActor
final class CursorConnectorTests: XCTestCase {

    func test_connectorProvider_defaults_comeFromCatalog() {
        XCTAssertEqual(ConnectorProvider.zai.displayName, "Z.ai")
        XCTAssertEqual(ConnectorProvider.zai.defaultBaseURL, "https://api.z.ai/api/coding/paas/v4")
        XCTAssertEqual(ConnectorProvider.zai.suggestedModels, ["glm-5-turbo", "glm-5"])

        XCTAssertEqual(ConnectorProvider.minimax.displayName, "MiniMax")
        XCTAssertEqual(ConnectorProvider.minimax.defaultBaseURL, "https://api.minimax.io/v1")
        XCTAssertEqual(ConnectorProvider.minimax.suggestedModels, ["minimax-m2.7-highspeed"])
    }

    func test_supportedModel_allowsSupportedProvidersOnly() {
        XCTAssertTrue(CursorConnectorManager.supportedModel("glm-5"))
        XCTAssertTrue(CursorConnectorManager.supportedModel("MiniMax-M2.7-highspeed"))
        XCTAssertTrue(CursorConnectorManager.supportedModel("MiniMax-M3-pro"))
        XCTAssertFalse(CursorConnectorManager.supportedModel("kimi-for-coding"))
        XCTAssertFalse(CursorConnectorManager.supportedModel("pony-alpha-2"))
        XCTAssertFalse(CursorConnectorManager.supportedModel("claude-3-7-sonnet"))
        XCTAssertFalse(CursorConnectorManager.supportedModel(""))
    }

    func test_supportedModel_respectsProviderCatalogMatchers() {
        XCTAssertTrue(CursorConnectorManager.supportedModel("glm-5-plus", provider: .zai))
        XCTAssertTrue(CursorConnectorManager.supportedModel("MiniMax-M3-pro", provider: .minimax))
        XCTAssertFalse(CursorConnectorManager.supportedModel("MiniMax-M3-pro", provider: .zai))
    }

    func test_modelPricing_usesCatalogWithSharedFallback() {
        let zaiPricing = ModelPricing.lookup(model: "glm-5")
        XCTAssertEqual(zaiPricing.inputPerMToken, 0.07, accuracy: 0.001)
        XCTAssertEqual(zaiPricing.outputPerMToken, 0.07, accuracy: 0.001)

        let fallbackPricing = ModelPricing.lookup(model: "unknown-model")
        XCTAssertEqual(fallbackPricing.inputPerMToken, 2.5, accuracy: 0.001)
        XCTAssertEqual(fallbackPricing.outputPerMToken, 10, accuracy: 0.001)
        XCTAssertEqual(fallbackPricing.cacheReadPerMToken, 1.25, accuracy: 0.001)
    }

    func test_exposedModels_deduplicatesSelectionAndCustomValues() {
        let config = ConnectorProviderConfig(
            id: .zai,
            enabled: true,
            selectedModels: ["glm-5", "glm-5-turbo", "glm-5"],
            customModels: ["glm-5-turbo", "glm-5-plus"]
        )

        XCTAssertEqual(config.exposedModels, ["glm-5", "glm-5-turbo", "glm-5-plus"])
    }

    func test_cursorConnectorConfig_onlyIncludesEnabledProviders() {
        let config = CursorConnectorConfig(
            providerConfigs: [
                ConnectorProviderConfig(
                    id: .zai,
                    enabled: true,
                    selectedModels: ["glm-5"],
                    customModels: ["glm-5-turbo"]
                ),
                ConnectorProviderConfig(
                    id: .minimax,
                    enabled: false,
                    selectedModels: ["MiniMax-M2.7-highspeed"]
                )
            ]
        )

        XCTAssertEqual(config.exposedModels, ["glm-5", "glm-5-turbo"])
    }
}
