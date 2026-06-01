import Foundation
import XCTest
import SQLite3
import OpenBurnBarCore
@testable import OpenBurnBar

// MARK: - CursorCookieExtractor Scoped Session Tests

/// Tests for the `CursorCookieExtractor.readSession(fromAgentConfigDirectory:)`
/// scoped reader that powers per-profile quota isolation.
final class CursorAgentScopedSessionTests: XCTestCase {

    // MARK: - Helpers

    private var tempDirectories: [URL] = []

    override func tearDown() {
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
        super.tearDown()
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CursorAgentScopedTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        return directory
    }

    /// Creates a minimal `state.vscdb` at `configDirectory/User/globalStorage/state.vscdb`
    /// with the given access token.
    private func seedAgentDatabase(
        in configDirectory: URL,
        accessToken: String,
        email: String? = nil
    ) throws -> URL {
        let storagePath = configDirectory
            .appendingPathComponent("User/globalStorage", isDirectory: true)
        try FileManager.default.createDirectory(at: storagePath, withIntermediateDirectories: true)
        let dbURL = storagePath.appendingPathComponent("state.vscdb")

        // SQLITE_TRANSIENT is a C macro (-1 cast to destructor_type) not bridged in Swift test targets.
        let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type?.self)

        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else {
            throw NSError(domain: "CursorAgentTestHelper", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to open SQLite DB at \(dbURL.path)"])
        }
        defer { sqlite3_close(db) }

        sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS ItemTable (key TEXT UNIQUE, value TEXT)", nil, nil, nil)
        let insertSQL = "INSERT OR REPLACE INTO ItemTable (key, value) VALUES (?, ?)"

        func insert(_ key: String, _ value: String) {
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil)
            sqlite3_bind_text(stmt, 1, key, -1, sqliteTransient)
            sqlite3_bind_text(stmt, 2, value, -1, sqliteTransient)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }

        insert("cursorAuth/accessToken", accessToken)
        if let email { insert("cursorAuth/cachedEmail", email) }

        return dbURL
    }

    // MARK: - Tests

    func test_scopedRead_returnsNilForMissingDirectory() {
        let session = CursorCookieExtractor.readSession(fromAgentConfigDirectory: "/nonexistent/path/\(UUID().uuidString)")
        XCTAssertNil(session, "Scoped read must return nil when the config directory does not exist")
    }

    func test_scopedRead_returnsNilWhenDirectoryExistsButNoDB() throws {
        let dir = try makeTemporaryDirectory()
        let session = CursorCookieExtractor.readSession(fromAgentConfigDirectory: dir.path)
        XCTAssertNil(session, "Scoped read must return nil when state.vscdb is absent")
    }

    func test_scopedRead_returnsSessionFromVSCodeStylePath() throws {
        let dir = try makeTemporaryDirectory()
        // A realistic JWT sub claim: "auth0|abc123"
        let fakeJWT = makeJWT(sub: "auth0|abc123")
        try seedAgentDatabase(in: dir, accessToken: fakeJWT, email: "reserve@example.com")

        let session = CursorCookieExtractor.readSession(fromAgentConfigDirectory: dir.path)
        XCTAssertNotNil(session, "Scoped read must find state.vscdb under User/globalStorage/")
        XCTAssertEqual(session?.email, "reserve@example.com")
        XCTAssertTrue(session?.cookieHeader.hasPrefix("WorkosCursorSessionToken=") == true)
    }

    func test_scopedRead_extractsUserIdFromJWT() throws {
        let dir = try makeTemporaryDirectory()
        let fakeJWT = makeJWT(sub: "auth0|myuserid999")
        try seedAgentDatabase(in: dir, accessToken: fakeJWT)

        let session = CursorCookieExtractor.readSession(fromAgentConfigDirectory: dir.path)
        XCTAssertNotNil(session)
        // The cookie header must contain the extracted userId portion (after '|')
        XCTAssertTrue(session?.cookieHeader.contains("myuserid999") == true,
                      "Cookie header must embed the userId extracted from JWT sub claim")
    }

    func test_scopedRead_doesNotFallThroughToGlobalDB() throws {
        // Even if the global Cursor app DB exists, the scoped reader must NOT
        // read from it — only from the supplied config directory.
        let dir = try makeTemporaryDirectory()
        // dir has NO state.vscdb → must return nil, never touching global ~/.cursor/state.vscdb
        let session = CursorCookieExtractor.readSession(fromAgentConfigDirectory: dir.path)
        XCTAssertNil(session, "Scoped read must not fall through to global Cursor DB")
    }

    func test_scopedRead_isolatesAccountsAcrossProfiles() throws {
        let dir1 = try makeTemporaryDirectory()
        let dir2 = try makeTemporaryDirectory()

        let jwt1 = makeJWT(sub: "auth0|primary123", email: "primary@example.com")
        let jwt2 = makeJWT(sub: "auth0|reserve456", email: "reserve@example.com")
        try seedAgentDatabase(in: dir1, accessToken: jwt1, email: "primary@example.com")
        try seedAgentDatabase(in: dir2, accessToken: jwt2, email: "reserve@example.com")

        let session1 = CursorCookieExtractor.readSession(fromAgentConfigDirectory: dir1.path)
        let session2 = CursorCookieExtractor.readSession(fromAgentConfigDirectory: dir2.path)

        XCTAssertEqual(session1?.email, "primary@example.com")
        XCTAssertEqual(session2?.email, "reserve@example.com")
        XCTAssertNotEqual(session1?.cookieHeader, session2?.cookieHeader,
                          "Each profile's cookie must be derived from its own isolated session")
    }

    // MARK: - JWT Helpers

    private func makeJWT(sub: String, email: String? = nil) -> String {
        let header = base64URLEncode(#"{"alg":"RS256","typ":"JWT"}"#.data(using: .utf8)!)
        var claims: [String: String] = ["sub": sub]
        if let email { claims["email"] = email }
        let claimsJSON = try! JSONSerialization.data(withJSONObject: claims)
        let payload = base64URLEncode(claimsJSON)
        return "\(header).\(payload).fakesig"
    }

    private func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - BurnBarProviderAuthRegistry Cursor Agent Descriptor Tests

final class CursorAgentAuthRegistryTests: XCTestCase {

    func test_registry_containsCursorAgentDescriptor() {
        let descriptor = BurnBarProviderAuthRegistry.descriptor(forCatalogProviderID: "cursor-agent")
        XCTAssertNotNil(descriptor, "Registry must contain a descriptor for 'cursor-agent'")
        XCTAssertEqual(descriptor?.providerID, "cursor-agent")
    }

    func test_registry_cursorAliasResolvesToCursorAgentDescriptor() {
        // 'cursor' is an alias for the cursor-agent descriptor
        let descriptor = BurnBarProviderAuthRegistry.descriptor(forCatalogProviderID: "cursor")
        XCTAssertNotNil(descriptor, "Registry must resolve 'cursor' alias to cursor-agent descriptor")
    }

    func test_registry_cursorAgentAliasResolvesToDescriptor() {
        let descriptor = BurnBarProviderAuthRegistry.descriptor(forCatalogProviderID: "cursoragent")
        XCTAssertNotNil(descriptor, "Registry must resolve 'cursoragent' alias to cursor-agent descriptor")
    }

    func test_cursorAgentDescriptor_hasBrowserLoginMethod() {
        guard let descriptor = BurnBarProviderAuthRegistry.descriptor(forCatalogProviderID: "cursor-agent") else {
            XCTFail("Missing cursor-agent descriptor")
            return
        }
        let browserLoginMethod = descriptor.methods.first { $0.kind == .browserLogin }
        XCTAssertNotNil(browserLoginMethod, "Cursor Agent descriptor must have a browserLogin auth method")
        XCTAssertEqual(browserLoginMethod?.id, "cursor-agent-browser-login")
        XCTAssertTrue(browserLoginMethod?.unlocksQuotaRefresh == true,
                      "Browser login method must unlock quota refresh")
        XCTAssertFalse(browserLoginMethod?.unlocksProxyRouting == true,
                       "Browser login must not unlock proxy routing (Cursor Agent is a local CLI)")
    }

    func test_cursorAgentDescriptor_hasCookieMethod() {
        guard let descriptor = BurnBarProviderAuthRegistry.descriptor(forCatalogProviderID: "cursor-agent") else {
            XCTFail("Missing cursor-agent descriptor")
            return
        }
        let cookieMethod = descriptor.methods.first { $0.kind == .cookie }
        XCTAssertNotNil(cookieMethod, "Cursor Agent descriptor must have a cookie auth method")
        XCTAssertEqual(cookieMethod?.id, "cursor-cookie")
    }

    func test_cursorAgentDescriptor_primaryMethodIsBrowserLogin() {
        guard let descriptor = BurnBarProviderAuthRegistry.descriptor(forCatalogProviderID: "cursor-agent") else {
            XCTFail("Missing cursor-agent descriptor")
            return
        }
        XCTAssertEqual(descriptor.primaryMethodID, "cursor-agent-browser-login")
        XCTAssertEqual(descriptor.primaryMethod.id, "cursor-agent-browser-login")
    }

    func test_cursorAgentDescriptor_supportsQuotaRefresh() {
        guard let descriptor = BurnBarProviderAuthRegistry.descriptor(forCatalogProviderID: "cursor-agent") else {
            XCTFail("Missing cursor-agent descriptor")
            return
        }
        XCTAssertTrue(descriptor.supportsQuotaRefresh,
                      "Cursor Agent descriptor must declare at least one quota-refresh method")
    }

    func test_cursorAgentDescriptor_doesNotSupportProxyRouting() {
        guard let descriptor = BurnBarProviderAuthRegistry.descriptor(forCatalogProviderID: "cursor-agent") else {
            XCTFail("Missing cursor-agent descriptor")
            return
        }
        XCTAssertFalse(descriptor.supportsProxyRouting,
                       "Cursor Agent is a local CLI — proxy routing must not be enabled")
    }

    func test_allRegistryDescriptors_uniqueProviderIDs() {
        let ids = BurnBarProviderAuthRegistry.descriptors.map(\.providerID)
        let unique = Set(ids)
        XCTAssertEqual(ids.count, unique.count, "All registry descriptors must have unique providerIDs")
    }

    // MARK: - CursorQuotaAdapter targetProvider regression tests

    func test_cursorQuotaAdapter_cursorAgentTargetProduces_cursorAgentProvider() {
        // Ensures the adapter's targetProvider wiring is correct. Without the
        // targetProvider fix, snapshots from .cursorAgent registrations would
        // carry provider: .cursor, breaking failover eligibility checks and
        // Firestore attribution.
        let adapter = CursorQuotaAdapter(targetProvider: .cursorAgent)
        XCTAssertEqual(adapter.targetProvider, .cursorAgent,
                       "CursorQuotaAdapter initialized with .cursorAgent must expose that as targetProvider")
    }

    func test_cursorQuotaAdapter_cursorTargetProduces_cursorProvider() {
        let adapter = CursorQuotaAdapter(targetProvider: .cursor)
        XCTAssertEqual(adapter.targetProvider, .cursor,
                       "CursorQuotaAdapter initialized with .cursor must expose that as targetProvider")
    }

    func test_cursorQuotaAdapter_defaultInitProduces_cursorProvider() {
        let adapter = CursorQuotaAdapter()
        XCTAssertEqual(adapter.targetProvider, .cursor,
                       "CursorQuotaAdapter default init (no argument) must default to .cursor for backward compat")
    }
}

// MARK: - SwitcherCLIFallbackPlanner Cursor Agent Tests

@MainActor
final class CursorAgentFallbackPlannerTests: XCTestCase {

    func test_orderedCandidates_groupsCursorAgentProfilesForFailover() async {
        let planner = SwitcherCLIFallbackPlanner { _ in nil }

        let primary = makeCursorAgentProfile(id: "primary", label: "Cursor Primary")
        let reserve = makeCursorAgentProfile(id: "reserve-1", label: "Cursor Reserve")

        let ordered = await planner.orderedCandidates(
            for: primary,
            allProfiles: [primary, reserve]
        )

        XCTAssertTrue(ordered.map(\.id).contains("primary"),
                      "Primary profile must be in candidates")
        XCTAssertTrue(ordered.map(\.id).contains("reserve-1"),
                      "Reserve profile must be included for failover")
    }

    func test_orderedCandidates_doesNotMixCursorAgentWithCodexProfiles() async {
        let planner = SwitcherCLIFallbackPlanner { _ in nil }

        let cursorPrimary = makeCursorAgentProfile(id: "cursor-primary", label: "Cursor Primary")
        let codexProfile = makeCodexProfile(id: "codex-main", label: "Codex Main")

        let ordered = await planner.orderedCandidates(
            for: cursorPrimary,
            allProfiles: [cursorPrimary, codexProfile]
        )

        XCTAssertFalse(ordered.map(\.id).contains("codex-main"),
                       "Codex profiles must not be included in Cursor Agent failover candidates")
    }

    func test_eligibility_marksExhaustedCursorAgentProfileAsIneligible() async {
        let exhaustionEnd = Date().addingTimeInterval(3600) // exhausted for 1 hour
        let planner = SwitcherCLIFallbackPlanner { _ in nil }

        let exhaustedProfile = SwitcherProfileRecord(
            id: "exhausted-cursor",
            targetKind: .cli,
            cliType: .cursorAgent,
            cliMetadata: SwitcherCLIProfileMetadata(
                displayLabel: "Cursor Reserve",
                exhaustedUntil: exhaustionEnd
            ),
            sortKey: 1
        )

        let eligibility = await planner.eligibility(for: exhaustedProfile)
        if case .quotaExhausted = eligibility {
            // Correct — exhausted Cursor Agent profiles are quota-exhausted (ineligible for failover)
        } else {
            XCTFail("Exhausted Cursor Agent profiles must be quota-exhausted for failover, got: \(eligibility)")
        }
    }

    func test_eligibility_marksReadyCursorAgentProfileAsEligible() async {
        let planner = SwitcherCLIFallbackPlanner { _ in nil }

        let readyProfile = SwitcherProfileRecord(
            id: "ready-cursor",
            targetKind: .cli,
            cliType: .cursorAgent,
            cliMetadata: SwitcherCLIProfileMetadata(
                displayLabel: "Cursor Reserve",
                exhaustedUntil: nil
            ),
            sortKey: 1
        )

        let eligibility = await planner.eligibility(for: readyProfile)
        XCTAssertEqual(eligibility, .eligible,
                       "Non-exhausted Cursor Agent profiles must be eligible for failover")
    }

    // MARK: - Helpers

    private func makeCursorAgentProfile(id: String, label: String) -> SwitcherProfileRecord {
        SwitcherProfileRecord(
            id: id,
            targetKind: .cli,
            cliType: .cursorAgent,
            cliMetadata: SwitcherCLIProfileMetadata(
                displayLabel: label,
                configDirectory: "/tmp/cursor-agent-\(id)"
            ),
            sortKey: 0
        )
    }

    private func makeCodexProfile(id: String, label: String) -> SwitcherProfileRecord {
        SwitcherProfileRecord(
            id: id,
            targetKind: .cli,
            cliType: .codex,
            cliMetadata: SwitcherCLIProfileMetadata(
                displayLabel: label,
                configDirectory: "/tmp/codex-\(id)"
            ),
            sortKey: 0
        )
    }
}
