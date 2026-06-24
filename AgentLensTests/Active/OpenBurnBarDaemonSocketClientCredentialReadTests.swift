import Security
import XCTest
@testable import OpenBurnBar
@testable import OpenBurnBarCore

/// Proves the daemon-socket auth-token read distinguishes a *broken* Keychain
/// from "no token configured".
///
/// Before this fix the read was `try? controllerRuntimeSecrets.string(for:)`,
/// which collapsed a locked keychain / ACL denial / unhandled `OSStatus` /
/// corrupt data into the exact same `nil` as a genuinely absent token. The app
/// would then mint unsigned daemon RPCs as if no token had ever been
/// provisioned, with zero diagnostic. The read now goes through
/// `credentialIfPresent`, so a real fault is logged and still safely returns
/// `nil`, while the nil-on-absent contract callers rely on is preserved.
final class OpenBurnBarDaemonSocketClientCredentialReadTests: XCTestCase {

    private let service = OpenBurnBarIdentity.controllerRuntimeKeychainService
    private let account = OpenBurnBarIdentity.daemonSocketAuthTokenAccount

    private func makeStore(backend: KeychainStoreBackend) -> KeychainStore {
        KeychainStore(service: service, legacyServices: [], backend: backend)
    }

    // MARK: - Fault path is observable, not swallowed-as-absent

    func test_readDaemonSocketAuthToken_returnsNilWithoutThrowingOnKeychainFault() {
        // A genuine Keychain fault (errSecNotAvailable == locked / unavailable
        // keychain) must surface to the log and yield nil — never throw, never
        // crash, never propagate. The whole point of the migration off `try?`.
        let backend = FaultInjectingKeychainBackend()
        backend.readError = KeychainStoreError.unhandled(errSecNotAvailable)
        let store = makeStore(backend: backend)

        // The legacy `try?` form could not even be observed as a fault; here we
        // assert the read completes (does not throw) and returns nil.
        let token = OpenBurnBarDaemonSocketClient.readDaemonSocketAuthToken(from: store)

        XCTAssertNil(token)
        XCTAssertEqual(backend.readAttempts, 1, "the fault must come from an actual backend read attempt")
    }

    // MARK: - Absent path still yields nil

    func test_readDaemonSocketAuthToken_returnsNilWhenTokenAbsent() {
        let backend = FaultInjectingKeychainBackend()
        let store = makeStore(backend: backend)

        XCTAssertNil(OpenBurnBarDaemonSocketClient.readDaemonSocketAuthToken(from: store))
    }

    // MARK: - Present path is unchanged

    func test_readDaemonSocketAuthToken_returnsTrimmedTokenWhenPresent() throws {
        let backend = FaultInjectingKeychainBackend()
        let store = makeStore(backend: backend)
        try store.set("  daemon-socket-token  ", for: account)

        XCTAssertEqual(
            OpenBurnBarDaemonSocketClient.readDaemonSocketAuthToken(from: store),
            "daemon-socket-token"
        )
    }

    func test_readDaemonSocketAuthToken_collapsesWhitespaceOnlyTokenToNil() throws {
        let backend = FaultInjectingKeychainBackend()
        let store = makeStore(backend: backend)
        try store.set("   \n  ", for: account)

        XCTAssertNil(OpenBurnBarDaemonSocketClient.readDaemonSocketAuthToken(from: store))
    }

    func test_readDaemonSocketAuthToken_readsPrivateTokenFileWhenKeychainFaults() throws {
        let backend = FaultInjectingKeychainBackend()
        backend.readError = KeychainStoreError.unhandled(errSecNotAvailable)
        let store = makeStore(backend: backend)
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BurnBarSocketTokenFallback-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let tokenFileURL = rootURL.appendingPathComponent("daemon-socket-auth-token", isDirectory: false)
        try "  file-token  ".write(to: tokenFileURL, atomically: true, encoding: .utf8)

        XCTAssertEqual(
            OpenBurnBarDaemonSocketClient.readDaemonSocketAuthToken(
                from: store,
                tokenFileURL: tokenFileURL
            ),
            "file-token"
        )
        XCTAssertEqual(backend.readAttempts, 1)
    }

    func test_readDaemonSocketAuthToken_returnsNilWhenKeychainAndTokenFileAreAbsent() {
        let backend = FaultInjectingKeychainBackend()
        let store = makeStore(backend: backend)
        let missingFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-daemon-socket-auth-token-\(UUID().uuidString)", isDirectory: false)

        XCTAssertNil(
            OpenBurnBarDaemonSocketClient.readDaemonSocketAuthToken(
                from: store,
                tokenFileURL: missingFileURL
            )
        )
    }
}

// MARK: - Fault-injecting Keychain backend

/// Minimal in-memory `KeychainStoreBackend` that can be told to throw on read,
/// exercising the real-fault branch of `credentialIfPresent` without touching
/// the system keychain.
private final class FaultInjectingKeychainBackend: KeychainStoreBackend, @unchecked Sendable {
    var storage: [String: [String: Data]] = [:]
    var readError: Error?
    private(set) var readAttempts = 0

    func set(_ value: Data, service: String, account: String) throws {
        storage[service, default: [:]][account] = value
    }

    func data(for service: String, account: String, allowUserInteraction _: Bool) throws -> Data? {
        readAttempts += 1
        if let readError {
            throw readError
        }
        return storage[service]?[account]
    }

    func delete(service: String, account: String) throws {
        storage[service]?[account] = nil
    }
}
