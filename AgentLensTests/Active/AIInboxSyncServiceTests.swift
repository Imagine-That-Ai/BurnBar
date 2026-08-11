import XCTest
import GRDB
import OpenBurnBarCore
@testable import OpenBurnBar

/// Covers the four properties the AI Inbox mirror must hold: an idle sync writes
/// nothing, a changed item re-uploads, the sealed payload round-trips, and
/// phone-written item state lands locally.
@MainActor
final class AIInboxSyncServiceTests: XCTestCase {
    private var dataStore: DataStore!
    private var accountManager: FakeAccountManager!
    private var settingsManager: SettingsManager!
    private var fakeGateway: CloudSyncFirestoreFakeGateway!
    private var context: CloudSyncContext!
    private var defaults: UserDefaults!
    private var defaultsSuiteName: String!

    private static let uid = "test-uid-1"
    private static let vaultKeyData = Data(repeating: 0x42, count: 32)

    private var itemPath: String { "users/\(Self.uid)/ai_inbox_items" }
    private var statePath: String { "users/\(Self.uid)/ai_inbox_item_state" }

    override func setUp() async throws {
        try await super.setUp()
        try await MainActor.run {
            let queue = try DatabaseQueue()
            dataStore = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
            accountManager = FakeAccountManager.makeSignedIn(uid: Self.uid)
            settingsManager = SettingsManager(defaults: UserDefaults(suiteName: "settings-\(UUID().uuidString)")!)
            fakeGateway = CloudSyncFirestoreFakeGateway()
            defaultsSuiteName = "aiinbox-\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: defaultsSuiteName)!
            context = CloudSyncContext(
                dataStore: dataStore,
                accountManager: accountManager,
                settingsManager: settingsManager,
                firestoreGateway: fakeGateway
            )
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            if let defaultsSuiteName {
                UserDefaults.standard.removePersistentDomain(forName: defaultsSuiteName)
            }
            dataStore = nil
            accountManager = nil
            settingsManager = nil
            fakeGateway = nil
            context = nil
            defaults = nil
            defaultsSuiteName = nil
        }
        try await super.tearDown()
    }

    // MARK: - Watermark

    func testUnchangedSecondSyncUploadsNothing() async throws {
        try await insertItem(id: "inb_alpha", title: "CI is burning cycles", lastSeenAt: Date(timeIntervalSince1970: 1_780_000_000))

        let service = makeService()
        await service.sync()
        XCTAssertNil(service.lastSyncError)

        let firstWrite = try XCTUnwrap(fakeGateway.documentData(at: "\(itemPath)/inb_alpha"))
        let firstSealed = try XCTUnwrap(firstWrite["sealedPayload"] as? [String: Any])
        let firstCiphertext = try XCTUnwrap(firstSealed["sealedBoxBase64"] as? String)

        await service.sync()

        // A fresh AES-GCM nonce per seal means an unsuppressed re-upload would
        // produce a DIFFERENT ciphertext — so comparing the sealed box proves
        // the watermark suppressed the write rather than merely overwriting it
        // with equal bytes.
        let secondWrite = try XCTUnwrap(fakeGateway.documentData(at: "\(itemPath)/inb_alpha"))
        let secondSealed = try XCTUnwrap(secondWrite["sealedPayload"] as? [String: Any])
        XCTAssertEqual(secondSealed["sealedBoxBase64"] as? String, firstCiphertext)
        XCTAssertNil(service.lastSyncError)
    }

    func testChangedItemReUploads() async throws {
        try await insertItem(id: "inb_alpha", title: "CI is burning cycles", lastSeenAt: Date(timeIntervalSince1970: 1_780_000_000))

        let service = makeService()
        await service.sync()
        let firstSealed = try XCTUnwrap(
            (fakeGateway.documentData(at: "\(itemPath)/inb_alpha")?["sealedPayload"] as? [String: Any])?["sealedBoxBase64"] as? String
        )

        // The daemon rewrites the row in place when a condition recurs with new
        // content; that must cross the watermark.
        try await updateItem(
            id: "inb_alpha",
            title: "CI is burning cycles (worse)",
            occurrenceCount: 2,
            lastSeenAt: Date(timeIntervalSince1970: 1_780_000_600)
        )

        await service.sync()

        let document = try XCTUnwrap(fakeGateway.documentData(at: "\(itemPath)/inb_alpha"))
        let secondSealed = try XCTUnwrap((document["sealedPayload"] as? [String: Any])?["sealedBoxBase64"] as? String)
        XCTAssertNotEqual(secondSealed, firstSealed)
        XCTAssertEqual(document["occurrenceCount"] as? Int, 2)
        XCTAssertNil(service.lastSyncError)
    }

    // MARK: - Sealing

    func testSealedPayloadRoundTripsAndOmitsPlaintext() async throws {
        let payload = BurnBarInboxItemPayload(
            evidence: [
                BurnBarInboxEvidence(
                    id: "pr:openburnbar/burnbar#1975",
                    kind: .pullRequest,
                    label: "Stuck PR",
                    detail: "No movement in 9 days"
                )
            ],
            metrics: ["idle_days": "9"]
        )
        try await insertItem(
            id: "inb_beta",
            title: "PR #1975 has stalled",
            summaryMarkdown: "It has not moved in **9 days**.",
            projectName: "BurnBar",
            payload: payload,
            lastSeenAt: Date(timeIntervalSince1970: 1_780_000_000)
        )

        let service = makeService()
        await service.sync()
        XCTAssertNil(service.lastSyncError)

        let document = try XCTUnwrap(fakeGateway.documentData(at: "\(itemPath)/inb_beta"))

        // Routing metadata stays readable so mobile can sort/filter/badge without a key.
        XCTAssertEqual(document["id"] as? String, "inb_beta")
        XCTAssertEqual(document["kind"] as? String, BurnBarInboxItemKind.stuckPR.rawValue)
        XCTAssertEqual(document["state"] as? String, BurnBarInboxItemState.new.rawValue)
        XCTAssertEqual(document["contentSealed"] as? Bool, true)
        XCTAssertEqual(document["sealedSchemaVersion"] as? Int, 2)

        // Everything that reads like the user's own work must NOT be top-level.
        // These exact key names are what `forbidsSealedPlaintextContentFields()`
        // rejects in firestore.rules, so a regression here is a rules rejection.
        for plaintextKey in ["title", "summary", "projectName", "payload", "summaryMarkdown", "resolutionNote"] {
            XCTAssertNil(document[plaintextKey], "\(plaintextKey) must never ride in cleartext")
        }
        // Every key written must be in the rules allowlist.
        XCTAssertTrue(
            Set(document.keys).isSubset(of: Set(AIInboxMirrorCodec.documentKeys)),
            "unexpected keys: \(Set(document.keys).subtracting(Set(AIInboxMirrorCodec.documentKeys)))"
        )

        let decoded = try XCTUnwrap(
            AIInboxMirrorCodec.decodeSealed(
                documentID: "inb_beta",
                uid: Self.uid,
                data: document,
                vaultKey: Self.vaultKeyData
            )
        )
        XCTAssertEqual(decoded.title, "PR #1975 has stalled")
        XCTAssertEqual(decoded.summaryMarkdown, "It has not moved in **9 days**.")
        XCTAssertEqual(decoded.projectName, "BurnBar")
        XCTAssertEqual(decoded.payload.evidence.first?.id, "pr:openburnbar/burnbar#1975")
        XCTAssertEqual(decoded.payload.metrics["idle_days"], "9")
    }

    // MARK: - Item state download

    func testDownloadedItemStateAppliesLocally() async throws {
        try await insertItem(id: "inb_gamma", title: "Uncommitted work", lastSeenAt: Date(timeIntervalSince1970: 1_780_000_000))

        // A phone archived it while this Mac was asleep.
        let archivedAt = Date(timeIntervalSince1970: 1_780_005_000)
        fakeGateway.setDocumentData(
            AIInboxMirrorCodec.encodeItemState(
                AIInboxMirrorItemState(
                    id: "inb_gamma",
                    readAt: archivedAt,
                    archivedAt: archivedAt,
                    feedback: "useful",
                    updatedAt: archivedAt,
                    updatedByDeviceID: "iphone-1"
                ),
                documentID: "inb_gamma"
            ),
            at: "\(statePath)/inb_gamma"
        )

        let service = makeService()
        await service.sync()
        XCTAssertNil(service.lastSyncError)

        let rows = try await dataStore.fetchAIInboxItemStates()
        let applied = try XCTUnwrap(rows.first(where: { $0.id == "inb_gamma" }))
        XCTAssertNotNil(applied.archivedAt)
        XCTAssertNotNil(applied.readAt)
        XCTAssertEqual(applied.feedback, "useful")
        // The remote timestamp is preserved verbatim; restamping to `now` would
        // make the row look locally newer and get pushed straight back.
        XCTAssertEqual(applied.updatedAt.timeIntervalSince1970, archivedAt.timeIntervalSince1970, accuracy: 1)

        // And the item is now hidden from the Mac's default list.
        let visible = try await dataStore.fetchAIInboxRows()
        let mirroredRow = try XCTUnwrap(visible.first(where: { $0.id == "inb_gamma" }))
        XCTAssertTrue(mirroredRow.isArchived)
    }

    func testLocalItemStateUploadsAndIsNotEchoedBack() async throws {
        try await insertItem(id: "inb_delta", title: "Cost anomaly", lastSeenAt: Date(timeIntervalSince1970: 1_780_000_000))
        try await dataStore.setAIInboxItemArchived(id: "inb_delta", archived: true)

        let service = makeService()
        await service.sync()
        XCTAssertNil(service.lastSyncError)

        let stateDocument = try XCTUnwrap(fakeGateway.documentData(at: "\(statePath)/inb_delta"))
        XCTAssertEqual(stateDocument["id"] as? String, "inb_delta")
        XCTAssertNotNil(stateDocument["archivedAt"])
        XCTAssertEqual(stateDocument["updatedByDeviceID"] as? String, accountManager.deviceId)
        XCTAssertTrue(
            Set(stateDocument.keys).isSubset(of: Set(AIInboxMirrorCodec.stateDocumentKeys)),
            "unexpected keys: \(Set(stateDocument.keys).subtracting(Set(AIInboxMirrorCodec.stateDocumentKeys)))"
        )

        // The download half must not treat our own upload as a remote change and
        // rewrite the local row — that loop would restamp `updated_at` forever.
        let beforeRows = try await dataStore.fetchAIInboxItemStates()
        let before = try XCTUnwrap(beforeRows.first(where: { $0.id == "inb_delta" }))
        await service.sync()
        let afterRows = try await dataStore.fetchAIInboxItemStates()
        let after = try XCTUnwrap(afterRows.first(where: { $0.id == "inb_delta" }))
        XCTAssertEqual(before.updatedAt, after.updatedAt)
    }

    // MARK: - Pruning

    func testDeletedLocalItemRemovesTheMirroredGhost() async throws {
        try await insertItem(id: "inb_ghost", title: "Index health", lastSeenAt: Date(timeIntervalSince1970: 1_780_000_000))

        let service = makeService()
        await service.sync()
        XCTAssertNotNil(fakeGateway.documentData(at: "\(itemPath)/inb_ghost"))

        try await deleteItem(id: "inb_ghost")
        await service.sync()

        XCTAssertNil(
            fakeGateway.documentData(at: "\(itemPath)/inb_ghost"),
            "a locally-deleted item must not linger on the phone as an unclearable ghost"
        )
        XCTAssertNil(service.lastSyncError)
    }

    // MARK: - Gates

    func testDisabledPreferenceUploadsNothing() async throws {
        try await insertItem(id: "inb_off", title: "Should stay local", lastSeenAt: Date(timeIntervalSince1970: 1_780_000_000))
        defaults.set(false, forKey: AIInboxSyncService.preferenceKey)

        let service = makeService()
        await service.sync()

        XCTAssertTrue(fakeGateway.documents(under: itemPath).isEmpty)
        XCTAssertNil(service.lastSyncDate)
    }

    func testSignedOutUploadsNothing() async throws {
        try await insertItem(id: "inb_out", title: "Should stay local", lastSeenAt: Date(timeIntervalSince1970: 1_780_000_000))
        accountManager.isSignedIn = false

        let service = makeService()
        await service.sync()

        XCTAssertTrue(fakeGateway.documents(under: itemPath).isEmpty)
        XCTAssertNil(service.lastSyncDate)
    }

    // MARK: - Helpers

    private func makeService() -> AIInboxSyncService {
        AIInboxSyncService(
            context: context,
            vaultKeyProvider: TestConversationVaultKeyProvider(keyData: Self.vaultKeyData),
            defaults: defaults
        )
    }

    private func insertItem(
        id: String,
        title: String,
        summaryMarkdown: String = "Body.",
        kind: BurnBarInboxItemKind = .stuckPR,
        priority: BurnBarInboxPriority = .p2,
        projectName: String? = nil,
        payload: BurnBarInboxItemPayload = BurnBarInboxItemPayload(),
        lastSeenAt: Date
    ) async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payloadJSON = String(decoding: try encoder.encode(payload), as: UTF8.self)
        let stamp = ControlPlaneStore.aiInboxTimestamp(lastSeenAt)

        try await dataStore.actor.controlPlaneStore.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO ai_inbox_items (
                        id, fingerprint, kind, priority, state, title, summary_md, payload_json,
                        project_id, project_name, occurrence_count, first_seen_at, last_seen_at,
                        resolved_at, resolution_note, tick_id, model_provenance
                    ) VALUES (?, ?, ?, ?, 'new', ?, ?, ?, NULL, ?, 1, ?, ?, NULL, NULL, ?, 'local-rules')
                    """,
                arguments: [
                    id, "fp_\(id)", kind.rawValue, priority.rawValue, title, summaryMarkdown,
                    payloadJSON, projectName, stamp, stamp, "tick_1"
                ]
            )
        }
    }

    private func updateItem(
        id: String,
        title: String,
        occurrenceCount: Int,
        lastSeenAt: Date
    ) async throws {
        let stamp = ControlPlaneStore.aiInboxTimestamp(lastSeenAt)
        try await dataStore.actor.controlPlaneStore.dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE ai_inbox_items
                    SET title = ?, occurrence_count = ?, last_seen_at = ?, state = 'updated'
                    WHERE id = ?
                    """,
                arguments: [title, occurrenceCount, stamp, id]
            )
        }
    }

    private func deleteItem(id: String) async throws {
        try await dataStore.actor.controlPlaneStore.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM ai_inbox_items WHERE id = ?", arguments: [id])
        }
    }
}
