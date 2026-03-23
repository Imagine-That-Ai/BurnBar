import BurnBarCore
@testable import BurnBarDaemon
import Foundation
import XCTest

final class BurnBarConfigStoreTests: XCTestCase {
    func testSnapshotDefaultsToSupportedProvidersOnly() async throws {
        let harness = try makeHarness(name: "defaults")
        let snapshot = try await harness.configStore.snapshot()

        XCTAssertEqual(snapshot.providers.map(\.providerID), ["zai", "minimax"])
        XCTAssertEqual(snapshot.providerSettings(id: "zai")?.preferredModelIDs, ["glm-5-turbo", "glm-5"])
        XCTAssertEqual(snapshot.providerSettings(id: "minimax")?.preferredModelIDs, ["minimax-m2.7-highspeed"])
    }

    func testResolvedConfigurationReflectsStoredCredentialAndBaseURLOverride() async throws {
        let harness = try makeHarness(name: "auth")

        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "zai",
                isEnabled: true,
                baseURL: "https://proxy.internal/zai",
                preferredModelIDs: ["glm-5"]
            )
        )
        try await harness.configStore.setSecret("zai-secret", for: "zai")

        let configuration = try await harness.configStore.resolvedConfiguration(for: "zai")
        XCTAssertTrue(configuration.settings.isEnabled)
        XCTAssertTrue(configuration.hasCredential)
        XCTAssertEqual(configuration.settings.baseURL, "https://proxy.internal/zai")
        XCTAssertEqual(configuration.preferredModels.map(\.id), ["glm-5"])
        XCTAssertEqual(configuration.apiKey, "zai-secret")
    }

    func testConfigStoreRejectsUnsupportedProviderAndModel() async throws {
        let harness = try makeHarness(name: "validation")

        do {
            _ = try await harness.configStore.upsertProvider(
                BurnBarProviderSettings(
                    providerID: "moonshot",
                    isEnabled: true,
                    baseURL: "https://api.moonshot.cn/v1",
                    preferredModelIDs: ["kimi-family"]
                )
            )
            XCTFail("Expected unsupported provider error")
        } catch let error as BurnBarConfigStoreError {
            guard case .unsupportedProvider(let providerID) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(providerID, "moonshot")
        }

        do {
            _ = try await harness.configStore.upsertProvider(
                BurnBarProviderSettings(
                    providerID: "zai",
                    isEnabled: true,
                    baseURL: "https://api.z.ai/api/coding/paas/v4",
                    preferredModelIDs: ["pony-alpha-2"]
                )
            )
            XCTFail("Expected unsupported model error")
        } catch let error as BurnBarConfigStoreError {
            guard case .unsupportedModel(let providerID, let modelID) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(providerID, "zai")
            XCTAssertEqual(modelID, "pony-alpha-2")
        }
    }

    private func makeHarness(name: String) throws -> BurnBarConfigStoreHarness {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("burnbar-config-store-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let secretStore = BurnBarInMemorySecretStore()
        let configStore = BurnBarConfigStore(
            fileURL: rootURL.appendingPathComponent("provider-config.json", isDirectory: false),
            catalog: BurnBarCatalogLoader.bundledCatalog,
            secretStore: secretStore,
            logger: BurnBarDaemonLogger(category: "config-store-tests")
        )
        return BurnBarConfigStoreHarness(rootURL: rootURL, configStore: configStore)
    }
}

private struct BurnBarConfigStoreHarness {
    let rootURL: URL
    let configStore: BurnBarConfigStore
}
