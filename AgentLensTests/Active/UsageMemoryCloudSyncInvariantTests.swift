import Foundation
import GRDB
import OpenBurnBarCore
import XCTest
@testable import OpenBurnBar

/// U8 of the usage-memory program — the executable v1 replication invariant:
/// **usage memories are LOCAL-ONLY**. They must never reach the sealed-facts
/// lane (`users/{uid}/memory_facts`, uploaded by
/// `MemoryCloudSyncService.syncApprovedMemories`, whose candidate query is
/// `cloudSyncCandidateChatMemories` = chat-only by construction).
///
/// Why: per-vector cloud forget receipts do not exist yet — receipts exist only
/// for the vectorless `memory_facts` lane, and `cloud_search_knowledge` supports
/// only source-level deletes. Until that gap closes, replicating a usage memory
/// would create a cloud row the member cannot provably forget, so replication is
/// BLOCKED structurally (not by a runtime flag). The server-side half of the
/// invariant (the `cloud_search_knowledge` vector lane rejects usage kinds) is
/// pinned by `functions/src/__tests__/usageMemoryReplicationInvariant.test.ts`.
/// See docs/USAGE_MEMORY_DESIGN.md § The v1 replication invariant.
@MainActor
final class UsageMemoryCloudSyncInvariantTests: XCTestCase {
    private func makeStore() throws -> (DatabaseQueue, ControlPlaneStore) {
        let queue = try DatabaseQueue()
        let database = OpenBurnBarDatabase(databaseQueue: queue)
        try database.runMigrationsSafely()
        return (queue, ControlPlaneStore(dbQueue: queue))
    }

    /// Seeds one APPROVED memory per usage kind plus one approved chat memory,
    /// all in the same user scope. Returns the chat memory id.
    private func seedApprovedChatAndUsageMemories(
        store: ControlPlaneStore,
        uid: String,
        now: Date
    ) async throws -> MemoryID {
        let scope = MemoryScope(userID: uid)
        let chatID = "mem-chat-cloud-ok"

        _ = try await store.addChatMemoryAuthorityRecord(
            MemoryAddRequest(
                text: "Chat-derived fact that is allowed to replicate.",
                kind: .preference,
                scope: scope,
                confidence: 0.9,
                citations: [
                    MemoryCitation(
                        id: "cite-chat",
                        threadLogicalID: "thread-u8",
                        messageID: "msg-u8",
                        role: "user",
                        authoredAt: now,
                        contentHash: "hash-chat",
                        crossDeviceHMAC: "hmac-chat"
                    )
                ],
                reviewStatus: .approved
            ),
            id: chatID,
            now: now,
            enabled: true
        )

        _ = try await store.addMemoryAuthorityRecord(
            MemoryAddRequest(
                text: "Safari-ask fact that must stay on device.",
                kind: .fact,
                scope: scope,
                confidence: 0.8,
                reviewStatus: .approved
            ),
            id: "mem-usage-safari-ask",
            sourceKind: .safariAsk,
            now: now.addingTimeInterval(1),
            enabled: true
        )

        _ = try await store.addMemoryAuthorityRecord(
            MemoryAddRequest(
                text: "Agent-session fact that must stay on device.",
                kind: .fact,
                scope: scope,
                confidence: 0.8,
                reviewStatus: .approved
            ),
            id: "mem-usage-agent-session",
            sourceKind: .agentSession,
            now: now.addingTimeInterval(2),
            enabled: true
        )

        return chatID
    }

    // MARK: - The structural invariant (store level)

    /// APPROVED usage memories (one per usage kind) sit next to an approved chat
    /// memory in the same user scope, yet BOTH cloud-sync queries return only
    /// the chat memory. The exclusion is structural — the candidate query is
    /// parameterized to `sourceKinds: [.chat]` — not a review-status or consent
    /// side effect, so no flag flip can leak a usage row into the fact uploader.
    func test_usageMemoriesNeverEnterCloudFactSync() async throws {
        let (_, store) = try makeStore()
        let uid = "u8-user"
        let now = Date(timeIntervalSince1970: 1_800_001_000)
        let chatID = try await seedApprovedChatAndUsageMemories(store: store, uid: uid, now: now)

        // Sanity: all three rows are live, approved, and user-scoped — each one
        // would pass the candidate filter if source kind did not exclude it.
        let usageRecords = try await store.fetchActiveMemoryAuthorityRecords(
            sourceKinds: MemorySourceKind.usageKinds
        )
        XCTAssertEqual(usageRecords.count, 2)
        for record in usageRecords {
            XCTAssertEqual(record.reviewStatus, .approved)
            XCTAssertNil(record.validTo)
            XCTAssertEqual(record.scope.userID, uid)
        }

        let candidates = try await store.cloudSyncCandidateChatMemories(userID: uid)
        XCTAssertEqual(candidates.map(\.id), [chatID])
        XCTAssertEqual(candidates.map(\.sourceKind), [.chat])

        let eligible = try await store.cloudSyncEligibleChatMemories(userID: uid)
        XCTAssertEqual(eligible.map(\.id), [chatID])
        XCTAssertEqual(eligible.map(\.sourceKind), [.chat])
    }

    // MARK: - The invariant through the real uploader (domain level)

    /// Same seed, exercised through `MemoryCloudSyncDomain.sync()` with BOTH
    /// chat-lane egress levers deliberately open (user opt-in + fleet ceiling)
    /// and the real uploader running against the fake Firestore gateway: exactly
    /// ONE document lands under `users/{uid}/memory_facts` — the chat memory.
    /// Opening every chat-lane gate still cannot replicate a usage memory.
    func test_domainSync_replicatesOnlyTheChatFact_whenApprovedUsageMemoriesExist() async throws {
        let uid = "u8-user-domain"
        let (_, store) = try makeStore()
        let now = Date(timeIntervalSince1970: 1_800_002_000)
        _ = try await seedApprovedChatAndUsageMemories(store: store, uid: uid, now: now)

        let gateway = CloudSyncFirestoreFakeGateway()
        let settings = SettingsManager(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!)
        settings.memoryApprovedCloudBackupOptIn = true
        settings.memoryExtractionRemoteConfigEnabled = true
        let domain = MemoryCloudSyncDomain(
            store: store,
            accountManager: FakeAccountManager.makeSignedIn(uid: uid),
            settingsManager: settings,
            firestoreGateway: gateway,
            vaultKeyProvider: TestConversationVaultKeyProvider()
        )

        XCTAssertTrue(settings.memoryApprovedCloudBackupEnabled)
        await domain.sync()

        XCTAssertNil(domain.lastSyncError)
        let docs = gateway.documents(under: "users/\(uid)/memory_facts")
        XCTAssertEqual(
            docs.count, 1,
            "Only the chat memory may replicate; approved usage memories must stay local."
        )
    }
}
