#if os(Linux)
import Foundation
import OpenBurnBarCore
import OpenBurnBarLinuxSecurity
@testable import OpenBurnBarDaemon
import XCTest

final class MissionControlNotificationSecretStoreLinuxTests: XCTestCase {
    private let service = "com.openburnbar.test.notification-secrets"

    func testTelegramTokenRoundTripsThroughInjectedCustodian() throws {
        let backend = MutableNotificationSecretBackend()
        let store = makeStore(backend: backend)

        try store.setTelegramBotToken("  telegram-test-token  \n")

        XCTAssertEqual(try store.telegramBotToken(), "telegram-test-token")
        XCTAssertEqual(
            backend.record(for: secretID)?.metadata.secretClass,
            .connectorCredential
        )
        XCTAssertEqual(backend.record(for: secretID)?.secret, "telegram-test-token")
    }

    func testMissingTelegramTokenIsReportedAsUnconfigured() throws {
        let store = makeStore(backend: MutableNotificationSecretBackend())

        XCTAssertNil(try store.telegramBotToken())
    }

    func testClearingTelegramTokenDeletesCustodianSecret() throws {
        let backend = MutableNotificationSecretBackend()
        let store = makeStore(backend: backend)
        try store.setTelegramBotToken("telegram-token-to-delete")

        try store.setTelegramBotToken(nil)

        XCTAssertNil(try store.telegramBotToken())
        XCTAssertNil(backend.record(for: secretID))
    }

    func testLockedBackendErrorIsPropagatedAndPlaintextTrustIsRefused() throws {
        let lockedStore = makeStore(backend: ThrowingNotificationSecretBackend())

        XCTAssertThrowsError(try lockedStore.telegramBotToken()) { error in
            XCTAssertEqual(
                error as? LinuxSecretStoreError,
                .backendUnavailable("Secret Service is locked")
            )
        }
        XCTAssertThrowsError(try lockedStore.setTelegramBotToken("must-not-fallback")) { error in
            XCTAssertEqual(
                error as? LinuxSecretStoreError,
                .backendUnavailable("Secret Service is locked")
            )
        }

        let id = secretIDFor(service: service)
        let plaintextKey = id
            .uppercased()
            .replacingOccurrences(of: "-", with: "_")
        let plaintextBackend = LinuxHeadlessSecretStoreBackend(
            trustLevel: .explicitLowerTrustFile,
            environment: [plaintextKey: "plaintext-token"],
            allowsEnvironmentSecrets: true
        )
        let plaintextStore = BurnBarNotificationKeychainSecretStore(
            service: service,
            linuxSecretCustodian: LinuxSecretCustodian(backends: [plaintextBackend])
        )

        XCTAssertThrowsError(try plaintextStore.telegramBotToken()) { error in
            XCTAssertEqual(
                error as? LinuxSecretStoreError,
                .plaintextFallbackRefused(secretClass: .connectorCredential)
            )
        }
    }

    private var secretID: String {
        Self.secretIDFor(service: service)
    }

    private func makeStore(backend: any LinuxSecretStoreBackend) -> BurnBarNotificationKeychainSecretStore {
        BurnBarNotificationKeychainSecretStore(
            service: service,
            linuxSecretCustodian: LinuxSecretCustodian(backends: [backend])
        )
    }

    private static func secretIDFor(service: String) -> String {
        "\(service):mission-control.telegram.bot-token"
    }
}

private final class MutableNotificationSecretBackend: LinuxSecretStoreBackend, @unchecked Sendable {
    let backendName = "test-notification-secret-service"
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
        _ = lock.withLock { records.removeValue(forKey: id) }
    }

    func healthCheck() throws {}

    func record(for id: String) -> LinuxSecretRecord? {
        lock.withLock { records[id] }
    }
}

private struct ThrowingNotificationSecretBackend: LinuxSecretStoreBackend {
    let backendName = "locked-notification-secret-service"
    let trustLevel = LinuxSecretTrustLevel.secretService
    let supportsMutations = true

    func readSecret(id _: String, secretClass _: LinuxHighValueSecretClass) throws -> LinuxSecretRecord? {
        throw LinuxSecretStoreError.backendUnavailable("Secret Service is locked")
    }

    func storeSecret(
        _ secret: String,
        id: String,
        secretClass: LinuxHighValueSecretClass
    ) throws -> LinuxSecretMetadata {
        throw LinuxSecretStoreError.backendUnavailable("Secret Service is locked")
    }

    func deleteSecret(id _: String, secretClass _: LinuxHighValueSecretClass) throws {
        throw LinuxSecretStoreError.backendUnavailable("Secret Service is locked")
    }

    func healthCheck() throws {
        throw LinuxSecretStoreError.backendUnavailable("Secret Service is locked")
    }
}
#endif
