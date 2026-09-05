import FirebaseFirestore
import Foundation
import GRDB
import OpenBurnBarCore
import XCTest
@testable import OpenBurnBar

/// PR-E2 — proves the cloud-sync scheduling lane ships DORMANT and only egresses
/// when BOTH the explicit user opt-in AND the Remote Config fleet ceiling allow.
///
/// `MemoryCloudSyncService.syncApprovedMemories` (the wrapped uploader) is covered
/// by `OpenBurnBarDatabaseMigrationTests`; this suite covers the *gate* the domain
/// wraps it in — the safety property that the activation must never regress.
@MainActor
final class MemoryCloudSyncDomainTests: XCTestCase {

    private func makeStoreWithApprovedMemory(uid: String) async throws -> (ControlPlaneStore, DatabaseQueue) {
        let queue = try DatabaseQueue()
        let database = OpenBurnBarDatabase(databaseQueue: queue)
        try database.runMigrationsSafely()
        let store = ControlPlaneStore(dbQueue: queue)
        let now = Date(timeIntervalSince1970: 1_800_000_900)
        let scope = MemoryScope(userID: uid, appID: "cloud-app")
        _ = try await store.addChatMemoryAuthorityRecord(
            MemoryAddRequest(
                text: "Approved memory body that must only leave the device when opted in.",
                kind: .preference,
                scope: scope,
                confidence: 0.9,
                citations: [
                    MemoryCitation(
                        id: "cite-e2",
                        threadLogicalID: "thread-e2",
                        messageID: "message-e2",
                        role: "user",
                        authoredAt: now,
                        contentHash: "content-e2",
                        crossDeviceHMAC: "hmac-e2"
                    )
                ],
                reviewStatus: .approved
            ),
            id: "mem-e2-approved",
            now: now,
            enabled: true
        )
        return (store, queue)
    }

    /// Seeds a MIRRORED AGENT memory — the only kind that carries §5's
    /// convergence identity, and therefore the only kind the pull can park.
    /// A chat memory belongs to no engine project, so `memoryCloudFactAttributes`
    /// gives it no `projectID` and the pull refuses it without parking (see
    /// `MemoryCloudPullRejection.projectIdentityMissing`) — which is exactly the
    /// behaviour the chat-corpus assertion below relies on.
    private func seedMirroredAgentMemory(
        store: ControlPlaneStore,
        queue: DatabaseQueue,
        uid: String,
        id: String,
        engineID: String,
        body: String
    ) async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_900)
        _ = try await store.addMemoryAuthorityRecord(
            MemoryAddRequest(
                text: body,
                kind: .fact,
                scope: MemoryScope(userID: uid, appID: "cloud-app"),
                confidence: 0.9,
                reviewStatus: .approved
            ),
            id: id,
            sourceKind: .agent,
            now: now,
            enabled: true
        )
        try await queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO agent_memory_bodies
                    (memory_id, project_id, engine_memory_id, body, body_hash, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [id, "proj_domaintest00001111222233334444", engineID, body, "hash-domain", "\(now)", "\(now)"]
            )
            try db.execute(
                sql: "UPDATE agent_memories SET project_id = ?, scope = ? WHERE id = ?",
                arguments: ["proj_domaintest00001111222233334444", "project", id]
            )
        }
    }

    /// Stands in for `MacCloudEntitlementStore` (a `@MainActor` singleton a unit
    /// test cannot drive) so the Data Vault lever of the pull gate is
    /// exercisable in both directions.
    private struct FakeDataVaultEntitlementResolver: MemoryDataVaultEntitlementResolving {
        let entitled: Bool
        @MainActor var isDataVaultEntitled: Bool { entitled }
    }

    /// `entitlementSatisfied` defaults true so the pre-existing push/pull cases
    /// exercise the levers they were written for; the entitlement lever gets its
    /// own negative case below.
    private func makeSettings(
        optIn: Bool,
        fleetEnabled: Bool,
        deviceSync: Bool = false,
        entitlementSatisfied: Bool = true
    ) -> SettingsManager {
        let settings = SettingsManager(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!)
        settings.memoryApprovedCloudBackupOptIn = optIn
        settings.memoryExtractionRemoteConfigEnabled = fleetEnabled
        settings.memoryDeviceSyncOptIn = deviceSync
        settings.memoryDeviceSyncEntitlementSatisfied = entitlementSatisfied
        return settings
    }

    private func makeDomain(
        store: ControlPlaneStore,
        accountManager: FakeAccountManager,
        settings: SettingsManager,
        gateway: CloudSyncFirestoreFakeGateway,
        entitled: Bool = true
    ) -> MemoryCloudSyncDomain {
        MemoryCloudSyncDomain(
            store: store,
            accountManager: accountManager,
            settingsManager: settings,
            firestoreGateway: gateway,
            vaultKeyProvider: TestConversationVaultKeyProvider(),
            entitlementResolver: FakeDataVaultEntitlementResolver(entitled: entitled)
        )
    }

    // MARK: - Dormant by default (the headline guarantee)

    func test_sync_isNoOp_whenCloudBackupOptInIsOff_evenWithApprovedMemory() async throws {
        let uid = "e2-user-default-off"
        let (store, _) = try await makeStoreWithApprovedMemory(uid: uid)
        let gateway = CloudSyncFirestoreFakeGateway()
        let settings = makeSettings(optIn: false, fleetEnabled: true)
        let domain = makeDomain(
            store: store,
            accountManager: .makeSignedIn(uid: uid),
            settings: settings,
            gateway: gateway
        )

        // The opt-in defaults OFF: the domain must replicate NOTHING.
        XCTAssertFalse(settings.memoryApprovedCloudBackupEnabled)
        await domain.sync()

        XCTAssertTrue(gateway.documents(under: "users/\(uid)/memory_facts").isEmpty)
        XCTAssertNil(domain.lastSyncDate)
        XCTAssertNil(domain.lastSyncError)
    }

    // MARK: - Fleet ceiling clamps even an opted-in user

    func test_sync_isNoOp_whenFleetCeilingIsOff_despiteOptIn() async throws {
        let uid = "e2-user-fleet-off"
        let (store, _) = try await makeStoreWithApprovedMemory(uid: uid)
        let gateway = CloudSyncFirestoreFakeGateway()
        let settings = makeSettings(optIn: true, fleetEnabled: false)
        let domain = makeDomain(
            store: store,
            accountManager: .makeSignedIn(uid: uid),
            settings: settings,
            gateway: gateway
        )

        // Opt-in is ON, but the Remote Config fleet kill switch clamps egress shut.
        XCTAssertTrue(settings.memoryApprovedCloudBackupOptIn)
        XCTAssertFalse(settings.memoryApprovedCloudBackupEnabled)
        await domain.sync()

        XCTAssertTrue(gateway.documents(under: "users/\(uid)/memory_facts").isEmpty)
    }

    // MARK: - Account gate

    func test_sync_isNoOp_whenNotSignedIn() async throws {
        let uid = "e2-user-signed-out"
        let (store, _) = try await makeStoreWithApprovedMemory(uid: uid)
        let gateway = CloudSyncFirestoreFakeGateway()
        let settings = makeSettings(optIn: true, fleetEnabled: true)
        let account = FakeAccountManager() // not signed in
        let domain = makeDomain(store: store, accountManager: account, settings: settings, gateway: gateway)

        await domain.sync()

        XCTAssertTrue(gateway.documents(under: "users/\(uid)/memory_facts").isEmpty)
    }

    // MARK: - Enabled path actually reaches the uploader

    func test_sync_replicatesApprovedMemory_whenBothLeversAllow() async throws {
        let uid = "e2-user-enabled"
        let (store, _) = try await makeStoreWithApprovedMemory(uid: uid)
        let gateway = CloudSyncFirestoreFakeGateway()
        let settings = makeSettings(optIn: true, fleetEnabled: true)
        let domain = makeDomain(
            store: store,
            accountManager: .makeSignedIn(uid: uid),
            settings: settings,
            gateway: gateway
        )

        XCTAssertTrue(settings.memoryApprovedCloudBackupEnabled)
        await domain.sync()

        let docs = gateway.documents(under: "users/\(uid)/memory_facts")
        XCTAssertEqual(docs.count, 1)
        // Structural seal invariant (m5): the uploaded document must carry the sealed
        // ciphertext envelope and NO cleartext body/text/vector field — asserting the seal
        // exists, not merely that one known plaintext substring is absent.
        let fields = try XCTUnwrap(docs.values.first)
        XCTAssertNotNil(fields["sealedMemory"], "Uploaded memory fact must carry a sealedMemory envelope.")
        XCTAssertNil(fields["text"], "Plaintext `text` must never be a cleartext Firestore field.")
        XCTAssertNil(fields["body"], "Plaintext `body` must never be a cleartext Firestore field.")
        XCTAssertNil(fields["vector"], "Raw embedding `vector` must never be a cleartext Firestore field.")
        XCTAssertEqual(fields["reviewStatus"] as? String, MemoryReviewStatus.approved.rawValue)
        // Belt-and-suspenders: the known plaintext body must not appear anywhere in the doc.
        XCTAssertFalse(String(describing: docs).contains("Approved memory body"))
        XCTAssertNotNil(domain.lastSyncDate)
        XCTAssertNil(domain.lastSyncError)
    }

    // MARK: - The PULL sub-toggle (Memory Blind Sync PR-2)

    /// Backing memory up is not the same consent as syncing it across devices. A
    /// member who opted into backup and nothing else must see the upload run and
    /// the download not happen — no `memory_facts` read, no inbox row.
    func test_sync_doesNotPull_whenTheDeviceSyncSubToggleIsOff() async throws {
        let uid = "e2-user-pull-off"
        let (store, queue) = try await makeStoreWithApprovedMemory(uid: uid)
        let gateway = CloudSyncFirestoreFakeGateway()
        let settings = makeSettings(optIn: true, fleetEnabled: true, deviceSync: false)
        let domain = makeDomain(
            store: store,
            accountManager: .makeSignedIn(uid: uid),
            settings: settings,
            gateway: gateway
        )

        XCTAssertTrue(settings.memoryApprovedCloudBackupEnabled)
        XCTAssertFalse(settings.memoryDeviceSyncEnabled, "the pull sub-toggle defaults OFF")
        await domain.sync()

        // The push still ran: the sub-toggle gates only the read-back.
        XCTAssertEqual(gateway.documents(under: "users/\(uid)/memory_facts").count, 1)
        let inboxRows = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM agent_memory_inbox") ?? -1
        }
        XCTAssertEqual(inboxRows, 0, "no pull runs while the sub-toggle is off")
        XCTAssertEqual(
            gateway.queryCount(under: "users/\(uid)/memory_facts"),
            0,
            "a closed sub-toggle must issue zero memory_facts reads, not merely have no effect"
        )
        XCTAssertNil(domain.lastSyncError)
    }

    /// Critical-1 regression. The Data Vault entitlement is the FOURTH lever of
    /// the effective pull gate, and it has to live on the client:
    /// `firestore.rules` gates `memory_facts` *writes* on
    /// `hasActiveDataVaultEntitlement(userId)`, while *reads* are granted by the
    /// per-user namespace rule with no entitlement check at all. So a member
    /// whose entitlement lapsed, with both toggles still persisted true and
    /// nothing left to upload, would otherwise keep issuing live Firestore reads
    /// the server would happily answer. Entitlement absent ⇒ zero reads.
    func test_sync_doesNotPull_whenTheDataVaultEntitlementIsAbsent() async throws {
        let uid = "e2-user-unentitled"
        let (store, queue) = try await makeStoreWithApprovedMemory(uid: uid)
        let gateway = CloudSyncFirestoreFakeGateway()
        let settings = makeSettings(optIn: true, fleetEnabled: true, deviceSync: true)
        let domain = makeDomain(
            store: store,
            accountManager: .makeSignedIn(uid: uid),
            settings: settings,
            gateway: gateway,
            entitled: false
        )

        // Both user toggles are on and persisted — only the entitlement is gone.
        XCTAssertTrue(settings.memoryDeviceSyncOptIn)
        XCTAssertTrue(settings.memoryApprovedCloudBackupEnabled)
        await domain.sync()

        // The live tier is resolved onto the settings mirror each cycle, so the
        // Settings row goes closed on the same evidence the pull did.
        XCTAssertFalse(settings.memoryDeviceSyncEntitlementSatisfied)
        XCTAssertFalse(settings.memoryDeviceSyncEnabled, "the effective pull gate is closed without the entitlement")
        XCTAssertFalse(settings.memoryDeviceSyncRowEnabled, "and the row shows exactly that gate")

        XCTAssertEqual(
            gateway.queryCount(under: "users/\(uid)/memory_facts"),
            0,
            "an unentitled install must issue zero memory_facts reads"
        )
        let inboxRows = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM agent_memory_inbox") ?? -1
        }
        XCTAssertEqual(inboxRows, 0, "and the inbox stays empty")
        XCTAssertNil(domain.lastSyncError)
    }

    /// Turning cloud backup off must stop the download too: a member who revokes
    /// memory egress does not keep an active memory sync channel open inbound.
    func test_theDeviceSyncGateIsClampedByTheCloudBackupGate() {
        let settings = makeSettings(optIn: false, fleetEnabled: true, deviceSync: true)
        XCTAssertTrue(settings.memoryDeviceSyncOptIn)
        XCTAssertFalse(settings.memoryDeviceSyncEnabled, "the sub-toggle alone can never start a download")

        settings.memoryApprovedCloudBackupOptIn = true
        XCTAssertTrue(settings.memoryDeviceSyncEnabled)

        // And the fleet ceiling clamps both halves with one flip.
        settings.memoryExtractionRemoteConfigEnabled = false
        XCTAssertFalse(settings.memoryDeviceSyncEnabled)

        // As does the Data Vault entitlement, the fourth lever.
        settings.memoryExtractionRemoteConfigEnabled = true
        XCTAssertTrue(settings.memoryDeviceSyncEnabled)
        settings.memoryDeviceSyncEntitlementSatisfied = false
        XCTAssertFalse(settings.memoryDeviceSyncEnabled, "a lapsed entitlement closes the pull gate too")
    }

    /// With both levers on, the same cycle uploads and then reads back. The order
    /// matters: the pull runs AFTER the push, so a device that just learned a fact
    /// publishes it before it looks for other devices' facts.
    func test_sync_pullsRemoteFacts_whenBothTheBackupGateAndTheSubToggleAllow() async throws {
        let uid = "e2-user-pull-on"
        // The store carries BOTH kinds: the chat memory the other tests use, and
        // a mirrored agent memory. Only the second can ever merge — see the
        // helper — so this also pins the chat-corpus behaviour end to end.
        let (store, queue) = try await makeStoreWithApprovedMemory(uid: uid)
        try await seedMirroredAgentMemory(
            store: store,
            queue: queue,
            uid: uid,
            id: "mem-e2-agent",
            engineID: "mem_e2e2000011112222333344445555666e",
            body: "Deploys are cut from the release branch."
        )
        let gateway = CloudSyncFirestoreFakeGateway()
        let settings = makeSettings(optIn: true, fleetEnabled: true, deviceSync: true)
        let domain = makeDomain(
            store: store,
            accountManager: .makeSignedIn(uid: uid),
            settings: settings,
            gateway: gateway
        )

        XCTAssertTrue(settings.memoryDeviceSyncEnabled)
        await domain.sync()

        // Both documents went up; only the one that carries an engine project
        // identity comes back down. This device's own upload is read straight
        // back — the same-member, same-vault-key round trip a second device sees.
        XCTAssertEqual(gateway.documents(under: "users/\(uid)/memory_facts").count, 2)
        let parked = try await queue.read { db in
            try String.fetchAll(db, sql: "SELECT engine_memory_id FROM agent_memory_inbox")
        }
        XCTAssertEqual(
            parked,
            ["mem_e2e2000011112222333344445555666e"],
            "the agent memory parks; the chat memory can never be keyed for convergence and is refused without parking"
        )
        let report = try XCTUnwrap(domain.lastPullReport)
        XCTAssertEqual(report.counters?.applied, 1)
        XCTAssertEqual(report.counters?.skipped, 1, "the chat memory is counted, not silently dropped")
        // Proves the read counter the negative cases assert on is not vacuous:
        // the open gate really does query `memory_facts`.
        XCTAssertGreaterThan(gateway.queryCount(under: "users/\(uid)/memory_facts"), 0)
        XCTAssertNil(domain.lastSyncError)
        XCTAssertNotNil(domain.lastSyncDate)
        // The daemon's drain filters on this marker, so an open gate must
        // publish it — otherwise the rows the pull just parked never merge.
        let marker = try await store.fetchMemoryDeviceSyncMarkerUserID()
        XCTAssertEqual(marker, uid, "an open gate names the consenting member for the daemon to enforce")
    }

    // MARK: - The inbox guard (final-review Critical 1)

    /// Consent off means nothing pending may drain — the member's OWN parked
    /// rows included. The sub-toggle governs ingress into the engine as much as
    /// ingress into the inbox: before this, a member who turned device sync off
    /// still had every already-parked fact merged on the next MCP tool call,
    /// because the drain was reachable without consulting a single consent lever.
    func test_sync_purgesTheMembersOwnPendingRowsAndWithdrawsConsent_whenTheSubToggleIsOff() async throws {
        let uid = "e2-user-consent-withdrawn"
        let (store, queue) = try await makeStoreWithApprovedMemory(uid: uid)
        try await store.upsertRemoteMemoryFact(
            docID: "doc-own-pending",
            userID: uid,
            engineMemoryID: "mem_own",
            payloadJSON: "{}",
            remoteUpdatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        try await store.writeMemoryDeviceSyncMarker(userID: uid)

        let settings = makeSettings(optIn: true, fleetEnabled: true, deviceSync: false)
        let domain = makeDomain(
            store: store,
            accountManager: .makeSignedIn(uid: uid),
            settings: settings,
            gateway: CloudSyncFirestoreFakeGateway()
        )
        await domain.sync()

        let pending = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM agent_memory_inbox WHERE applied_at IS NULL") ?? -1
        }
        XCTAssertEqual(pending, 0, "consent off ⇒ the member's own pending rows go, not just other members'")
        let marker = try await store.fetchMemoryDeviceSyncMarkerUserID()
        XCTAssertNil(marker, "and the daemon is told there is no consent, so a racing drain hands over nothing")
    }

    /// The account-switch half, enforced EAGERLY. The purge used to live inside
    /// `pullRemoteFacts`, which runs only when every lever is open — so member B
    /// signing in without ever turning device sync on never ran it, and member
    /// A's rows sat there waiting for B's engine. This purge runs before the gate
    /// can return.
    func test_sync_purgesTheFormerMembersPendingRows_evenWithTheGateClosed() async throws {
        let uid = "e2-user-b"
        let (store, queue) = try await makeStoreWithApprovedMemory(uid: uid)
        try await store.upsertRemoteMemoryFact(
            docID: "doc-member-a",
            userID: "e2-user-a",
            engineMemoryID: "mem_a",
            payloadJSON: #"{"text":"A private fact"}"#,
            remoteUpdatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        // B is signed in and has never touched the device-sync toggle.
        let settings = makeSettings(optIn: true, fleetEnabled: true, deviceSync: false)
        let domain = makeDomain(
            store: store,
            accountManager: .makeSignedIn(uid: uid),
            settings: settings,
            gateway: CloudSyncFirestoreFakeGateway()
        )
        await domain.sync()

        let rows = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM agent_memory_inbox") ?? -1
        }
        XCTAssertEqual(rows, 0, "the previous member's unmerged rows are gone before any drain could see them")
    }

    // MARK: - Pull observability (final-review Important 7)

    /// Stands in for the pull so the one case that cannot be reached from
    /// outside `sync()` — the push succeeded and the PULL failed — is testable.
    private struct StubPullService: MemoryCloudPulling {
        let result: MemoryCloudPullResult?

        func pullRemoteFacts(uid: String, vaultKey: Data, since: Date?, now: Date) async throws -> MemoryCloudPullResult {
            guard let result else { throw NSError(domain: "UnitTest", code: 7) }
            return result
        }
    }

    /// A failed pull must NOT be reported as a successful cycle. This is the one
    /// operator signal a convergence feature has, and a device failing every
    /// pull on every cycle used to emit an unbroken run of `outcome: "success"`.
    func test_aFailedPullDegradesTheCycleOutcomeAndIsRecorded() async throws {
        XCTAssertEqual(MemoryCloudPullReport.completedOutcome(pullOutcome: "failure"), "partial")
        XCTAssertEqual(MemoryCloudPullReport.completedOutcome(pullOutcome: "success"), "success")
        XCTAssertEqual(
            MemoryCloudPullReport.completedOutcome(pullOutcome: "skipped"),
            "success",
            "a cycle that was never asked to pull is still a clean cycle"
        )

        let uid = "e2-user-pull-failure"
        let (store, _) = try await makeStoreWithApprovedMemory(uid: uid)
        let gateway = CloudSyncFirestoreFakeGateway()
        let settings = makeSettings(optIn: true, fleetEnabled: true, deviceSync: true)
        let domain = MemoryCloudSyncDomain(
            store: store,
            accountManager: FakeAccountManager.makeSignedIn(uid: uid),
            settingsManager: settings,
            firestoreGateway: gateway,
            vaultKeyProvider: TestConversationVaultKeyProvider(),
            entitlementResolver: FakeDataVaultEntitlementResolver(entitled: true),
            pullService: StubPullService(result: nil)
        )

        await domain.sync()

        // The push still succeeded — the pull failure must not undo it.
        XCTAssertEqual(gateway.documents(under: "users/\(uid)/memory_facts").count, 1)
        XCTAssertNotNil(domain.lastSyncError, "a failed pull is an error on this domain, not silence")
        let report = try XCTUnwrap(domain.lastPullReport)
        XCTAssertEqual(report.outcome, MemoryCloudPullReport.failureOutcome)
        XCTAssertNil(report.counters)
        XCTAssertEqual(MemoryCloudPullReport.completedOutcome(pullOutcome: report.outcome), "partial")
    }

    /// The counters exist so an operator can answer "is anything arriving on
    /// this Mac, and is any of it being refused". They used to be computed,
    /// returned, and thrown away at `_ = try await pullService.pullRemoteFacts`.
    func test_aSuccessfulPullPublishesItsCounters() async throws {
        let uid = "e2-user-pull-counters"
        let (store, _) = try await makeStoreWithApprovedMemory(uid: uid)
        let counters = MemoryCloudPullResult(
            applied: 3,
            unchanged: 1,
            rejected: 2,
            purgedOtherAccount: 4,
            skipped: 5,
            sweptStale: 6
        )
        let settings = makeSettings(optIn: true, fleetEnabled: true, deviceSync: true)
        let domain = MemoryCloudSyncDomain(
            store: store,
            accountManager: FakeAccountManager.makeSignedIn(uid: uid),
            settingsManager: settings,
            firestoreGateway: CloudSyncFirestoreFakeGateway(),
            vaultKeyProvider: TestConversationVaultKeyProvider(),
            entitlementResolver: FakeDataVaultEntitlementResolver(entitled: true),
            pullService: StubPullService(result: counters)
        )

        await domain.sync()

        let report = try XCTUnwrap(domain.lastPullReport)
        XCTAssertEqual(report.outcome, MemoryCloudPullReport.successOutcome)
        XCTAssertEqual(report.counters, counters)
        XCTAssertNil(domain.lastSyncError)
    }

    /// A closed sub-toggle is not a failed pull: the cycle is clean and the
    /// report says the pull was skipped rather than leaving a stale one behind.
    func test_aClosedSubToggleReportsASkippedPullNotAFailedOne() async throws {
        let uid = "e2-user-pull-skipped"
        let (store, _) = try await makeStoreWithApprovedMemory(uid: uid)
        let settings = makeSettings(optIn: true, fleetEnabled: true, deviceSync: false)
        let domain = MemoryCloudSyncDomain(
            store: store,
            accountManager: FakeAccountManager.makeSignedIn(uid: uid),
            settingsManager: settings,
            firestoreGateway: CloudSyncFirestoreFakeGateway(),
            vaultKeyProvider: TestConversationVaultKeyProvider(),
            entitlementResolver: FakeDataVaultEntitlementResolver(entitled: true),
            pullService: StubPullService(result: nil)
        )

        await domain.sync()

        let report = try XCTUnwrap(domain.lastPullReport)
        XCTAssertEqual(report.outcome, MemoryCloudPullReport.skippedOutcome)
        XCTAssertNil(domain.lastSyncError)
    }
}
