import Foundation
import XCTest
@testable import OpenBurnBarLogParsers
import OpenBurnBarKernel
import OpenBurnBarSQLiteReader

final class ProviderAccountIdentityAttributionTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("account-identity-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    // MARK: - Resolvers

    func testCursorResolverReadsCachedEmailFromStateDB() throws {
        let dbPath = scratch.appendingPathComponent("state.vscdb").path
        let db = try SQLiteConnection.openForWriting(creatingAt: dbPath)
        try db.execute("CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value BLOB)")
        try db.execute(
            "INSERT INTO ItemTable (key, value) VALUES (?, ?)",
            arguments: [.text("cursorAuth/cachedEmail"), .text("Seat-Two@Example.com")]
        )
        db.close()

        let resolver = CursorAccountIdentityResolver(databaseCandidates: [dbPath])
        let identity = try XCTUnwrap(resolver.resolveCurrentIdentity())
        XCTAssertEqual(identity.rawIdentity, "seat-two@example.com")
        XCTAssertEqual(identity.label, "Seat-Two@Example.com")
        XCTAssertEqual(identity.scope, .localOnly)
    }

    func testCursorResolverReturnsNilWithoutDatabaseOrEmail() throws {
        XCTAssertNil(
            CursorAccountIdentityResolver(
                databaseCandidates: [scratch.appendingPathComponent("missing.vscdb").path]
            ).resolveCurrentIdentity()
        )

        let dbPath = scratch.appendingPathComponent("empty.vscdb").path
        let db = try SQLiteConnection.openForWriting(creatingAt: dbPath)
        try db.execute("CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value BLOB)")
        db.close()
        XCTAssertNil(
            CursorAccountIdentityResolver(databaseCandidates: [dbPath]).resolveCurrentIdentity()
        )
    }

    func testCodexResolverPrefersAccountIDAndLabelsWithEmailClaim() throws {
        let payload = try JSONSerialization.data(withJSONObject: ["email": "ops@example.com"])
        let idToken = "eyJhbGciOiJIUzI1NiJ9.\(payload.base64URLEncodedForTest()).sig"
        let auth: [String: Any] = [
            "OPENAI_API_KEY": "sk-test-not-a-real-key",
            "tokens": [
                "id_token": idToken,
                "access_token": "not-inspected",
                "account_id": "acct-1234567890"
            ]
        ]
        let authURL = scratch.appendingPathComponent("auth.json")
        try JSONSerialization.data(withJSONObject: auth).write(to: authURL)

        let resolver = CodexAccountIdentityResolver(authFileCandidates: [authURL])
        let identity = try XCTUnwrap(resolver.resolveCurrentIdentity())
        XCTAssertEqual(identity.rawIdentity, "acct-1234567890")
        XCTAssertEqual(identity.label, "ops@example.com")
        XCTAssertEqual(identity.scope, .localOnly)
    }

    func testCodexResolverReturnsNilForAPIKeyOnlyInstall() throws {
        let authURL = scratch.appendingPathComponent("auth.json")
        try JSONSerialization.data(withJSONObject: ["OPENAI_API_KEY": "sk-only"]).write(to: authURL)
        XCTAssertNil(
            CodexAccountIdentityResolver(authFileCandidates: [authURL]).resolveCurrentIdentity()
        )
    }

    func testClaudeResolverReadsOAuthAccount() throws {
        let config: [String: Any] = [
            "oauthAccount": [
                "accountUuid": "0aa11bb2-3cc4-5dd6-7ee8-9ff000111222",
                "emailAddress": "Me@Example.com"
            ],
            "projects": ["~/big/unrelated/state": ["history": []]]
        ]
        let configURL = scratch.appendingPathComponent(".claude.json")
        try JSONSerialization.data(withJSONObject: config).write(to: configURL)

        let resolver = ClaudeAccountIdentityResolver(configFileCandidates: [configURL])
        let identity = try XCTUnwrap(resolver.resolveCurrentIdentity())
        XCTAssertEqual(identity.rawIdentity, "0aa11bb2-3cc4-5dd6-7ee8-9ff000111222")
        XCTAssertEqual(identity.label, "Me@Example.com")
    }

    // MARK: - Timeline

    /// History predating the first observation must stay unattributed rather
    /// than being assigned to whichever account happened to be signed in when
    /// attribution first ran — on a multi-seat device that guess is wrong often
    /// enough to mislead.
    func testHistoryBeforeFirstObservationStaysUnattributed() {
        let store = makeStore()
        store.observe(identity("a@example.com"), provider: .cursor, at: date("2026-08-01T12:00:00Z"))

        XCTAssertNil(
            store.attribution(
                for: .cursor,
                start: date("2020-01-01T00:00:00Z"),
                end: date("2020-01-01T01:00:00Z")
            )
        )
        // Usage from the observation onward is attributed.
        XCTAssertEqual(
            store.attribution(
                for: .cursor,
                start: date("2026-08-01T13:00:00Z"),
                end: date("2026-08-01T14:00:00Z")
            )?.rawIdentity,
            "a@example.com"
        )
    }

    func testIdentityHoldsAcrossObservationGapsUntilSwitch() {
        let store = makeStore()
        store.observe(identity("a@example.com"), provider: .cursor, at: date("2026-08-01T12:00:00Z"))
        store.observe(identity("b@example.com"), provider: .cursor, at: date("2026-08-05T09:00:00Z"))

        // Inside the gap between a's last observation and b's first: still a.
        XCTAssertEqual(
            store.attribution(
                for: .cursor,
                start: date("2026-08-03T10:00:00Z"),
                end: date("2026-08-03T11:00:00Z")
            )?.rawIdentity,
            "a@example.com"
        )
        // After the switch: b, extending indefinitely.
        XCTAssertEqual(
            store.attribution(
                for: .cursor,
                start: date("2026-08-10T10:00:00Z"),
                end: date("2026-08-10T11:00:00Z")
            )?.rawIdentity,
            "b@example.com"
        )
        // Spanning the switch: ambiguous, unattributed.
        XCTAssertNil(
            store.attribution(
                for: .cursor,
                start: date("2026-08-04T10:00:00Z"),
                end: date("2026-08-06T11:00:00Z")
            )
        )
    }

    func testTimelinePersistsAcrossReload() {
        let fileURL = scratch.appendingPathComponent("timeline.json")
        let store = ProviderAccountIdentityTimelineStore(fileURL: fileURL)
        store.observe(identity("a@example.com"), provider: .codex, at: date("2026-08-01T12:00:00Z"))
        store.observe(identity("b@example.com"), provider: .codex, at: date("2026-08-02T12:00:00Z"))

        let reloaded = ProviderAccountIdentityTimelineStore(fileURL: fileURL)
        XCTAssertEqual(
            reloaded.attribution(
                for: .codex,
                start: date("2026-08-03T00:00:00Z"),
                end: date("2026-08-03T00:30:00Z")
            )?.rawIdentity,
            "b@example.com"
        )
        // The switch boundary survives the reload: a's window still owns the
        // usage recorded between a's observation and b's.
        XCTAssertEqual(
            reloaded.attribution(
                for: .codex,
                start: date("2026-08-01T13:00:00Z"),
                end: date("2026-08-01T14:00:00Z")
            )?.rawIdentity,
            "a@example.com"
        )
    }

    func testProvidersAreIsolatedFromEachOther() {
        let store = makeStore()
        store.observe(identity("a@example.com"), provider: .cursor, at: date("2026-08-01T12:00:00Z"))
        XCTAssertNil(
            store.attribution(
                for: .codex,
                start: date("2026-08-01T12:00:00Z"),
                end: date("2026-08-01T13:00:00Z")
            )
        )
    }

    // MARK: - Attributor

    func testAttributorFillsOnlyUnattributedRows() {
        let store = makeStore()
        store.observe(identity("seat@example.com"), provider: .cursor, at: date("2026-08-01T12:00:00Z"))
        let attributor = ProviderAccountUsageAttributor(resolvers: [], timeline: store)

        let unattributed = makeUsage(provider: .cursor)
        let preAttributed = makeUsage(provider: .cursor)
            .attributingAccount(rawIdentity: "other@example.com", label: "other@example.com", source: .localOnly)

        let result = attributor.attribute([unattributed, preAttributed])
        XCTAssertEqual(result[0].providerAccountID, "seat@example.com")
        XCTAssertEqual(result[0].providerAccountLabel, "seat@example.com")
        XCTAssertEqual(result[0].providerAccountSource, .localOnly)
        XCTAssertEqual(result[1].providerAccountID, "other@example.com")
    }

    func testAttributorObservationRefreshIsThrottled() {
        let store = makeStore()
        let counting = CountingResolver()
        var currentDate = date("2026-08-01T12:00:00Z")
        let clock = Locked(currentDate)
        let attributor = ProviderAccountUsageAttributor(
            resolvers: [counting],
            timeline: store,
            observationInterval: 300,
            now: { clock.read() }
        )

        attributor.refreshObservations()
        attributor.refreshObservations()
        XCTAssertEqual(counting.resolveCount.read(), 1)

        currentDate = currentDate.addingTimeInterval(301)
        clock.write(currentDate)
        attributor.refreshObservations()
        XCTAssertEqual(counting.resolveCount.read(), 2)
    }

    /// Guards the full-reinit copy in `attributingAccount`: if `TokenUsage`
    /// grows a field the helper does not mirror, the JSON diff here fails.
    func testAttributingAccountChangesOnlyAccountFieldsAndID() throws {
        let base = makeUsage(provider: .codex)
        let attributed = base.attributingAccount(
            rawIdentity: "acct-123", label: "ops@example.com", source: .localOnly
        )

        let encoder = JSONEncoder()
        let baseDict = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(base)) as? [String: Any]
        )
        let attributedDict = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(attributed)) as? [String: Any]
        )

        let allowedToDiffer: Set<String> = [
            "id", "providerAccountID", "providerAccountLabel", "providerAccountSource"
        ]
        let allKeys = Set(baseDict.keys).union(attributedDict.keys)
        for key in allKeys where !allowedToDiffer.contains(key) {
            XCTAssertEqual(
                String(describing: baseDict[key] ?? "<absent>"),
                String(describing: attributedDict[key] ?? "<absent>"),
                "Field \(key) unexpectedly changed by attributingAccount — mirror it in the helper."
            )
        }
        XCTAssertNotEqual(base.id, attributed.id)
        XCTAssertEqual(
            attributed.id,
            TokenUsage.deterministicID(
                provider: base.provider,
                sessionId: base.sessionId,
                model: base.model,
                sourceDeviceId: base.sourceDeviceId,
                providerAccountID: "acct-123"
            )
        )
    }

    // MARK: - Helpers

    private final class CountingResolver: ProviderAccountIdentityResolving, @unchecked Sendable {
        let providers: [AgentProvider] = [.cursor]
        let resolveCount = Locked(0)

        func resolveCurrentIdentity() -> ResolvedProviderAccountIdentity? {
            resolveCount.withLock { $0 += 1 }
            return ResolvedProviderAccountIdentity(
                rawIdentity: "seat@example.com", label: "seat@example.com", scope: .localOnly
            )
        }
    }

    private func makeStore() -> ProviderAccountIdentityTimelineStore {
        ProviderAccountIdentityTimelineStore(
            fileURL: scratch.appendingPathComponent("timeline-\(UUID().uuidString).json")
        )
    }

    private func identity(_ email: String) -> ResolvedProviderAccountIdentity {
        ResolvedProviderAccountIdentity(rawIdentity: email, label: email, scope: .localOnly)
    }

    private func makeUsage(provider: AgentProvider) -> TokenUsage {
        TokenUsage(
            provider: provider,
            sessionId: "session-1",
            projectName: "Project",
            model: "model-x",
            inputTokens: 100,
            outputTokens: 20,
            costUSD: 0.01,
            startTime: date("2026-08-02T10:00:00Z"),
            endTime: date("2026-08-02T10:30:00Z"),
            provenanceMethod: .providerLog,
            provenanceConfidence: .exact
        )
    }

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }
}

private extension Data {
    func base64URLEncodedForTest() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
