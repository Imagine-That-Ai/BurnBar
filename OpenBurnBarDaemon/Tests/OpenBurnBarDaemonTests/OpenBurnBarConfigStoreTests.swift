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
            hermesCredentialPoolURL: authURL,
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
            fallbackSecretFileURL: fallbackURL
        )
        try await store.setSecret("new-oauth-token", for: providerSlotKey)

        let secret = try await store.secret(for: providerSlotKey)
        XCTAssertEqual(secret, "new-oauth-token")
        let attributes = try XCTUnwrap(keychainAttributes(service: service, account: account))
        XCTAssertNil(attributes[kSecAttrComment as String], "Overwriting a provider slot should recreate the row, not preserve stale keychain metadata.")
        XCTAssertEqual(try fallbackSecret(in: fallbackURL, account: account), "new-oauth-token")
    }

    func testKeychainSecretStoreReadsContinuityVaultWhenKeychainRowIsUnavailable() async throws {
        let service = "com.openburnbar.tests.keychain.continuity.\(UUID().uuidString)"
        let providerSlotKey = "anthropic.slot.max"
        let account = "provider.\(providerSlotKey).apiKey"
        let fallbackURL = temporaryFallbackVaultURL()
        defer {
            deleteKeychainSecret(service: service, account: account)
            removeFallbackVault(fallbackURL)
        }

        let store = BurnBarKeychainSecretStore(
            service: service,
            hermesCredentialPoolURL: nil,
            fallbackSecretFileURL: fallbackURL
        )
        try await store.setSecret("new-oauth-token", for: providerSlotKey)
        deleteKeychainSecret(service: service, account: account)

        let secret = try await store.secret(for: providerSlotKey)
        XCTAssertEqual(secret, "new-oauth-token")
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
            fallbackSecretFileURL: fallbackURL,
            claudeOAuthRefreshSession: session
        )
        try await store.setSecret(storedPayload, for: providerSlotKey)

        let secret = try await store.secret(for: providerSlotKey)
        XCTAssertEqual(secret, "refreshed-oauth-token")
        XCTAssertEqual(ClaudeOAuthRefreshURLProtocol.recordedRequestBodies(), [
            "grant_type=refresh_token&refresh_token=old-refresh-token&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e"
        ])
        let refreshedPayload = try fallbackSecret(in: fallbackURL, account: account)
        let oauth = try XCTUnwrap(claudeOAuthPayload(from: refreshedPayload))
        XCTAssertEqual(oauth["accessToken"] as? String, "refreshed-oauth-token")
        XCTAssertEqual(oauth["refreshToken"] as? String, "new-refresh-token")
        XCTAssertEqual(oauth["subscriptionType"] as? String, "max")
        XCTAssertEqual(oauth["rateLimitTier"] as? String, "default_claude_max_20x")
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
            fallbackSecretFileURL: fallbackURL
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

private func temporaryFallbackVaultURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("openburnbar-secret-continuity-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("provider-secrets.continuity.json", isDirectory: false)
}

private func removeFallbackVault(_ fallbackURL: URL) {
    try? FileManager.default.removeItem(at: fallbackURL.deletingLastPathComponent())
}

private func fallbackSecret(in fallbackURL: URL, account: String) throws -> String? {
    let data = try Data(contentsOf: fallbackURL)
    let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let secrets = try XCTUnwrap(root["secrets"] as? [String: String])
    return secrets[account]
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

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "platform.claude.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
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
