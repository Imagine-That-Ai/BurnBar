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

    // MARK: - Eager purge on auth transitions (re-review Important)

    /// **The sign-out window.** `enforce` ran only from `sync()` (the refresh
    /// cadence, 600 s by default) and the Settings toggle, so a sign-out left the
    /// consent marker naming the member who left for up to a full tick — and for
    /// ever if the app quit before the next one, because the daemon that honours
    /// the marker outlives the app. This is the same closure applied at the
    /// moment the identity changes, with no tick to wait for.
    func test_signOut_purgesEveryPendingRowAndWithdrawsConsent_withoutASyncTick() async throws {
        let uid = "e2-user-signing-out"
        let (store, queue) = try await makeStoreWithApprovedMemory(uid: uid)
        try await store.upsertRemoteMemoryFact(
            docID: "doc-own-pending",
            userID: uid,
            engineMemoryID: "mem_own",
            payloadJSON: "{}",
            remoteUpdatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        try await store.writeMemoryDeviceSyncMarker(userID: uid)

        // Device sync fully ON: this must purge because the member LEFT, not
        // because a consent lever happens to be closed.
        let domain = makeDomain(
            store: store,
            accountManager: .makeSignedIn(uid: uid),
            settings: makeSettings(optIn: true, fleetEnabled: true, deviceSync: true),
            gateway: CloudSyncFirestoreFakeGateway()
        )

        await domain.handleAccountIdentityChange(to: nil)

        let pending = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM agent_memory_inbox WHERE applied_at IS NULL") ?? -1
        }
        XCTAssertEqual(pending, 0, "nobody is signed in to consent to a drain: every pending row goes")
        let marker = try await store.fetchMemoryDeviceSyncMarkerUserID()
        XCTAssertNil(marker, "and the marker the daemon reads is withdrawn immediately, not on the next tick")
    }

    /// A uid change A → B, applied at the transition. A's parked plaintext goes
    /// and the marker names nobody, so a drain landing before B's next
    /// consenting sync gets nothing rather than A's memories.
    func test_accountSwitch_dropsTheFormerMembersRowsAndLeavesNobodyNamed() async throws {
        let (store, queue) = try await makeStoreWithApprovedMemory(uid: "e2-switch-b")
        for (doc, owner) in [("doc-a", "e2-switch-a"), ("doc-b", "e2-switch-b")] {
            try await store.upsertRemoteMemoryFact(
                docID: doc,
                userID: owner,
                engineMemoryID: "mem_\(doc)",
                payloadJSON: "{}",
                remoteUpdatedAt: Date(timeIntervalSince1970: 1_800_000_000)
            )
        }
        try await store.writeMemoryDeviceSyncMarker(userID: "e2-switch-a")

        let domain = makeDomain(
            store: store,
            accountManager: .makeSignedIn(uid: "e2-switch-b"),
            settings: makeSettings(optIn: true, fleetEnabled: true, deviceSync: true),
            gateway: CloudSyncFirestoreFakeGateway()
        )

        await domain.handleAccountIdentityChange(to: "e2-switch-b")

        let remaining = try await queue.read { db in
            try String.fetchAll(db, sql: "SELECT doc_id FROM agent_memory_inbox ORDER BY doc_id")
        }
        XCTAssertEqual(
            remaining,
            ["doc-b"],
            "A's unmerged rows go; B's own survive — a session restore is a transition too, and must not throw away the member's own pending facts"
        )
        let markerAfterSwitch = try await store.fetchMemoryDeviceSyncMarkerUserID()
        XCTAssertNil(
            markerAfterSwitch,
            "consent is re-established by the next consenting sync reading the live gate, not assumed here"
        )
    }

    /// The wiring itself: the domain subscribes, and the subscription is what
    /// actually runs the purge. Without this the two halves above are dead code
    /// — `enforceAccountTransition` existing is not the same as it being called.
    func test_theDomainSubscribesToAccountIdentityChangesAndPurgesOnOne() async throws {
        let uid = "e2-observer-a"
        let (store, queue) = try await makeStoreWithApprovedMemory(uid: uid)
        try await store.upsertRemoteMemoryFact(
            docID: "doc-a",
            userID: uid,
            engineMemoryID: "mem_a",
            payloadJSON: "{}",
            remoteUpdatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        try await store.writeMemoryDeviceSyncMarker(userID: uid)

        let accountManager = FakeAccountManager.makeSignedIn(uid: uid)
        let domain = makeDomain(
            store: store,
            accountManager: accountManager,
            settings: makeSettings(optIn: true, fleetEnabled: true, deviceSync: true),
            gateway: CloudSyncFirestoreFakeGateway()
        )
        XCTAssertTrue(accountManager.accountIdentityObservers.isEmpty)

        domain.startObservingAccountIdentity()
        XCTAssertEqual(accountManager.accountIdentityObservers.count, 1, "the domain subscribed")

        accountManager.simulateAccountIdentityChange(to: nil)

        // The observer hands off to a Task; poll rather than sleep a fixed span.
        var pending = -1
        for _ in 0..<200 {
            pending = try await queue.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM agent_memory_inbox WHERE applied_at IS NULL") ?? -1
            }
            if pending == 0 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(pending, 0, "the sign-out the observer saw purged the parked plaintext")
        let markerAfterObservedSignOut = try await store.fetchMemoryDeviceSyncMarkerUserID()
        XCTAssertNil(markerAfterObservedSignOut)
    }

    /// The marker is REFRESHED, not merely written once. The daemon's age bound
    /// (`deviceSyncConsentMarkerMaxAge`) only works if a consenting cycle
    /// advances the stamp every tick — a write-on-change marker would go stale
    /// under a member who never changed anything.
    func test_everyConsentingSyncRefreshesTheMarkerStamp() async throws {
        let uid = "e2-marker-refresh"
        let (store, queue) = try await makeStoreWithApprovedMemory(uid: uid)
        let early = Date(timeIntervalSince1970: 1_800_000_000)
        try await store.writeMemoryDeviceSyncMarker(userID: uid, now: early)
        let firstStamp = try await queue.read { db in
            try Date.fetchOne(
                db,
                sql: "SELECT lastSyncedAt FROM remote_sync_watermarks WHERE collectionKind = ?",
                arguments: [BurnBarMemoryDeviceSyncMarker.collectionKind]
            )
        }
        XCTAssertEqual(firstStamp, early)

        try await store.writeMemoryDeviceSyncMarker(userID: uid, now: early.addingTimeInterval(600))
        let secondStamp = try await queue.read { db in
            try Date.fetchOne(
                db,
                sql: "SELECT lastSyncedAt FROM remote_sync_watermarks WHERE collectionKind = ?",
                arguments: [BurnBarMemoryDeviceSyncMarker.collectionKind]
            )
        }
        XCTAssertEqual(
            secondStamp,
            early.addingTimeInterval(600),
            "the same member, unchanged, still advances the stamp — otherwise the daemon's age bound would expire a live consent"
        )
        let markerCount = try await queue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM remote_sync_watermarks WHERE collectionKind = ?",
                arguments: [BurnBarMemoryDeviceSyncMarker.collectionKind]
            ) ?? -1
        }
        XCTAssertEqual(markerCount, 1, "one marker, ever — two is the ambiguity the daemon reads as no consent")
    }

    // MARK: - Withdrawal generation (sign-out closure re-review: the enforce/transition race)

    private func park(_ docID: String, owner: String, in store: ControlPlaneStore) async throws {
        try await store.upsertRemoteMemoryFact(
            docID: docID,
            userID: owner,
            engineMemoryID: "mem_\(docID)",
            payloadJSON: "{}",
            remoteUpdatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    private func pendingDocIDs(_ queue: DatabaseQueue) async throws -> [String] {
        try await queue.read { db in
            try String.fetchAll(db, sql: "SELECT doc_id FROM agent_memory_inbox WHERE applied_at IS NULL ORDER BY doc_id")
        }
    }

    /// The interleaving the re-review named. A sync tick reads the generation
    /// and captures "member A, consenting", then suspends; A signs out (marker
    /// withdrawn, rows purged); the stale tick resumes. Before the generation
    /// check it republished A's marker — the daemon would have honoured A's
    /// consent for up to a whole refresh interval after A left.
    func test_aTickThatObservedTheDepartedMemberCannotRepublishTheirConsent() async throws {
        let uid = "e2-stale-a"
        let (store, queue) = try await makeStoreWithApprovedMemory(uid: uid)
        try await park("doc-a", owner: uid, in: store)
        try await store.writeMemoryDeviceSyncMarker(userID: uid)

        // The tick, up to its first await: generation first, then the scope.
        let observed = MemoryDeviceSyncInboxGuard.observeGeneration(store: store)
        let staleScope = MemoryDeviceSyncScope(uid: uid, consentGranted: true)
        // A signs out while the tick is suspended.
        try await MemoryDeviceSyncInboxGuard.enforceAccountTransition(to: nil, store: store)

        let outcome = try await MemoryDeviceSyncInboxGuard.enforce(
            scope: staleScope,
            observedGeneration: observed,
            store: store
        )

        XCTAssertTrue(outcome.staleObservation, "the publish was refused, not applied")
        XCTAssertFalse(outcome.markerPublished)
        let marker = try await store.fetchMemoryDeviceSyncMarkerUserID()
        XCTAssertNil(marker, "the departed member's consent stays withdrawn")
        let pending = try await pendingDocIDs(queue)
        XCTAssertEqual(pending, [], "and their purged plaintext stays purged")
    }

    /// The other arm of the same race: after A → B, B's next sync parks B's
    /// rows; a stale A-tick's "purge everything that is not A's" must not eat
    /// them.
    func test_aStaleTickCannotPurgeTheNewMembersFreshlyPulledRows() async throws {
        let (store, queue) = try await makeStoreWithApprovedMemory(uid: "e2-stale-b")
        try await park("doc-a", owner: "e2-stale-a", in: store)
        try await store.writeMemoryDeviceSyncMarker(userID: "e2-stale-a")

        let observed = MemoryDeviceSyncInboxGuard.observeGeneration(store: store)
        let staleScope = MemoryDeviceSyncScope(uid: "e2-stale-a", consentGranted: true)
        try await MemoryDeviceSyncInboxGuard.enforceAccountTransition(to: "e2-stale-b", store: store)
        // B's pull lands a row before the stale tick resumes.
        try await park("doc-b", owner: "e2-stale-b", in: store)

        let outcome = try await MemoryDeviceSyncInboxGuard.enforce(
            scope: staleScope,
            observedGeneration: observed,
            store: store
        )

        XCTAssertTrue(outcome.staleObservation)
        let pending = try await pendingDocIDs(queue)
        XCTAssertEqual(pending, ["doc-b"], "B's freshly-pulled row survives the stale A-tick")
        let marker = try await store.fetchMemoryDeviceSyncMarkerUserID()
        XCTAssertNil(marker, "nobody is named until B's own consenting tick reads the live gate")
    }

    /// The check must not be always-false: a tick that read the generation
    /// AFTER the transition publishes the new member normally.
    func test_aFreshObservationAfterTheTransitionPublishesTheNewMember() async throws {
        let (store, queue) = try await makeStoreWithApprovedMemory(uid: "e2-fresh-b")
        try await park("doc-a", owner: "e2-fresh-a", in: store)
        try await park("doc-b", owner: "e2-fresh-b", in: store)
        try await MemoryDeviceSyncInboxGuard.enforceAccountTransition(to: "e2-fresh-b", store: store)

        let observed = MemoryDeviceSyncInboxGuard.observeGeneration(store: store)
        let outcome = try await MemoryDeviceSyncInboxGuard.enforce(
            scope: MemoryDeviceSyncScope(uid: "e2-fresh-b", consentGranted: true),
            observedGeneration: observed,
            store: store
        )

        XCTAssertFalse(outcome.staleObservation)
        XCTAssertTrue(outcome.markerPublished)
        let marker = try await store.fetchMemoryDeviceSyncMarkerUserID()
        XCTAssertEqual(marker, "e2-fresh-b")
        let pending = try await pendingDocIDs(queue)
        XCTAssertEqual(pending, ["doc-b"])
    }

    /// The Settings toggle is a withdrawal too. Turning device sync OFF between
    /// a tick's gate read and its publish must win: the closed pass advances
    /// the generation, so the stale open pass is refused rather than
    /// republishing consent the member just withdrew.
    func test_turningTheToggleOffInvalidatesATickThatObservedItOn() async throws {
        let uid = "e2-toggle-race"
        let (store, queue) = try await makeStoreWithApprovedMemory(uid: uid)
        try await park("doc-own", owner: uid, in: store)
        try await store.writeMemoryDeviceSyncMarker(userID: uid)

        let observedByTick = MemoryDeviceSyncInboxGuard.observeGeneration(store: store)
        let tickScope = MemoryDeviceSyncScope(uid: uid, consentGranted: true)

        // The toggle flips off and enforces immediately. Withdrawals are never
        // conditional, so its own generation read is irrelevant to the outcome.
        let toggleOutcome = try await MemoryDeviceSyncInboxGuard.enforce(
            scope: MemoryDeviceSyncScope(uid: uid, consentGranted: false),
            observedGeneration: MemoryDeviceSyncInboxGuard.observeGeneration(store: store),
            store: store
        )
        XCTAssertEqual(toggleOutcome.purgedConsentWithdrawn, 1)
        XCTAssertEqual(
            MemoryDeviceSyncInboxGuard.observeGeneration(store: store),
            observedByTick + 1,
            "a closing pass is a withdrawal and advances the generation"
        )

        let tickOutcome = try await MemoryDeviceSyncInboxGuard.enforce(
            scope: tickScope,
            observedGeneration: observedByTick,
            store: store
        )

        XCTAssertTrue(tickOutcome.staleObservation)
        let marker = try await store.fetchMemoryDeviceSyncMarkerUserID()
        XCTAssertNil(marker, "consent the member withdrew is not republished by a tick that predates the withdrawal")
        let pending = try await pendingDocIDs(queue)
        XCTAssertEqual(pending, [])
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

    // MARK: - One consent computation (Codex L)

    /// The Settings toggle and the sync tick must mean the same thing by
    /// "consent". They did not: the toggle handler built its scope from the
    /// MEMORY levers alone, so a member whose ACCOUNT-wide cloud sync was off
    /// could flip the memory sub-toggle on and have the app publish a fresh
    /// daemon consent marker — pending remote facts draining into the engine
    /// until the next tick withdrew it. An account-level opt-out a sub-toggle
    /// can override for a refresh interval is not an opt-out.
    func test_accountWideCloudSyncOffClosesTheScopeEvenWithEveryMemoryLeverOn() async throws {
        let uid = "e2-account-sync-off"
        let (store, queue) = try await makeStoreWithApprovedMemory(uid: uid)
        let settings = makeSettings(optIn: true, fleetEnabled: true, deviceSync: true, entitlementSatisfied: true)
        let account = FakeAccountManager.makeSignedIn(uid: uid)
        account.isCloudSyncEnabled = false

        // Every MEMORY lever is open — this is exactly the state the toggle
        // handler used to read as consent.
        XCTAssertTrue(settings.memoryApprovedCloudBackupEnabled)
        XCTAssertTrue(settings.memoryDeviceSyncEnabled)

        let scope = MemoryDeviceSyncScope.current(account: account, settings: settings)
        XCTAssertFalse(scope.consentGranted, "account-wide cloud sync off is a withdrawal of pull consent too")
        XCTAssertFalse(scope.isOpen)

        // And enforcing it does what a closed scope must: no marker for the
        // daemon, and the member's OWN pending rows go — nothing may drain.
        try await store.writeMemoryDeviceSyncMarker(userID: uid)
        try await store.upsertRemoteMemoryFact(
            docID: "doc-own-pending",
            userID: uid,
            engineMemoryID: "mem_own",
            payloadJSON: "{}",
            remoteUpdatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let outcome = try await MemoryDeviceSyncInboxGuard.enforce(
            scope: scope,
            observedGeneration: MemoryDeviceSyncInboxGuard.observeGeneration(store: store),
            store: store
        )
        XCTAssertFalse(outcome.markerPublished)
        XCTAssertEqual(outcome.purgedConsentWithdrawn, 1)
        let marker = try await store.fetchMemoryDeviceSyncMarkerUserID()
        XCTAssertNil(marker, "the daemon must not be told a member consents when their account opted out")
        let pending = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM agent_memory_inbox WHERE applied_at IS NULL") ?? -1
        }
        XCTAssertEqual(pending, 0)
    }

    /// The positive half of the same helper: with the account levers open it
    /// grants consent and names the signed-in member, so the fix cannot be
    /// "always closed".
    func test_theSharedScopeHelperGrantsConsentWhenEveryLeverIsOpen() async throws {
        let settings = makeSettings(optIn: true, fleetEnabled: true, deviceSync: true, entitlementSatisfied: true)
        let account = FakeAccountManager.makeSignedIn(uid: "e2-all-open")
        let scope = MemoryDeviceSyncScope.current(account: account, settings: settings)
        XCTAssertTrue(scope.isOpen)
        XCTAssertEqual(scope.uid, "e2-all-open")
    }

    // MARK: - Marker freshness on its own cadence (Codex K)

    private func markerStamp(_ queue: DatabaseQueue) async throws -> Date? {
        try await queue.read { db in
            try Date.fetchOne(
                db,
                sql: "SELECT lastSyncedAt FROM remote_sync_watermarks WHERE collectionKind = ?",
                arguments: [BurnBarMemoryDeviceSyncMarker.collectionKind]
            )
        }
    }

    /// The daemon expires a marker no refresh has touched inside
    /// `BurnBarMemoryDeviceSyncMarker.maxAge`. Riding that on the app's refresh
    /// cadence made freshness a function of a user-adjustable interval that the
    /// background coordinator stretches 5x while the app is inactive — up to 75
    /// minutes between writes against a 20-minute bound, so the daemon returned
    /// an empty inbox for most of every cycle while every switch said the
    /// feature was on. The marker now beats on its own timer.
    func test_theMarkerRefresherRepublishesConsentWithoutRunningASyncCycle() async throws {
        let uid = "e2-marker-cadence"
        let (store, queue) = try await makeStoreWithApprovedMemory(uid: uid)
        let gateway = CloudSyncFirestoreFakeGateway()
        let settings = makeSettings(optIn: true, fleetEnabled: true, deviceSync: true)
        let domain = makeDomain(
            store: store,
            accountManager: .makeSignedIn(uid: uid),
            settings: settings,
            gateway: gateway
        )

        let refreshed = await domain.refreshConsentMarker()
        let outcome = try XCTUnwrap(refreshed)

        XCTAssertTrue(outcome.markerPublished)
        let marker = try await store.fetchMemoryDeviceSyncMarkerUserID()
        XCTAssertEqual(marker, uid)
        // ...and it did NOT run the cycle: no upload, no pull, no Firestore read.
        XCTAssertTrue(gateway.documents(under: "users/\(uid)/memory_facts").isEmpty)
        XCTAssertEqual(gateway.queryCount(under: "users/\(uid)/memory_facts"), 0)
        XCTAssertNil(domain.lastSyncDate, "a marker beat is not a sync cycle")
        XCTAssertNil(domain.lastPullReport)
    }

    /// The stamp ADVANCES on every beat — presence alone cannot expire, so a
    /// write-on-change marker would go stale under a member who changed nothing.
    func test_everyMarkerBeatAdvancesTheStampTheDaemonAgeBounds() async throws {
        let uid = "e2-marker-beat"
        let (store, queue) = try await makeStoreWithApprovedMemory(uid: uid)
        let settings = makeSettings(optIn: true, fleetEnabled: true, deviceSync: true)
        let clock = Locked(Date(timeIntervalSince1970: 1_800_000_000))
        let domain = MemoryCloudSyncDomain(
            store: store,
            accountManager: FakeAccountManager.makeSignedIn(uid: uid),
            settingsManager: settings,
            firestoreGateway: CloudSyncFirestoreFakeGateway(),
            vaultKeyProvider: TestConversationVaultKeyProvider(),
            entitlementResolver: FakeDataVaultEntitlementResolver(entitled: true),
            now: { clock.read() }
        )

        await domain.refreshConsentMarker()
        let firstStamp = try await markerStamp(queue)
        let first = try XCTUnwrap(firstStamp)

        clock.write(first.addingTimeInterval(MemoryCloudSyncDomain.markerRefreshInterval))
        await domain.refreshConsentMarker()
        let secondStamp = try await markerStamp(queue)
        let second = try XCTUnwrap(secondStamp)

        XCTAssertGreaterThan(second, first, "an unchanged consent still has to be re-vouched for")
    }

    /// A closed gate must not be refreshed into an open one. The beat withdraws
    /// rather than publishes, and takes the member's pending rows with it.
    func test_theMarkerRefresherWithdrawsRatherThanPublishesWhenTheGateIsClosed() async throws {
        let uid = "e2-marker-closed"
        let (store, queue) = try await makeStoreWithApprovedMemory(uid: uid)
        let settings = makeSettings(optIn: true, fleetEnabled: true, deviceSync: false)
        let domain = makeDomain(
            store: store,
            accountManager: .makeSignedIn(uid: uid),
            settings: settings,
            gateway: CloudSyncFirestoreFakeGateway()
        )
        try await store.writeMemoryDeviceSyncMarker(userID: uid)
        try await store.upsertRemoteMemoryFact(
            docID: "doc-pending",
            userID: uid,
            engineMemoryID: "mem_pending",
            payloadJSON: "{}",
            remoteUpdatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        let refreshed = await domain.refreshConsentMarker()
        let outcome = try XCTUnwrap(refreshed)

        XCTAssertFalse(outcome.markerPublished)
        XCTAssertEqual(outcome.purgedConsentWithdrawn, 1)
        let marker = try await store.fetchMemoryDeviceSyncMarkerUserID()
        XCTAssertNil(marker)
        let pending = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM agent_memory_inbox WHERE applied_at IS NULL") ?? -1
        }
        XCTAssertEqual(pending, 0)
    }

    /// The two halves of the contract, pinned against each other. The app's
    /// cadence and the daemon's bound live in one place precisely so a change to
    /// either cannot silently make the marker expire under a live consent.
    func test_theMarkerCadenceLeavesRoomForMissedBeatsInsideTheDaemonsBound() {
        XCTAssertEqual(MemoryCloudSyncDomain.markerRefreshInterval, BurnBarMemoryDeviceSyncMarker.refreshInterval)
        XCTAssertGreaterThanOrEqual(
            BurnBarMemoryDeviceSyncMarker.maxAge,
            3 * MemoryCloudSyncDomain.markerRefreshInterval,
            "the daemon must tolerate at least two missed beats before it stops believing a live consent"
        )
        XCTAssertEqual(BurnBarMemoryDeviceSyncMarker.maxAge, 1200, "20 minutes, unchanged for the daemon")
    }
}
