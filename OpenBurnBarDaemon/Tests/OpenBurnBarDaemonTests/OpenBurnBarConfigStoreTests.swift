import OpenBurnBarCore
@testable import OpenBurnBarDaemon
import Foundation
import XCTest

final class BurnBarConfigStoreTests: XCTestCase {
    func testSnapshotDefaultsToAllCatalogProviders() async throws {
        let harness = try makeHarness(name: "defaults")
        let snapshot = try await harness.configStore.snapshot()

        // All catalog providers are now supported (not just zai/minimax)
        let providerIDs = snapshot.providers.map(\.providerID)
        XCTAssertTrue(providerIDs.contains("zai"), "Expected zai in defaults")
        XCTAssertTrue(providerIDs.contains("minimax"), "Expected minimax in defaults")
        XCTAssertTrue(providerIDs.contains("anthropic"), "Expected anthropic in defaults")
        XCTAssertTrue(providerIDs.contains("openai"), "Expected openai in defaults")
        XCTAssertEqual(snapshot.providerSettings(id: "zai")?.preferredModelIDs, ["glm-5-turbo", "glm-5"])
        XCTAssertEqual(snapshot.providerSettings(id: "minimax")?.preferredModelIDs, ["minimax-m2.7-highspeed"])
    }

    func testResolvedConfigurationReflectsStoredCredentialAndBaseURLOverride() async throws {
        let harness = try makeHarness(name: "auth")

        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "zai",
                isEnabled: true,
                baseURL: "https://proxy.example.com/zai",
                preferredModelIDs: ["glm-5"]
            )
        )
        try await harness.configStore.setSecret("zai-secret", for: "zai")

        let configuration = try await harness.configStore.resolvedConfiguration(for: "zai")
        XCTAssertTrue(configuration.settings.isEnabled)
        XCTAssertTrue(configuration.hasCredential)
        XCTAssertEqual(configuration.settings.baseURL, "https://proxy.example.com/zai")
        XCTAssertEqual(configuration.preferredModels.map(\.id), ["glm-5"])
        XCTAssertEqual(configuration.apiKey, "zai-secret")
    }

    func testConfigStoreRejectsUnsupportedModel() async throws {
        let harness = try makeHarness(name: "validation")

        // moonshot is now a supported catalog provider — upsert should succeed
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "moonshot",
                isEnabled: true,
                baseURL: "https://api.moonshot.cn/v1",
                preferredModelIDs: ["kimi-family"]
            )
        )

        // But unsupported models should still be rejected
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

    func testResolvedConfigurationMigratesLegacySecretToDefaultSlot() async throws {
        let harness = try makeHarness(name: "legacy-migration")
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "zai",
                isEnabled: true,
                baseURL: "https://api.z.ai/api/coding/paas/v4",
                preferredModelIDs: ["glm-5"]
            )
        )
        try await harness.configStore.setSecret("legacy-zai-key", for: "zai")

        let configuration = try await harness.configStore.resolvedConfiguration(for: "zai")
        XCTAssertEqual(configuration.credentialSlots.count, 1)
        XCTAssertEqual(configuration.credentialSlots.first?.slot.slotID, "default")
        XCTAssertEqual(configuration.credentialSlots.first?.apiKey, "legacy-zai-key")
        XCTAssertEqual(configuration.settings.preferredCredentialSlotID, "default")
    }

    private func makeHarness(name: String) throws -> BurnBarConfigStoreHarness {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-config-store-\(name)-\(UUID().uuidString)", isDirectory: true)
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
