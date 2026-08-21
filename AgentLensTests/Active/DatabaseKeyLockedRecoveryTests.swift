#if DEBUG
import XCTest
import Security
@testable import OpenBurnBar

/// The most dangerous edge in the whole permission change.
///
/// Suppressing macOS keychain UI means a stale ACL no longer produces a password box.
/// It produces a *failure status* instead -- and the old code collapsed every failure
/// into `nil`, which `getOrCreatePersistedKey()` reads as "no key yet, mint a new one".
/// A new key makes an existing encrypted database unopenable forever.
///
/// So: "the key is absent" and "the key is there and macOS won't give it to me" must
/// never be confused, and only the first may create a key.
final class DatabaseKeyLockedRecoveryTests: XCTestCase {

    private func client(
        status: OSStatus,
        data: Data? = nil,
        onAdd: @escaping (@Sendable ([String: Any]) -> OSStatus) = { _ in errSecSuccess }
    ) -> DatabaseEncryptionKeychainClient {
        DatabaseEncryptionKeychainClient(
            copyMatching: { _ in (status, data as AnyObject?) },
            add: onAdd,
            delete: { _ in errSecSuccess }
        )
    }

    // MARK: lookUpKey classification

    func test_readableKeyIsFound() {
        let key = "dGVzdC1rZXk="
        DatabaseEncryptionService.withKeychainClientForTesting(
            client(status: errSecSuccess, data: Data(key.utf8))
        ) {
            guard case let .found(value) = DatabaseEncryptionService.lookUpKey() else {
                return XCTFail("expected .found")
            }
            XCTAssertEqual(value, key)
        }
    }

    func test_missingItemIsAbsentNotUnreadable() {
        DatabaseEncryptionService.withKeychainClientForTesting(client(status: errSecItemNotFound)) {
            guard case .absent = DatabaseEncryptionService.lookUpKey() else {
                return XCTFail("errSecItemNotFound must classify as .absent")
            }
        }
    }

    /// The statuses a stale login-keychain ACL actually produces once UI is suppressed.
    func test_blockedReadsAreUnreadableNotAbsent() {
        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled] {
            DatabaseEncryptionService.withKeychainClientForTesting(client(status: status)) {
                guard case .unreadable = DatabaseEncryptionService.lookUpKey() else {
                    return XCTFail("OSStatus \(status) must classify as .unreadable, not .absent")
                }
            }
        }
    }

    /// Present but not valid UTF-8: corrupt, not missing. Minting a replacement would
    /// still orphan the database.
    func test_undecodableDataIsUnreadableNotAbsent() {
        DatabaseEncryptionService.withKeychainClientForTesting(
            client(status: errSecSuccess, data: Data([0xFF, 0xFE, 0xFD]))
        ) {
            guard case .unreadable = DatabaseEncryptionService.lookUpKey() else {
                return XCTFail("undecodable key data must classify as .unreadable")
            }
        }
    }

    // MARK: the data-loss guard

    func test_unreadableKeyNeverMintsAReplacement() throws {
        final class AddCounter: @unchecked Sendable { var count = 0 }
        let adds = AddCounter()

        try DatabaseEncryptionService.withKeychainClientForTesting(
            client(status: errSecInteractionNotAllowed, onAdd: { _ in adds.count += 1; return errSecSuccess })
        ) {
            XCTAssertThrowsError(try DatabaseEncryptionService.getOrCreatePersistedKey()) { error in
                guard case DatabaseEncryptionError.keychainKeyUnreadable = error else {
                    return XCTFail("expected .keychainKeyUnreadable, got \(error)")
                }
            }
        }

        XCTAssertEqual(
            adds.count, 0,
            """
            A locked key must never be replaced. Writing a fresh key here would encrypt \
            future data with a key the existing database cannot be opened with -- silent, \
            permanent data loss.
            """
        )
    }

    /// The legitimate first-install path must still work.
    func test_absentKeyStillCreatesOne() throws {
        DatabaseEncryptionService.withKeychainClientForTesting(client(status: errSecItemNotFound)) {
            let key = try? DatabaseEncryptionService.getOrCreatePersistedKey()
            XCTAssertNotNil(key, "a genuinely absent key must still be created on first install")
            XCTAssertFalse(key?.isEmpty ?? true)
        }
    }

    // MARK: recovery surfacing

    func test_lockedKeyFailureIsMarkedRecoverable() {
        let failure = DataStoreStartupFailure.make(
            error: DatabaseEncryptionError.keychainKeyUnreadable(status: errSecInteractionNotAllowed)
        )
        XCTAssertTrue(
            failure.isKeychainLocked,
            "the recovery screen needs this to offer Unlock instead of only archive-and-reset"
        )
    }

    func test_otherFailuresAreNotMarkedRecoverable() {
        let failure = DataStoreStartupFailure.make(error: DatabaseEncryptionError.cipherUnavailable)
        XCTAssertFalse(failure.isKeychainLocked)
    }

    /// A locked key must read as recoverable to the user, not as data loss.
    func test_lockedKeyErrorCopyDoesNotSoundLikeDataLoss() {
        let error = DatabaseEncryptionError.keychainKeyUnreadable(status: errSecInteractionNotAllowed)
        let text = ((error.errorDescription ?? "") + " " + error.description).lowercased()
        XCTAssertTrue(text.contains("safe") || text.contains("preserved"),
                      "copy should reassure that the database is intact: \(text)")
        XCTAssertNotNil(error.recoverySuggestion)
    }

    /// Review caught this one: `lookUpKey()` classified correctly, but the caller that
    /// actually opens an existing encrypted database used `getKey()`, which collapses
    /// `.unreadable` back to nil. A locked key was therefore reported as *missing*, and
    /// the recovery screen offered archive-and-reset -- discarding an intact database --
    /// instead of the one-click Unlock that resolves it. The classification is only
    /// useful if it survives to the caller.
    func test_lockedAndMissingKeysProduceDifferentDiagnoses() {
        let locked = DataStoreStartupFailure.make(
            error: DatabaseEncryptionError.keychainKeyUnreadable(status: errSecInteractionNotAllowed)
        )
        let missing = DataStoreStartupFailure.make(
            error: DatabaseEncryptionError.existingEncryptedDatabaseKeyMissing(path: "/tmp/x.sqlite")
        )
        XCTAssertTrue(locked.isKeychainLocked, "a locked key must offer Unlock")
        XCTAssertFalse(missing.isKeychainLocked, "a genuinely missing key has no key to unlock")
        XCTAssertNotEqual(
            locked.errorSummary, missing.errorSummary,
            "the two states must not read identically to the user"
        )
    }
}
#endif
