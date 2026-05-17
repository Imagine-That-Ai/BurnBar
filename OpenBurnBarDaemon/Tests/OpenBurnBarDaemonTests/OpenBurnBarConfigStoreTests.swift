import OpenBurnBarCore
@testable import OpenBurnBarDaemon
import Foundation
import XCTest
#if os(macOS)
import Security
#endif

final class BurnBarConfigStoreTests: XCTestCase {
    func testDaemonKeychainSecretStoresDisableSystemPromptsForBackgroundReads() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let gateSource = try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/OpenBurnBarDaemon/SecKeychainInteractionGate.swift"),
            encoding: .utf8
        )
        let connectorSource = try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/OpenBurnBarDaemon/OpenBurnBarConnectorSecretStore.swift"),
            encoding: .utf8
        )
        let providerSource = try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/OpenBurnBarDaemon/OpenBurnBarProviderExecutor.swift"),
            encoding: .utf8
        )
        let switcherSource = try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/OpenBurnBarDaemon/OpenBurnBarSwitcherShell.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(gateSource.contains("SecKeychainSetUserInteractionAllowed"))
        XCTAssertTrue(
            connectorSource.contains("withKeychainUserInteractionDisabled {\n            SecItemCopyMatching"),
            "Connector-plane keychain reads must not be able to show login-keychain prompts."
        )
        XCTAssertTrue(
            connectorSource.contains("withKeychainUserInteractionDisabled {\n                SecItemUpdate")
                && connectorSource.contains("withKeychainUserInteractionDisabled {\n                    SecItemAdd")
                && connectorSource.contains("withKeychainUserInteractionDisabled {\n                SecItemDelete"),
            "Connector-plane keychain writes must not be able to show login-keychain prompts."
        )
        XCTAssertTrue(
            providerSource.contains("withKeychainUserInteractionDisabled {\n            SecItemCopyMatching"),
            "Provider-router keychain reads must not be able to show login-keychain prompts."
        )
        XCTAssertTrue(
            providerSource.contains("withKeychainUserInteractionDisabled {\n                SecItemUpdate")
                && providerSource.contains("withKeychainUserInteractionDisabled {\n                    SecItemAdd")
                && providerSource.contains("withKeychainUserInteractionDisabled {\n                SecItemDelete"),
            "Provider-router keychain writes must not be able to show login-keychain prompts."
        )
        XCTAssertTrue(
            switcherSource.contains("withKeychainUserInteractionDisabled {\n            SecItemCopyMatching"),
            "Switcher keychain reads must not be able to show login-keychain prompts."
        )
    }

    func testSnapshotDefaultsToAllCatalogProviders() async throws {
        let harness = try makeHarness(name: "defaults")
        let snapshot = try await harness.configStore.snapshot()

        // All catalog providers are now supported (not just zai/minimax)
        let providerIDs = snapshot.providers.map(\.providerID)
        XCTAssertTrue(providerIDs.contains("zai"), "Expected zai in defaults")
        XCTAssertTrue(providerIDs.contains("minimax"), "Expected minimax in defaults")
        XCTAssertTrue(providerIDs.contains("ollama"), "Expected ollama in defaults")
        XCTAssertTrue(providerIDs.contains("anthropic"), "Expected anthropic in defaults")
        XCTAssertTrue(providerIDs.contains("openai"), "Expected openai in defaults")
        XCTAssertEqual(snapshot.routerMode, .providerFamilyFailover)
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

    func testResolvedConfigurationSkipsLegacySecretReadWhenSlotsExist() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-config-store-slotted-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let secretStore = SlotOnlySecretStore(
            providerID: "zai",
            slotID: "default",
            secret: "slot-zai-key"
        )
        let configStore = BurnBarConfigStore(
            fileURL: rootURL.appendingPathComponent("provider-config.json", isDirectory: false),
            catalog: BurnBarCatalogLoader.bundledCatalog,
            secretStore: secretStore,
            logger: BurnBarDaemonLogger(category: "config-store-tests")
        )

        _ = try await configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "zai",
                isEnabled: true,
                baseURL: "https://api.z.ai/api/coding/paas/v4",
                preferredModelIDs: ["glm-5-turbo"],
                preferredCredentialSlotID: "default",
                credentialSlots: [
                    BurnBarProviderCredentialSlot(
                        slotID: "default",
                        label: "Default",
                        isEnabled: true,
                        status: .ready
                    )
                ]
            )
        )

        let configuration = try await configStore.resolvedConfiguration(for: "zai")
        XCTAssertTrue(configuration.hasCredential)
        XCTAssertEqual(configuration.apiKey, "slot-zai-key")
        XCTAssertEqual(configuration.credentialSlots.first?.apiKey, "slot-zai-key")
    }

    func testKeychainSecretStoreFallsBackToHermesCredentialPoolWithoutPrompt() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-hermes-pool-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let authURL = rootURL.appendingPathComponent("auth.json", isDirectory: false)
        let authJSON = """
        {
          "credential_pool": {
            "minimax": [
              {
                "access_token": "minimax-from-hermes",
                "last_status": null
              }
            ]
          }
        }
        """
        try authJSON.data(using: .utf8)!.write(to: authURL, options: .atomic)

        let store = BurnBarKeychainSecretStore(
            service: "com.openburnbar.tests.missing.\(UUID().uuidString)",
            hermesCredentialPoolURL: authURL
        )

        let secret = try await store.secret(for: "minimax.slot.default")
        XCTAssertEqual(secret, "minimax-from-hermes")
    }

    #if os(macOS)
    func testKeychainSecretStoreReadsDaemonSlotWithoutGlobalInteractionGate() async throws {
        let service = "com.openburnbar.tests.keychain.\(UUID().uuidString)"
        let providerSlotKey = "zai.slot.default"
        let account = "provider.\(providerSlotKey).apiKey"
        defer {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            SecItemDelete(query as CFDictionary)
        }

        let store = BurnBarKeychainSecretStore(
            service: service,
            hermesCredentialPoolURL: nil
        )

        try await store.setSecret("zai-keychain-secret", for: providerSlotKey)

        let secret = try await store.secret(for: providerSlotKey)
        XCTAssertEqual(secret, "zai-keychain-secret")
    }

    func testKeychainSecretStorePrefersDaemonServiceAndCanReadLegacyService() async throws {
        let primaryService = "com.openburnbar.tests.keychain.primary.\(UUID().uuidString)"
        let legacyService = "com.openburnbar.tests.keychain.legacy.\(UUID().uuidString)"
        let providerSlotKey = "anthropic.slot.default"
        let account = "provider.\(providerSlotKey).apiKey"
        defer {
            for service in [primaryService, legacyService] {
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: account
                ]
                SecItemDelete(query as CFDictionary)
            }
        }

        try addKeychainSecret("legacy-secret", service: legacyService, account: account)
        let legacyOnlyStore = BurnBarKeychainSecretStore(
            service: primaryService,
            legacyServices: [legacyService],
            hermesCredentialPoolURL: nil
        )
        let legacySecret = try await legacyOnlyStore.secret(for: providerSlotKey)
        XCTAssertEqual(legacySecret, "legacy-secret")

        try await legacyOnlyStore.setSecret("daemon-secret", for: providerSlotKey)
        let daemonSecret = try await legacyOnlyStore.secret(for: providerSlotKey)
        XCTAssertEqual(daemonSecret, "daemon-secret")
    }
    #endif

    func testRouterModePersistsAndLegacySnapshotsDefaultSafely() async throws {
        let harness = try makeHarness(name: "router-mode")

        try await harness.configStore.setRouterMode(.intelligentModelRouter)
        let updated = try await harness.configStore.snapshot()
        XCTAssertEqual(updated.routerMode, .intelligentModelRouter)

        let legacyJSON = """
        {
          "providers": []
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(BurnBarProviderConfigurationSnapshot.self, from: legacyJSON)
        XCTAssertEqual(decoded.routerMode, .providerFamilyFailover)
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

#if os(macOS)
private func addKeychainSecret(_ secret: String, service: String, account: String) throws {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecValueData as String: Data(secret.utf8),
        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    ]
    let status = SecItemAdd(query as CFDictionary, nil)
    guard status == errSecSuccess else {
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
}
#endif

private struct BurnBarConfigStoreHarness {
    let rootURL: URL
    let configStore: BurnBarConfigStore
}

private actor SlotOnlySecretStore: BurnBarProviderSecretStoring {
    private let providerID: String
    private let slotID: String
    private let secret: String

    init(providerID: String, slotID: String, secret: String) {
        self.providerID = providerID
        self.slotID = slotID
        self.secret = secret
    }

    func secret(for providerID: String) async throws -> String? {
        if providerID == "\(self.providerID).slot.\(slotID)" {
            return secret
        }
        if providerID == self.providerID {
            throw NSError(
                domain: "SlotOnlySecretStore",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Legacy provider secret should not be read when credential slots exist."]
            )
        }
        return nil
    }

    func setSecret(_ secret: String?, for providerID: String) async throws {}
}
