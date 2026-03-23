import BurnBarCore
@testable import BurnBarDaemon
import Foundation
import XCTest

final class BurnBarProviderRouterTests: XCTestCase {
    func testRouterSelectsZAIForConfiguredGLMModel() async throws {
        let harness = try makeHarness(name: "zai")
        try await harness.configStore.setSecret("zai-key", for: "zai")
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "zai",
                isEnabled: true,
                baseURL: "https://api.z.ai/api/coding/paas/v4",
                preferredModelIDs: ["glm-5-turbo", "glm-5"]
            )
        )

        let route = try await harness.router.route(modelName: "glm-5-turbo")
        XCTAssertEqual(route.providerID, "zai")
        XCTAssertEqual(route.resolvedModelID, "glm-5-turbo")
        XCTAssertEqual(route.pricing, BurnBarCatalogLoader.bundledCatalog.pricing(forModelName: "glm-5-turbo"))
    }

    func testRouterSelectsMiniMaxForConfiguredModel() async throws {
        let harness = try makeHarness(name: "minimax")
        try await harness.configStore.setSecret("minimax-key", for: "minimax")
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "minimax",
                isEnabled: true,
                baseURL: "https://api.minimax.io/v1",
                preferredModelIDs: ["minimax-m2.7-highspeed"]
            )
        )

        let route = try await harness.router.route(modelName: "MiniMax-M2.7-highspeed")
        XCTAssertEqual(route.providerID, "minimax")
        XCTAssertEqual(route.resolvedModelID, "minimax-m2.7-highspeed")
    }

    func testRouterRejectsUnsupportedProviderModelsAndMissingCredentials() async throws {
        let harness = try makeHarness(name: "rejections")
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "zai",
                isEnabled: true,
                baseURL: "https://api.z.ai/api/coding/paas/v4",
                preferredModelIDs: ["glm-5"]
            )
        )

        do {
            _ = try await harness.router.route(modelName: "glm-5", preferredProviderID: "zai")
            XCTFail("Expected missing credential error")
        } catch let error as BurnBarProviderRouterError {
            guard case .missingCredential(let providerID) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(providerID, "zai")
        }

        try await harness.configStore.setSecret("zai-key", for: "zai")

        do {
            _ = try await harness.router.route(modelName: "kimi")
            XCTFail("Expected unsupported model error")
        } catch let error as BurnBarProviderRouterError {
            guard case .unsupportedModel(let modelName) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(modelName, "kimi")
        }

        do {
            _ = try await harness.router.route(modelName: "pony-alpha-2")
            XCTFail("Expected unsupported model error")
        } catch let error as BurnBarProviderRouterError {
            guard case .unsupportedModel(let modelName) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(modelName, "pony-alpha-2")
        }
    }

    private func makeHarness(name: String) throws -> BurnBarProviderRouterHarness {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("burnbar-provider-router-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let secretStore = BurnBarInMemorySecretStore()
        let configStore = BurnBarConfigStore(
            fileURL: rootURL.appendingPathComponent("provider-config.json", isDirectory: false),
            catalog: BurnBarCatalogLoader.bundledCatalog,
            secretStore: secretStore,
            logger: BurnBarDaemonLogger(category: "provider-router-tests")
        )

        return BurnBarProviderRouterHarness(
            rootURL: rootURL,
            configStore: configStore,
            router: BurnBarProviderRouter(
                configStore: configStore,
                logger: BurnBarDaemonLogger(category: "provider-router-tests")
            )
        )
    }
}

private struct BurnBarProviderRouterHarness {
    let rootURL: URL
    let configStore: BurnBarConfigStore
    let router: BurnBarProviderRouter
}
