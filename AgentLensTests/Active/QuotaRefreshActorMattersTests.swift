import XCTest
@testable import OpenBurnBar
@testable import OpenBurnBarCore

/// Proves the switcher-profile Claude credential path that `QuotaRefreshActor`
/// now relies on instead of a bare `try?`.
///
/// `QuotaRefreshActor.claudeOAuthCredentials(fromSwitcherProfileConfigDirectory:)`
/// builds a `ClaudeCodeOAuthCredentialImporter` with `configDirectory:` set and
/// `allowDefaultKeychainFallback: false`, then calls
/// `load(allowUserInteraction: false)`. That `load()` deliberately distinguishes
/// *why* a profile-scoped credential is unusable:
///   - `.missing`   — no signed-in Claude Code session for this switcher profile
///                    (the common, benign case);
///   - `.malformed` — a credential file/keychain item exists but its shape is
///                    unreadable; and
///   - `.expired`   — a token is past its usable window (no refresh token to
///                    recover it).
///
/// The previous `try? ...load(...)` collapsed all three — plus any unexpected
/// fault — into one silent `nil`. In a security/quota product that means a
/// *corrupt* or *expired* profile credential looked identical to "no Claude Code
/// session": the switcher snapshot quietly fell back to the credential-less CLI
/// (reporting `.unavailable`) with no diagnostic and no trace of the real cause.
///
/// The fix replaces the bare `try?` with an explicit `do/catch` that:
///   1. preserves the graceful-degradation contract exactly — every failure
///      still yields `nil`, so the call site's `if let` simply skips credential
///      injection and runs the CLI unchanged (no behavior regression); and
///   2. makes the *meaningful* failures observable — `.malformed`, `.expired`,
///      and any unexpected error log at error level via `AppLogger`, while the
///      benign `.missing` path stays quiet to avoid log noise for every
///      non-Claude profile.
///
/// Critically, the fail-closed property holds: a malformed or expired profile
/// credential is **never** promoted into a usable credential. These tests drive
/// the importer through the exact construction the call site uses (a real temp
/// config directory feeding `.credentials.json`, an empty profile-scoped
/// keychain), so the precise mechanism `QuotaRefreshActor` depends on is
/// verified directly.
final class QuotaRefreshActorMattersTests: XCTestCase {
    private var tempRoots: [URL] = []

    override func tearDown() {
        for root in tempRoots {
            try? FileManager.default.removeItem(at: root)
        }
        tempRoots.removeAll()
        super.tearDown()
    }

    /// Mirrors `claudeOAuthCredentials(fromSwitcherProfileConfigDirectory:)`
    /// verbatim: profile-scoped config directory, no default keychain fallback,
    /// non-interactive. An empty in-memory backend feeds the profile-scoped
    /// keychain so the only credential source is the on-disk config dir.
    private func switcherProfileImporter(configDirectory: String) -> ClaudeCodeOAuthCredentialImporter {
        let backend = EmptyClaudeKeychainBackend()
        return ClaudeCodeOAuthCredentialImporter(
            keychain: KeychainStore(
                service: ClaudeCodeOAuthCredentialImporter.keychainService,
                legacyServices: [],
                backend: backend
            ),
            profileKeychainStore: { service in
                KeychainStore(service: service, legacyServices: [], backend: backend)
            },
            externalKeychainPasswordReader: { _, _ in nil },
            accounts: ["test-user"],
            configDirectory: configDirectory,
            allowDefaultKeychainFallback: false
        )
    }

    private func makeConfigDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-quota-switcher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        tempRoots.append(root)
        return root
    }

    private func writeCredentials(_ json: String, to root: URL) throws {
        try json.write(
            to: root.appendingPathComponent(".credentials.json", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
    }

    // MARK: - Healthy path (sanity)

    /// A well-formed, unexpired profile credential must still load — proving the
    /// fault/absent nils below are not masking a regression that always returns
    /// nil, and that the migrated call site still injects real credentials.
    func test_switcherProfile_validCredential_loadsAndInjects() throws {
        let root = try makeConfigDirectory()
        try writeCredentials(
            """
            {
              "claudeAiOauth": {
                "accessToken": "switcher-valid-token",
                "refreshToken": "switcher-valid-refresh",
                "expiresAt": 4102444800000,
                "subscriptionType": "max",
                "rateLimitTier": "default_claude_max_20x"
              }
            }
            """,
            to: root
        )

        let credentials = try switcherProfileImporter(configDirectory: root.path)
            .load(allowUserInteraction: false)

        XCTAssertEqual(credentials.accessToken, "switcher-valid-token")
        XCTAssertEqual(credentials.planDisplayName, "Max")
    }

    // MARK: - Benign absent path (.missing → silent nil)

    /// An empty config directory (no `.credentials.json`, empty profile keychain)
    /// throws `.missing`. The migrated call site maps this to a *silent* nil —
    /// the common, benign "no Claude Code session for this profile" case. The
    /// caller's `if let` then skips credential injection, identical to the
    /// pre-fix behavior, but without the error-level noise reserved for genuine
    /// correctness faults.
    func test_switcherProfile_absentCredential_throwsMissing() throws {
        let root = try makeConfigDirectory()

        XCTAssertThrowsError(
            try switcherProfileImporter(configDirectory: root.path).load(allowUserInteraction: false)
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                ClaudeCodeOAuthCredentialImportError.missing.localizedDescription,
                "An empty profile config directory must surface .missing, which the call site maps to a silent nil."
            )
        }
    }

    // MARK: - Fail-closed: malformed credential never promoted

    /// A credential file that exists but whose shape is unreadable throws
    /// `.malformed`. The fix logs this at error level (observable) and returns
    /// nil — it must NEVER be promoted into a usable credential. This is the
    /// fail-closed property the bare `try?` silently erased: a corrupt profile
    /// credential previously looked identical to "no session" with no trace.
    func test_switcherProfile_malformedCredential_throwsMalformedNeverPromoted() throws {
        let root = try makeConfigDirectory()
        // Valid JSON, but no usable `accessToken` — `ClaudeCredentialsReader`
        // returns nil, so `load()` records a malformed payload.
        try writeCredentials(
            """
            {
              "claudeAiOauth": {
                "refreshToken": "only-a-refresh-token",
                "subscriptionType": "max"
              }
            }
            """,
            to: root
        )

        XCTAssertThrowsError(
            try switcherProfileImporter(configDirectory: root.path).load(allowUserInteraction: false)
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                ClaudeCodeOAuthCredentialImportError.malformed.localizedDescription,
                "A malformed profile credential must fail closed as .malformed, never be promoted to a usable credential."
            )
        }
    }

    // MARK: - Fail-closed: expired credential never promoted

    /// An access token that is past its usable window with NO refresh token
    /// cannot recover, so `load()` throws `.expired`. The fix logs this at error
    /// level and returns nil — an expired token must never be injected into a
    /// quota/usage request (where it would 401), and must never be silently
    /// confused with "no session" as the bare `try?` allowed.
    func test_switcherProfile_expiredCredential_throwsExpiredNeverPromoted() throws {
        let root = try makeConfigDirectory()
        // expiresAt = 1_000_000_000_000 ms ≈ 2001-09-09, long past; no refresh
        // token, so `canCallUsageEndpoint()` is false → `.expired`.
        try writeCredentials(
            """
            {
              "claudeAiOauth": {
                "accessToken": "switcher-expired-token",
                "expiresAt": 1000000000000,
                "subscriptionType": "pro",
                "rateLimitTier": "default_claude_pro_5x"
              }
            }
            """,
            to: root
        )

        XCTAssertThrowsError(
            try switcherProfileImporter(configDirectory: root.path).load(allowUserInteraction: false)
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                ClaudeCodeOAuthCredentialImportError.expired.localizedDescription,
                "An expired, non-refreshable profile credential must fail closed as .expired, never be injected."
            )
        }
    }
}

// MARK: - Test backend

/// A `KeychainStoreBackend` that holds nothing, modelling an empty
/// profile-scoped keychain so the switcher importer's only credential source is
/// the on-disk config directory under test.
private final class EmptyClaudeKeychainBackend: KeychainStoreBackend, @unchecked Sendable {
    func set(_: Data, service _: String, account _: String) throws {}

    func data(for _: String, account _: String, allowUserInteraction _: Bool) throws -> Data? {
        nil
    }

    func delete(service _: String, account _: String) throws {}
}
