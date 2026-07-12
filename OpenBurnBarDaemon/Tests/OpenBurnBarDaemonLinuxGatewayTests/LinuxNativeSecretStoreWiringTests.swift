#if os(Linux)
import Foundation
import OpenBurnBarCore
import OpenBurnBarLinuxSecurity
@testable import OpenBurnBarDaemon
import XCTest

final class LinuxNativeSecretStoreWiringTests: XCTestCase {
    func testProviderAndConnectorStoresUseInjectedLinuxCustodianForCRUD() async throws {
        let backend = MutableLinuxSecretBackend()
        let custodian = LinuxSecretCustodian(backends: [backend])
        let providerStore = BurnBarKeychainSecretStore(
            service: "com.openburnbar.test.providers",
            legacyServices: [],
            hermesCredentialPoolURL: nil,
            claudeCodeCredentialsURL: nil,
            fallbackSecretFileURL: nil,
            linuxSecretCustodian: custodian
        )
        let connectorStore = BurnBarConnectorKeychainSecretStore(
            service: "com.openburnbar.test.connectors",
            linuxSecretCustodian: custodian
        )

        try await providerStore.setSecret("zai-secret", for: "zai")
        let providerSecret = try await providerStore.secret(for: "zai")
        XCTAssertEqual(providerSecret, "zai-secret")
        XCTAssertEqual(
            backend.secretClass(for: "com.openburnbar.test.providers:provider.zai.apiKey"),
            .providerCredential
        )

        try await connectorStore.setSecret("github-secret", for: .github)
        let connectorSecret = try await connectorStore.secret(for: .github)
        XCTAssertEqual(connectorSecret, "github-secret")
        XCTAssertEqual(
            backend.secretClass(for: "com.openburnbar.test.connectors:connector.github.credential"),
            .connectorCredential
        )

        try await providerStore.setSecret(nil, for: "zai")
        try await connectorStore.setSecret(nil, for: .github)
        let deletedProviderSecret = try await providerStore.secret(for: "zai")
        let deletedConnectorSecret = try await connectorStore.secret(for: .github)
        XCTAssertNil(deletedProviderSecret)
        XCTAssertNil(deletedConnectorSecret)
    }

    func testNotificationStoreUsesLinuxSecretCustodianForCRUD() throws {
        let backend = MutableLinuxSecretBackend()
        let store = BurnBarNotificationKeychainSecretStore(
            service: "com.openburnbar.test.notifications",
            linuxSecretCustodian: LinuxSecretCustodian(backends: [backend])
        )

        XCTAssertNil(try store.telegramBotToken())
        try store.setTelegramBotToken("  telegram-token  ")

        XCTAssertEqual(try store.telegramBotToken(), "telegram-token")
        XCTAssertEqual(
            backend.secretClass(
                for: "com.openburnbar.test.notifications:mission-control.telegram.bot-token"
            ),
            .connectorCredential
        )

        try store.setTelegramBotToken(nil)
        XCTAssertNil(try store.telegramBotToken())
    }
}

private final class MutableLinuxSecretBackend: LinuxSecretStoreBackend, @unchecked Sendable {
    let backendName = "test-native-secret-service"
    let trustLevel = LinuxSecretTrustLevel.secretService
    let supportsMutations = true

    private let lock = NSLock()
    private var records: [String: LinuxSecretRecord] = [:]

    func readSecret(
        id: String,
        secretClass _: LinuxHighValueSecretClass
    ) throws -> LinuxSecretRecord? {
        lock.withLock { records[id] }
    }

    func storeSecret(
        _ secret: String,
        id: String,
        secretClass: LinuxHighValueSecretClass
    ) throws -> LinuxSecretMetadata {
        let metadata = LinuxSecretMetadata(
            id: id,
            secretClass: secretClass,
            trustLevel: trustLevel,
            backend: backendName,
            createdAtMillis: 1_900_000_000_000,
            note: "test metadata"
        )
        lock.withLock {
            records[id] = LinuxSecretRecord(secret: secret, metadata: metadata)
        }
        return metadata
    }

    func deleteSecret(id: String, secretClass _: LinuxHighValueSecretClass) throws {
        _ = lock.withLock {
            records.removeValue(forKey: id)
        }
    }

    func healthCheck() throws {}

    func secretClass(for id: String) -> LinuxHighValueSecretClass? {
        lock.withLock { records[id]?.metadata.secretClass }
    }
}
#endif
