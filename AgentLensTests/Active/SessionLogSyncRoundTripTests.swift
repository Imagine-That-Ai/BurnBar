import XCTest
import GRDB
import FirebaseFirestore
import CryptoKit
import OpenBurnBarCore
@testable import OpenBurnBar

@MainActor
final class SessionLogSyncRoundTripTests: XCTestCase {
    private var dataStore: DataStore!
    private var accountManager: FakeAccountManager!
    private var settingsManager: SettingsManager!
    private var fakeGateway: CloudSyncFirestoreFakeGateway!
    private var fakeEncryptedCloudClient: FakeSessionLogEncryptedCloudClient!
    private var fakeVaultKeyStore: FakeSessionLogVaultKeyStore!
    private var fakeVaultKeyPublisher: FakeSessionLogVaultKeyPublisher!
    private var fakeArchivedSessionMirror: FakeSessionLogArchivedSessionMirror!
    private var conversationVaultKeyProvider: TestConversationVaultKeyProvider!
    private var context: CloudSyncContext!
    private var sessionLogSync: SessionLogSyncService!
    private var downloadSync: DownloadSyncService!

    override func setUp() async throws {
        dataStore = try makeDiscoveryInMemoryStore()
        accountManager = FakeAccountManager.makeSignedIn()
        settingsManager = SettingsManager(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!)
        settingsManager.sessionLogCloudBackupEnabled = true
        fakeGateway = CloudSyncFirestoreFakeGateway()
        fakeEncryptedCloudClient = FakeSessionLogEncryptedCloudClient()
        fakeVaultKeyStore = FakeSessionLogVaultKeyStore()
        fakeVaultKeyPublisher = FakeSessionLogVaultKeyPublisher()
        fakeArchivedSessionMirror = FakeSessionLogArchivedSessionMirror()
        conversationVaultKeyProvider = TestConversationVaultKeyProvider()
        context = CloudSyncContext(
            dataStore: dataStore,
            accountManager: accountManager,
            settingsManager: settingsManager,
            firestoreGateway: fakeGateway
        )
        sessionLogSync = SessionLogSyncService(
            context: context,
            encryptedCloudClient: fakeEncryptedCloudClient,
            vaultKeyStore: fakeVaultKeyStore,
            vaultKeyPublisher: fakeVaultKeyPublisher,
            archivedSessionMirror: fakeArchivedSessionMirror
        )
        downloadSync = DownloadSyncService(
            context: context,
            conversationVaultKeyProvider: conversationVaultKeyProvider
        )
    }

    // MARK: - Upload

    func test_sessionLogUploadSkipsConcurrentDuplicateRunsAcrossServiceInstances() async throws {
        let record = ConversationRecord(
            id: ConversationRecord.stableId(provider: .codex, sessionId: "session-concurrent-backup"),
            provider: .codex,
            sessionId: "session-concurrent-backup",
            projectName: "BackupRace",
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            endTime: Date(timeIntervalSince1970: 1_700_000_120),
            messageCount: 2,
            userWordCount: 4,
            assistantWordCount: 8,
            keyFiles: [],
            keyCommands: [],
            keyTools: [],
            inferredTaskTitle: "Concurrent backup race",
            lastAssistantMessage: "Only one uploader should drain this queue.",
            fullText: "A manual backup and refresh backup started at the same time.",
            fileModifiedAt: nil,
            summaryTitle: "Concurrent Backup"
        )
        try dataStore.upsertConversation(record)

        let firstUploadStarted = expectation(description: "first upload started")
        fakeEncryptedCloudClient.onBeginUpload = {
            firstUploadStarted.fulfill()
            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        let secondEncryptedCloudClient = FakeSessionLogEncryptedCloudClient()
        let secondService = SessionLogSyncService(
            context: context,
            encryptedCloudClient: secondEncryptedCloudClient,
            vaultKeyStore: fakeVaultKeyStore,
            vaultKeyPublisher: fakeVaultKeyPublisher,
            archivedSessionMirror: fakeArchivedSessionMirror
        )

        let firstTask = Task {
            await sessionLogSync.sync()
        }
        await fulfillment(of: [firstUploadStarted], timeout: 1.0)

        await secondService.sync()
        await firstTask.value

        XCTAssertEqual(fakeEncryptedCloudClient.uploadedBodies.count, 1)
        XCTAssertEqual(fakeEncryptedCloudClient.searchIndexCommits.count, 1)
        XCTAssertTrue(secondEncryptedCloudClient.uploadedBodies.isEmpty)
        XCTAssertTrue(secondEncryptedCloudClient.searchIndexCommits.isEmpty)
    }

    func test_sessionLogUploadUsesCanonicalCloudDocumentIDForPathShapedRecords() async throws {
        let record = ConversationRecord(
            id: ConversationRecord.stableId(
                provider: .factory,
                sessionId: "~/albertonunez/Documents/Windsurf/Imagine That.Ai/App/2.0"
            ),
            provider: .factory,
            sessionId: "~/albertonunez/Documents/Windsurf/Imagine That.Ai/App/2.0",
            projectName: "Imagine That.Ai",
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            endTime: Date(timeIntervalSince1970: 1_700_000_120),
            messageCount: 9,
            userWordCount: 40,
            assistantWordCount: 120,
            keyFiles: [],
            keyCommands: [],
            keyTools: [],
            inferredTaskTitle: "About Page Visual Upgrade with Editorial Bento Layout",
            lastAssistantMessage: "Updated the about page layout.",
            fullText: "Conversation body from a provider log whose session id is a local filesystem path.",
            fileModifiedAt: nil,
            summaryTitle: "About Page Visual Upgrade"
        )
        try dataStore.upsertConversation(record)

        await sessionLogSync.sync()

        let upload = try XCTUnwrap(fakeEncryptedCloudClient.uploadRequests.first)
        XCTAssertEqual(upload.documentID, SessionLogSyncService.cloudDocumentID(deviceId: "test-device-1", record: record))
        XCTAssertNil(upload.documentID.range(of: #"[^A-Za-z0-9_.:-]"#, options: .regularExpression))
        XCTAssertFalse(upload.documentID.contains("/"))
        XCTAssertFalse(upload.documentID.contains("~"))
        XCTAssertLessThanOrEqual(upload.documentID.count, 512)
    }

    func test_sessionLogUpload_writesCheapSearchMetadataOnExistingChunks() async throws {
        let record = ConversationRecord(
            id: ConversationRecord.stableId(provider: .kimi, sessionId: "session-kimi-1"),
            provider: .kimi,
            sessionId: "session-kimi-1",
            projectName: "MobileSearch",
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            endTime: Date(timeIntervalSince1970: 1_700_000_120),
            messageCount: 2,
            userWordCount: 5,
            assistantWordCount: 8,
            keyFiles: [],
            keyCommands: [],
            keyTools: [],
            inferredTaskTitle: "Find firebase search path",
            lastAssistantMessage: "Use existing chunks.",
            fullText: "How do we search previous streams cheaply?\nReuse the opt-in Firebase session log chunk path.",
            fileModifiedAt: nil,
            summaryTitle: "Cheap Firebase Search"
        )
        try dataStore.upsertConversation(record)
        let docId = SessionLogSyncService.cloudDocumentID(deviceId: "test-device-1", record: record)
        let manifestPath = "users/test-uid-1/session_logs/\(docId)"
        let chunkPath = "\(manifestPath)/chunks/0"
        fakeGateway.setDocumentData([
            "id": record.id,
            "sessionId": record.sessionId,
            "bodyStorage": "firebase_storage_encrypted",
            "bodyHash": "legacy",
            "body": "legacy plaintext manifest body"
        ], at: manifestPath)
        fakeGateway.setDocumentData([
            "index": 0,
            "sessionId": record.sessionId,
            "body": "legacy plaintext chunk body",
            "title": "legacy plaintext title",
            "snippet": "legacy plaintext snippet",
            "terms": ["legacy", "plaintext"]
        ], at: chunkPath)

        await sessionLogSync.sync()

        let manifest = try XCTUnwrap(fakeGateway.documentData(at: manifestPath))
        XCTAssertEqual(manifest["sessionId"] as? String, "session-kimi-1")
        XCTAssertEqual(manifest["model"] as? String, "unknown")
        XCTAssertEqual(manifest["bodyStorage"] as? String, "firebase_storage_encrypted")
        XCTAssertEqual(manifest["storagePath"] as? String, "session-logs/\(docId).json")
        XCTAssertNil(manifest["body"] as? String)
        XCTAssertNotNil(manifest["bodyHash"] as? String)
        XCTAssertEqual(manifest["chunkMetadataVersion"] as? Int, 1)
        XCTAssertEqual(manifest["cloudSearchIndexVersion"] as? Int, 5)
        XCTAssertNil(manifest["projectName"] as? String)
        XCTAssertNil(manifest["workingDirectory"] as? String)
        XCTAssertEqual(fakeEncryptedCloudClient.uploadedBodies.count, 1)
        XCTAssertEqual(fakeEncryptedCloudClient.searchIndexCommits.count, 1)

        let chunk = try XCTUnwrap(fakeGateway.documentData(at: chunkPath))
        XCTAssertEqual(chunk["uid"] as? String, "test-uid-1")
        XCTAssertEqual(chunk["sessionId"] as? String, "session-kimi-1")
        XCTAssertEqual(chunk["deviceId"] as? String, "test-device-1")
        XCTAssertEqual(chunk["docId"] as? String, docId)
        XCTAssertEqual(chunk["schemaVersion"] as? Int, 1)
        XCTAssertEqual(chunk["bodyStorage"] as? String, "firebase_storage_encrypted")
        XCTAssertNil(chunk["body"] as? String)
        XCTAssertNil(chunk["title"] as? String)
        XCTAssertNil(chunk["snippet"] as? String)
        XCTAssertNil(chunk["terms"] as? [String])
        XCTAssertNil(chunk["projectName"] as? String)
        XCTAssertNil(chunk["workingDirectory"] as? String)
        XCTAssertNotNil(chunk["sealedSnippet"] as? [String: Any])
        XCTAssertFalse((chunk["tokenHashes"] as? [String] ?? []).isEmpty)
        XCTAssertFalse((chunk["semanticHashes"] as? [String] ?? []).isEmpty)
    }

    func test_sessionLogUploadIndexesExactNameBeyondFirstTokenWindow() async throws {
        let key = Data(repeating: 7, count: 32)
        let emilioHash = try XCTUnwrap(
            CloudVaultCrypto.tokenHashes(for: "emilio", keyData: key, limit: 1).first
        )
        let longPrefix = (0..<1_200)
            .map { "uniquetoken\($0)" }
            .joined(separator: " ")
        let record = ConversationRecord(
            id: ConversationRecord.stableId(provider: .codex, sessionId: "session-emilio-late"),
            provider: .codex,
            sessionId: "session-emilio-late",
            projectName: "MobileSearch",
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            endTime: Date(timeIntervalSince1970: 1_700_000_120),
            messageCount: 2,
            userWordCount: 1_200,
            assistantWordCount: 20,
            keyFiles: [],
            keyCommands: [],
            keyTools: [],
            inferredTaskTitle: "Search exact person names",
            lastAssistantMessage: "Mentioned Emilio near the end.",
            fullText: "\(longPrefix) Emilio should still be searchable from the hosted encrypted index.",
            fileModifiedAt: nil,
            summaryTitle: "Exact name search"
        )
        try dataStore.upsertConversation(record)

        await sessionLogSync.sync()

        let commit = try XCTUnwrap(fakeEncryptedCloudClient.searchIndexCommits.first)
        XCTAssertEqual(commit.indexVersion, 5)
        XCTAssertNil(commit.document["projectName"] as? String)
        XCTAssertTrue(commit.chunks.allSatisfy { $0["projectName"] == nil })
        XCTAssertGreaterThan(commit.chunks.count, 1)
        XCTAssertTrue(
            commit.chunks.contains { chunk in
                (chunk["tokenHashes"] as? [String] ?? []).contains(emilioHash)
            },
            "The hosted index must retain exact names even when they appear after hundreds of earlier unique tokens."
        )
    }

    func test_sessionLogUploadIndexesPrefixMatchesForLongPathNames() async throws {
        let key = Data(repeating: 7, count: 32)
        let queryHashes = try CloudVaultCrypto.searchQueryTokenHashes(for: "emilio", keyData: key, limit: 10)
        let record = ConversationRecord(
            id: ConversationRecord.stableId(provider: .codex, sessionId: "session-emilio-prefix"),
            provider: .codex,
            sessionId: "session-emilio-prefix",
            projectName: "MobileSearch",
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            endTime: Date(timeIntervalSince1970: 1_700_000_120),
            messageCount: 2,
            userWordCount: 40,
            assistantWordCount: 20,
            keyFiles: [],
            keyCommands: [],
            keyTools: [],
            inferredTaskTitle: "Search path owner names",
            lastAssistantMessage: "Indexed a long path owner token.",
            fullText: "The transcript referenced /Users/emilionunezgarcia/Developer/LaHormigaDormida during setup.",
            fileModifiedAt: nil,
            summaryTitle: "Prefix name search"
        )
        try dataStore.upsertConversation(record)

        await sessionLogSync.sync()

        let commit = try XCTUnwrap(fakeEncryptedCloudClient.searchIndexCommits.first)
        let indexedHashes = commit.chunks.flatMap { ($0["tokenHashes"] as? [String]) ?? [] }
        XCTAssertFalse(
            Set(indexedHashes).isDisjoint(with: queryHashes),
            "The hosted index must let a short name query match longer path/user tokens without plaintext search."
        )
    }

    func test_sessionLogUpload_skipsUnchangedBodyToAvoidExtraWrites() async throws {
        let record = ConversationRecord(
            id: ConversationRecord.stableId(provider: .factory, sessionId: "unchanged-session"),
            provider: .factory,
            sessionId: "unchanged-session",
            projectName: "CheapSync",
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            endTime: Date(timeIntervalSince1970: 1_700_000_120),
            messageCount: 1,
            userWordCount: 4,
            assistantWordCount: 4,
            keyFiles: [],
            keyCommands: [],
            keyTools: [],
            inferredTaskTitle: "Avoid duplicate chunk writes",
            lastAssistantMessage: "Done.",
            fullText: "Stable transcript body.",
            fileModifiedAt: nil
        )
        try dataStore.upsertConversation(record)

        await sessionLogSync.sync()
        let commitsAfterFirstSync = fakeGateway.batchCommitCount
        XCTAssertGreaterThan(commitsAfterFirstSync, 0)

        try await dataStore.dbQueue.write { db in
            try db.execute(sql: "UPDATE conversations SET logSyncedAt = NULL WHERE id = ?", arguments: [record.id])
        }

        await sessionLogSync.sync()
        XCTAssertEqual(fakeGateway.batchCommitCount, commitsAfterFirstSync)
        XCTAssertTrue(try dataStore.fetchUnsyncedSessionLogs().isEmpty)
    }

    func test_sessionLogUpload_skipPathScrubsLegacyChunkPlaintext() async throws {
        let record = ConversationRecord(
            id: ConversationRecord.stableId(provider: .factory, sessionId: "unchanged-legacy-chunk-session"),
            provider: .factory,
            sessionId: "unchanged-legacy-chunk-session",
            projectName: "CheapSync",
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            endTime: Date(timeIntervalSince1970: 1_700_000_120),
            messageCount: 1,
            userWordCount: 4,
            assistantWordCount: 4,
            keyFiles: [],
            keyCommands: [],
            keyTools: [],
            inferredTaskTitle: "Scrub legacy chunks",
            lastAssistantMessage: "Done.",
            fullText: "Stable transcript body with enough content to produce a search chunk.",
            fileModifiedAt: nil
        )
        try dataStore.upsertConversation(record)

        await sessionLogSync.sync()
        let commitsAfterFirstSync = fakeGateway.batchCommitCount
        XCTAssertEqual(fakeEncryptedCloudClient.uploadedBodies.count, 1)
        XCTAssertEqual(fakeEncryptedCloudClient.searchIndexCommits.count, 1)

        let docId = SessionLogSyncService.cloudDocumentID(deviceId: "test-device-1", record: record)
        let manifestPath = "users/test-uid-1/session_logs/\(docId)"
        let chunkPath = "\(manifestPath)/chunks/0"
        let orphanChunkPath = "\(manifestPath)/chunks/stale"
        fakeGateway.setDocumentData([
            "index": 0,
            "sessionId": record.sessionId,
            "body": "legacy plaintext chunk body",
            "title": "legacy plaintext title",
            "snippet": "legacy plaintext snippet",
            "terms": ["legacy", "plaintext"]
        ], at: chunkPath)
        fakeGateway.setDocumentData([
            "index": 999,
            "sessionId": record.sessionId,
            "body": "orphaned legacy plaintext chunk body",
            "snippet": "orphaned legacy plaintext snippet",
            "terms": ["orphaned", "plaintext"]
        ], at: orphanChunkPath)

        try await dataStore.dbQueue.write { db in
            try db.execute(sql: "UPDATE conversations SET logSyncedAt = NULL WHERE id = ?", arguments: [record.id])
        }

        await sessionLogSync.sync()

        XCTAssertEqual(fakeEncryptedCloudClient.uploadedBodies.count, 1)
        XCTAssertEqual(fakeEncryptedCloudClient.searchIndexCommits.count, 1)
        XCTAssertEqual(fakeGateway.batchCommitCount, commitsAfterFirstSync + 1)
        XCTAssertTrue(try dataStore.fetchUnsyncedSessionLogs().isEmpty)

        let chunk = try XCTUnwrap(fakeGateway.documentData(at: chunkPath))
        XCTAssertEqual(chunk["bodyStorage"] as? String, "firebase_storage_encrypted")
        XCTAssertEqual(chunk["docId"] as? String, docId)
        XCTAssertNil(chunk["body"] as? String)
        XCTAssertNil(chunk["title"] as? String)
        XCTAssertNil(chunk["snippet"] as? String)
        XCTAssertNil(chunk["terms"] as? [String])
        XCTAssertNotNil(chunk["sealedSnippet"] as? [String: Any])
        XCTAssertFalse((chunk["tokenHashes"] as? [String] ?? []).isEmpty)
        XCTAssertFalse((chunk["semanticHashes"] as? [String] ?? []).isEmpty)

        let orphan = try XCTUnwrap(fakeGateway.documentData(at: orphanChunkPath))
        XCTAssertEqual(orphan["bodyStorage"] as? String, "firebase_storage_encrypted")
        XCTAssertEqual(orphan["docId"] as? String, docId)
        XCTAssertEqual(orphan["orphanedByEncryptedReindex"] as? Bool, true)
        XCTAssertNil(orphan["body"] as? String)
        XCTAssertNil(orphan["snippet"] as? String)
        XCTAssertNil(orphan["terms"] as? [String])
        XCTAssertTrue((orphan["tokenHashes"] as? [String] ?? ["not-empty"]).isEmpty)
        XCTAssertTrue((orphan["semanticHashes"] as? [String] ?? ["not-empty"]).isEmpty)
    }

    func test_sessionLogUpload_incompleteEncryptedManifestReuploadsBeforeScrubbingLegacyChunks() async throws {
        let record = ConversationRecord(
            id: ConversationRecord.stableId(provider: .factory, sessionId: "incomplete-manifest-session"),
            provider: .factory,
            sessionId: "incomplete-manifest-session",
            projectName: "CheapSync",
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            endTime: Date(timeIntervalSince1970: 1_700_000_120),
            messageCount: 1,
            userWordCount: 4,
            assistantWordCount: 4,
            keyFiles: [],
            keyCommands: [],
            keyTools: [],
            inferredTaskTitle: "Repair missing storage path",
            lastAssistantMessage: "Done.",
            fullText: "Stable transcript body with a manifest that lost its encrypted storage path.",
            fileModifiedAt: nil
        )
        try dataStore.upsertConversation(record)

        let markdown = SessionLogMarkdownFormatter.markdown(for: record)
        let bodyHash = SHA256.hash(data: Data(markdown.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let docId = SessionLogSyncService.cloudDocumentID(deviceId: "test-device-1", record: record)
        let manifestPath = "users/test-uid-1/session_logs/\(docId)"
        let chunkPath = "\(manifestPath)/chunks/0"
        fakeGateway.setDocumentData([
            "id": record.id,
            "sessionId": record.sessionId,
            "bodyHash": bodyHash,
            "bodyStorage": "firebase_storage_encrypted",
            "chunkMetadataVersion": 1,
            "cloudSearchIndexVersion": 5
        ], at: manifestPath)
        fakeGateway.setDocumentData([
            "index": 0,
            "sessionId": record.sessionId,
            "body": "legacy plaintext chunk body",
            "snippet": "legacy plaintext snippet",
            "terms": ["legacy", "plaintext"]
        ], at: chunkPath)

        await sessionLogSync.sync()

        XCTAssertEqual(fakeEncryptedCloudClient.uploadedBodies.count, 1)
        XCTAssertEqual(fakeEncryptedCloudClient.searchIndexCommits.count, 1)

        let manifest = try XCTUnwrap(fakeGateway.documentData(at: manifestPath))
        XCTAssertEqual(manifest["bodyStorage"] as? String, "firebase_storage_encrypted")
        XCTAssertEqual(manifest["storagePath"] as? String, "session-logs/\(docId).json")
        XCTAssertNil(manifest["body"] as? String)

        let chunk = try XCTUnwrap(fakeGateway.documentData(at: chunkPath))
        XCTAssertEqual(chunk["bodyStorage"] as? String, "firebase_storage_encrypted")
        XCTAssertEqual(chunk["storagePath"] as? String, "session-logs/\(docId).json")
        XCTAssertNil(chunk["body"] as? String)
        XCTAssertNil(chunk["snippet"] as? String)
        XCTAssertNil(chunk["terms"] as? [String])
        XCTAssertNotNil(chunk["sealedSnippet"] as? [String: Any])
    }

    func test_countUnsyncedSessionLogs_tracksDirtyFlags() throws {
        let record = ConversationRecord(
            id: ConversationRecord.stableId(provider: .cursor, sessionId: "sess-count"),
            provider: .cursor,
            sessionId: "sess-count",
            projectName: "CountProject",
            startTime: Date(),
            endTime: Date(),
            messageCount: 1,
            userWordCount: 1,
            assistantWordCount: 1,
            keyFiles: [],
            keyCommands: [],
            keyTools: [],
            inferredTaskTitle: "Count me",
            lastAssistantMessage: "Done",
            fullText: "Body",
            fileModifiedAt: nil
        )
        try dataStore.upsertConversation(record)
        XCTAssertEqual(try dataStore.countUnsyncedSessionLogs(), 1)
    }

    func test_backupUsageSnapshot_countsPendingStorageAndLimits() throws {
        let synced = ConversationRecord(
            id: ConversationRecord.stableId(provider: .cursor, sessionId: "sess-usage-synced"),
            provider: .cursor,
            sessionId: "sess-usage-synced",
            projectName: "UsageProject",
            startTime: Date(),
            endTime: Date(),
            messageCount: 1,
            userWordCount: 2,
            assistantWordCount: 3,
            keyFiles: [],
            keyCommands: [],
            keyTools: [],
            inferredTaskTitle: "Already backed up",
            lastAssistantMessage: "Done",
            fullText: "Synced body",
            fileModifiedAt: nil
        )
        let pending = ConversationRecord(
            id: ConversationRecord.stableId(provider: .codex, sessionId: "sess-usage-pending"),
            provider: .codex,
            sessionId: "sess-usage-pending",
            projectName: "UsageProject",
            startTime: Date(),
            endTime: Date(),
            messageCount: 1,
            userWordCount: 4,
            assistantWordCount: 5,
            keyFiles: [],
            keyCommands: [],
            keyTools: [],
            inferredTaskTitle: "Emilio searchable",
            lastAssistantMessage: "Mentioned Emilio",
            fullText: "Pending body that should still count toward backup storage.",
            fileModifiedAt: nil
        )
        try dataStore.upsertConversation(synced)
        try dataStore.upsertConversation(pending)
        try dataStore.markSessionLogsSynced(ids: [synced.id])

        let usage = try dataStore.backupUsageSnapshot(
            limits: CloudBackupPlanLimits(
                transcriptByteLimit: 16 * 1024,
                searchableIndexByteLimit: 128 * 1024,
                conversationLimit: 10
            )
        )

        XCTAssertEqual(usage.conversationCount, 2)
        XCTAssertEqual(usage.pendingConversationCount, 1)
        XCTAssertEqual(usage.searchChunkCount, 2)
        XCTAssertEqual(usage.pendingSearchChunkCount, 1)
        XCTAssertGreaterThan(usage.rawTranscriptBytes, 0)
        XCTAssertGreaterThan(usage.estimatedSearchIndexBytes, usage.rawTranscriptBytes)
        XCTAssertTrue(usage.isWithinLimits)

        let blocked = try dataStore.backupUsageSnapshot(
            limits: CloudBackupPlanLimits(
                transcriptByteLimit: 1,
                searchableIndexByteLimit: .max,
                conversationLimit: 10
            )
        )
        XCTAssertFalse(blocked.isWithinLimits)
        XCTAssertEqual(blocked.blockingReason?.contains("Backup storage limit reached"), true)
    }

    func test_sessionLogUpload_stopsBeforeNetworkWhenBackupLimitExceeded() async throws {
        let record = ConversationRecord(
            id: ConversationRecord.stableId(provider: .factory, sessionId: "sess-limit"),
            provider: .factory,
            sessionId: "sess-limit",
            projectName: "LimitProject",
            startTime: Date(),
            endTime: Date(),
            messageCount: 1,
            userWordCount: 1,
            assistantWordCount: 1,
            keyFiles: [],
            keyCommands: [],
            keyTools: [],
            inferredTaskTitle: "Too much backup",
            lastAssistantMessage: "Blocked",
            fullText: "This body is intentionally larger than the tiny test limit.",
            fileModifiedAt: nil
        )
        try dataStore.upsertConversation(record)
        let limitedContext = CloudSyncContext(
            dataStore: dataStore,
            accountManager: accountManager,
            settingsManager: settingsManager,
            firestoreGateway: fakeGateway,
            backupPlanLimits: CloudBackupPlanLimits(
                transcriptByteLimit: 1,
                searchableIndexByteLimit: .max,
                conversationLimit: 50_000
            )
        )
        let limitedSync = SessionLogSyncService(
            context: limitedContext,
            encryptedCloudClient: fakeEncryptedCloudClient,
            vaultKeyStore: fakeVaultKeyStore,
            vaultKeyPublisher: fakeVaultKeyPublisher,
            archivedSessionMirror: fakeArchivedSessionMirror
        )

        await limitedSync.sync(drainAll: true)

        XCTAssertEqual(fakeEncryptedCloudClient.uploadedBodies.count, 0)
        XCTAssertEqual(fakeEncryptedCloudClient.searchIndexCommits.count, 0)
        XCTAssertEqual(try dataStore.countUnsyncedSessionLogs(), 1)
        XCTAssertEqual(limitedSync.lastSyncError?.contains("Backup storage limit reached"), true)
    }

    func test_manualBackupProgress_emitsRealCounters() async throws {
        let record = ConversationRecord(
            id: ConversationRecord.stableId(provider: .kimi, sessionId: "sess-progress"),
            provider: .kimi,
            sessionId: "sess-progress",
            projectName: "ProgressProject",
            startTime: Date(),
            endTime: Date(),
            messageCount: 2,
            userWordCount: 3,
            assistantWordCount: 4,
            keyFiles: [],
            keyCommands: [],
            keyTools: [],
            inferredTaskTitle: "Progress session",
            lastAssistantMessage: "Complete",
            fullText: "Progress body text.",
            fileModifiedAt: nil
        )
        try dataStore.upsertConversation(record)

        var snapshots: [CloudBackupProgressSnapshot] = []
        let tracker = CloudBackupProgressTracker { snapshots.append($0) }
        tracker.begin(pendingSessionLogs: 1, pendingChatThreads: 0)

        await sessionLogSync.sync(drainAll: true, progress: tracker)
        tracker.complete()

        XCTAssertFalse(snapshots.isEmpty)
        XCTAssertEqual(snapshots.last?.uploadedSessionLogs, 1)
        XCTAssertGreaterThan(snapshots.last?.encryptedBytes ?? 0, 0)
        XCTAssertEqual(snapshots.last?.storageUploads, 1)
    }

    // MARK: - Download

    func test_sessionLogDownload_decryptsEncryptedBody() async throws {
        let docId = "remote-device-2_session-log-remote"
        let manifestPath = "users/test-uid-1/session_logs/\(docId)"

        let largeBody = String(repeating: "B", count: 1_000_000)
        let storagePath = "users/test-uid-1/session_logs/\(docId)/bodies/encrypted.json.aesgcm"
        let envelope = try CloudVaultCrypto.sealBlob(
            Data(largeBody.utf8),
            keyData: try fakeVaultKeyStore.getOrCreateKey(uid: "test-uid-1")
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        fakeEncryptedCloudClient.downloadableBodies[storagePath] = try encoder.encode(envelope)

        fakeGateway.setDocumentData([
            "id": "session-log-remote",
            "deviceId": "remote-device-2",
            "provider": AgentProvider.cursor.rawValue,
            "sourceType": ConversationSourceType.providerLog.rawValue,
            "projectName": "RemoteProject",
            "inferredTaskTitle": "Remote Task",
            "messageCount": 5,
            "bodyStorage": "firebase_storage_encrypted",
            "storagePath": storagePath,
            "vaultKeyID": try CloudVaultCrypto.vaultKeyID(for: fakeVaultKeyStore.getOrCreateKey(uid: "test-uid-1")),
            "byteCount": largeBody.utf8.count
        ], at: manifestPath)

        let body = try await sessionLogSync.fetchCloudSessionLogBody(docId: docId)
        XCTAssertEqual(body, largeBody)
    }

    func test_sessionLogDownload_viaFullSync_ignoresLegacyFirestoreChunkBody() async throws {
        let remoteDeviceId = "remote-device-2"
        let remoteConvId = "conv-remote-log"
        let docId = "\(remoteDeviceId)_\(remoteConvId)"
        let manifestPath = "users/test-uid-1/session_logs/\(docId)"
        let updatedAt = Date().addingTimeInterval(-60) // recent enough to pass 90-day watermark

        let body = "# Remote Session Log\n\nThis is the full markdown body."
        let sealed = try ConversationCloudSealer.seal(
            ConversationCloudPrivatePayload(
                projectName: "RemoteProject",
                keyFiles: [],
                keyCommands: [],
                keyTools: [],
                inferredTaskTitle: "Remote Task",
                lastAssistantMessage: "Remote msg",
                workingDirectory: nil,
                summary: nil,
                summaryTitle: nil,
                summaryProvider: nil,
                summaryModel: nil
            ),
            key: try conversationVaultKeyProvider.resolvedKey(),
            uid: "test-uid-1",
            docId: docId
        )

        let convDocPath = "users/test-uid-1/conversations/\(remoteDeviceId)_\(remoteConvId)"
        fakeGateway.setDocumentData([
            "id": remoteConvId,
            "deviceId": remoteDeviceId,
            "provider": AgentProvider.cursor.rawValue,
            "sessionId": "remote-session",
            "messageCount": 3,
            "userWordCount": 10,
            "assistantWordCount": 20,
            "contentSealed": true,
            "sealedSchemaVersion": 1,
            "vaultKeyID": try conversationVaultKeyProvider.resolvedKey().vaultKeyID,
            "sealedPayload": sealed,
            "sourceType": ConversationSourceType.providerLog.rawValue,
            "updatedAt": Timestamp(date: updatedAt),
            "startTime": Timestamp(date: updatedAt),
            "endTime": Timestamp(date: updatedAt.addingTimeInterval(100))
        ], at: convDocPath)

        // Seed a legacy Firestore chunk body. Hardened sync must ignore it;
        // encrypted blob readback is the only body path.
        fakeGateway.setDocumentData([
            "id": remoteConvId,
            "deviceId": remoteDeviceId,
            "provider": AgentProvider.cursor.rawValue,
            "sourceType": ConversationSourceType.providerLog.rawValue,
            "projectName": "RemoteProject",
            "inferredTaskTitle": "Remote Task",
            "messageCount": 3,
            "chunkCount": 1,
            "byteCount": body.utf8.count
        ], at: manifestPath)

        fakeGateway.setDocumentData([
            "index": 0,
            "body": body
        ], at: "\(manifestPath)/chunks/0")

        // Seed device registry
        fakeGateway.setDocumentData([
            "deviceName": "Remote Studio",
            "platform": "macOS",
            "lastActiveAt": updatedAt
        ], at: "users/test-uid-1/devices/\(remoteDeviceId)")

        await downloadSync.sync()

        let conversations = try await dataStore.fetchConversations()
        let remoteConversations = conversations.filter { $0.isRemote }
        XCTAssertEqual(remoteConversations.count, 1)

        let remote = remoteConversations.first!
        XCTAssertEqual(remote.fullText, "")
    }

    // MARK: - Private project search text clamping

    func test_clampedPrivateSearchText_passesThroughShortValues() {
        XCTAssertEqual(
            SessionLogSyncService.clampedPrivateSearchText("~/Developer/LaHormigaDormida"),
            "~/Developer/LaHormigaDormida"
        )
    }

    func test_clampedPrivateSearchText_trimsWhitespace() {
        XCTAssertEqual(SessionLogSyncService.clampedPrivateSearchText("  spaced path  "), "spaced path")
    }

    func test_clampedPrivateSearchText_truncatesToTheHashBudget() {
        let clamped = SessionLogSyncService.clampedPrivateSearchText(String(repeating: "a", count: 900))
        XCTAssertEqual(clamped.utf16.count, SessionLogSyncService.cloudFacetMaxLength)
        XCTAssertEqual(clamped.utf16.count, 512)
    }

    func test_clampedPrivateSearchText_neverSplitsAGrapheme() {
        // Each emoji is 2 UTF-16 units, so a 512-unit budget admits exactly 256 whole emoji and the
        // truncation must not leave a dangling surrogate half.
        let clamped = SessionLogSyncService.clampedPrivateSearchText(String(repeating: "😀", count: 600))
        XCTAssertLessThanOrEqual(clamped.utf16.count, SessionLogSyncService.cloudFacetMaxLength)
        XCTAssertTrue(clamped.allSatisfy { $0 == "😀" })
        XCTAssertEqual(clamped.count, 256)
    }
}

@MainActor
private final class FakeSessionLogVaultKeyStore: SessionLogVaultKeyProviding {
    private var key = Data(repeating: 7, count: 32)

    func loadKey(uid: String) throws -> Data? {
        key
    }

    func getOrCreateKey(uid: String) throws -> Data {
        key
    }
}

@MainActor
private final class FakeSessionLogVaultKeyPublisher: SessionLogVaultKeyPublishing {
    private(set) var publishedKeys: [(uid: String, key: Data)] = []

    func publishCloudVaultKey(uid: String, vaultKey: Data, context: CloudSyncContext) async throws {
        publishedKeys.append((uid, vaultKey))
    }
}

@MainActor
private final class FakeSessionLogArchivedSessionMirror: SessionLogArchivedSessionMirroring {
    private(set) var mirrored: [(conversationID: String, cloudLogDocumentID: String?)] = []

    func mirrorArchivedLog(_ conversation: ConversationRecord, cloudLogDocumentID: String?) async {
        mirrored.append((conversation.id, cloudLogDocumentID))
    }
}
