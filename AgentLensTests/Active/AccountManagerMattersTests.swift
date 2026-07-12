import XCTest
@testable import OpenBurnBar

/// Locks down the Firebase-Auth keychain-identifier extraction that gates the
/// keychain-recovery cleanup (`clearFirebaseAuthKeychainState`).
///
/// The bundled `GoogleService-Info.plist` is the *only* source of the
/// `apiKey` / `googleAppID` from which the destructive keychain delete queries
/// are built. Previously the plist read + decode used `try?`, so an unreadable
/// or corrupt bundled resource silently produced `nil` -> the recovery deletes
/// were skipped with no observable signal, leaving stale Firebase Auth keychain
/// rows behind on the very keychain-fault path that recovery exists to heal.
///
/// These tests assert the hardened behavior: the failure still fails *closed*
/// (returns `nil`, skipping the dangerous deletes — there is no safe permissive
/// fallback), but the failure is now *surfaced* via `logAuthKeychainFailure`.
@MainActor
final class AccountManagerMattersTests: XCTestCase {

    private enum DeletionTestError: Error, Equatable {
        case server
        case localSignOut
    }

    private var observedFailures: [Error] = []

    override func setUp() {
        super.setUp()
        observedFailures = []
        AccountManager.authKeychainFailureObserverForTesting = { [weak self] error in
            self?.observedFailures.append(error)
        }
    }

    override func tearDown() {
        AccountManager.authKeychainFailureObserverForTesting = nil
        observedFailures = []
        super.tearDown()
    }

    // MARK: - Helpers

    private func writeTempFile(_ data: Data, ext: String = "plist") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("acctmgr-\(UUID().uuidString).\(ext)")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func validConfigPlistData(
        apiKey: String = "AIza-test-api-key",
        googleAppID: String = "1:123:ios:abcdef"
    ) throws -> Data {
        let dict: [String: Any] = [
            "API_KEY": apiKey,
            "GOOGLE_APP_ID": googleAppID,
            "BUNDLE_ID": "com.openburnbar.app"
        ]
        return try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    }

    // MARK: - Server-authoritative account deletion

    func test_accountDeletion_serverFailurePropagatesWithoutClearingLocalSession() async {
        var didAttemptLocalSignOut = false
        var didClearClientState = false
        var observedLocalFailure: Error?

        do {
            try await AccountManager.completeServerAuthoritativeAccountDeletion(
                requestServerErasure: { throw DeletionTestError.server },
                signOutFirebaseLocally: { didAttemptLocalSignOut = true },
                clearClientAuthState: { didClearClientState = true },
                observeLocalSignOutFailure: { observedLocalFailure = $0 }
            )
            XCTFail("A server erasure failure must propagate to keep the account retryable.")
        } catch {
            XCTAssertEqual(error as? DeletionTestError, .server)
        }

        XCTAssertFalse(didAttemptLocalSignOut)
        XCTAssertFalse(didClearClientState)
        XCTAssertNil(observedLocalFailure)
    }

    func test_accountDeletion_serverSuccessSignsOutAndClearsClientState() async throws {
        var didAttemptLocalSignOut = false
        var didClearClientState = false
        var observedLocalFailure: Error?

        try await AccountManager.completeServerAuthoritativeAccountDeletion(
            requestServerErasure: {},
            signOutFirebaseLocally: { didAttemptLocalSignOut = true },
            clearClientAuthState: { didClearClientState = true },
            observeLocalSignOutFailure: { observedLocalFailure = $0 }
        )

        XCTAssertTrue(didAttemptLocalSignOut)
        XCTAssertTrue(didClearClientState)
        XCTAssertNil(observedLocalFailure)
    }

    func test_accountDeletion_localSignOutFailureDoesNotMisreportCompletedErasure() async throws {
        var didClearClientState = false
        var observedLocalFailure: Error?

        try await AccountManager.completeServerAuthoritativeAccountDeletion(
            requestServerErasure: {},
            signOutFirebaseLocally: { throw DeletionTestError.localSignOut },
            clearClientAuthState: { didClearClientState = true },
            observeLocalSignOutFailure: { observedLocalFailure = $0 }
        )

        XCTAssertTrue(didClearClientState)
        XCTAssertEqual(observedLocalFailure as? DeletionTestError, .localSignOut)
    }

    // MARK: - Happy path: valid plist yields identifiers

    func test_identifiers_fromValidDict_deriveServiceNameAndPreserveAppName() {
        let result = AccountManager.firebaseAuthKeychainIdentifiers(
            from: [
                "API_KEY": "AIza-key",
                "GOOGLE_APP_ID": "1:42:ios:deadbeef"
            ],
            appName: "__FIRAPP_DEFAULT"
        )

        XCTAssertEqual(result?.apiKey, "AIza-key")
        XCTAssertEqual(result?.googleAppID, "1:42:ios:deadbeef")
        XCTAssertEqual(result?.serviceName, "firebase_auth_1:42:ios:deadbeef")
        XCTAssertEqual(result?.appName, "__FIRAPP_DEFAULT")
        XCTAssertTrue(observedFailures.isEmpty, "Happy path must not surface a failure.")
    }

    func test_loadConfigPlist_validFile_returnsDictionaryWithoutFailure() throws {
        let url = try writeTempFile(try validConfigPlistData())

        let values = AccountManager.loadFirebaseConfigPlist(at: url)

        XCTAssertEqual(values?["API_KEY"] as? String, "AIza-test-api-key")
        XCTAssertEqual(values?["GOOGLE_APP_ID"] as? String, "1:123:ios:abcdef")
        XCTAssertTrue(observedFailures.isEmpty, "A readable, well-formed plist must not surface a failure.")
    }

    // MARK: - Missing required keys: fail closed, NO spurious failure log

    func test_identifiers_missingApiKey_returnsNil() {
        let result = AccountManager.firebaseAuthKeychainIdentifiers(
            from: ["GOOGLE_APP_ID": "1:42:ios:deadbeef"],
            appName: "__FIRAPP_DEFAULT"
        )
        XCTAssertNil(result, "Missing API_KEY must fail closed (no identifiers -> deletes skipped).")
    }

    func test_identifiers_missingGoogleAppID_returnsNil() {
        let result = AccountManager.firebaseAuthKeychainIdentifiers(
            from: ["API_KEY": "AIza-key"],
            appName: "__FIRAPP_DEFAULT"
        )
        XCTAssertNil(result, "Missing GOOGLE_APP_ID must fail closed.")
    }

    func test_identifiers_nonStringValues_returnsNil() {
        let result = AccountManager.firebaseAuthKeychainIdentifiers(
            from: ["API_KEY": 123, "GOOGLE_APP_ID": ["nested"]],
            appName: "__FIRAPP_DEFAULT"
        )
        XCTAssertNil(result, "Non-string identifier values must fail closed, never coerce.")
    }

    // MARK: - Corrupt / unreadable bundled resource: fail closed AND surface

    func test_loadConfigPlist_corruptData_returnsNilAndSurfacesFailure() throws {
        // Not a property list at all.
        let url = try writeTempFile(Data("this is not a plist {{{".utf8))

        let values = AccountManager.loadFirebaseConfigPlist(at: url)

        XCTAssertNil(values, "A corrupt bundled plist must fail closed (skip the destructive deletes).")
        XCTAssertEqual(
            observedFailures.count, 1,
            "A corrupt bundled plist must be surfaced via logAuthKeychainFailure, not swallowed by try?."
        )
    }

    func test_loadConfigPlist_missingFile_returnsNilAndSurfacesFailure() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("acctmgr-does-not-exist-\(UUID().uuidString).plist")

        let values = AccountManager.loadFirebaseConfigPlist(at: url)

        XCTAssertNil(values, "An unreadable bundled plist must fail closed.")
        XCTAssertEqual(
            observedFailures.count, 1,
            "A read failure on the bundled plist must be surfaced, not swallowed by try?."
        )
    }

    func test_loadConfigPlist_nonDictionaryPlist_returnsNilAndSurfacesMalformedFailure() throws {
        // A valid property list whose root is an array, not a dictionary.
        let arrayData = try PropertyListSerialization.data(
            fromPropertyList: ["a", "b"], format: .xml, options: 0
        )
        let url = try writeTempFile(arrayData)

        let values = AccountManager.loadFirebaseConfigPlist(at: url)

        XCTAssertNil(values, "A non-dictionary plist root must fail closed.")
        XCTAssertEqual(observedFailures.count, 1, "A malformed plist shape must be surfaced.")
        XCTAssertTrue(
            observedFailures.first is AccountError,
            "Malformed plist shape should surface as AccountError.malformedFirebaseConfigResource."
        )
    }

    // MARK: - End-to-end through loadFirebaseConfigPlist + extraction

    func test_loadThenExtract_validFile_yieldsIdentifiers() throws {
        let url = try writeTempFile(try validConfigPlistData(
            apiKey: "AIza-e2e", googleAppID: "1:7:ios:cafe"
        ))

        let values = try XCTUnwrap(AccountManager.loadFirebaseConfigPlist(at: url))
        let identifiers = AccountManager.firebaseAuthKeychainIdentifiers(
            from: values, appName: "app-under-test"
        )

        XCTAssertEqual(identifiers?.apiKey, "AIza-e2e")
        XCTAssertEqual(identifiers?.serviceName, "firebase_auth_1:7:ios:cafe")
        XCTAssertEqual(identifiers?.appName, "app-under-test")
        XCTAssertTrue(observedFailures.isEmpty)
    }
}
