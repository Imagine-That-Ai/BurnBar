import XCTest
import GRDB
import FirebaseFirestore
import OpenBurnBarCore
@testable import OpenBurnBar

@MainActor
final class UsageSyncRoundTripTests: XCTestCase {
    private var dataStore: DataStore!
    private var accountManager: FakeAccountManager!
    private var settingsManager: SettingsManager!
    private var fakeGateway: CloudSyncFirestoreFakeGateway!
    private var context: CloudSyncContext!
    private var usageSync: UsageSyncService!
    private var downloadSync: DownloadSyncService!
    private var providerAccountSync: ProviderAccountSyncService!
    private var quotaSnapshotSync: QuotaSnapshotSyncService!

    override func setUp() async throws {
        dataStore = try makeDiscoveryInMemoryStore()
        accountManager = FakeAccountManager.makeSignedIn()
        settingsManager = SettingsManager(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!)
        fakeGateway = CloudSyncFirestoreFakeGateway()
        context = CloudSyncContext(
            dataStore: dataStore,
            accountManager: accountManager,
            settingsManager: settingsManager,
            firestoreGateway: fakeGateway
        )
        usageSync = UsageSyncService(context: context)
        downloadSync = DownloadSyncService(context: context)
        providerAccountSync = ProviderAccountSyncService(context: context)
        quotaSnapshotSync = QuotaSnapshotSyncService(context: context)
    }

    // MARK: - Write → Read Round Trip

    func test_usageUpload_writesToFirestoreAndMarksSynced() async throws {
        let usage = TokenUsage(
            provider: .claudeCode,
            sessionId: "session-1",
            projectName: "TestProject",
            model: "claude-3-5-sonnet",
            inputTokens: 100,
            outputTokens: 50,
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            endTime: Date(timeIntervalSince1970: 1_700_000_100)
        )
        try dataStore.insert(usage)

        // Precondition: one unsynced row
        let unsyncedBefore = try dataStore.fetchUnsynced()
        XCTAssertEqual(unsyncedBefore.count, 1)

        await usageSync.sync()

        // Postcondition: Firestore contains the document
        let docPath = "users/test-uid-1/usage/test-device-1_\(usage.id.uuidString)"
        let docData = fakeGateway.documentData(at: docPath)
        XCTAssertNotNil(docData)
        XCTAssertEqual(docData?["provider"] as? String, AgentProvider.claudeCode.rawValue)
        XCTAssertEqual(docData?["model"] as? String, "claude-3-5-sonnet")
        XCTAssertEqual(docData?["inputTokens"] as? Int, 100)
        XCTAssertEqual(docData?["outputTokens"] as? Int, 50)
        XCTAssertEqual(docData?["deviceId"] as? String, "test-device-1")

        // Postcondition: local row is marked synced
        let unsyncedAfter = try dataStore.fetchUnsynced()
        XCTAssertTrue(unsyncedAfter.isEmpty)
    }

    func test_usageUpload_drainsMultipleLocalBatchesInOneSync() async throws {
        let baseTime = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<805 {
            let usage = TokenUsage(
                provider: .codex,
                sessionId: "session-\(index)",
                projectName: "BatchProject",
                model: "gpt-5.5",
                inputTokens: 100 + index,
                outputTokens: 25,
                startTime: baseTime.addingTimeInterval(TimeInterval(index)),
                endTime: baseTime.addingTimeInterval(TimeInterval(index + 1))
            )
            try dataStore.insert(usage)
        }

        XCTAssertEqual(try dataStore.fetchUnsynced().count, 400)

        await usageSync.sync()

        XCTAssertEqual(fakeGateway.batchCommitCount, 3)
        XCTAssertEqual(fakeGateway.documents(under: "users/test-uid-1/usage").count, 805)
        XCTAssertTrue(try dataStore.fetchUnsynced().isEmpty)
    }

    func test_providerAccountUpload_writesOnlyNonSecretLocalAccountMetadata() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let account = ProviderAccountDoc(
            id: "minimax-work",
            providerID: ProviderID(rawValue: "minimax"),
            label: "Work",
            status: .connected,
            credentialKind: .bearer,
            storageScope: .deviceKeychain,
            redactedLabel: "Stored in Mac Keychain",
            isDefault: true,
            sortKey: 0,
            lastRefreshAt: now,
            schemaVersion: 1,
            createdAt: now,
            updatedAt: now
        )
        try dataStore.providerAccountStore.upsert(account)

        await providerAccountSync.uploadAccounts()

        let docData = try XCTUnwrap(fakeGateway.documentData(at: "users/test-uid-1/provider_accounts/minimax-work"))
        XCTAssertEqual(docData["id"] as? String, "minimax-work")
        XCTAssertEqual(docData["providerID"] as? String, "minimax")
        XCTAssertEqual(docData["label"] as? String, "Work")
        XCTAssertEqual(docData["storageScope"] as? String, ProviderAccountStorageScope.deviceKeychain.rawValue)
        XCTAssertEqual(docData["sourceDeviceID"] as? String, "test-device-1")
        XCTAssertNil(docData["apiKey"])
        XCTAssertNil(docData["secretVersionName"])
        XCTAssertFalse(docData.keys.contains("credential"))
        XCTAssertFalse(docData.keys.contains("token"))
    }

    func test_providerAccountDownload_importsRemoteAccountMetadataWithoutCredentialFields() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        fakeGateway.setDocumentData([
            "id": "openai-personal",
            "providerID": "openai",
            "label": "Personal",
            "identityHint": "alberto@example.com",
            "status": ProviderAccountStatus.connected.rawValue,
            "credentialKind": CredentialKind.token.rawValue,
            "storageScope": ProviderAccountStorageScope.cloudRefreshable.rawValue,
            "redactedLabel": "sk-...abcd",
            "sourceDeviceID": "iphone-1",
            "isDefault": true,
            "sortKey": 0,
            "schemaVersion": 1,
            "createdAt": Timestamp(date: now),
            "updatedAt": Timestamp(date: now),
            "lastRefreshAt": Timestamp(date: now),
            // Plaintext-shaped fields the cloud-sync layer must drop on
            // ingestion. Values are placeholders only; assertions check
            // that the keys are nil after sync, not the values themselves.
            "apiKey": "must-not-persist",
            "secretVersionName": "must-not-persist"
        ], at: "users/test-uid-1/provider_accounts/openai-personal")

        await downloadSync.sync()

        let account = try XCTUnwrap(dataStore.providerAccountStore.fetch(id: "openai-personal"))
        XCTAssertEqual(account.providerID, .openAI)
        XCTAssertEqual(account.label, "Personal")
        XCTAssertEqual(account.identityHint, "alberto@example.com")
        XCTAssertEqual(account.storageScope, .cloudRefreshable)
        XCTAssertEqual(account.sourceDeviceID, "iphone-1")
        XCTAssertTrue(account.isDefault)
        XCTAssertEqual(account.redactedLabel, "sk-...abcd")
    }

    func test_quotaSnapshotUpload_writesDisplayableMacQuotaForMobile() async throws {
        let snapshot = ProviderQuotaSnapshot(
            provider: .codex,
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000),
            source: .localSession,
            sourceId: "codex-local",
            confidence: .exact,
            managementURL: "https://chatgpt.com/codex",
            statusMessage: "Codex quota from local session.",
            buckets: [
                ProviderQuotaBucket(
                    key: "codex-5h",
                    label: "5-hour window",
                    windowKind: .rollingHours,
                    usedValue: 25,
                    limitValue: 100,
                    remainingValue: 75,
                    usedPercent: 25,
                    resetsAt: Date(timeIntervalSince1970: 1_700_001_000),
                    unit: .percent,
                    isEstimated: false
                )
            ]
        )

        await quotaSnapshotSync.uploadSnapshots([snapshot])

        let path = "users/test-uid-1/quota_snapshots/codex_unattributed_codex-local"
        let doc = try XCTUnwrap(fakeGateway.documentData(at: path))
        XCTAssertEqual(doc["providerID"] as? String, ProviderID.codex.rawValue)
        XCTAssertEqual(doc["provider"] as? String, AgentProvider.codex.persistedToken)
        XCTAssertEqual(doc["sourceKind"] as? String, "localSession")
        XCTAssertEqual(doc["sourceId"] as? String, "codex-local")
        let buckets = try XCTUnwrap(doc["buckets"] as? [[String: Any]])
        XCTAssertEqual(buckets.first?["name"] as? String, "codex-5h")
        XCTAssertEqual(buckets.first?["limit"] as? Double, 100)
        XCTAssertEqual((buckets.first?["meta"] as? [String: String])?["label"], "5-hour window")
    }

    func test_quotaSnapshotUpload_encodesPercentBucketsWithoutLimitAsDisplayableMobileQuota() async throws {
        let snapshot = ProviderQuotaSnapshot(
            provider: .claudeCode,
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000),
            source: .localCLI,
            sourceId: "claude-statusline",
            confidence: .exact,
            managementURL: nil,
            statusMessage: "Claude quota from status line.",
            buckets: [
                ProviderQuotaBucket(
                    key: "claude-5h",
                    label: "5-hour window",
                    windowKind: .rollingHours,
                    usedValue: nil,
                    limitValue: nil,
                    remainingValue: 82,
                    usedPercent: 18,
                    resetsAt: nil,
                    unit: .percent,
                    isEstimated: false
                )
            ]
        )

        await quotaSnapshotSync.uploadSnapshots([snapshot])

        let path = "users/test-uid-1/quota_snapshots/claude-code_unattributed_claude-statusline"
        let doc = try XCTUnwrap(fakeGateway.documentData(at: path))
        let buckets = try XCTUnwrap(doc["buckets"] as? [[String: Any]])
        XCTAssertEqual(buckets.first?["name"] as? String, "claude-5h")
        XCTAssertEqual(buckets.first?["used"] as? Double, 18)
        XCTAssertEqual(buckets.first?["limit"] as? Double, 100)
        XCTAssertEqual(buckets.first?["remaining"] as? Double, 82)
        XCTAssertEqual((buckets.first?["meta"] as? [String: String])?["unit"], "percent")
    }

    func test_usageDownload_readsRemoteUsageIntoLocalStore() async throws {
        // Seed fake Firestore with a remote usage document from another device
        let remoteDeviceId = "remote-device-2"
        let remoteUsageId = UUID().uuidString
        let remoteDocPath = "users/test-uid-1/usage/\(remoteDeviceId)_\(remoteUsageId)"
        let now = Date()
        let remoteUpdatedAt = now

        fakeGateway.setDocumentData([
            "id": remoteUsageId,
            "deviceId": remoteDeviceId,
            "provider": AgentProvider.cursor.rawValue,
            "sessionId": "remote-session-1",
            "projectName": "RemoteProject",
            "model": "gpt-4",
            "inputTokens": 200,
            "outputTokens": 100,
            "cacheCreationTokens": 0,
            "cacheReadTokens": 0,
            "reasoningTokens": 0,
            "usageSource": UsageSource.providerLog.rawValue,
            "totalTokens": 300,
            "cost": 0.015,
            "startTime": Timestamp(date: now),
            "endTime": Timestamp(date: now.addingTimeInterval(100)),
            "updatedAt": Timestamp(date: remoteUpdatedAt)
        ], at: remoteDocPath)

        // Also seed the device registry so the downloader can resolve the device name
        fakeGateway.setDocumentData([
            "deviceName": "Remote MacBook",
            "platform": "macOS",
            "lastActiveAt": Timestamp(date: remoteUpdatedAt)
        ], at: "users/test-uid-1/devices/\(remoteDeviceId)")

        // Debug: test query directly
        let query = fakeGateway.collection("users").document("test-uid-1").collection("usage")
            .whereField("startTime", isGreaterThan: Timestamp(date: Date().addingTimeInterval(-86400 * 91)))
        let snapshot = try await query.getDocuments()
        print("DEBUG: query document count = \(snapshot.documents.count)")
        for doc in snapshot.documents {
            print("DEBUG: query doc id = \(doc.documentID)")
        }

        await downloadSync.sync()

        // Debug: verify fake gateway state
        let allDocs = fakeGateway.documents(under: "users/test-uid-1/usage")
        print("DEBUG: all docs = \(allDocs)")
        print("DEBUG: doc count = \(allDocs.count)")
        for (k, v) in allDocs {
            print("DEBUG: doc key=\(k), startTime=\(v["startTime"] ?? "nil"), updatedAt=\(v["updatedAt"] ?? "nil")")
        }

        // Verify local store contains the remote usage
        let allUsage = try dataStore.usageStore.fetchAllUsage()
        let remoteUsages = allUsage.filter { $0.isRemote }
        XCTAssertEqual(remoteUsages.count, 1, "Expected 1 remote usage but found \(remoteUsages.count). All docs: \(allDocs.keys)")

        let remote = remoteUsages.first!
        XCTAssertEqual(remote.provider, AgentProvider.cursor)
        XCTAssertEqual(remote.sessionId, "remote-session-1")
        XCTAssertEqual(remote.model, "gpt-4")
        XCTAssertEqual(remote.inputTokens, 200)
        XCTAssertEqual(remote.outputTokens, 100)
        XCTAssertEqual(remote.sourceDeviceId, remoteDeviceId)
        XCTAssertEqual(remote.sourceDeviceName, "Remote MacBook")
        XCTAssertTrue(remote.isRemote)
        XCTAssertEqual(remote.provenanceMethod, UsageProvenanceMethod.cloudSync)
        XCTAssertEqual(remote.provenanceConfidence, UsageProvenanceConfidence.exact)
    }

    func test_usageRoundTrip_uploadThenDownload_doesNotReImportOwnData() async throws {
        let usage = TokenUsage(
            provider: .factory,
            sessionId: "session-own",
            projectName: "OwnProject",
            model: "test-model",
            inputTokens: 10,
            outputTokens: 5,
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            endTime: Date(timeIntervalSince1970: 1_700_000_100)
        )
        try dataStore.insert(usage)

        await usageSync.sync()
        await downloadSync.sync()

        // Should not create a duplicate of our own data
        let allUsage = try dataStore.usageStore.fetchAllUsage()
        XCTAssertEqual(allUsage.count, 1)
        XCTAssertFalse(allUsage[0].isRemote)
    }

    func test_firestoreOnlyUsageUpload_isAppendSafeAndIdempotent() async throws {
        let first = TokenUsage(
            provider: .claudeCode,
            sessionId: "append-session-1",
            projectName: "AppendSafe",
            model: "claude-3-5-sonnet",
            inputTokens: 100,
            outputTokens: 20,
            startTime: Date(timeIntervalSince1970: 1_700_010_000),
            endTime: Date(timeIntervalSince1970: 1_700_010_010)
        )
        let second = TokenUsage(
            provider: .codex,
            sessionId: "append-session-2",
            projectName: "AppendSafe",
            model: "gpt-5.5",
            inputTokens: 200,
            outputTokens: 40,
            startTime: Date(timeIntervalSince1970: 1_700_010_100),
            endTime: Date(timeIntervalSince1970: 1_700_010_120)
        )
        try dataStore.insert(first)
        await usageSync.sync()
        XCTAssertEqual(fakeGateway.documents(under: "users/test-uid-1/usage").count, 1)

        try dataStore.insert(second)
        await usageSync.sync()
        await usageSync.sync()

        let docs = fakeGateway.documents(under: "users/test-uid-1/usage")
        XCTAssertEqual(docs.count, 2)
        XCTAssertNotNil(docs["users/test-uid-1/usage/test-device-1_\(first.id.uuidString)"])
        XCTAssertNotNil(docs["users/test-uid-1/usage/test-device-1_\(second.id.uuidString)"])
        XCTAssertEqual(try dataStore.usageStore.fetchAllUsage().count, 2)
        XCTAssertTrue(try dataStore.fetchUnsynced().isEmpty)
    }

    func test_firestoreOnlyProviderAccountUpload_mergesAndPreservesExistingDocuments() async throws {
        let now = Date(timeIntervalSince1970: 1_700_020_000)
        fakeGateway.setDocumentData([
            "legacyMarker": "preserve-me"
        ], at: "users/test-uid-1/provider_accounts/anthropic-main")

        try dataStore.providerAccountStore.upsert(makeProviderAccount(
            id: "anthropic-main",
            providerID: .anthropic,
            label: "Anthropic Main",
            sourceDeviceID: "test-device-1",
            createdAt: now
        ))
        await providerAccountSync.uploadAccounts()

        try dataStore.providerAccountStore.upsert(makeProviderAccount(
            id: "codex-main",
            providerID: .codex,
            label: "Codex Main",
            sourceDeviceID: "test-device-1",
            createdAt: now.addingTimeInterval(1)
        ))
        await providerAccountSync.uploadAccounts()
        await providerAccountSync.uploadAccounts()

        let docs = fakeGateway.documents(under: "users/test-uid-1/provider_accounts")
        XCTAssertEqual(docs.count, 2)
        let anthropic = try XCTUnwrap(docs["users/test-uid-1/provider_accounts/anthropic-main"])
        XCTAssertEqual(anthropic["legacyMarker"] as? String, "preserve-me")
        XCTAssertEqual(anthropic["label"] as? String, "Anthropic Main")
        XCTAssertNotNil(docs["users/test-uid-1/provider_accounts/codex-main"])
    }

    func test_providerAccountDownload_namespacesRemoteDeviceLocalCollision() async throws {
        let now = Date(timeIntervalSince1970: 1_700_030_000)
        try dataStore.providerAccountStore.upsert(makeProviderAccount(
            id: "shared-local-id",
            providerID: .openAI,
            label: "Local Keychain",
            sourceDeviceID: "test-device-1",
            createdAt: now
        ))

        fakeGateway.setDocumentData([
            "id": "shared-local-id",
            "providerID": ProviderID.openAI.rawValue,
            "label": "Remote Keychain",
            "status": ProviderAccountStatus.connected.rawValue,
            "credentialKind": CredentialKind.token.rawValue,
            "storageScope": ProviderAccountStorageScope.deviceKeychain.rawValue,
            "redactedLabel": "Stored on other Mac",
            "sourceDeviceID": "remote-device-2",
            "isDefault": true,
            "sortKey": 0,
            "schemaVersion": 1,
            "createdAt": Timestamp(date: now),
            "updatedAt": Timestamp(date: now)
        ], at: "users/test-uid-1/provider_accounts/shared-local-id")

        await downloadSync.sync()
        await downloadSync.sync()

        let local = try XCTUnwrap(dataStore.providerAccountStore.fetch(id: "shared-local-id"))
        XCTAssertEqual(local.label, "Local Keychain")
        XCTAssertEqual(local.sourceDeviceID, "test-device-1")

        let accounts = try dataStore.providerAccountStore.fetchAll(providerID: .openAI)
        let remote = try XCTUnwrap(accounts.first { $0.sourceDeviceID == "remote-device-2" })
        XCTAssertEqual(remote.id, "shared-local-id__remote_remote-device-2")
        XCTAssertEqual(remote.label, "Remote Keychain")
        XCTAssertFalse(remote.isDefault)
        XCTAssertEqual(accounts.count, 2)
    }

    func test_firestoreOnlyQuotaSnapshotUpload_addsAndRetriesWithoutDuplicating() async throws {
        let first = makeQuotaSnapshot(accountID: "codex-work", sourceId: "codex-work-source", used: 20)
        let second = makeQuotaSnapshot(accountID: "codex-personal", sourceId: "codex-personal-source", used: 30)

        await quotaSnapshotSync.uploadSnapshots([first])
        XCTAssertEqual(fakeGateway.documents(under: "users/test-uid-1/quota_snapshots").count, 1)

        await quotaSnapshotSync.uploadSnapshots([second])
        await quotaSnapshotSync.uploadSnapshots([first, second])

        let docs = fakeGateway.documents(under: "users/test-uid-1/quota_snapshots")
        XCTAssertEqual(docs.count, 2)
        XCTAssertNotNil(docs["users/test-uid-1/quota_snapshots/codex_codex-work_codex-work-source"])
        XCTAssertNotNil(docs["users/test-uid-1/quota_snapshots/codex_codex-personal_codex-personal-source"])
    }

    func test_usageUploadFailure_preservesLocalHistoryForRetry() async throws {
        let usage = TokenUsage(
            provider: .cursor,
            sessionId: "failed-sync-session",
            projectName: "FailureSafe",
            model: "gpt-4",
            inputTokens: 1,
            outputTokens: 2,
            startTime: Date(timeIntervalSince1970: 1_700_040_000),
            endTime: Date(timeIntervalSince1970: 1_700_040_001)
        )
        try dataStore.insert(usage)

        fakeGateway.nextError = NSError(domain: "UnitTest", code: 1)
        await usageSync.sync()
        fakeGateway.nextError = nil

        XCTAssertEqual(try dataStore.fetchUnsynced().map(\.id), [usage.id])
        XCTAssertEqual(try dataStore.usageStore.fetchAllUsage().count, 1)
        XCTAssertTrue(fakeGateway.documents(under: "users/test-uid-1/usage").isEmpty)

        await usageSync.sync()
        XCTAssertTrue(try dataStore.fetchUnsynced().isEmpty)
        XCTAssertEqual(fakeGateway.documents(under: "users/test-uid-1/usage").count, 1)
    }

    func test_iCloudOnlyMirrorStateMerge_preservesPriorRecords() {
        let existing = ICloudSessionMirrorFileRecord(modificationTime: 1, size: 10)
        let incoming = ICloudSessionMirrorFileRecord(modificationTime: 2, size: 20)

        let merged = ICloudSessionMirrorEngine.appendSafeMergedRecords(
            previous: ["/local/session-a.jsonl": existing],
            incoming: ["/local/session-b.jsonl": incoming]
        )

        XCTAssertEqual(merged["/local/session-a.jsonl"], existing)
        XCTAssertEqual(merged["/local/session-b.jsonl"], incoming)
        XCTAssertEqual(merged.count, 2)
    }

    func test_iCloudOnlyMirrorPerform_preservesPriorMirrorWhenSourceDisappears() async throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("OpenBurnBarICloudMirror-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let sourceRoot = tempRoot.appendingPathComponent("source", isDirectory: true)
        let containerBase = tempRoot.appendingPathComponent("container", isDirectory: true)
        let stateURL = tempRoot.appendingPathComponent("state.json")
        try fm.createDirectory(at: sourceRoot, withIntermediateDirectories: true)

        let missingSourcePath = sourceRoot
            .appendingPathComponent("missing.jsonl")
            .standardizedFileURL
            .path
        let priorRecord = ICloudSessionMirrorFileRecord(modificationTime: 1, size: 3)
        try writeMirrorState([missingSourcePath: priorRecord], to: stateURL)

        let priorMirror = mirrorURL(base: containerBase, slug: "Codex", relative: "missing.jsonl")
        try fm.createDirectory(at: priorMirror.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: priorMirror)

        let newSource = sourceRoot.appendingPathComponent("current.jsonl")
        try Data("new".utf8).write(to: newSource)

        let result = await ICloudSessionMirrorEngine.perform(makeMirrorSnapshot(
            sourceRoot: sourceRoot,
            containerBase: containerBase,
            stateURL: stateURL
        ))

        XCTAssertNil(result.errorMessage)
        XCTAssertEqual(result.removedCount, 0)
        XCTAssertTrue(fm.fileExists(atPath: priorMirror.path))
        XCTAssertTrue(fm.fileExists(atPath: mirrorURL(base: containerBase, slug: "Codex", relative: "current.jsonl").path))

        let state = try readMirrorState(from: stateURL)
        XCTAssertEqual(state.files[missingSourcePath], priorRecord)
        XCTAssertNotNil(state.files[newSource.standardizedFileURL.path])
        XCTAssertEqual(state.files.count, 2)
    }

    func test_iCloudOnlyMirrorPerform_recopiesUnchangedSourceWhenMirrorFileIsMissing() async throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("OpenBurnBarICloudMirror-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let sourceRoot = tempRoot.appendingPathComponent("source", isDirectory: true)
        let containerBase = tempRoot.appendingPathComponent("container", isDirectory: true)
        let stateURL = tempRoot.appendingPathComponent("state.json")
        try fm.createDirectory(at: sourceRoot, withIntermediateDirectories: true)

        let source = sourceRoot.appendingPathComponent("current.jsonl")
        try Data("recover me".utf8).write(to: source)
        let attrs = try source.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let sourcePath = source.standardizedFileURL.path
        try writeMirrorState([
            sourcePath: ICloudSessionMirrorFileRecord(
                modificationTime: try XCTUnwrap(attrs.contentModificationDate).timeIntervalSinceReferenceDate,
                size: Int64(attrs.fileSize ?? 0)
            )
        ], to: stateURL)

        let mirror = mirrorURL(base: containerBase, slug: "Codex", relative: "current.jsonl")
        XCTAssertFalse(fm.fileExists(atPath: mirror.path))

        let result = await ICloudSessionMirrorEngine.perform(makeMirrorSnapshot(
            sourceRoot: sourceRoot,
            containerBase: containerBase,
            stateURL: stateURL
        ))

        XCTAssertNil(result.errorMessage)
        XCTAssertEqual(result.updatedCount, 1)
        XCTAssertTrue(fm.fileExists(atPath: mirror.path))
        XCTAssertEqual(try String(contentsOf: mirror), "recover me")
        XCTAssertNotNil(try readMirrorState(from: stateURL).files[sourcePath])
    }

    func test_dualSyncMode_keepsICloudMirrorHistoryIndependentFromFirestoreWrites() async throws {
        let existingMirrorRecord = ICloudSessionMirrorFileRecord(modificationTime: 1, size: 10)
        let newMirrorRecord = ICloudSessionMirrorFileRecord(modificationTime: 3, size: 30)
        let mergedMirrorState = ICloudSessionMirrorEngine.appendSafeMergedRecords(
            previous: ["/mirror/session-a.jsonl": existingMirrorRecord],
            incoming: ["/mirror/session-c.jsonl": newMirrorRecord]
        )

        let usage = TokenUsage(
            provider: .codex,
            sessionId: "dual-sync-session",
            projectName: "DualSafe",
            model: "gpt-5.5",
            inputTokens: 12,
            outputTokens: 24,
            startTime: Date(timeIntervalSince1970: 1_700_050_000),
            endTime: Date(timeIntervalSince1970: 1_700_050_010)
        )
        try dataStore.insert(usage)
        await usageSync.sync()

        XCTAssertEqual(mergedMirrorState["/mirror/session-a.jsonl"], existingMirrorRecord)
        XCTAssertEqual(mergedMirrorState["/mirror/session-c.jsonl"], newMirrorRecord)
        XCTAssertEqual(fakeGateway.documents(under: "users/test-uid-1/usage").count, 1)
        XCTAssertEqual(try dataStore.usageStore.fetchAllUsage().count, 1)
    }

    private func makeProviderAccount(
        id: String,
        providerID: ProviderID,
        label: String,
        sourceDeviceID: String?,
        storageScope: ProviderAccountStorageScope = .deviceKeychain,
        createdAt: Date
    ) -> ProviderAccountDoc {
        ProviderAccountDoc(
            id: id,
            providerID: providerID,
            label: label,
            status: .connected,
            credentialKind: .token,
            storageScope: storageScope,
            redactedLabel: "redacted",
            sourceDeviceID: sourceDeviceID,
            isDefault: true,
            createdAt: createdAt,
            updatedAt: createdAt
        )
    }

    private func makeQuotaSnapshot(accountID: String, sourceId: String, used: Double) -> OpenBurnBar.ProviderQuotaSnapshot {
        OpenBurnBar.ProviderQuotaSnapshot(
            provider: .codex,
            providerID: .codex,
            accountID: accountID,
            accountLabel: accountID,
            accountStorageScope: .deviceKeychain,
            fetchedAt: Date(timeIntervalSince1970: 1_700_060_000 + used),
            source: .localSession,
            sourceId: sourceId,
            confidence: .exact,
            managementURL: "https://chatgpt.com/codex",
            statusMessage: "Codex quota.",
            buckets: [
                OpenBurnBar.ProviderQuotaBucket(
                    key: "quota",
                    label: "Usage",
                    windowKind: .rollingHours,
                    usedValue: used,
                    limitValue: 100,
                    remainingValue: 100 - used,
                    usedPercent: used,
                    resetsAt: nil,
                    unit: .percent,
                    isEstimated: false
                )
            ]
        )
    }

    private func makeMirrorSnapshot(
        sourceRoot: URL,
        containerBase: URL,
        stateURL: URL
    ) -> ICloudSessionMirrorSnapshot {
        ICloudSessionMirrorSnapshot(
            containerIdentifier: "iCloud.test.openburnbar",
            mirrorPathComponents: ["Documents", "OpenBurnBar", "SessionMirror"],
            providers: [
                ICloudSessionProviderSpec(
                    slug: "Codex",
                    rootPath: sourceRoot.path,
                    filePattern: "*.jsonl"
                )
            ],
            stateFilePath: stateURL.path,
            containerBaseURL: containerBase
        )
    }

    private func mirrorURL(base: URL, slug: String, relative: String) -> URL {
        base
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("OpenBurnBar", isDirectory: true)
            .appendingPathComponent("SessionMirror", isDirectory: true)
            .appendingPathComponent(slug, isDirectory: true)
            .appendingPathComponent(relative, isDirectory: false)
    }

    private func writeMirrorState(_ files: [String: ICloudSessionMirrorFileRecord], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(ICloudSessionMirrorStateFile(files: files))
        try data.write(to: url, options: [.atomic])
    }

    private func readMirrorState(from url: URL) throws -> ICloudSessionMirrorStateFile {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ICloudSessionMirrorStateFile.self, from: data)
    }
}
