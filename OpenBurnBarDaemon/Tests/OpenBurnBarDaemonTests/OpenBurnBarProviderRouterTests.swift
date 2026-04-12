import OpenBurnBarCore
@testable import OpenBurnBarDaemon
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

    func testRouterPrefersManualSlotThenFallsBackToRoundRobin() async throws {
        let harness = try makeHarness(name: "slots")
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "zai",
                isEnabled: true,
                baseURL: "https://api.z.ai/api/coding/paas/v4",
                preferredModelIDs: ["glm-5"]
            )
        )
        _ = try await harness.configStore.upsertCredentialSlot(
            providerID: "zai",
            slotID: "slot-a",
            label: "Plan A",
            apiKey: "zai-key-a"
        )
        _ = try await harness.configStore.upsertCredentialSlot(
            providerID: "zai",
            slotID: "slot-b",
            label: "Plan B",
            apiKey: "zai-key-b"
        )
        try await harness.configStore.recordCredentialSelection(providerID: "zai", slotID: "slot-a")
        try await harness.configStore.setPreferredCredentialSlot(providerID: "zai", slotID: nil)

        let roundRobinRoute = try await harness.router.route(modelName: "glm-5")
        XCTAssertEqual(roundRobinRoute.credentialSlotID, "slot-b")

        try await harness.configStore.setPreferredCredentialSlot(providerID: "zai", slotID: "slot-a")
        let preferredRoute = try await harness.router.route(modelName: "glm-5")
        XCTAssertEqual(preferredRoute.credentialSlotID, "slot-a")
    }

    func testRouterMarksQuotaFailureAsExhaustedSlot() async throws {
        let harness = try makeHarness(name: "failure-status")
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "zai",
                isEnabled: true,
                baseURL: "https://api.z.ai/api/coding/paas/v4",
                preferredModelIDs: ["glm-5"]
            )
        )
        _ = try await harness.configStore.upsertCredentialSlot(
            providerID: "zai",
            slotID: "slot-a",
            label: "Plan A",
            apiKey: "zai-key-a"
        )

        let route = try await harness.router.route(modelName: "glm-5")
        await harness.router.markRouteFailure(route, error: BurnBarProviderExecutorError.upstreamError(402, "quota exceeded"))

        let snapshot = try await harness.configStore.snapshot()
        let slotStatus = snapshot.providerSettings(id: "zai")?.credentialSlots.first(where: { $0.slotID == "slot-a" })?.status
        XCTAssertEqual(slotStatus, .exhausted)
    }

    private func makeHarness(name: String) throws -> BurnBarProviderRouterHarness {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-provider-router-\(name)-\(UUID().uuidString)", isDirectory: true)
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
