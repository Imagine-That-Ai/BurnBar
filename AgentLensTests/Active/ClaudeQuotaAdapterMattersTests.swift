import XCTest
@testable import OpenBurnBarCore
@testable import OpenBurnBar
final class ClaudeQuotaAdapterMattersTests: XCTestCase {

    private var tempRoot: URL!
    private var profileDir: URL!
    private var homeDir: URL!
    private var fileManager: FileManager!
    private var store: ProviderQuotaSnapshotStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        fileManager = FileManager.default
        tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("obb-claude-gate-\(UUID().uuidString)", isDirectory: true)
        profileDir = tempRoot.appendingPathComponent("profile", isDirectory: true)
        homeDir = tempRoot.appendingPathComponent("home", isDirectory: true)
        try fileManager.createDirectory(at: profileDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: homeDir, withIntermediateDirectories: true)

        let appPaths = OpenBurnBarAppPaths(applicationSupportRoot: tempRoot)
        store = ProviderQuotaSnapshotStore(appPaths: appPaths, fileManager: fileManager)
    }

    override func tearDownWithError() throws {
        if let tempRoot { try? fileManager.removeItem(at: tempRoot) }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private var profileStateURL: URL {
        profileDir.appendingPathComponent(".claude.json", isDirectory: false)
    }

    private var defaultStateURL: URL {
        homeDir.appendingPathComponent(".claude.json", isDirectory: false)
    }

    private func writeState(_ url: URL, accountUuid: String?, email: String? = nil, organizationUuid: String? = nil) throws {
        var account: [String: Any] = [:]
        if let accountUuid { account["accountUuid"] = accountUuid }
        if let email { account["emailAddress"] = email }
        if let organizationUuid { account["organizationUuid"] = organizationUuid }
        let object: [String: Any] = ["oauthAccount": account]
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: url, options: .atomic)
    }

    private func writeRaw(_ url: URL, _ contents: String) throws {
        try Data(contents.utf8).write(to: url, options: .atomic)
    }

    private func matches() -> Bool {
        ClaudeQuotaAdapter.scopedClaudeProfileMatchesDefaultLogin(
            snapshotStore: store,
            profileStateURL: profileStateURL,
            defaultStateURL: defaultStateURL
        )
    }

    // MARK: - Positive identity match

    /// Same account UUID in both files: reuse is allowed (the global statusline
    /// hook is this account's live signal, not cross-account leakage).
    func testMatchesWhenSameAccountUUID() throws {
        try writeState(profileStateURL, accountUuid: "ACC-123")
        try writeState(defaultStateURL, accountUuid: "ACC-123")
        XCTAssertTrue(matches())
    }

    /// Case-insensitive identity match: the adapter lowercases candidates.
    func testMatchesCaseInsensitively() throws {
        try writeState(profileStateURL, accountUuid: "Acc-ABC")
        try writeState(defaultStateURL, accountUuid: "acc-abc")
        XCTAssertTrue(matches())
    }

    /// Overlap on any one identity field (email here) is sufficient.
    func testMatchesOnSharedEmailEvenWithDifferentUUID() throws {
        try writeState(profileStateURL, accountUuid: "ACC-1", email: "user@example.com")
        try writeState(defaultStateURL, accountUuid: "ACC-2", email: "user@example.com")
        XCTAssertTrue(matches())
    }

    // MARK: - Fail-closed: different identity

    /// Distinct accounts: reuse must be denied so this card never shows the
    /// other account's quota.
    func testDeniesWhenDifferentAccount() throws {
        try writeState(profileStateURL, accountUuid: "ACC-AAA", email: "a@example.com")
        try writeState(defaultStateURL, accountUuid: "ACC-BBB", email: "b@example.com")
        XCTAssertFalse(matches())
    }

    /// Empty identity on either side (no usable fields) denies reuse — an
    /// empty set must never be treated as "matching".
    func testDeniesWhenProfileIdentityEmpty() throws {
        try writeRaw(profileStateURL, "{\"oauthAccount\":{}}")
        try writeState(defaultStateURL, accountUuid: "ACC-123")
        XCTAssertFalse(matches())
    }

    // MARK: - Absent files (benign nil): quiet fail-closed

    /// Profile file absent (the common "no .claude.json for this profile"
    /// case): `readJSONObject` returns nil, gate denies reuse without erroring.
    func testDeniesWhenProfileFileAbsent() throws {
        try writeState(defaultStateURL, accountUuid: "ACC-123")
        XCTAssertFalse(fileManager.fileExists(atPath: profileStateURL.path))
        XCTAssertFalse(matches())
    }

    /// Default file absent: same quiet denial.
    func testDeniesWhenDefaultFileAbsent() throws {
        try writeState(profileStateURL, accountUuid: "ACC-123")
        XCTAssertFalse(fileManager.fileExists(atPath: defaultStateURL.path))
        XCTAssertFalse(matches())
    }

    // MARK: - Real read/parse fault: fail-closed (and logged)

    /// Corrupt JSON in the profile file makes `readJSONObject` throw. This is a
    /// genuine fault, not an absent file. The gate must still FAIL CLOSED
    /// (deny reuse) rather than fall open to the previous silent default — and
    /// it must not crash. The error is logged in the adapter (observability),
    /// which this test exercises through the throwing read path.
    func testFailsClosedWhenProfileFileCorrupt() throws {
        try writeRaw(profileStateURL, "{ this is not valid json :::")
        try writeState(defaultStateURL, accountUuid: "ACC-123")
        XCTAssertFalse(matches())
    }

    /// Corrupt JSON in the default file: same fail-closed guarantee. Even
    /// though the profile read succeeds and would have a valid identity, an
    /// unreadable default-login identity must never permit reuse.
    func testFailsClosedWhenDefaultFileCorrupt() throws {
        try writeState(profileStateURL, accountUuid: "ACC-123")
        try writeRaw(defaultStateURL, "<<<not json>>>")
        XCTAssertFalse(matches())
    }

    /// A file whose JSON is a top-level array (not an object) parses but is not
    /// a `[String: Any]`; `readJSONObject` returns nil and the gate denies
    /// reuse without faulting.
    func testDeniesWhenStateIsNonObjectJSON() throws {
        try writeRaw(profileStateURL, "[1, 2, 3]")
        try writeState(defaultStateURL, accountUuid: "ACC-123")
        XCTAssertFalse(matches())
    }
}
