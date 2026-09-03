import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import Foundation
import XCTest
#if os(macOS)
import Security
#endif

final class BurnBarConfigStoreTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // Keep the developer's real "Claude Code-credentials" Keychain item from leaking
        // into Claude Code fallback fixtures. CI runners have no such item; dev machines do.
        setenv("BURNBAR_DISABLE_CLAUDE_CODE_KEYCHAIN_FALLBACK", "1", 1)
    }

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
        let databaseCipherSource = try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/OpenBurnBarDaemon/BurnBarDaemonDatabaseCipher.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(gateSource.contains("SecKeychainSetUserInteractionAllowed"))
        func sourceWrapsSecurityCall(_ source: String, call: String) -> Bool {
            source.range(
                of: #"withKeychainUserInteractionDisabled\s*\{\s*\#(call)"#,
                options: .regularExpression
            ) != nil
        }

        XCTAssertTrue(
            sourceWrapsSecurityCall(connectorSource, call: "SecItemCopyMatching"),
            "Connector-plane keychain reads must not be able to show login-keychain prompts."
        )
        XCTAssertTrue(
            sourceWrapsSecurityCall(connectorSource, call: "SecItemUpdate")
                && sourceWrapsSecurityCall(connectorSource, call: "SecItemAdd")
                && sourceWrapsSecurityCall(connectorSource, call: "SecItemDelete"),
            "Connector-plane keychain writes must not be able to show login-keychain prompts."
        )
        XCTAssertTrue(
            sourceWrapsSecurityCall(providerSource, call: "SecItemCopyMatching"),
            "Provider-router keychain reads must not be able to show login-keychain prompts."
        )
        XCTAssertTrue(
            sourceWrapsSecurityCall(providerSource, call: "SecItemUpdate")
                && sourceWrapsSecurityCall(providerSource, call: "SecItemAdd")
                && sourceWrapsSecurityCall(providerSource, call: "SecItemDelete"),
            "Provider-router keychain writes must not be able to show login-keychain prompts."
        )
        XCTAssertTrue(
            sourceWrapsSecurityCall(switcherSource, call: "SecItemCopyMatching"),
            "Switcher keychain reads must not be able to show login-keychain prompts."
        )
        XCTAssertTrue(
            sourceWrapsSecurityCall(databaseCipherSource, call: "SecItemCopyMatching"),
            "Database-key reads must not be able to show login-keychain prompts."
        )
        for source in [connectorSource, providerSource, switcherSource, databaseCipherSource] {
            XCTAssertTrue(
                source.contains("kSecUseAuthenticationUI as String") && source.contains("kSecUseAuthenticationUIFail"),
                "Daemon keychain reads must explicitly fail instead of opening macOS SecurityAgent UI."
            )
        }
    }

    func testClaudeCodeKeychainFallbackKeepsSecretCaptureInMemory() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let providerSource = try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/OpenBurnBarDaemon/OpenBurnBarProviderExecutor.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(
            providerSource.contains("let outputPipe = Pipe()")
                && providerSource.contains("process.standardOutput = outputPipe"),
            "Keychain CLI fallback must capture secret output through an in-memory pipe."
        )
        XCTAssertFalse(
            providerSource.contains("openburnbar-keychain-")
                || providerSource.contains("process.standardOutput = outputHandle")
                || providerSource.contains("Data(contentsOf: outputURL)"),
            "Keychain CLI fallback must not persist OAuth/keychain material through a temporary output file."
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
        XCTAssertTrue(providerIDs.contains("ollama-local"), "Expected local Ollama in defaults")
        XCTAssertTrue(providerIDs.contains("anthropic"), "Expected anthropic in defaults")
        XCTAssertTrue(providerIDs.contains("openai"), "Expected openai in defaults")
        XCTAssertEqual(snapshot.routerMode, .providerFamilyFailover)
        XCTAssertEqual(snapshot.providerSettings(id: "zai")?.preferredModelIDs, ["glm-5-turbo", "glm-5"])
        XCTAssertEqual(snapshot.providerSettings(id: "minimax")?.preferredModelIDs, ["minimax-m2.7-highspeed"])
        let localOllama = try XCTUnwrap(snapshot.providerSettings(id: "ollama-local"))
        XCTAssertEqual(localOllama.ollamaEndpoints.map(\.id), ["default"])
        XCTAssertEqual(localOllama.credentialSlots.map(\.slotID), ["default"])
        XCTAssertEqual(localOllama.ollamaEndpoints.first?.baseURL, "http://localhost:11434")
    }

    func testOnboardingRoutingProviderIDsExcludeDisabledRoutes() async throws {
        let harness = try makeHarness(name: "onboarding-routing")
        let initial = try await harness.configStore.onboardingRoutingProviderIDs()
        XCTAssertTrue(initial.contains("codex"), "The default local Codex route should satisfy onboarding.")

        let snapshot = try await harness.configStore.snapshot()
        let codex = try XCTUnwrap(snapshot.providerSettings(id: "codex"))
        var disabled = codex
        disabled.isEnabled = false
        _ = try await harness.configStore.upsertProvider(disabled)

        let afterDisable = try await harness.configStore.onboardingRoutingProviderIDs()
        XCTAssertFalse(afterDisable.contains("codex"), "A disabled local provider must not satisfy onboarding.")
    }

    func testOllamaEndpointDecodeSynthesizesLegacyDefaultFromProviderBaseURL() throws {
        let previous = setEnvironment("OLLAMA_HOST", to: nil)
        defer { restoreEnvironment("OLLAMA_HOST", previous) }
        let data = Data("""
        {
          "providerID": "ollama-local",
          "isEnabled": true,
          "baseURL": "http://ollama-lab.local:11434/v1",
          "preferredModelIDs": [],
          "credentialSlots": []
        }
        """.utf8)

        let settings = try JSONDecoder().decode(BurnBarProviderSettings.self, from: data)

        XCTAssertEqual(settings.ollamaEndpoints.count, 1)
        XCTAssertEqual(settings.ollamaEndpoints[0].id, "default")
        XCTAssertEqual(settings.ollamaEndpoints[0].baseURL, "http://ollama-lab.local:11434")
        XCTAssertEqual(settings.ollamaEndpoints[0].priority, 0)
        XCTAssertTrue(settings.ollamaEndpoints[0].enabled)
    }

    func testOllamaEndpointDecodeUsesOllamaHostForSynthesizedDefault() throws {
        let previous = setEnvironment("OLLAMA_HOST", to: "http://edge-ollama.local:11435")
        defer { restoreEnvironment("OLLAMA_HOST", previous) }
        let data = Data("""
        {
          "providerID": "ollama-local",
          "isEnabled": true,
          "baseURL": "http://localhost:11434/v1",
          "preferredModelIDs": [],
          "credentialSlots": []
        }
        """.utf8)

        let settings = try JSONDecoder().decode(BurnBarProviderSettings.self, from: data)

        XCTAssertEqual(settings.ollamaEndpoints.map(\.baseURL), ["http://edge-ollama.local:11435"])
    }

    func testOllamaEndpointDecodeAcceptsPopulatedArray() throws {
        let data = Data("""
        {
          "providerID": "ollama-local",
          "isEnabled": true,
          "baseURL": "http://localhost:11434/v1",
          "preferredModelIDs": [],
          "credentialSlots": [],
          "ollamaEndpoints": [
            {"id": "edge-b", "label": "Edge B", "baseURL": "http://127.0.0.1:21435", "priority": 10, "enabled": true},
            {"id": "edge-a", "label": "Edge A", "baseURL": "http://127.0.0.1:21434/", "priority": 0, "enabled": true}
          ]
        }
        """.utf8)

        let settings = try JSONDecoder().decode(BurnBarProviderSettings.self, from: data)

        XCTAssertEqual(settings.ollamaEndpoints.map(\.id), ["edge-a", "edge-b"])
        XCTAssertEqual(settings.ollamaEndpoints.map(\.baseURL), ["http://127.0.0.1:21434", "http://127.0.0.1:21435"])
        XCTAssertEqual(settings.ollamaEndpoints.map(\.label), ["Edge A", "Edge B"])
    }

    func testOllamaEndpointDecodeAndEncodePreservesExplicitEmptyArray() throws {
        let data = Data("""
        {
          "providerID": "ollama-local",
          "isEnabled": true,
          "baseURL": "http://localhost:11434/v1",
          "preferredModelIDs": [],
          "credentialSlots": [],
          "ollamaEndpoints": []
        }
        """.utf8)

        let settings = try JSONDecoder().decode(BurnBarProviderSettings.self, from: data)

        XCTAssertEqual(settings.ollamaEndpoints, [])

        let encoded = try JSONEncoder().encode(settings)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNotNil(object["ollamaEndpoints"])
        XCTAssertEqual((object["ollamaEndpoints"] as? [Any])?.count, 0)
    }

    func testOllamaEndpointDecodeRejectsDuplicateIDsAndNonHTTPURLs() throws {
        let duplicateIDs = Data("""
        {
          "providerID": "ollama-local",
          "isEnabled": true,
          "baseURL": "http://localhost:11434/v1",
          "preferredModelIDs": [],
          "credentialSlots": [],
          "ollamaEndpoints": [
            {"id": "edge", "baseURL": "http://127.0.0.1:21434"},
            {"id": " edge ", "baseURL": "http://127.0.0.1:21435"}
          ]
        }
        """.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(BurnBarProviderSettings.self, from: duplicateIDs))

        let invalidURL = Data("""
        {
          "providerID": "ollama-local",
          "isEnabled": true,
          "baseURL": "http://localhost:11434/v1",
          "preferredModelIDs": [],
          "credentialSlots": [],
          "ollamaEndpoints": [
            {"id": "edge", "baseURL": "file:///tmp/ollama.sock"}
          ]
        }
        """.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(BurnBarProviderSettings.self, from: invalidURL))
    }

    func testConfigStorePersistsOllamaEndpointSlotsAndRejectsInvalidEndpointURL() async throws {
        let harness = try makeHarness(name: "ollama-endpoints")

        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "ollama-local",
                isEnabled: true,
                baseURL: "http://localhost:11434/v1",
                preferredModelIDs: [],
                ollamaEndpoints: [
                    BurnBarOllamaEndpointConfig(id: "edge-b", baseURL: "http://127.0.0.1:21435", label: "Edge B", priority: 10),
                    BurnBarOllamaEndpointConfig(id: "edge-a", baseURL: "http://127.0.0.1:21434", label: "Edge A", priority: 0)
                ]
            )
        )

        let snapshot = try await harness.configStore.snapshot()
        let localOllama = try XCTUnwrap(snapshot.providerSettings(id: "ollama-local"))
        XCTAssertEqual(localOllama.ollamaEndpoints.map(\.id), ["edge-a", "edge-b"])
        XCTAssertEqual(localOllama.credentialSlots.map(\.slotID), ["edge-a", "edge-b"])
        XCTAssertEqual(localOllama.credentialSlots.map(\.label), ["Edge A", "Edge B"])

        do {
            _ = try await harness.configStore.upsertProvider(
                BurnBarProviderSettings(
                    providerID: "ollama-local",
                    isEnabled: true,
                    baseURL: "http://localhost:11434/v1",
                    preferredModelIDs: [],
                    ollamaEndpoints: [
                        BurnBarOllamaEndpointConfig(id: "bad", baseURL: "ftp://127.0.0.1:11434")
                    ]
                )
            )
            XCTFail("Expected invalid Ollama endpoint URL to be rejected.")
        } catch let error as BurnBarConfigStoreError {
            guard case .invalidBaseURL(let providerID) = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
            XCTAssertEqual(providerID, "ollama-local")
        }
    }

    func testConfigStorePreservesExplicitEmptyOllamaEndpointSlots() async throws {
        let harness = try makeHarness(name: "empty-ollama-endpoints")

        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "ollama-local",
                isEnabled: true,
                baseURL: "http://localhost:11434/v1",
                preferredModelIDs: [],
                ollamaEndpoints: [
                    BurnBarOllamaEndpointConfig(id: "edge", baseURL: "http://127.0.0.1:21434", label: "Edge", priority: 0)
                ]
            )
        )
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "ollama-local",
                isEnabled: true,
                baseURL: "http://localhost:11434/v1",
                preferredModelIDs: [],
                ollamaEndpoints: []
            )
        )

        let snapshot = try await harness.configStore.snapshot()
        let localOllama = try XCTUnwrap(snapshot.providerSettings(id: "ollama-local"))
        XCTAssertEqual(localOllama.ollamaEndpoints, [])
        XCTAssertEqual(localOllama.credentialSlots, [])
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
        XCTAssertEqual(configuration.preferredModels.map(\.id), ["glm-5", "glm-5-turbo"])
        XCTAssertEqual(configuration.apiKey, "zai-secret")
    }

    func testResolvedConfigurationRepairsMissingSecretSlotWhenCredentialResolves() async throws {
        let harness = try makeHarness(name: "missing-secret-repair")
        let slotID = "current-claude-code-login"

        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "anthropic",
                isEnabled: true,
                baseURL: "https://api.anthropic.com",
                preferredModelIDs: ["claude-opus-4-8"],
                preferredCredentialSlotID: slotID
            )
        )
        _ = try await harness.configStore.upsertCredentialSlot(
            providerID: "anthropic",
            slotID: slotID,
            label: "Current Claude Code login",
            apiKey: "valid-claude-route-token",
            authMethodID: "anthropic-claude-oauth"
        )
        try await harness.configStore.updateCredentialSlotStatus(
            providerID: "anthropic",
            slotID: slotID,
            status: .missingSecret,
            cooldownUntil: nil,
            message: "missingSecret"
        )

        let resolved = try await harness.configStore.resolvedConfiguration(for: "anthropic")
        let resolvedSlot = try XCTUnwrap(resolved.settings.credentialSlots.first { $0.slotID == slotID })
        XCTAssertTrue(resolved.hasCredential)
        XCTAssertEqual(resolvedSlot.status, .ready)
        XCTAssertNil(resolvedSlot.lastStatusMessage)

        let persisted = try await harness.configStore.snapshot()
        let persistedSlot = try XCTUnwrap(
            persisted.providerSettings(id: "anthropic")?.credentialSlots.first { $0.slotID == slotID }
        )
        XCTAssertEqual(persistedSlot.status, .ready)
        XCTAssertNil(persistedSlot.lastStatusMessage)
    }

    func testResolvedConfigurationDoesNotRepairNormalMissingSecretSlot() async throws {
        let harness = try makeHarness(name: "normal-missing-secret-stays-blocked")
        let slotID = "primary"

        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "zai",
                isEnabled: true,
                baseURL: "https://api.z.ai/api/paas/v4",
                preferredModelIDs: ["glm-5"],
                preferredCredentialSlotID: slotID
            )
        )
        _ = try await harness.configStore.upsertCredentialSlot(
            providerID: "zai",
            slotID: slotID,
            label: "Z.ai coding plan",
            apiKey: "invalid-still-present-key",
            authMethodID: "zai-coding-plan"
        )
        try await harness.configStore.updateCredentialSlotStatus(
            providerID: "zai",
            slotID: slotID,
            status: .missingSecret,
            cooldownUntil: nil,
            message: "Upstream rejected saved credential."
        )

        let resolved = try await harness.configStore.resolvedConfiguration(for: "zai")
        let resolvedSlot = try XCTUnwrap(resolved.settings.credentialSlots.first { $0.slotID == slotID })
        XCTAssertNil(resolved.apiKey)
        XCTAssertEqual(resolvedSlot.status, .missingSecret)
        XCTAssertEqual(resolvedSlot.lastStatusMessage, "Upstream rejected saved credential.")

        let persisted = try await harness.configStore.snapshot()
        let persistedSlot = try XCTUnwrap(
            persisted.providerSettings(id: "zai")?.credentialSlots.first { $0.slotID == slotID }
        )
        XCTAssertEqual(persistedSlot.status, .missingSecret)
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
                XCTFail("Unexpected error: \(error)")
                return
            }
            XCTAssertEqual(providerID, "zai")
            XCTAssertEqual(modelID, "pony-alpha-2")
        }
    }

    func testConfigStoreRejectsNonHTTPProviderBaseURL() async throws {
        let harness = try makeHarness(name: "invalid-base-url")

        for blockedURL in ["file:///etc/passwd", "javascript:alert(1)", "not-a-url"] {
            do {
                _ = try await harness.configStore.upsertProvider(
                    BurnBarProviderSettings(
                        providerID: "zai",
                        isEnabled: true,
                        baseURL: blockedURL,
                        preferredModelIDs: ["glm-5"]
                    )
                )
                XCTFail("Expected invalid base URL error for \(blockedURL)")
            } catch let error as BurnBarConfigStoreError {
                guard case .invalidBaseURL(let providerID) = error else {
                    XCTFail("Unexpected error for \(blockedURL): \(error)")
                    return
                }
                XCTAssertEqual(providerID, "zai")
            }
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

    func testCredentialSlotUpsertRequiresDaemonReadableSecretBeforePersistingSlot() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-config-store-unreadable-slot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let configStore = BurnBarConfigStore(
            fileURL: rootURL.appendingPathComponent("provider-config.json", isDirectory: false),
            catalog: BurnBarCatalogLoader.bundledCatalog,
            secretStore: UnreadableSecretStore(),
            logger: BurnBarDaemonLogger(category: "config-store-tests")
        )

        do {
            _ = try await configStore.upsertCredentialSlot(
                providerID: "ollama",
                slotID: "gmail",
                label: "gmail",
                apiKey: "sk-ollama-test-key",
                isEnabled: true
            )
            XCTFail("Expected unreadable slot secret to fail the upsert.")
        } catch let error as BurnBarConfigStoreError {
            guard case .credentialReadbackFailed(let providerID, let slotID) = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
            XCTAssertEqual(providerID, "ollama")
            XCTAssertEqual(slotID, "gmail")
        }

        let snapshot = try await configStore.snapshot()
        XCTAssertTrue(snapshot.providerSettings(id: "ollama")?.credentialSlots.isEmpty ?? false)
    }

    func testRemoveCredentialSlotSucceedsWhenSecretDeletionFaults() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-config-store-remove-fault-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let secretStore = DeleteFaultingSecretStore()
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
                preferredCredentialSlotID: "gmail",
                credentialSlots: [
                    BurnBarProviderCredentialSlot(
                        slotID: "gmail",
                        label: "Gmail",
                        isEnabled: true,
                        status: .ready
                    )
                ]
            )
        )

        // A keychain delete fault (e.g. errSecInvalidOwnerEdit / -25244 from an
        // item whose ACL was written by an older daemon identity) must not fail
        // the removal: the slot is already gone from config, which is the
        // user-facing success. The previous behavior surfaced a false
        // "couldn't remove" error and left the deleted row on screen.
        try await configStore.removeCredentialSlot(providerID: "zai", slotID: "gmail")

        let snapshot = try await configStore.snapshot()
        let slots = snapshot.providerSettings(id: "zai")?.credentialSlots ?? []
        XCTAssertFalse(
            slots.contains(where: { $0.slotID == "gmail" }),
            "Removal must drop the slot from config even when keychain secret cleanup faults."
        )
        let attempts = await secretStore.deleteAttempts
        XCTAssertEqual(attempts, 3, "Secret cleanup must retry the transient fault before giving up.")
    }

    func testCredentialSlotUpsertRejectsEmptyRouteCredential() async throws {
        let harness = try makeHarness(name: "empty-slot-secret")

        do {
            _ = try await harness.configStore.upsertCredentialSlot(
                providerID: "ollama",
                slotID: "gmail",
                label: "gmail",
                apiKey: " ",
                isEnabled: true
            )
            XCTFail("Expected empty slot credential to fail the upsert.")
        } catch let error as BurnBarConfigStoreError {
            guard case .missingCredential(let providerID) = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
            XCTAssertEqual(providerID, "ollama")
        }

        let snapshot = try await harness.configStore.snapshot()
        XCTAssertTrue(snapshot.providerSettings(id: "ollama")?.credentialSlots.isEmpty ?? false)
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
            hermesCredentialPoolURL: authURL,
            claudeCodeCredentialsURL: nil,
            fallbackSecretFileURL: nil
        )

        let secret = try await store.secret(for: "minimax.slot.default")
        XCTAssertEqual(secret, "minimax-from-hermes")
    }

    #if os(macOS)
    func testKeychainSecretStoreReadsDaemonSlotWithoutGlobalInteractionGate() async throws {
        let service = "com.openburnbar.tests.keychain.\(UUID().uuidString)"
        let providerSlotKey = "zai.slot.default"
        let account = "provider.\(providerSlotKey).apiKey"
        let fallbackURL = temporaryFallbackVaultURL()
        defer {
            deleteKeychainSecret(service: service, account: account)
            removeFallbackVault(fallbackURL)
        }

        let store = BurnBarKeychainSecretStore(
            service: service,
            hermesCredentialPoolURL: nil,
            claudeCodeCredentialsURL: nil,
            fallbackSecretFileURL: fallbackURL
        )

        try await store.setSecret("zai-keychain-secret", for: providerSlotKey)

        let secret = try await store.secret(for: providerSlotKey)
        XCTAssertEqual(secret, "zai-keychain-secret")
    }

    func testKeychainSecretStoreRecreatesExistingSlotSecretOnOverwrite() async throws {
        let service = "com.openburnbar.tests.keychain.recreate.\(UUID().uuidString)"
        let providerSlotKey = "anthropic.slot.max"
        let account = "provider.\(providerSlotKey).apiKey"
        let fallbackURL = temporaryFallbackVaultURL()
        defer {
            deleteKeychainSecret(service: service, account: account)
            removeFallbackVault(fallbackURL)
        }

        try addKeychainSecret(
            "old-oauth-token",
            service: service,
            account: account,
            comment: "stale-access-marker"
        )

        let store = BurnBarKeychainSecretStore(
            service: service,
            hermesCredentialPoolURL: nil,
            claudeCodeCredentialsURL: nil,
            fallbackSecretFileURL: fallbackURL
        )
        try await store.setSecret("new-oauth-token", for: providerSlotKey)

        let secret = try await store.secret(for: providerSlotKey)
        XCTAssertEqual(secret, "new-oauth-token")
        let attributes = try XCTUnwrap(keychainAttributes(service: service, account: account))
        XCTAssertNil(attributes[kSecAttrComment as String], "Overwriting a provider slot should recreate the row, not preserve stale keychain metadata.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fallbackURL.path), "Provider secrets must not be mirrored into a plaintext continuity vault.")
    }

    func testKeychainSecretStoreScrubsAndIgnoresLegacyContinuityVault() async throws {
        let service = "com.openburnbar.tests.keychain.continuity.\(UUID().uuidString)"
        let providerSlotKey = "anthropic.slot.max"
        let account = "provider.\(providerSlotKey).apiKey"
        let fallbackURL = temporaryFallbackVaultURL()
        defer {
            deleteKeychainSecret(service: service, account: account)
            removeFallbackVault(fallbackURL)
        }

        try FileManager.default.createDirectory(
            at: fallbackURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let legacyVault = #"{"secrets":{"\#(account)":"legacy-plaintext-oauth-token"}}"#
        try Data(legacyVault.utf8).write(to: fallbackURL, options: .atomic)

        let store = BurnBarKeychainSecretStore(
            service: service,
            hermesCredentialPoolURL: nil,
            claudeCodeCredentialsURL: nil,
            fallbackSecretFileURL: fallbackURL
        )

        let secret = try await store.secret(for: providerSlotKey)
        XCTAssertNil(secret)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fallbackURL.path), "Legacy plaintext continuity vaults should be scrubbed on store initialization.")
    }

    func testKeychainSecretStoreRefreshesStoredClaudeOAuthPayloadWhenExpired() async throws {
        ClaudeOAuthRefreshURLProtocol.reset()
        ClaudeOAuthRefreshURLProtocol.enqueue(
            status: 200,
            body: #"{"access_token":"refreshed-oauth-token","refresh_token":"new-refresh-token","expires_in":28800}"#
        )
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [ClaudeOAuthRefreshURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)

        let service = "com.openburnbar.tests.keychain.oauth-refresh.\(UUID().uuidString)"
        let providerSlotKey = "anthropic.slot.max"
        let account = "provider.\(providerSlotKey).apiKey"
        let fallbackURL = temporaryFallbackVaultURL()
        defer {
            deleteKeychainSecret(service: service, account: account)
            removeFallbackVault(fallbackURL)
            ClaudeOAuthRefreshURLProtocol.reset()
        }

        let expiredAtMilliseconds = Date().addingTimeInterval(-120).timeIntervalSince1970 * 1000
        let storedPayload = """
        {
          "claudeAiOauth": {
            "accessToken": "expired-oauth-token",
            "refreshToken": "old-refresh-token",
            "expiresAt": \(expiredAtMilliseconds),
            "subscriptionType": "max",
            "rateLimitTier": "default_claude_max_20x"
          },
          "organizationUuid": "org-test"
        }
        """
        let store = BurnBarKeychainSecretStore(
            service: service,
            hermesCredentialPoolURL: nil,
            claudeCodeCredentialsURL: nil,
            fallbackSecretFileURL: fallbackURL,
            claudeOAuthRefreshSession: session
        )
        try await store.setSecret(storedPayload, for: providerSlotKey)

        let secret = try await store.secret(for: providerSlotKey)
        XCTAssertEqual(secret, "refreshed-oauth-token")
        XCTAssertEqual(ClaudeOAuthRefreshURLProtocol.recordedRequestBodies(), [
            "grant_type=refresh_token&refresh_token=old-refresh-token&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e"
        ])
        let refreshedPayload = try keychainSecret(service: service, account: account)
        let oauth = try XCTUnwrap(claudeOAuthPayload(from: refreshedPayload))
        XCTAssertEqual(oauth["accessToken"] as? String, "refreshed-oauth-token")
        XCTAssertEqual(oauth["refreshToken"] as? String, "new-refresh-token")
        XCTAssertEqual(oauth["subscriptionType"] as? String, "max")
        XCTAssertEqual(oauth["rateLimitTier"] as? String, "default_claude_max_20x")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fallbackURL.path), "OAuth refresh must not recreate the removed continuity vault.")
    }

    func testKeychainSecretStorePrefersDaemonServiceAndCanReadLegacyService() async throws {
        let primaryService = "com.openburnbar.tests.keychain.primary.\(UUID().uuidString)"
        let legacyService = "com.openburnbar.tests.keychain.legacy.\(UUID().uuidString)"
        let providerSlotKey = "anthropic.slot.default"
        let account = "provider.\(providerSlotKey).apiKey"
        let fallbackURL = temporaryFallbackVaultURL()
        defer {
            for service in [primaryService, legacyService] {
                deleteKeychainSecret(service: service, account: account)
            }
            removeFallbackVault(fallbackURL)
        }

        try addKeychainSecret("legacy-secret", service: legacyService, account: account)
        let legacyOnlyStore = BurnBarKeychainSecretStore(
            service: primaryService,
            legacyServices: [legacyService],
            hermesCredentialPoolURL: nil,
            claudeCodeCredentialsURL: nil,
            fallbackSecretFileURL: fallbackURL
        )
        let legacySecret = try await legacyOnlyStore.secret(for: providerSlotKey)
        XCTAssertEqual(legacySecret, "legacy-secret")

        try await legacyOnlyStore.setSecret("daemon-secret", for: providerSlotKey)
        let daemonSecret = try await legacyOnlyStore.secret(for: providerSlotKey)
        XCTAssertEqual(daemonSecret, "daemon-secret")
    }

    func testKeychainSecretStoreDoesNotPromoteExpiredLegacyOAuthOverRefresh() async throws {
        ClaudeOAuthRefreshURLProtocol.reset()
        ClaudeOAuthRefreshURLProtocol.enqueue(
            status: 200,
            body: #"{"access_token":"legacy-refreshed-token","refresh_token":"legacy-new-refresh","expires_in":28800}"#
        )
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [ClaudeOAuthRefreshURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)

        let primaryService = "com.openburnbar.tests.keychain.primary-refresh.\(UUID().uuidString)"
        let legacyService = "com.openburnbar.tests.keychain.legacy-refresh.\(UUID().uuidString)"
        let providerKey = "anthropic"
        let account = "provider.\(providerKey).apiKey"
        let fallbackURL = temporaryFallbackVaultURL()
        defer {
            deleteKeychainSecret(service: primaryService, account: account)
            deleteKeychainSecret(service: legacyService, account: account)
            removeFallbackVault(fallbackURL)
            ClaudeOAuthRefreshURLProtocol.reset()
        }

        let expiredAtMilliseconds = Date().addingTimeInterval(-120).timeIntervalSince1970 * 1000
        let legacyPayload = """
        {"claudeAiOauth":{"accessToken":"legacy-expired-token","refreshToken":"legacy-old-refresh","expiresAt":\(expiredAtMilliseconds),"subscriptionType":"max"},"organizationUuid":"org-legacy"}
        """
        try addKeychainSecret(legacyPayload, service: legacyService, account: account)

        let store = BurnBarKeychainSecretStore(
            service: primaryService,
            legacyServices: [legacyService],
            hermesCredentialPoolURL: nil,
            claudeCodeCredentialsURL: nil,
            fallbackSecretFileURL: fallbackURL,
            claudeOAuthRefreshSession: session
        )

        let secret = try await store.secret(for: providerKey)

        XCTAssertEqual(secret, "legacy-refreshed-token")
        let promotedPayload = try keychainSecret(service: primaryService, account: account)
        let oauth = try XCTUnwrap(claudeOAuthPayload(from: promotedPayload))
        XCTAssertEqual(oauth["accessToken"] as? String, "legacy-refreshed-token")
        XCTAssertEqual(oauth["refreshToken"] as? String, "legacy-new-refresh")
        XCTAssertEqual(ClaudeOAuthRefreshURLProtocol.recordedRequestBodies(), [
            "grant_type=refresh_token&refresh_token=legacy-old-refresh&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e"
        ])
    }

    func testKeychainSecretStoreFallsBackToClaudeCodeCredentialsWhenKeychainOAuthRefreshFails() async throws {
        ClaudeOAuthRefreshURLProtocol.reset()
        // The daemon-owned Keychain token refresh fails. Claude Code's file is
        // already valid, so the daemon can borrow it without mutating that file.
        ClaudeOAuthRefreshURLProtocol.enqueue(status: 400, body: #"{"error":"invalid_grant"}"#)
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [ClaudeOAuthRefreshURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)

        let service = "com.openburnbar.tests.keychain.cc-fallback.\(UUID().uuidString)"
        let providerKey = "anthropic"
        let account = "provider.\(providerKey).apiKey"
        let fallbackURL = temporaryFallbackVaultURL()
        let ccCredentialsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-creds-\(UUID().uuidString).json")
        defer {
            deleteKeychainSecret(service: service, account: account)
            removeFallbackVault(fallbackURL)
            try? FileManager.default.removeItem(at: ccCredentialsURL)
            ClaudeOAuthRefreshURLProtocol.reset()
        }

        // Store an expired OAuth credential with an invalid refresh token in the Keychain.
        let expiredAtMilliseconds = Date().addingTimeInterval(-120).timeIntervalSince1970 * 1000
        let expiredPayload = """
        {"claudeAiOauth":{"accessToken":"expired-daemon-token","refreshToken":"invalid-refresh","expiresAt":\(expiredAtMilliseconds),"subscriptionType":"max","rateLimitTier":"default_claude_max_20x"},"organizationUuid":"org-daemon"}
        """
        let store = BurnBarKeychainSecretStore(
            service: service,
            hermesCredentialPoolURL: nil,
            claudeCodeCredentialsURL: ccCredentialsURL,
            fallbackSecretFileURL: fallbackURL,
            claudeOAuthRefreshSession: session
        )
        try await store.setSecret(expiredPayload, for: providerKey)

        // Write a Claude Code credentials file with a valid access token.
        let ccExpiresAtMilliseconds = Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000
        let ccPayload = """
        {"claudeAiOauth":{"accessToken":"valid-cc-token","refreshToken":"cc-refresh","expiresAt":\(ccExpiresAtMilliseconds),"scopes":["user:inference"]},"organizationUuid":"org-daemon"}
        """
        try Data(ccPayload.utf8).write(to: ccCredentialsURL, options: .atomic)

        // secret(for:) should:
        // 1. Read the Keychain -> expired -> refresh fails (400) -> routeSecret returns nil
        // 2. Fall through to a still-valid canonical Claude Code credential
        // 3. Return that access token without refreshing or rewriting Claude Code's file
        let secret = try await store.secret(for: providerKey)
        XCTAssertEqual(secret, "valid-cc-token")
        XCTAssertEqual(try String(contentsOf: ccCredentialsURL, encoding: .utf8), ccPayload)
        XCTAssertEqual(ClaudeOAuthRefreshURLProtocol.recordedRequestBodies().count, 1)

        // The daemon must not copy Claude Code's refresh token into its own
        // Keychain; that would let two processes rotate the same OAuth session.
        let daemonKeychain = try keychainSecret(service: service, account: account)
        let oauth = try XCTUnwrap(claudeOAuthPayload(from: daemonKeychain))
        XCTAssertEqual(oauth["accessToken"] as? String, "expired-daemon-token")
    }

    func testKeychainSecretStoreRejectsClaudeCodeFallbackForDifferentOrganization() async throws {
        ClaudeOAuthRefreshURLProtocol.reset()
        ClaudeOAuthRefreshURLProtocol.enqueue(status: 400, body: #"{"error":"invalid_grant"}"#)
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [ClaudeOAuthRefreshURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)

        let service = "com.openburnbar.tests.keychain.cc-org-boundary.\(UUID().uuidString)"
        let providerKey = "anthropic"
        let account = "provider.\(providerKey).apiKey"
        let fallbackURL = temporaryFallbackVaultURL()
        let ccCredentialsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-creds-org-\(UUID().uuidString).json")
        defer {
            deleteKeychainSecret(service: service, account: account)
            removeFallbackVault(fallbackURL)
            try? FileManager.default.removeItem(at: ccCredentialsURL)
            ClaudeOAuthRefreshURLProtocol.reset()
        }

        let expiredAtMilliseconds = Date().addingTimeInterval(-120).timeIntervalSince1970 * 1000
        let expiredPayload = """
        {"claudeAiOauth":{"accessToken":"expired-daemon-token","refreshToken":"invalid-refresh","expiresAt":\(expiredAtMilliseconds)},"organizationUuid":"org-daemon"}
        """
        let store = BurnBarKeychainSecretStore(
            service: service,
            hermesCredentialPoolURL: nil,
            claudeCodeCredentialsURL: ccCredentialsURL,
            fallbackSecretFileURL: fallbackURL,
            claudeOAuthRefreshSession: session
        )
        try await store.setSecret(expiredPayload, for: providerKey)

        let ccExpiresAtMilliseconds = Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000
        let ccPayload = """
        {"claudeAiOauth":{"accessToken":"other-org-cc-token","refreshToken":"cc-refresh","expiresAt":\(ccExpiresAtMilliseconds)},"organizationUuid":"org-other"}
        """
        try Data(ccPayload.utf8).write(to: ccCredentialsURL, options: .atomic)

        let secret = try await store.secret(for: providerKey)
        XCTAssertNil(secret)
        XCTAssertEqual(try String(contentsOf: ccCredentialsURL, encoding: .utf8), ccPayload)
        XCTAssertEqual(ClaudeOAuthRefreshURLProtocol.recordedRequestBodies().count, 1)
    }

    func testKeychainSecretStoreRejectsClaudeCodeFallbackWithMissingOrganizationWhenExpected() async throws {
        ClaudeOAuthRefreshURLProtocol.reset()
        ClaudeOAuthRefreshURLProtocol.enqueue(status: 400, body: #"{"error":"invalid_grant"}"#)
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [ClaudeOAuthRefreshURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)

        let service = "com.openburnbar.tests.keychain.cc-nil-org-boundary.\(UUID().uuidString)"
        let providerKey = "anthropic"
        let account = "provider.\(providerKey).apiKey"
        let fallbackURL = temporaryFallbackVaultURL()
        let ccCredentialsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-creds-nil-org-\(UUID().uuidString).json")
        defer {
            deleteKeychainSecret(service: service, account: account)
            removeFallbackVault(fallbackURL)
            try? FileManager.default.removeItem(at: ccCredentialsURL)
            ClaudeOAuthRefreshURLProtocol.reset()
        }

        let expiredAtMilliseconds = Date().addingTimeInterval(-120).timeIntervalSince1970 * 1000
        let expiredPayload = """
        {"claudeAiOauth":{"accessToken":"expired-daemon-token","refreshToken":"invalid-refresh","expiresAt":\(expiredAtMilliseconds)},"organizationUuid":"org-daemon"}
        """
        let store = BurnBarKeychainSecretStore(
            service: service,
            hermesCredentialPoolURL: nil,
            claudeCodeCredentialsURL: ccCredentialsURL,
            fallbackSecretFileURL: fallbackURL,
            claudeOAuthRefreshSession: session
        )
        try await store.setSecret(expiredPayload, for: providerKey)

        let ccExpiresAtMilliseconds = Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000
        let ccPayload = """
        {"claudeAiOauth":{"accessToken":"nil-org-cc-token","refreshToken":"cc-refresh","expiresAt":\(ccExpiresAtMilliseconds)}}
        """
        try Data(ccPayload.utf8).write(to: ccCredentialsURL, options: .atomic)

        let secret = try await store.secret(for: providerKey)
        XCTAssertNil(secret)
        XCTAssertEqual(try String(contentsOf: ccCredentialsURL, encoding: .utf8), ccPayload)
        XCTAssertEqual(ClaudeOAuthRefreshURLProtocol.recordedRequestBodies().count, 1)
    }

    func testKeychainSecretStoreRejectsClaudeCodeFallbackWhenDaemonOrganizationIsMissing() async throws {
        ClaudeOAuthRefreshURLProtocol.reset()
        ClaudeOAuthRefreshURLProtocol.enqueue(status: 400, body: #"{"error":"invalid_grant"}"#)
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [ClaudeOAuthRefreshURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)

        let service = "com.openburnbar.tests.keychain.cc-missing-org-boundary.\(UUID().uuidString)"
        let providerKey = "anthropic"
        let account = "provider.\(providerKey).apiKey"
        let fallbackURL = temporaryFallbackVaultURL()
        let ccCredentialsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-creds-missing-org-\(UUID().uuidString).json")
        defer {
            deleteKeychainSecret(service: service, account: account)
            removeFallbackVault(fallbackURL)
            try? FileManager.default.removeItem(at: ccCredentialsURL)
            ClaudeOAuthRefreshURLProtocol.reset()
        }

        let expiredAtMilliseconds = Date().addingTimeInterval(-120).timeIntervalSince1970 * 1000
        let expiredPayload = """
        {"claudeAiOauth":{"accessToken":"expired-daemon-token","refreshToken":"invalid-refresh","expiresAt":\(expiredAtMilliseconds)}}
        """
        let store = BurnBarKeychainSecretStore(
            service: service,
            hermesCredentialPoolURL: nil,
            claudeCodeCredentialsURL: ccCredentialsURL,
            fallbackSecretFileURL: fallbackURL,
            claudeOAuthRefreshSession: session
        )
        try await store.setSecret(expiredPayload, for: providerKey)

        let ccExpiresAtMilliseconds = Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000
        let ccPayload = """
        {"claudeAiOauth":{"accessToken":"valid-cc-token","refreshToken":"cc-refresh","expiresAt":\(ccExpiresAtMilliseconds)},"organizationUuid":"org-cc"}
        """
        try Data(ccPayload.utf8).write(to: ccCredentialsURL, options: .atomic)

        let secret = try await store.secret(for: providerKey)
        XCTAssertNil(secret)
        XCTAssertEqual(try String(contentsOf: ccCredentialsURL, encoding: .utf8), ccPayload)
        XCTAssertEqual(ClaudeOAuthRefreshURLProtocol.recordedRequestBodies().count, 1)
    }

    func testKeychainSecretStoreFallsBackToClaudeCodeCredentialsForAnthropicSlotWhenRefreshFails() async throws {
        ClaudeOAuthRefreshURLProtocol.reset()
        ClaudeOAuthRefreshURLProtocol.enqueue(status: 400, body: #"{"error":"invalid_grant"}"#)
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [ClaudeOAuthRefreshURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)

        let service = "com.openburnbar.tests.keychain.cc-slot-boundary.\(UUID().uuidString)"
        let providerSlotKey = "anthropic.slot.default"
        let account = "provider.\(providerSlotKey).apiKey"
        let fallbackURL = temporaryFallbackVaultURL()
        let ccCredentialsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-creds-slot-\(UUID().uuidString).json")
        defer {
            deleteKeychainSecret(service: service, account: account)
            removeFallbackVault(fallbackURL)
            try? FileManager.default.removeItem(at: ccCredentialsURL)
            ClaudeOAuthRefreshURLProtocol.reset()
        }

        let expiredAtMilliseconds = Date().addingTimeInterval(-120).timeIntervalSince1970 * 1000
        let expiredPayload = """
        {"claudeAiOauth":{"accessToken":"expired-slot-token","refreshToken":"invalid-slot-refresh","expiresAt":\(expiredAtMilliseconds)}}
        """
        let store = BurnBarKeychainSecretStore(
            service: service,
            hermesCredentialPoolURL: nil,
            claudeCodeCredentialsURL: ccCredentialsURL,
            fallbackSecretFileURL: fallbackURL,
            claudeOAuthRefreshSession: session
        )
        try await store.setSecret(expiredPayload, for: providerSlotKey)

        let ccExpiresAtMilliseconds = Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000
        let ccPayload = """
        {"claudeAiOauth":{"accessToken":"valid-global-cc-token","refreshToken":"cc-refresh","expiresAt":\(ccExpiresAtMilliseconds)}}
        """
        try Data(ccPayload.utf8).write(to: ccCredentialsURL, options: .atomic)

        let secret = try await store.secret(for: providerSlotKey)
        XCTAssertEqual(secret, "valid-global-cc-token")
        XCTAssertEqual(try String(contentsOf: ccCredentialsURL, encoding: .utf8), ccPayload)
    }

    func testKeychainSecretStoreFallsBackToClaudeCodeCredentialsForAnthropicSlotWhenSecretMissing() async throws {
        let service = "com.openburnbar.tests.keychain.cc-slot-missing.\(UUID().uuidString)"
        let providerSlotKey = "anthropic.slot.default"
        let account = "provider.\(providerSlotKey).apiKey"
        let fallbackURL = temporaryFallbackVaultURL()
        let ccCredentialsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-creds-slot-missing-\(UUID().uuidString).json")
        defer {
            deleteKeychainSecret(service: service, account: account)
            removeFallbackVault(fallbackURL)
            try? FileManager.default.removeItem(at: ccCredentialsURL)
        }

        let store = BurnBarKeychainSecretStore(
            service: service,
            hermesCredentialPoolURL: nil,
            claudeCodeCredentialsURL: ccCredentialsURL,
            fallbackSecretFileURL: fallbackURL
        )

        let ccExpiresAtMilliseconds = Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000
        let ccPayload = """
        {"claudeAiOauth":{"accessToken":"valid-slot-missing-cc-token","refreshToken":"cc-refresh","expiresAt":\(ccExpiresAtMilliseconds)}}
        """
        try Data(ccPayload.utf8).write(to: ccCredentialsURL, options: .atomic)

        let secret = try await store.secret(for: providerSlotKey)
        XCTAssertEqual(secret, "valid-slot-missing-cc-token")
    }

    func testKeychainSecretStorePrefersFreshClaudeCodeCredentialForCurrentLoginSlot() async throws {
        let service = "com.openburnbar.tests.keychain.cc-current-slot.\(UUID().uuidString)"
        let providerSlotKey = "anthropic.slot.current-claude-code-login"
        let account = "provider.\(providerSlotKey).apiKey"
        let fallbackURL = temporaryFallbackVaultURL()
        let ccCredentialsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-creds-current-slot-\(UUID().uuidString).json")
        defer {
            deleteKeychainSecret(service: service, account: account)
            removeFallbackVault(fallbackURL)
            try? FileManager.default.removeItem(at: ccCredentialsURL)
        }

        let store = BurnBarKeychainSecretStore(
            service: service,
            hermesCredentialPoolURL: nil,
            claudeCodeCredentialsURL: ccCredentialsURL,
            fallbackSecretFileURL: fallbackURL
        )

        let storedExpiresAtMilliseconds = Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000
        let storedPayload = """
        {"claudeAiOauth":{"accessToken":"stale-copied-slot-token","refreshToken":"stale-refresh","expiresAt":\(storedExpiresAtMilliseconds)}}
        """
        try await store.setSecret(storedPayload, for: providerSlotKey)

        let ccExpiresAtMilliseconds = Date().addingTimeInterval(7200).timeIntervalSince1970 * 1000
        let ccPayload = """
        {"claudeAiOauth":{"accessToken":"fresh-current-claude-code-token","refreshToken":"cc-refresh","expiresAt":\(ccExpiresAtMilliseconds)}}
        """
        try Data(ccPayload.utf8).write(to: ccCredentialsURL, options: .atomic)

        let secret = try await store.secret(for: providerSlotKey)
        XCTAssertEqual(secret, "fresh-current-claude-code-token")
        let daemonKeychain = try keychainSecret(service: service, account: account)
        let oauth = try XCTUnwrap(claudeOAuthPayload(from: daemonKeychain))
        XCTAssertEqual(oauth["accessToken"] as? String, "stale-copied-slot-token")
    }

    func testKeychainSecretStoreReturnsNilWhenAllOAuthRefreshPathsFail() async throws {
        ClaudeOAuthRefreshURLProtocol.reset()
        ClaudeOAuthRefreshURLProtocol.enqueue(status: 400, body: #"{"error":"invalid_grant"}"#)
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [ClaudeOAuthRefreshURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)

        let service = "com.openburnbar.tests.keychain.all-fail.\(UUID().uuidString)"
        let providerKey = "anthropic"
        let account = "provider.\(providerKey).apiKey"
        let fallbackURL = temporaryFallbackVaultURL()
        let ccCredentialsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-creds-fail-\(UUID().uuidString).json")
        defer {
            deleteKeychainSecret(service: service, account: account)
            removeFallbackVault(fallbackURL)
            try? FileManager.default.removeItem(at: ccCredentialsURL)
            ClaudeOAuthRefreshURLProtocol.reset()
        }

        let expiredAtMilliseconds = Date().addingTimeInterval(-120).timeIntervalSince1970 * 1000
        let expiredPayload = """
        {"claudeAiOauth":{"accessToken":"expired-token","refreshToken":"dead-refresh","expiresAt":\(expiredAtMilliseconds)}}
        """
        let store = BurnBarKeychainSecretStore(
            service: service,
            hermesCredentialPoolURL: nil,
            claudeCodeCredentialsURL: ccCredentialsURL,
            fallbackSecretFileURL: fallbackURL,
            claudeOAuthRefreshSession: session
        )
        try await store.setSecret(expiredPayload, for: providerKey)

        let ccPayload = """
        {"claudeAiOauth":{"accessToken":"expired-cc","refreshToken":"dead-cc-refresh","expiresAt":\(expiredAtMilliseconds)}}
        """
        try Data(ccPayload.utf8).write(to: ccCredentialsURL, options: .atomic)

        // Both the Keychain and Claude Code refresh tokens are invalid.
        // secret(for:) should return nil (fail-closed) instead of returning
        // an expired token that would cause a 401 on the live model refresh.
        let secret = try await store.secret(for: providerKey)
        XCTAssertNil(secret)
        XCTAssertEqual(ClaudeOAuthRefreshURLProtocol.recordedRequestBodies().count, 1)
    }

    func testKeychainSecretStoreProactivelyRefreshesExpiringOAuthCredential() async throws {
        ClaudeOAuthRefreshURLProtocol.reset()
        ClaudeOAuthRefreshURLProtocol.enqueue(
            status: 200,
            body: #"{"access_token":"proactive-access","refresh_token":"proactive-refresh","expires_in":28800}"#
        )
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [ClaudeOAuthRefreshURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)

        let service = "com.openburnbar.tests.keychain.proactive-refresh.\(UUID().uuidString)"
        let providerKey = "anthropic"
        let account = "provider.\(providerKey).apiKey"
        let fallbackURL = temporaryFallbackVaultURL()
        defer {
            deleteKeychainSecret(service: service, account: account)
            removeFallbackVault(fallbackURL)
            ClaudeOAuthRefreshURLProtocol.reset()
        }

        let expiresAtMilliseconds = Date().addingTimeInterval(120).timeIntervalSince1970 * 1000
        let expiringPayload = """
        {"claudeAiOauth":{"accessToken":"old-access","refreshToken":"old-refresh","expiresAt":\(expiresAtMilliseconds)},"organizationUuid":"org-daemon"}
        """
        let store = BurnBarKeychainSecretStore(
            service: service,
            hermesCredentialPoolURL: nil,
            claudeCodeCredentialsURL: nil,
            fallbackSecretFileURL: fallbackURL,
            claudeOAuthRefreshSession: session
        )
        try await store.setSecret(expiringPayload, for: providerKey)

        await store.proactivelyRefreshExpiringOAuthCredentials(for: [providerKey], refreshWindow: 3600)

        let refreshedPayload = try keychainSecret(service: service, account: account)
        let oauth = try XCTUnwrap(claudeOAuthPayload(from: refreshedPayload))
        XCTAssertEqual(oauth["accessToken"] as? String, "proactive-access")
        XCTAssertEqual(oauth["refreshToken"] as? String, "proactive-refresh")
        XCTAssertEqual(ClaudeOAuthRefreshURLProtocol.recordedRequestBodies(), [
            "grant_type=refresh_token&refresh_token=old-refresh&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e"
        ])
    }

    func testKeychainSecretStoreSkipsProactiveRefreshForOutsideWindowAndNonAnthropicKeys() async throws {
        ClaudeOAuthRefreshURLProtocol.reset()
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [ClaudeOAuthRefreshURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)

        let service = "com.openburnbar.tests.keychain.proactive-skip.\(UUID().uuidString)"
        let anthropicAccount = "provider.anthropic.apiKey"
        let zaiAccount = "provider.zai.apiKey"
        let fallbackURL = temporaryFallbackVaultURL()
        defer {
            deleteKeychainSecret(service: service, account: anthropicAccount)
            deleteKeychainSecret(service: service, account: zaiAccount)
            removeFallbackVault(fallbackURL)
            ClaudeOAuthRefreshURLProtocol.reset()
        }

        let futureAtMilliseconds = Date().addingTimeInterval(7200).timeIntervalSince1970 * 1000
        let futurePayload = """
        {"claudeAiOauth":{"accessToken":"future-access","refreshToken":"future-refresh","expiresAt":\(futureAtMilliseconds)}}
        """
        let expiredAtMilliseconds = Date().addingTimeInterval(-120).timeIntervalSince1970 * 1000
        let nonAnthropicPayload = """
        {"claudeAiOauth":{"accessToken":"zai-access","refreshToken":"zai-refresh","expiresAt":\(expiredAtMilliseconds)}}
        """
        let store = BurnBarKeychainSecretStore(
            service: service,
            hermesCredentialPoolURL: nil,
            claudeCodeCredentialsURL: nil,
            fallbackSecretFileURL: fallbackURL,
            claudeOAuthRefreshSession: session
        )
        try await store.setSecret(futurePayload, for: "anthropic")
        try await store.setSecret(nonAnthropicPayload, for: "zai")

        await store.proactivelyRefreshExpiringOAuthCredentials(for: ["anthropic", "zai"], refreshWindow: 3600)

        XCTAssertEqual(try keychainSecret(service: service, account: anthropicAccount), futurePayload)
        XCTAssertEqual(try keychainSecret(service: service, account: zaiAccount), nonAnthropicPayload)
        XCTAssertTrue(ClaudeOAuthRefreshURLProtocol.recordedRequestBodies().isEmpty)
    }
    #endif

    func testRouterModePersistsAndLegacySnapshotsDefaultSafely() async throws {
        let harness = try makeHarness(name: "router-mode")

        try await harness.configStore.setRouterMode(.sameModelFailover)
        let updated = try await harness.configStore.snapshot()
        XCTAssertEqual(updated.routerMode, .sameModelFailover)

        let legacyJSON = """
        {
          "providers": []
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(BurnBarProviderConfigurationSnapshot.self, from: legacyJSON)
        XCTAssertEqual(decoded.routerMode, .providerFamilyFailover)

        let legacyIntelligentJSON = """
        {
          "providers": [],
          "routerMode": "intelligent_model_router"
        }
        """.data(using: .utf8)!
        let legacyIntelligent = try JSONDecoder().decode(
            BurnBarProviderConfigurationSnapshot.self,
            from: legacyIntelligentJSON
        )
        XCTAssertEqual(legacyIntelligent.routerMode, .sameModelFailover)
    }

    func testNormalizeBackfillsNewDefaultPreferredModelsForExistingProviders() async throws {
        let harness = try makeHarness(name: "preferred-model-backfill")

        _ = try await harness.configStore.upsertProvider(BurnBarProviderSettings(
            providerID: "anthropic",
            isEnabled: true,
            baseURL: "https://api.anthropic.com/v1",
            preferredModelIDs: [
                "claude-opus-4-7-family",
                "claude-sonnet-4-6-family",
                "claude-haiku-4-5-family"
            ]
        ))

        let snapshot = try await harness.configStore.snapshot()
        let preferred = try XCTUnwrap(snapshot.providerSettings(id: "anthropic")?.preferredModelIDs)

        XCTAssertTrue(preferred.contains("claude-opus-4-8-family"))
        XCTAssertTrue(preferred.contains("claude-opus-4-7-family"))
    }

    /// Regression: a `provider-config.json` written before a catalog shrink
    /// still references models that `catalog.json` no longer defines. Loading
    /// such a config must NOT throw — otherwise `snapshot()` fails and the HTTP
    /// gateway returns 500 for the *entire* `/v1/models` response, hiding every
    /// provider's models. The load path self-heals by pruning the stale IDs.
    func testSnapshotPrunesStalePreferredModelIDsInsteadOfThrowing() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-config-store-stale-codex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let fileURL = rootURL.appendingPathComponent("provider-config.json", isDirectory: false)

        // Derive the codex models the *current* catalog actually defines, so the
        // test stays correct across catalog revisions (the IDs codex ships have
        // changed over time). The stale on-disk config preferences every real
        // codex model plus synthetic IDs that no catalog will ever define —
        // standing in for models removed by a catalog shrink.
        let catalogSupportForSetup = BurnBarProviderCatalogSupport(catalog: BurnBarCatalogLoader.bundledCatalog)
        let realCodexModelIDs = BurnBarCatalogLoader.bundledCatalog.models(forProviderID: "codex").map(\.id)
        XCTAssertFalse(realCodexModelIDs.isEmpty, "Catalog must define at least one codex model for this test")
        let removedCodexModelIDs = [
            "codex-removed-by-catalog-shrink-alpha-family",
            "codex-removed-by-catalog-shrink-beta-family",
            "codex-removed-by-catalog-shrink-gamma-family"
        ]
        for removed in removedCodexModelIDs {
            XCTAssertFalse(
                catalogSupportForSetup.supportsModelID(removed, providerID: "codex"),
                "Synthetic removed ID \(removed) must not be a real catalog model"
            )
        }
        let staleCodex = BurnBarProviderSettings(
            providerID: "codex",
            isEnabled: true,
            baseURL: "codex-cli://local",
            preferredModelIDs: realCodexModelIDs + removedCodexModelIDs,
            disabledAdvertisedModelIDs: Array(removedCodexModelIDs.prefix(2))
        )
        let staleSnapshot = BurnBarProviderConfigurationSnapshot(
            providers: [staleCodex],
            routerMode: .providerFamilyFailover
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(staleSnapshot).write(to: fileURL, options: .atomic)

        let configStore = BurnBarConfigStore(
            fileURL: fileURL,
            catalog: BurnBarCatalogLoader.bundledCatalog,
            secretStore: BurnBarInMemorySecretStore(),
            logger: BurnBarDaemonLogger(category: "config-store-tests")
        )

        // Must not throw — the whole point of the fix.
        let snapshot = try await configStore.snapshot()
        let codexPreferred = try XCTUnwrap(snapshot.providerSettings(id: "codex")?.preferredModelIDs)

        // Only catalog-supported IDs survive; the synthetic removed models are gone.
        let catalogSupport = BurnBarProviderCatalogSupport(catalog: BurnBarCatalogLoader.bundledCatalog)
        for modelID in codexPreferred {
            XCTAssertTrue(
                catalogSupport.supportsModelID(modelID, providerID: "codex"),
                "Stale model \(modelID) should have been pruned from preferredModelIDs"
            )
        }
        for removed in removedCodexModelIDs {
            XCTAssertFalse(
                codexPreferred.contains(removed),
                "Removed catalog model \(removed) must not survive normalization"
            )
        }

        // Codex still advertises its surviving catalog models.
        XCTAssertFalse(codexPreferred.isEmpty, "Codex must retain at least its catalog-backed models")
    }

    /// Companion to the regression test: the explicit `upsertProvider` write
    /// path must STILL reject unknown model IDs (the public validation contract
    /// is unchanged — only the load/self-heal path prunes).
    func testUpsertProviderStillRejectsUnsupportedPreferredModel() async throws {
        let harness = try makeHarness(name: "upsert-rejects-stale-codex")
        let bogusModelID = "codex-removed-by-catalog-shrink-alpha-family"
        do {
            _ = try await harness.configStore.upsertProvider(
                BurnBarProviderSettings(
                    providerID: "codex",
                    isEnabled: true,
                    baseURL: "codex-cli://local",
                    preferredModelIDs: [bogusModelID]
                )
            )
            XCTFail("Expected unsupported model error for removed codex model")
        } catch let error as BurnBarConfigStoreError {
            guard case .unsupportedModel(let providerID, let modelID) = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
            XCTAssertEqual(providerID, "codex")
            XCTAssertEqual(modelID, bogusModelID)
        }
    }

    func testOAuthSlotKeysForProactiveRefreshIncludesCanonicalAnthropicKey() async throws {
        let harness = try makeHarness(name: "oauth-slot-keys")
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "anthropic",
                isEnabled: true,
                baseURL: "https://api.anthropic.com/v1",
                preferredModelIDs: ["claude-sonnet-4-6-family"],
                credentialSlots: [
                    BurnBarProviderCredentialSlot(
                        slotID: "max",
                        label: "Max",
                        isEnabled: true,
                        status: .ready
                    ),
                    BurnBarProviderCredentialSlot(
                        slotID: "disabled",
                        label: "Disabled",
                        isEnabled: false,
                        status: .disabled
                    )
                ]
            )
        )

        let keys = await harness.configStore.oAuthSlotKeysForProactiveRefresh()

        XCTAssertEqual(keys, ["anthropic", "anthropic.slot.max"])
    }

    func testNormalizedBaseURLRewritesTogetherHostsForMeta() {
        XCTAssertEqual(
            BurnBarConfigStore.normalizedBaseURL(
                providerID: "meta",
                rawBaseURL: "https://api.together.xyz/v1"
            ),
            "https://api.meta.ai/v1"
        )
        XCTAssertEqual(
            BurnBarConfigStore.normalizedBaseURL(
                providerID: "meta",
                rawBaseURL: "http://api.together.xyz/v1"
            ),
            "https://api.meta.ai/v1"
        )
        XCTAssertEqual(
            BurnBarConfigStore.normalizedBaseURL(
                providerID: "Meta",
                rawBaseURL: " https://api.together.xyz/v1/ "
            ),
            "https://api.meta.ai/v1"
        )
        XCTAssertEqual(
            BurnBarConfigStore.normalizedBaseURL(
                providerID: "meta",
                rawBaseURL: "https://inference.together.xyz/v1"
            ),
            "https://api.meta.ai/v1"
        )
        XCTAssertEqual(
            BurnBarConfigStore.normalizedBaseURL(
                providerID: "openai",
                rawBaseURL: "https://api.together.xyz/v1"
            ),
            "https://api.together.xyz/v1"
        )
        XCTAssertEqual(
            BurnBarConfigStore.normalizedBaseURL(
                providerID: "meta",
                rawBaseURL: "https://api.meta.ai/v1"
            ),
            "https://api.meta.ai/v1"
        )
    }

    func testPersistedTogetherMetaURLRewritesToMetaModelAPIOnLoad() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-config-store-meta-together-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let fileURL = rootURL.appendingPathComponent("provider-config.json")
        let persisted = BurnBarProviderConfigurationSnapshot(
            providers: [
                BurnBarProviderSettings(
                    providerID: "meta",
                    isEnabled: true,
                    baseURL: "https://api.together.xyz/v1",
                    preferredModelIDs: ["muse-spark-1.3", "muse-spark-1.3-contributor"]
                )
            ]
        )
        try JSONEncoder().encode(persisted).write(to: fileURL)

        let configStore = BurnBarConfigStore(
            fileURL: fileURL,
            catalog: BurnBarCatalogLoader.bundledCatalog,
            secretStore: BurnBarInMemorySecretStore(),
            logger: BurnBarDaemonLogger(category: "config-store-tests")
        )
        let snapshot = try await configStore.snapshot()
        XCTAssertEqual(snapshot.providerSettings(id: "meta")?.baseURL, "https://api.meta.ai/v1")
    }

    func testUpsertTogetherMetaURLRewritesToMetaModelAPI() async throws {
        let harness = try makeHarness(name: "meta-together-upsert")
        let updated = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "meta",
                isEnabled: true,
                baseURL: "https://api.together.xyz/v1",
                preferredModelIDs: ["muse-spark-1.3"]
            )
        )
        XCTAssertEqual(updated.baseURL, "https://api.meta.ai/v1")
        let snapshot = try await harness.configStore.snapshot()
        XCTAssertEqual(snapshot.providerSettings(id: "meta")?.baseURL, "https://api.meta.ai/v1")
    }

    func testPersistedTogetherMetaURLStampsUnlabeledSlotsAsTogetherKey() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-config-store-meta-together-slot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let fileURL = rootURL.appendingPathComponent("provider-config.json")
        let persisted = BurnBarProviderConfigurationSnapshot(
            providers: [
                BurnBarProviderSettings(
                    providerID: "meta",
                    isEnabled: true,
                    baseURL: "https://api.together.xyz/v1",
                    preferredModelIDs: ["muse-spark-1.3"],
                    credentialSlots: [
                        BurnBarProviderCredentialSlot(
                            slotID: "legacy",
                            label: "Together",
                            isEnabled: true,
                            status: .ready
                        )
                    ]
                )
            ]
        )
        try JSONEncoder().encode(persisted).write(to: fileURL)

        let configStore = BurnBarConfigStore(
            fileURL: fileURL,
            catalog: BurnBarCatalogLoader.bundledCatalog,
            secretStore: BurnBarInMemorySecretStore(),
            logger: BurnBarDaemonLogger(category: "config-store-tests")
        )
        let snapshot = try await configStore.snapshot()
        let meta = try XCTUnwrap(snapshot.providerSettings(id: "meta"))
        XCTAssertEqual(meta.baseURL, "https://api.meta.ai/v1")
        XCTAssertEqual(meta.credentialSlots.first?.authMethodID, "meta-together-key")
    }

    func testTogetherMetaURLRewritesToCatalogBaseURLNotHardcodedFallback() async throws {
        let catalog = BurnBarCatalog(
            schemaVersion: 1,
            providers: [
                BurnBarCatalogProvider(
                    id: "meta",
                    displayName: "Meta",
                    baseURL: "https://api.meta.ai/v2-fixture",
                    visibility: .public,
                    capabilities: [.routing],
                    models: [
                        BurnBarCatalogModel(
                            id: "muse-spark-1.3",
                            displayName: "Muse Spark 1.3",
                            visibility: .public,
                            pricing: BurnBarModelPricing(inputPerMToken: 1.25, outputPerMToken: 4.25, cacheReadPerMToken: 0.15)
                        )
                    ]
                )
            ]
        )
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-config-store-meta-catalog-base-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let fileURL = rootURL.appendingPathComponent("provider-config.json")
        let persisted = BurnBarProviderConfigurationSnapshot(
            providers: [
                BurnBarProviderSettings(
                    providerID: "meta",
                    isEnabled: true,
                    baseURL: "https://api.together.xyz/v1",
                    preferredModelIDs: ["muse-spark-1.3"]
                )
            ]
        )
        try JSONEncoder().encode(persisted).write(to: fileURL)

        let configStore = BurnBarConfigStore(
            fileURL: fileURL,
            catalog: catalog,
            secretStore: BurnBarInMemorySecretStore(),
            logger: BurnBarDaemonLogger(category: "config-store-tests")
        )
        let snapshot = try await configStore.snapshot()
        XCTAssertEqual(snapshot.providerSettings(id: "meta")?.baseURL, "https://api.meta.ai/v2-fixture")
    }

    func testMigratedMetaAuthMethodIDUsesTogetherKeyOnlyForTogetherHosts() {
        XCTAssertEqual(
            BurnBarConfigStore.migratedMetaAuthMethodID(existing: nil, rawBaseURL: "https://api.together.xyz/v1"),
            "meta-together-key"
        )
        XCTAssertEqual(
            BurnBarConfigStore.migratedMetaAuthMethodID(existing: nil, rawBaseURL: "https://api.meta.ai/v1"),
            "meta-model-api-key"
        )
        XCTAssertEqual(
            BurnBarConfigStore.migratedMetaAuthMethodID(
                existing: "meta-model-api-key",
                rawBaseURL: "https://api.together.xyz/v1"
            ),
            "meta-model-api-key"
        )
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

    private func setEnvironment(_ key: String, to value: String?) -> String? {
        let previous = getenv(key).map { String(cString: $0) }
        if let value {
            setenv(key, value, 1)
        } else {
            unsetenv(key)
        }
        return previous
    }

    private func restoreEnvironment(_ key: String, _ previous: String?) {
        if let previous {
            setenv(key, previous, 1)
        } else {
            unsetenv(key)
        }
    }
}

#if os(macOS)
private func addKeychainSecret(_ secret: String, service: String, account: String, comment: String? = nil) throws {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecValueData as String: Data(secret.utf8),
        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    ]
    var createQuery = query
    if let comment {
        createQuery[kSecAttrComment as String] = comment
    }
    let status = SecItemAdd(createQuery as CFDictionary, nil)
    guard status == errSecSuccess else {
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
}

private func deleteKeychainSecret(service: String, account: String) {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account
    ]
    SecItemDelete(query as CFDictionary)
}

private func keychainAttributes(service: String, account: String) -> [String: Any]? {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecReturnAttributes as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess else {
        return nil
    }
    return item as? [String: Any]
}

private func keychainSecret(service: String, account: String) throws -> String? {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound {
        return nil
    }
    guard status == errSecSuccess else {
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
    guard let data = item as? Data else {
        return nil
    }
    return String(data: data, encoding: .utf8)
}

private func temporaryFallbackVaultURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("openburnbar-secret-continuity-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("provider-secrets.continuity.json", isDirectory: false)
}

private func removeFallbackVault(_ fallbackURL: URL) {
    try? FileManager.default.removeItem(at: fallbackURL.deletingLastPathComponent())
}

private func claudeOAuthPayload(from storedSecret: String?) throws -> [String: Any]? {
    guard let storedSecret,
          let data = storedSecret.data(using: .utf8),
          let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    return root["claudeAiOauth"] as? [String: Any]
}

private final class ClaudeOAuthRefreshURLProtocol: URLProtocol {
    private struct Response {
        let status: Int
        let body: Data
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var queuedResponses: [Response] = []
    nonisolated(unsafe) private static var requestBodies: [String] = []

    static func enqueue(status: Int, body: String) {
        lock.lock()
        defer { lock.unlock() }
        queuedResponses.append(Response(status: status, body: Data(body.utf8)))
    }

    static func recordedRequestBodies() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return requestBodies
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        queuedResponses = []
        requestBodies = []
    }

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "platform.claude.com"
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        let response = Self.queuedResponses.isEmpty
            ? Response(status: 500, body: Data(#"{"error":"missing fixture"}"#.utf8))
            : Self.queuedResponses.removeFirst()
        Self.requestBodies.append(Self.bodyString(from: request))
        Self.lock.unlock()

        let httpResponse = HTTPURLResponse(
            url: request.url!,
            statusCode: response.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func bodyString(from request: URLRequest) -> String {
        if let body = request.httpBody {
            return String(data: body, encoding: .utf8) ?? ""
        }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return String(data: data, encoding: .utf8) ?? ""
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

private actor UnreadableSecretStore: BurnBarProviderSecretStoring {
    func secret(for providerID: String) async throws -> String? {
        nil
    }

    func setSecret(_ secret: String?, for providerID: String) async throws {}
}

/// A secret store whose reads/writes succeed but whose deletes
/// (`setSecret(nil, ...)`) always fault, modelling errSecInvalidOwnerEdit /
/// -25244 from a keychain item whose ACL was written by an older daemon
/// identity. Used to prove credential-slot removal stays successful even when
/// the best-effort secret cleanup cannot complete.
private actor DeleteFaultingSecretStore: BurnBarProviderSecretStoring {
    struct DeleteDenied: Error {}

    private(set) var deleteAttempts = 0

    func secret(for providerID: String) async throws -> String? {
        "sk-test-token"
    }

    func setSecret(_ secret: String?, for providerID: String) async throws {
        if secret == nil {
            deleteAttempts += 1
            throw DeleteDenied()
        }
    }
}
