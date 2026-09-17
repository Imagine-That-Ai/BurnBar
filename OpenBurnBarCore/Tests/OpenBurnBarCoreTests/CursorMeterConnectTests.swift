import Foundation
import XCTest
@testable import OpenBurnBarCore
@testable import OpenBurnBarKernel
@testable import OpenBurnBarQuota
@testable import OpenBurnBarSQLiteReader

final class CursorMeterConnectTests: XCTestCase {

    func test_keychainServices_meterStoreIsNotConnectorService() {
        XCTAssertEqual(OpenBurnBarIdentity.providerAPIKeychainService, "com.openburnbar.provider-api-keys")
        XCTAssertEqual(OpenBurnBarIdentity.cursorConnectorKeychainService, "com.openburnbar.cursor-connector")
        XCTAssertNotEqual(
            OpenBurnBarIdentity.providerAPIKeychainService,
            OpenBurnBarIdentity.cursorConnectorKeychainService,
            "Cursor meter cookies must not land in the connector Keychain service"
        )
    }

    func test_registry_registersCursorMeterMethods() {
        let descriptor = BurnBarProviderAuthRegistry.descriptor(forCatalogProviderID: "cursor")
        XCTAssertEqual(descriptor?.providerID, "cursor")
        XCTAssertEqual(descriptor?.displayName, "Cursor")
        XCTAssertEqual(descriptor?.primaryMethod.id, "cursor-cookie-paste")
        XCTAssertTrue(descriptor?.supportsQuotaRefresh ?? false)
        XCTAssertFalse(descriptor?.supportsProxyRouting ?? true)

        let paste = descriptor?.method(id: "cursor-cookie-paste")
        XCTAssertEqual(paste?.kind, .cookie)
        XCTAssertEqual(paste?.storage.mirrorAccountIdentifier, "cursor_cookie")
        XCTAssertTrue(paste?.unlocksQuotaRefresh ?? false)
        XCTAssertFalse(paste?.unlocksProxyRouting ?? true)

        let web = descriptor?.method(id: "cursor-workos-session")
        XCTAssertEqual(web?.kind, .browserLogin)
        XCTAssertTrue(web?.unlocksQuotaRefresh ?? false)
        XCTAssertFalse(web?.unlocksProxyRouting ?? true)

        let editor = descriptor?.method(id: "cursor-editor-vscdb")
        XCTAssertEqual(editor?.kind, .localRuntime)
        XCTAssertTrue(editor?.unlocksQuotaRefresh ?? false)
        XCTAssertFalse(editor?.unlocksProxyRouting ?? true)

        XCTAssertEqual(
            BurnBarProviderAuthRegistry.descriptor(forCatalogProviderID: "cursor-desktop")?.providerID,
            "cursor"
        )
    }

    func test_planPersist_missingAndInvalidCookie() {
        XCTAssertNil(
            CursorMeterSeatPlanning.planPersist(
                incomingCookie: "",
                existingDefaultCookie: nil,
                existingSeatIDs: [],
                installLabel: "Cursor"
            )
        )
        XCTAssertNil(
            CursorMeterSeatPlanning.planPersist(
                incomingCookie: "session=not-workos",
                existingDefaultCookie: nil,
                existingSeatIDs: [],
                installLabel: "Cursor"
            )
        )
    }

    func test_planPersist_successWritesDefaultSeat() throws {
        let jwt = makeCursorJWT(sub: "user_a", exp: Date().addingTimeInterval(3_600).timeIntervalSince1970)
        let cookie = "WorkosCursorSessionToken=user_a::\(jwt)"
        let plan = try XCTUnwrap(
            CursorMeterSeatPlanning.planPersist(
                incomingCookie: cookie,
                existingDefaultCookie: nil,
                existingSeatIDs: [],
                installLabel: "Cursor",
                email: "elioai@example.com"
            )
        )
        XCTAssertFalse(plan.avoidedOverwrite)
        XCTAssertEqual(plan.seat.seatID, CursorMeterSeat.defaultSeatID)
        XCTAssertEqual(plan.writes.map(\.account), [CursorMeterSeat.defaultCookieAccount])
        XCTAssertEqual(plan.seat.email, "elioai@example.com")
    }

    func test_planPersist_differentUserAddsSecondSeatWithoutOverwrite() throws {
        let existingJWT = makeCursorJWT(sub: "user_a", exp: Date().addingTimeInterval(3_600).timeIntervalSince1970)
        let incomingJWT = makeCursorJWT(sub: "user_b", exp: Date().addingTimeInterval(3_600).timeIntervalSince1970)
        let existing = "WorkosCursorSessionToken=user_a::\(existingJWT)"
        let incoming = "WorkosCursorSessionToken=user_b::\(incomingJWT)"

        let plan = try XCTUnwrap(
            CursorMeterSeatPlanning.planPersist(
                incomingCookie: incoming,
                existingDefaultCookie: existing,
                existingSeatIDs: [],
                installLabel: "Cursor-2",
                email: "gmail@example.com"
            )
        )
        XCTAssertTrue(plan.avoidedOverwrite)
        XCTAssertNotEqual(plan.seat.seatID, CursorMeterSeat.defaultSeatID)
        XCTAssertEqual(plan.seat.keychainAccount, "cursor_cookie.\(plan.seat.seatID)")
        XCTAssertFalse(plan.writes.contains(where: { $0.account == CursorMeterSeat.defaultCookieAccount }))
        XCTAssertTrue(plan.writes.contains(where: { $0.account == CursorMeterSeat.seatIndexAccount }))

        var keys: [String: String] = [CursorMeterSeat.defaultCookieAccount: existing]
        try CursorMeterSeatPlanning.apply(plan) { account, value in
            keys[account] = value
        }
        XCTAssertEqual(keys[CursorMeterSeat.defaultCookieAccount], existing)
        XCTAssertEqual(keys[plan.seat.keychainAccount], plan.seat.cookieHeader)
    }

    func test_planPersist_replaceExistingDefaultOverwritesWhenConfirmed() throws {
        let existingJWT = makeCursorJWT(sub: "user_a", exp: Date().addingTimeInterval(3_600).timeIntervalSince1970)
        let incomingJWT = makeCursorJWT(sub: "user_b", exp: Date().addingTimeInterval(3_600).timeIntervalSince1970)
        let plan = try XCTUnwrap(
            CursorMeterSeatPlanning.planPersist(
                incomingCookie: "WorkosCursorSessionToken=user_b::\(incomingJWT)",
                existingDefaultCookie: "WorkosCursorSessionToken=user_a::\(existingJWT)",
                existingSeatIDs: [],
                installLabel: "Cursor-2",
                replaceExistingDefault: true
            )
        )
        XCTAssertFalse(plan.avoidedOverwrite)
        XCTAssertEqual(plan.seat.seatID, CursorMeterSeat.defaultSeatID)
        XCTAssertEqual(plan.writes.map(\.account), [CursorMeterSeat.defaultCookieAccount])
    }

    func test_planPersist_expiredJWTIsRejected() {
        let jwt = makeCursorJWT(sub: "user_a", exp: Date().addingTimeInterval(-60).timeIntervalSince1970)
        XCTAssertNil(
            CursorMeterSeatPlanning.planPersist(
                incomingCookie: "WorkosCursorSessionToken=user_a::\(jwt)",
                existingDefaultCookie: nil,
                existingSeatIDs: [],
                installLabel: "Cursor"
            )
        )
        XCTAssertTrue(
            CursorMeterSeatPlanning.cookieHeaderIsExpired("WorkosCursorSessionToken=user_a::\(jwt)")
        )
    }

    func test_extractor_readsMultipleInstallsAndSkipsExpired() throws {
        let root = try makeTemporaryDirectory()
        let liveJWT = makeCursorJWT(sub: "user_live", exp: Date().addingTimeInterval(3_600).timeIntervalSince1970)
        let deadJWT = makeCursorJWT(sub: "user_dead", exp: Date().addingTimeInterval(-60).timeIntervalSince1970)
        try writeCursorStateDB(
            applicationSupport: root,
            installName: "Cursor",
            token: deadJWT,
            email: "old@example.com"
        )
        try writeCursorStateDB(
            applicationSupport: root,
            installName: "Cursor-2",
            token: liveJWT,
            email: "elioai@example.com",
            membership: "ultra"
        )

        let sessions = CursorCookieExtractor.discoverSessions(applicationSupportURL: root)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].install.label, "Cursor-2")
        XCTAssertEqual(sessions[0].session.email, "elioai@example.com")
        XCTAssertEqual(sessions[0].session.userId, "user_live")
        XCTAssertEqual(sessions[0].session.membershipType, "ultra")
        XCTAssertNil(CursorCookieExtractor.readSession(at: root.appendingPathComponent("Cursor/User/globalStorage/state.vscdb").path))
    }

    func test_adapter_missingCookieIsUnavailableWithoutEstimate() async throws {
        let snapshot = try await CursorQuotaAdapter().fetch(
            context: makeContext(
                environment: ["OPENBURNBAR_DISABLE_CURSOR_AUTO_AUTH": "1"],
                keys: [:]
            )
        )
        XCTAssertEqual(snapshot.confidence, .unavailable)
        XCTAssertTrue(snapshot.buckets.isEmpty)
        XCTAssertTrue(snapshot.statusMessage?.contains("Connect Cursor") ?? false)
        XCTAssertFalse(snapshot.statusMessage?.localizedCaseInsensitiveContains("firebase") ?? true)
        XCTAssertFalse(snapshot.statusMessage?.localizedCaseInsensitiveContains("sign in to burnbar") ?? true)
    }

    func test_adapter_extraSeatDoesNotUseEnvCookie() async throws {
        let snapshot = try await CursorQuotaAdapter().fetch(
            context: makeContext(
                environment: [
                    "CURSOR_COOKIE_HEADER": "WorkosCursorSessionToken=env::token",
                    "OPENBURNBAR_QUOTA_ACCOUNT_ID": "cursor-2_user_b",
                    "OPENBURNBAR_DISABLE_CURSOR_AUTO_AUTH": "1"
                ],
                keys: [:]
            )
        )
        XCTAssertEqual(snapshot.confidence, .unavailable)
        XCTAssertTrue(snapshot.statusMessage?.contains("Reconnect") ?? false)
    }

    func test_adapter_expiredConfiguredCookieAsksToReconnect() async throws {
        let jwt = makeCursorJWT(sub: "user_a", exp: Date().addingTimeInterval(-30).timeIntervalSince1970)
        let snapshot = try await CursorQuotaAdapter().fetch(
            context: makeContext(
                environment: ["OPENBURNBAR_DISABLE_CURSOR_AUTO_AUTH": "1"],
                keys: [CursorMeterSeat.defaultCookieAccount: "WorkosCursorSessionToken=user_a::\(jwt)"]
            )
        )
        XCTAssertEqual(snapshot.confidence, .unavailable)
        XCTAssertTrue(snapshot.statusMessage?.contains("signed this seat out") ?? false)
    }

    func test_adapter_sourceDoesNotHardCodeUltraDollarLimits() throws {
        let source = try String(
            contentsOfFile: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/OpenBurnBarQuota/ProviderQuota/CursorQuotaAdapter.swift")
                .path,
            encoding: .utf8
        )
        XCTAssertFalse(source.contains("$200"))
        XCTAssertFalse(source.contains("$400"))
        XCTAssertFalse(source.contains("40000"))
        XCTAssertTrue(source.contains("/ 100.0"))
    }

    private func makeCursorJWT(sub: String, exp: TimeInterval) -> String {
        func encode(_ object: [String: Any]) -> String {
            let data = try! JSONSerialization.data(withJSONObject: object)
            return data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        }
        return "\(encode(["alg": "none", "typ": "JWT"])).\(encode(["sub": "auth0|\(sub)", "exp": exp])).sig"
    }

    private func writeCursorStateDB(
        applicationSupport: URL,
        installName: String,
        token: String,
        email: String,
        membership: String? = nil
    ) throws {
        let dbURL = applicationSupport
            .appendingPathComponent(installName)
            .appendingPathComponent("User/globalStorage/state.vscdb")
        try FileManager.default.createDirectory(at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let db = try SQLiteConnection.openForWriting(creatingAt: dbURL.path)
        defer { db.close() }
        try db.execute("CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT)")
        try db.execute(
            "INSERT INTO ItemTable (key, value) VALUES (?, ?)",
            arguments: [.text("cursorAuth/accessToken"), .text(token)]
        )
        try db.execute(
            "INSERT INTO ItemTable (key, value) VALUES (?, ?)",
            arguments: [.text("cursorAuth/cachedEmail"), .text(email)]
        )
        if let membership {
            try db.execute(
                "INSERT INTO ItemTable (key, value) VALUES (?, ?)",
                arguments: [.text("cursorAuth/stripeMembershipType"), .text(membership)]
            )
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-cursor-meter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeContext(
        environment: [String: String],
        keys: [String: String?]
    ) -> ProviderQuotaAdapterContext {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-cursor-ctx-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return ProviderQuotaAdapterContext(
            appPaths: OpenBurnBarAppPaths(applicationSupportRoot: root),
            fileManager: .default,
            session: URLSession(configuration: .ephemeral),
            environment: environment,
            homeDirectoryURL: root,
            snapshotStore: CursorMeterStubSnapshotStore(),
            bridgeManager: CursorMeterStubBridge(),
            miniMaxMode: .tokenPlan,
            factoryPlan: .unknown,
            xaiPlan: .unknown,
            mimoTokenPlanRegion: .sgp,
            mimoTokenPlanTier: nil,
            mimoTokenPlanBillingCycle: .monthly,
            codexRolloutScanCache: .empty,
            updateCodexRolloutScanCache: { _, _ in },
            claudeCredentialsReader: NoClaudeCredentialsReader(),
            resolvedAPIKeys: keys
        )
    }
}

private struct CursorMeterStubSnapshotStore: ProviderQuotaSnapshotPersisting {
    func loadScratchString(forKey key: String) -> String? { nil }
    func saveScratchString(_ value: String, forKey key: String) {}
    func readJSONObject(from url: URL) throws -> [String: Any]? { nil }
}

private struct CursorMeterStubBridge: ClaudeQuotaBridgeManaging {
    func installClaudeQuotaBridge() throws {}
    func refreshClaudeBridgeStatus() -> ClaudeQuotaBridgeStatus {
        ClaudeQuotaBridgeStatus(state: .notInstalled, wrapperPath: "", detailText: "", lastPayloadAt: nil)
    }
}
