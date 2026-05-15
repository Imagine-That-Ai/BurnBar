import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import FirebaseFunctions
import Foundation
import OpenBurnBarCore

// MARK: - CloudSyncService

/// Uploads unsynced local TokenUsage rows to Firestore under the authenticated user's namespace.
///
/// Layout: `users/{uid}/usage/{deviceId}_{usageId}`
///
/// Conversation metadata (no full transcripts): `users/{uid}/conversations/{deviceId}_{conversationId}`
///
/// Idempotent: document IDs are deterministic, so re-uploading the same row is a no-op.
@Observable
@MainActor
final class CloudSyncService {
    private enum SyncBackoffPolicy {
        static let permissionDeniedCooldown: TimeInterval = 10 * 60
    }

    // MARK: - State

    internal(set) var isSyncing = false
    internal(set) var lastSyncDate: Date?
    internal(set) var lastSyncError: String?
    private(set) var cloudTotalCost: Double?
    internal(set) var lastCollaborationNotice: SharedArtifactCollaborationNotice?
    private var suppressedSyncUntil: Date?

    // MARK: - Dependencies

    let dataStore: DataStore
    let accountManager: AccountManager
    let settingsManager: SettingsManager

    /// `Firestore.firestore()` is only read from sync methods that guard `accountManager.isFirebaseAvailable` first.
    var db: Firestore { Firestore.firestore() }



    // MARK: - Init

    init(dataStore: DataStore, accountManager: AccountManager, settingsManager: SettingsManager = .shared) {
        self.dataStore = dataStore
        self.accountManager = accountManager
        self.settingsManager = settingsManager
    }

    static func currentMemorySyncBoundary(
        settingsManager: SettingsManager = .shared,
        accountManager: AccountManager = .shared
    ) -> OpenBurnBarMemorySyncBoundarySnapshot {
        OpenBurnBarMemorySyncBoundarySnapshot(
            mode: .localFirstOptionalCloud,
            canonicalAuthority: .localSQLite,
            cloudMetadataBackupEnabled: accountManager.isCloudSyncEnabled && settingsManager.conversationCloudBackupEnabled,
            cloudSessionLogBackupEnabled: accountManager.isCloudSyncEnabled && settingsManager.sessionLogCloudBackupEnabled,
            iCloudMirrorEnabled: settingsManager.iCloudSessionMirrorEnabled,
            collaborationUsesCloudHead: accountManager.isCloudSyncEnabled,
            notes: [
                "SQLite and daemon state remain canonical on-device.",
                "Firestore is an optional replication and collaboration plane, not the serving authority.",
                "iCloud mirroring copies files for convenience but does not become the canonical memory graph."
            ]
        )
    }

    func memorySyncBoundarySnapshot() -> OpenBurnBarMemorySyncBoundarySnapshot {
        Self.currentMemorySyncBoundary(
            settingsManager: settingsManager,
            accountManager: accountManager
        )
    }

    // MARK: - Sync

    func syncIsSuppressed(now: Date = Date()) -> Bool {
        guard let suppressedSyncUntil else { return false }
        if suppressedSyncUntil > now {
            return true
        }
        self.suppressedSyncUntil = nil
        return false
    }

    func recordSyncError(_ error: Error) {
        lastSyncError = error.localizedDescription

        let nsError = error as NSError
        guard nsError.domain == FirestoreErrorDomain,
              let code = FirestoreErrorCode.Code(rawValue: nsError.code),
              code == .permissionDenied || code == .unauthenticated else {
            return
        }

        suppressedSyncUntil = Date().addingTimeInterval(SyncBackoffPolicy.permissionDeniedCooldown)
    }

    /// Upload all unsynced local rows to Firestore. Call after refreshAll().
    func uploadPending() async {
        guard accountManager.isFirebaseAvailable,
              accountManager.isSignedIn,
              accountManager.isCloudSyncEnabled,
              !syncIsSuppressed(),
              !isSyncing,
              let uid = Auth.auth().currentUser?.uid else { return }

        isSyncing = true
        lastSyncError = nil
        let start = Date()

        do {
            let deviceId = accountManager.deviceId
            let collectionRef = db.collection("users").document(uid).collection("usage")
            var uploadedAnyBatch = false

            while true {
                let unsynced = try dataStore.fetchUnsynced()
                guard !unsynced.isEmpty else { break }

                // Firestore batch limit is 500 ops; fetchUnsynced caps each page at 400 rows.
                let batch = db.batch()

                for usage in unsynced {
                    let docId = "\(deviceId)_\(usage.id.uuidString)"
                    let docRef = collectionRef.document(docId)
                    let data = encodeUsage(usage, deviceId: deviceId)
                    batch.setData(data, forDocument: docRef, merge: true)
                }

                try await batch.commit()

                let syncedIds = unsynced.map { $0.id }
                try dataStore.markSynced(ids: syncedIds)
                uploadedAnyBatch = true
            }

            lastSyncDate = Date()
            lastSyncError = nil
            try await publishSyncHeartbeat(uid: uid, collectionsInSync: ["usage"])

            TelemetryService.shared.record(feature: .cloudSync, outcome: .success, durationMs: Int(Date().timeIntervalSince(start) * 1000))
            if uploadedAnyBatch {
                await downloadRemoteData(uid: uid)
                await fetchCloudTotal(uid: uid)
            }
        } catch {
            TelemetryService.shared.record(feature: .cloudSync, outcome: .failure, durationMs: Int(Date().timeIntervalSince(start) * 1000))
            recordSyncError(error)
        }

        isSyncing = false
    }

    private func publishSyncHeartbeat(uid: String, collectionsInSync: [String]) async throws {
        let deviceId = accountManager.deviceId
        let now = Date()
        let deviceName = Host.current().localizedName ?? "OpenBurnBar Mac"
        let userRef = db.collection("users").document(uid)

        try await userRef.collection("devices").document(deviceId).setData([
            "deviceId": deviceId,
            "deviceName": deviceName,
            "platform": "macOS",
            "isLocal": true,
            "lastSeenAt": Timestamp(date: now),
            "updatedAt": Timestamp(date: now)
        ], merge: true)

        try await userRef.collection("sync_status").document(deviceId).setData([
            "deviceId": deviceId,
            "isOnline": true,
            "lastSyncAt": Timestamp(date: now),
            "collectionsInSync": collectionsInSync,
            "updatedAt": Timestamp(date: now)
        ], merge: true)
    }

    /// Uploads unsynced conversation metadata (excluding full transcripts) for cross-device recall.
    /// Runs at the end of `UsageAggregator.refreshAll()` (after `uploadPending()`), matching token sync cadence.
    func uploadPendingConversations() async {
        guard accountManager.isFirebaseAvailable,
              accountManager.isSignedIn,
              accountManager.isCloudSyncEnabled,
              settingsManager.conversationCloudBackupEnabled,
              !syncIsSuppressed(),
              !isSyncing,
              let uid = Auth.auth().currentUser?.uid else { return }

        isSyncing = true
        lastSyncError = nil

        do {
            let unsynced = try dataStore.fetchUnsyncedConversations(limit: 400)
            guard !unsynced.isEmpty else {
                isSyncing = false
                lastSyncDate = Date()
                return
            }

            let deviceId = accountManager.deviceId
            let batch = db.batch()
            let collectionRef = db.collection("users").document(uid).collection("conversations")

            for record in unsynced {
                let docId = "\(deviceId)_\(record.id)"
                let docRef = collectionRef.document(docId)
                let data = Self.encodeConversation(record, deviceId: deviceId)
                batch.setData(data, forDocument: docRef, merge: true)
            }

            try await batch.commit()

            let ids = unsynced.map(\.id)
            try dataStore.markConversationsSynced(ids: ids)

            lastSyncDate = Date()
            lastSyncError = nil

            await downloadRemoteData(uid: uid)
            await fetchCloudTotal(uid: uid)
        } catch {
            recordSyncError(error)
        }

        isSyncing = false
    }

    // MARK: - Chat Thread Cloud Sync

    /// Uploads chat threads to Firestore for cross-device resume.
    /// Layout: `users/{uid}/chat_threads/{deviceId}_{threadId}`.
    /// Full message content/title/preview are included only after explicit chat content consent.
    func uploadPendingChatThreads() async {
        guard accountManager.isFirebaseAvailable,
              accountManager.isSignedIn,
              accountManager.isCloudSyncEnabled,
              !syncIsSuppressed(),
              !isSyncing,
              let uid = Auth.auth().currentUser?.uid else { return }

        isSyncing = true
        lastSyncError = nil

        do {
            let threads = try dataStore.fetchChatThreadSummaries(limit: 50)
            guard !threads.isEmpty else {
                isSyncing = false
                return
            }

            let deviceId = accountManager.deviceId
            let batch = db.batch()
            let collectionRef = db.collection("users").document(uid).collection("chat_threads")

            let includeContent = settingsManager.chatThreadContentCloudBackupEnabled
            for thread in threads {
                let messages = includeContent
                    ? ((try? dataStore.fetchChatMessages(threadID: thread.id)) ?? [])
                    : []

                let docId = "\(deviceId)_\(thread.id)"
                let docRef = collectionRef.document(docId)

                var data: [String: Any] = [
                    "threadId": thread.id,
                    "messageCount": thread.messageCount,
                    "createdAt": thread.lastActivityAt.timeIntervalSince1970,
                    "updatedAt": thread.lastActivityAt.timeIntervalSince1970,
                    "deviceId": deviceId,
                    "contentIncluded": includeContent,
                ]
                if includeContent {
                    let encodedMessages: [[String: Any]] = messages.map { msg in
                        var m: [String: Any] = [
                            "id": msg.id,
                            "role": msg.role == .user ? "user" : "assistant",
                            "content": String(msg.content.prefix(4000)),
                            "timestamp": msg.timestamp.timeIntervalSince1970,
                        ]
                        if let cli = msg.cliUsed {
                            m["cliUsed"] = cli
                        }
                        return m
                    }
                    data["title"] = thread.title
                    data["preview"] = String(thread.preview.prefix(500))
                    data["messages"] = encodedMessages
                } else {
                    data["messages"] = FieldValue.delete()
                    data["title"] = FieldValue.delete()
                    data["preview"] = FieldValue.delete()
                }
                batch.setData(data, forDocument: docRef, merge: true)
            }

            try await batch.commit()
            lastSyncDate = Date()
            lastSyncError = nil
        } catch {
            recordSyncError(error)
        }

        isSyncing = false
    }

    /// Synchronizes shared/team artifacts between local cache and Firestore.
    /// Local search remains authoritative; cloud is replication and collaboration transport.
    func syncSharedArtifacts(maxRemoteArtifacts: Int = 300) async {
        guard !isSyncing, !syncIsSuppressed() else { return }

        let firebaseAvailable = accountManager.isFirebaseAvailable
        let signedIn = accountManager.isSignedIn
        let cloudEnabled = accountManager.isCloudSyncEnabled
        let uid: String? = firebaseAvailable ? Auth.auth().currentUser?.uid : nil

        guard firebaseAvailable, signedIn, cloudEnabled, let uid else {
            let errorCode: String
            let message: String
            if firebaseAvailable == false {
                errorCode = "COLLABORATION_FIREBASE_UNAVAILABLE"
                message = "Firebase is unavailable. Shared/team sync is degraded to local-only."
            } else if signedIn == false {
                errorCode = "COLLABORATION_SIGNED_OUT"
                message = "Sign in to enable shared/team library sync."
            } else if cloudEnabled == false {
                errorCode = "COLLABORATION_CLOUD_SYNC_DISABLED"
                message = "Cloud sync is disabled. Shared/team sync remains local-only."
            } else {
                errorCode = "COLLABORATION_IDENTITY_UNAVAILABLE"
                message = "Signed-in identity is unavailable. Shared/team sync remains local-only."
            }

            lastSyncError = message
            do {
                try upsertCollaborationHealth(
                    status: .degraded,
                    errorCode: errorCode,
                    errorMessage: message,
                    report: nil,
                    cloudAvailable: false
                )
            } catch {
                lastSyncError = "\(message) Health persistence failed: \(error.localizedDescription)"
            }
            return
        }

        isSyncing = true
        lastSyncError = nil
        let scope = SharedArtifactScope.defaultScope(for: uid)
        var report = SharedArtifactSyncReport(scope: scope)

        defer {
            isSyncing = false
        }

        do {
            try await pushLocalSharedArtifacts(scope: scope, report: &report)
            try await pullRemoteSharedArtifacts(scope: scope, maxRemoteArtifacts: max(1, maxRemoteArtifacts), report: &report)

            let status: RetrievalHealthStatus = report.conflicts > 0 ? .degraded : .healthy
            let errorCode = report.conflicts > 0 ? "COLLABORATION_DIVERGENCE_DETECTED" : nil
            let errorMessage = report.conflicts > 0 ? "Detected local/cloud divergence for one or more shared artifacts." : nil

            try upsertCollaborationHealth(
                status: status,
                errorCode: errorCode,
                errorMessage: errorMessage,
                report: report,
                cloudAvailable: true
            )

            lastSyncDate = Date()
            lastSyncError = errorMessage
        } catch {
            let syncError = error
            recordSyncError(syncError)
            do {
                try upsertCollaborationHealth(
                    status: .failed,
                    errorCode: "COLLABORATION_SYNC_FAILED",
                    errorMessage: syncError.localizedDescription,
                    report: report,
                    cloudAvailable: true
                )
            } catch {
                let healthError = error
                lastSyncError = "\(syncError.localizedDescription) Health persistence failed: \(healthError.localizedDescription)"
            }
        }
    }

    // MARK: - Cross-Device Download

    /// Downloads remote data from Firestore with durable, per-account, per-collection watermark tracking.
    ///
    /// VAL-PERSIST-010: Watermark advances only after successful sync commit.
    /// VAL-PERSIST-011: Watermark scope is account-aware and collection-safe.
    func downloadRemoteData(uid: String? = nil) async {
        guard accountManager.isFirebaseAvailable, accountManager.isSignedIn else { return }
        let resolvedUid = uid ?? Auth.auth().currentUser?.uid
        guard let resolvedUid else { return }
        let localDeviceId = accountManager.deviceId

        await syncDeviceRegistry(uid: resolvedUid, localDeviceId: localDeviceId)

        // Download usage with durable watermark tracking
        await downloadRemoteUsage(uid: resolvedUid, localDeviceId: localDeviceId)

        // Download conversations with durable watermark tracking
        let newConversationIds = await downloadRemoteConversations(uid: resolvedUid, localDeviceId: localDeviceId)

        await downloadRemoteSessionLogBodies(uid: resolvedUid, conversationIds: newConversationIds)
        enqueueProjectionForRemoteConversations(newConversationIds)

        await dataStore.refresh()
    }

    private func syncDeviceRegistry(uid: String, localDeviceId: String) async {
        let devicesRef = db.collection("users").document(uid).collection("devices")
        let localName = Host.current().localizedName ?? "This Mac"
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        do {
            try await devicesRef.document(localDeviceId).setData([
                "deviceName": localName, "platform": "macOS",
                "lastActiveAt": FieldValue.serverTimestamp(), "appVersion": version,
                "hardwareModel": DeviceHardwareIcon.localHardwareModel
            ], merge: true)
        } catch { /* non-fatal */ }
        do {
            let snapshot = try await devicesRef.getDocuments()
            for doc in snapshot.documents {
                let data = doc.data()
                let device = DeviceRecord(
                    deviceId: doc.documentID,
                    deviceName: data["deviceName"] as? String ?? doc.documentID,
                    isLocal: doc.documentID == localDeviceId,
                    lastSeenAt: (data["lastActiveAt"] as? Timestamp)?.dateValue(),
                    createdAt: Date(),
                    hardwareModel: data["hardwareModel"] as? String,
                    customIcon: nil // preserve local overrides via COALESCE in upsert
                )
                try dataStore.upsertDevice(device)
            }
        } catch { /* non-fatal */ }
    }

    /// Updates the local device name in Firestore (called from Settings).
    func updateLocalDeviceName(_ name: String) async {
        guard accountManager.isFirebaseAvailable, let uid = Auth.auth().currentUser?.uid else { return }
        let devicesRef = db.collection("users").document(uid).collection("devices")
        try? await devicesRef.document(accountManager.deviceId).setData(["deviceName": name], merge: true)
    }

    private func downloadRemoteUsage(uid: String, localDeviceId: String) async {
        // VAL-PERSIST-010: Use durable, per-account watermark from database
        // VAL-PERSIST-011: Watermark scope is account-aware
        let watermark: Date
        do {
            watermark = try dataStore.remoteSyncWatermarkStore.fetchWatermarkOrDefault(
                accountUid: uid,
                collectionKind: .usage
            )
        } catch {
            // Fall back to default (90 days) if watermark fetch fails
            watermark = Calendar.current.date(byAdding: .day, value: -90, to: Date()) ?? Date()
        }

        let cutoff = Calendar.current.date(byAdding: .day, value: -90, to: Date()) ?? Date()

        // Create atomic transaction for durable watermark advancement
        let syncTx = AtomicRemoteSyncTransaction(
            dbQueue: dataStore.dbQueue,
            watermarkStore: dataStore.remoteSyncWatermarkStore,
            accountUid: uid,
            collectionKind: .usage
        )
        var completedDownload = false

        defer {
            // Advance only after the entire remote page is persisted locally.
            if completedDownload, syncTx.processedCount > 0 {
                do {
                    try syncTx.commit()
                } catch {
                    AppLogger.sync.error("sync_tx_commit_failed", metadata: ["accountUid": uid, "collectionKind": "usage", "error": String(describing: error)])
                }
            }
        }

        do {
            var query = db.collection("users").document(uid).collection("usage")
                .whereField("startTime", isGreaterThan: Timestamp(date: cutoff))
            if watermark > cutoff {
                query = query.whereField("updatedAt", isGreaterThan: Timestamp(date: watermark))
            }
            let snapshot = try await query.getDocuments()
            let devices = try dataStore.fetchDevices()
            let nameMap = Dictionary(uniqueKeysWithValues: devices.map { ($0.deviceId, $0.deviceName) })

            for doc in snapshot.documents {
                let data = doc.data()
                guard let remoteDeviceId = data["deviceId"] as? String, remoteDeviceId != localDeviceId,
                      let rawProvider = data["provider"] as? String, let provider = AgentProvider(rawValue: rawProvider),
                      let sessionId = data["sessionId"] as? String,
                      let id = UUID(uuidString: data["id"] as? String ?? doc.documentID) else { continue }

                let startTime = (data["startTime"] as? Timestamp)?.dateValue() ?? Date()
                let reasoning = data["reasoningTokens"] as? Int ?? 0
                let srcRaw = data["usageSource"] as? String
                let usageSource = srcRaw.flatMap { UsageSource(rawValue: $0) } ?? .unknown
                let providerID = (data["providerID"] as? String).map { ProviderID(rawValue: $0) } ?? provider.providerID
                let providerAccountSource = (data["providerAccountSource"] as? String)
                    .flatMap { ProviderAccountStorageScope(rawValue: $0) }

                let usage = TokenUsage(
                    id: id, provider: provider, sessionId: sessionId,
                    projectName: data["projectName"] as? String ?? "",
                    model: data["model"] as? String ?? "unknown",
                    inputTokens: data["inputTokens"] as? Int ?? 0,
                    outputTokens: data["outputTokens"] as? Int ?? 0,
                    cacheCreationTokens: data["cacheCreationTokens"] as? Int ?? 0,
                    cacheReadTokens: data["cacheReadTokens"] as? Int ?? 0,
                    reasoningTokens: reasoning,
                    costUSD: data["cost"] as? Double ?? 0,
                    startTime: startTime,
                    endTime: (data["endTime"] as? Timestamp)?.dateValue() ?? startTime,
                    usageSource: usageSource,
                    sourceDeviceId: remoteDeviceId,
                    sourceDeviceName: nameMap[remoteDeviceId] ?? remoteDeviceId,
                    isRemote: true,
                    providerID: providerID,
                    providerAccountID: data["providerAccountID"] as? String,
                    providerAccountLabel: data["providerAccountLabel"] as? String,
                    providerAccountSource: providerAccountSource,
                    provenanceMethod: .cloudSync,
                    provenanceConfidence: .exact
                )
                try dataStore.insertRemoteUsage(usage)

                // Track the latest remote update timestamp for watermark
                if let updatedAt = (data["updatedAt"] as? Timestamp)?.dateValue() {
                    syncTx.recordProcessedItem(remoteUpdatedAt: updatedAt)
                }
            }
            completedDownload = true
        } catch { /* non-fatal */ }
    }

    /// Returns IDs of newly inserted remote conversations (for lazy body download).
    @discardableResult
    private func downloadRemoteConversations(uid: String, localDeviceId: String) async -> [String] {
        var insertedIds: [String] = []

        // VAL-PERSIST-010: Use durable, per-account watermark from database
        // VAL-PERSIST-011: Watermark scope is account-aware
        let watermark: Date
        do {
            watermark = try dataStore.remoteSyncWatermarkStore.fetchWatermarkOrDefault(
                accountUid: uid,
                collectionKind: .conversations
            )
        } catch {
            // Fall back to nil (no watermark) if fetch fails
            watermark = Date.distantPast
        }

        // Create atomic transaction for durable watermark advancement
        let syncTx = AtomicRemoteSyncTransaction(
            dbQueue: dataStore.dbQueue,
            watermarkStore: dataStore.remoteSyncWatermarkStore,
            accountUid: uid,
            collectionKind: .conversations
        )
        var completedDownload = false

        defer {
            // Advance only after the entire remote page is persisted locally.
            if completedDownload, syncTx.processedCount > 0 {
                do {
                    try syncTx.commit()
                } catch {
                    AppLogger.sync.error("sync_tx_commit_failed", metadata: ["accountUid": uid, "collectionKind": "conversations", "error": String(describing: error)])
                }
            }
        }

        do {
            var query: Query
            if watermark > Date.distantPast {
                query = db.collection("users").document(uid).collection("conversations")
                    .whereField("updatedAt", isGreaterThan: Timestamp(date: watermark)).limit(to: 500)
            } else {
                query = db.collection("users").document(uid).collection("conversations")
                    .order(by: "updatedAt", descending: true).limit(to: 500)
            }
            let snapshot = try await query.getDocuments()
            let devices = try dataStore.fetchDevices()
            let nameMap = Dictionary(uniqueKeysWithValues: devices.map { ($0.deviceId, $0.deviceName) })

            for doc in snapshot.documents {
                let data = doc.data()
                guard let remoteDeviceId = data["deviceId"] as? String, remoteDeviceId != localDeviceId,
                      let rawProvider = data["provider"] as? String, let provider = AgentProvider(rawValue: rawProvider),
                      let sessionId = data["sessionId"] as? String else { continue }
                let id = data["id"] as? String ?? doc.documentID
                let stableId = "\(remoteDeviceId):\(id)"
                let deviceName = nameMap[remoteDeviceId] ?? remoteDeviceId
                let sourceTypeRaw = data["sourceType"] as? String ?? ConversationSourceType.providerLog.rawValue
                let record = ConversationRecord(
                    id: stableId, provider: provider, sessionId: sessionId,
                    projectName: data["projectName"] as? String ?? "",
                    startTime: (data["startTime"] as? Timestamp)?.dateValue(),
                    endTime: (data["endTime"] as? Timestamp)?.dateValue(),
                    messageCount: data["messageCount"] as? Int ?? 0,
                    userWordCount: data["userWordCount"] as? Int ?? 0,
                    assistantWordCount: data["assistantWordCount"] as? Int ?? 0,
                    keyFiles: data["keyFiles"] as? [String] ?? [],
                    keyCommands: data["keyCommands"] as? [String] ?? [],
                    keyTools: data["keyTools"] as? [String] ?? [],
                    inferredTaskTitle: data["inferredTaskTitle"] as? String ?? "",
                    lastAssistantMessage: data["lastAssistantMessage"] as? String ?? "",
                    fullText: "",
                    indexedAt: Date(), fileModifiedAt: nil,
                    summary: data["summary"] as? String,
                    sourceType: ConversationSourceType(rawValue: sourceTypeRaw) ?? .providerLog,
                    sourceDeviceId: remoteDeviceId, sourceDeviceName: deviceName, isRemote: true
                )
                try dataStore.insertRemoteConversation(record)
                insertedIds.append(stableId)

                // Track the latest remote update timestamp for watermark
                if let updatedAt = (data["updatedAt"] as? Timestamp)?.dateValue() {
                    syncTx.recordProcessedItem(remoteUpdatedAt: updatedAt)
                }
            }
            completedDownload = true
        } catch { /* non-fatal */ }
        return insertedIds
    }

    // MARK: - Lazy Session Log Body Download

    /// Downloads full Markdown bodies from session_logs for remote conversations
    /// and updates their fullText so FTS can index them.
    private func downloadRemoteSessionLogBodies(uid: String, conversationIds: [String]) async {
        guard !conversationIds.isEmpty else { return }
        let logsRef = db.collection("users").document(uid).collection("session_logs")

        for conversationId in conversationIds.prefix(20) { // Limit to avoid excessive reads per sync
            // The session_log docId is `{deviceId}_{escapedSessionId}` — we need to find it
            // by scanning the conversation's device prefix
            guard let colonIdx = conversationId.firstIndex(of: ":"),
                  conversationId.distance(from: conversationId.startIndex, to: colonIdx) > 0 else { continue }
            let devicePrefix = String(conversationId[conversationId.startIndex..<colonIdx])
            // Look for session_logs docs matching this device
            do {
                let snapshot = try await logsRef
                    .whereField("deviceId", isEqualTo: devicePrefix)
                    .limit(to: 200)
                    .getDocuments()

                for doc in snapshot.documents {
                    let data = doc.data()
                    guard let docConvId = data["id"] as? String else { continue }
                    let stableId = "\(devicePrefix):\(docConvId)"
                    guard conversationIds.contains(stableId) else { continue }

                    // Reassemble body from chunks
                    let body = try await fetchCloudSessionLogBody(docId: doc.documentID)
                    guard !body.isEmpty else { continue }

                    try dataStore.updateConversationFullText(id: stableId, fullText: body)
                }
            } catch { /* non-fatal */ }
        }
    }

    // MARK: - Projection Enqueue for Remote Conversations

    /// Enqueues projection jobs for newly downloaded remote conversations
    /// so they flow through the semantic search pipeline.
    func enqueueProjectionForRemoteConversations(_ conversationIds: [String]) {
        for id in conversationIds {
            let jobId = ProjectionIdentity.jobID(
                jobType: .reproject,
                sourceKind: .conversation,
                sourceID: id,
                sourceVersionID: ""
            )
            try? dataStore.enqueueProjectionJob(
                ProjectionJobRecord(
                    id: jobId,
                    jobType: .reproject,
                    sourceKind: .conversation,
                    sourceID: id,
                    sourceVersionID: "",
                    status: .queued,
                    priority: 0,
                    createdAt: Date(),
                    updatedAt: Date()
                )
            )
        }
    }

    // MARK: - Cloud Aggregate

    /// Fetch sum of cost across all devices for this user (last 90 days).
    func fetchCloudTotal(uid: String? = nil) async {
        guard accountManager.isFirebaseAvailable else { return }
        let resolvedUid = uid ?? Auth.auth().currentUser?.uid
        guard let resolvedUid else { return }

        let cutoff = Calendar.current.date(byAdding: .day, value: -90, to: Date()) ?? Date()

        do {
            let snapshot = try await db
                .collection("users")
                .document(resolvedUid)
                .collection("usage")
                .whereField("startTime", isGreaterThan: Timestamp(date: cutoff))
                .getDocuments()

            let total = snapshot.documents.compactMap { doc -> Double? in
                doc.data()["cost"] as? Double
            }.reduce(0, +)

            cloudTotalCost = total
        } catch {
            // Non-fatal: aggregate failing doesn't break local experience
        }
    }

    // MARK: - Encoding

    private func encodeUsage(_ usage: TokenUsage, deviceId: String) -> [String: Any] {
        let safeStart = TimestampNormalizationUtility.firestoreSafeDate(usage.startTime, fallback: usage.createdAt)
        let safeEndCandidate = TimestampNormalizationUtility.firestoreSafeDate(usage.endTime, fallback: safeStart)
        let safeEnd = max(safeStart, safeEndCandidate)

        var data: [String: Any] = [
            "id": usage.id.uuidString,
            "deviceId": deviceId,
            "provider": usage.provider.rawValue,
            "providerID": usage.providerID.rawValue,
            "sessionId": usage.sessionId,
            "projectName": usage.projectName,
            "model": usage.model,
            "inputTokens": usage.inputTokens,
            "outputTokens": usage.outputTokens,
            "cacheCreationTokens": usage.cacheCreationTokens,
            "cacheReadTokens": usage.cacheReadTokens,
            "reasoningTokens": usage.reasoningTokens,
            "usageSource": usage.usageSource.rawValue,
            "totalTokens": usage.totalTokens,
            "cost": usage.cost,
            "startTime": Timestamp(date: safeStart),
            "endTime": Timestamp(date: safeEnd),
            "updatedAt": FieldValue.serverTimestamp()
        ]
        if let providerAccountID = usage.providerAccountID {
            data["providerAccountID"] = providerAccountID
        }
        if let providerAccountLabel = usage.providerAccountLabel {
            data["providerAccountLabel"] = providerAccountLabel
        }
        if let providerAccountSource = usage.providerAccountSource {
            data["providerAccountSource"] = providerAccountSource.rawValue
        }
        return data
    }

    private static func encodeConversation(_ record: ConversationRecord, deviceId: String) -> [String: Any] {
        var data: [String: Any] = [
            "id": record.id,
            "deviceId": deviceId,
            "provider": record.provider.rawValue,
            "sessionId": record.sessionId,
            "projectName": record.projectName,
            "messageCount": record.messageCount,
            "userWordCount": record.userWordCount,
            "assistantWordCount": record.assistantWordCount,
            "keyFiles": record.keyFiles,
            "keyCommands": record.keyCommands,
            "keyTools": record.keyTools,
            "inferredTaskTitle": record.inferredTaskTitle,
            "lastAssistantMessage": capLastAssistantMessage(record.lastAssistantMessage),
            "updatedAt": FieldValue.serverTimestamp()
        ]
        let safeStart = record.startTime.map { TimestampNormalizationUtility.firestoreSafeDate($0) }
        let safeEnd = record.endTime.map { rawEnd in
            let normalizedEnd = TimestampNormalizationUtility.firestoreSafeDate(rawEnd, fallback: safeStart ?? rawEnd)
            if let safeStart {
                return max(safeStart, normalizedEnd)
            }
            return normalizedEnd
        }

        if let start = safeStart {
            data["startTime"] = Timestamp(date: start)
        } else {
            data["startTime"] = NSNull()
        }
        if let end = safeEnd {
            data["endTime"] = Timestamp(date: end)
        } else {
            data["endTime"] = NSNull()
        }
        if let summary = record.summary {
            data["summary"] = summary
        } else {
            data["summary"] = NSNull()
        }
        if let summaryTitle = record.summaryTitle {
            data["summaryTitle"] = summaryTitle
        } else {
            data["summaryTitle"] = NSNull()
        }
        if let summaryProvider = record.summaryProvider {
            data["summaryProvider"] = summaryProvider
        } else {
            data["summaryProvider"] = NSNull()
        }
        if let summaryModel = record.summaryModel {
            data["summaryModel"] = summaryModel
        } else {
            data["summaryModel"] = NSNull()
        }
        return data
    }

    private static func capLastAssistantMessage(_ text: String) -> String {
        if text.count <= 500 { return text }
        return String(text.prefix(500))
    }


}

// MARK: - Hermes Remote Relay Host

@MainActor
final class HermesRelayHostService {
    private let db: Firestore
    private let accountManager: AccountManager
    private let settingsManager: SettingsManager
    private let urlSession: URLSession
    private let relayKeyStore: HermesRelayKeyStore
    private var heartbeatTask: Task<Void, Never>?
    private var listener: ListenerRegistration?
    private var listenerUID: String?
    private var requestTasks: [String: Task<Void, Never>] = [:]
    private var processingRequestIDs: Set<String> = []

    init(
        db: Firestore = Firestore.firestore(),
        accountManager: AccountManager = .shared,
        settingsManager: SettingsManager = .shared,
        urlSession: URLSession = .shared,
        relayKeyStore: HermesRelayKeyStore = HermesRelayKeyStore()
    ) {
        self.db = db
        self.accountManager = accountManager
        self.settingsManager = settingsManager
        self.urlSession = urlSession
        self.relayKeyStore = relayKeyStore
    }

    var connectionID: String {
        "relay-\(Self.safeIdentifier(accountManager.deviceId))"
    }

    func start() {
        guard heartbeatTask == nil else { return }
        heartbeatTask = Task { @MainActor in
            while !Task.isCancelled {
                await refreshRelayHost()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    func stop() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        listener?.remove()
        listener = nil
        listenerUID = nil
        for task in requestTasks.values {
            task.cancel()
        }
        requestTasks.removeAll()
        processingRequestIDs.removeAll()
    }

    private func refreshRelayHost() async {
        guard accountManager.isFirebaseAvailable,
              accountManager.isSignedIn,
              accountManager.isCloudSyncEnabled,
              let uid = Auth.auth().currentUser?.uid else {
            listener?.remove()
            listener = nil
            listenerUID = nil
            for task in requestTasks.values {
                task.cancel()
            }
            requestTasks.removeAll()
            return
        }

        guard settingsManager.hermesRemoteRelayEnabled else {
            listener?.remove()
            listener = nil
            listenerUID = nil
            for task in requestTasks.values {
                task.cancel()
            }
            requestTasks.removeAll()
            await publishRelayOffline(uid: uid)
            return
        }

        await publishRelayConnection(uid: uid)
        ensureRequestListener(uid: uid)
    }

    private func publishRelayOffline(uid: String) async {
        let now = Self.iso8601.string(from: Date())
        let ref = db.collection("users").document(uid).collection("hermes_connections").document(connectionID)
        do {
            let snap = try await ref.getDocument()
            var data: [String: Any] = [
                "id": connectionID,
                "displayName": Host.current().localizedName.map { "\($0) Hermes Relay" } ?? "Mac Hermes Relay",
                "mode": HermesConnectionMode.relayLink.rawValue,
                "status": HermesConnectionStatus.offline.rawValue,
                "capabilities": ["chat_completions", "remote_relay"],
                "advertisedModel": FieldValue.delete(),
                "updatedAt": now,
                "schemaVersion": 2
            ]
            if let key = try? relayKeyStore.privateKey() {
                data["relayPublicKey"] = key.publicKeyBase64
                data["relayKeyVersion"] = HermesRelayCrypto.keyVersion
                data["relayEncryption"] = HermesRelayCrypto.algorithm
            }
            if !snap.exists {
                data["createdAt"] = now
            }
            try await ref.setData(data, merge: true)
        } catch {
            AppLogger.network.silentFailure("hermes_relay_offline_publish_failed", error: error)
        }
    }

    private func publishRelayConnection(uid: String) async {
        let relayPrivateKey: HermesRelayPrivateKey
        do {
            relayPrivateKey = try relayKeyStore.privateKey()
        } catch {
            AppLogger.network.error(
                "hermes_relay_key_unavailable",
                metadata: ["error": error.localizedDescription]
            )
            await publishRelayOffline(uid: uid)
            return
        }
        let probe = await OpenAICompatibleModelProbe.probeWithModel(
            baseURL: hermesBaseURL(),
            bearerToken: settingsManager.hermesBearerToken
        )
        let now = Self.iso8601.string(from: Date())
        var data: [String: Any] = [
            "id": connectionID,
            "displayName": Host.current().localizedName.map { "\($0) Hermes Relay" } ?? "Mac Hermes Relay",
            "mode": HermesConnectionMode.relayLink.rawValue,
            "status": probe.available ? HermesConnectionStatus.online.rawValue : HermesConnectionStatus.offline.rawValue,
            "capabilities": ["chat_completions", "remote_relay"],
            "relayPublicKey": relayPrivateKey.publicKeyBase64,
            "relayKeyVersion": HermesRelayCrypto.keyVersion,
            "relayEncryption": HermesRelayCrypto.algorithm,
            "updatedAt": now,
            "schemaVersion": 2
        ]
        if probe.available, let modelName = probe.modelName {
            data["advertisedModel"] = modelName
            data["lastSeenAt"] = now
        } else {
            data["advertisedModel"] = FieldValue.delete()
        }
        let ref = db.collection("users").document(uid).collection("hermes_connections").document(connectionID)
        do {
            let snap = try await ref.getDocument()
            if !snap.exists {
                data["createdAt"] = now
            }
            try await ref.setData(data, merge: true)
        } catch {
            AppLogger.network.error(
                "hermes_relay_connection_publish_failed",
                metadata: ["error": error.localizedDescription]
            )
        }
    }

    private func ensureRequestListener(uid: String) {
        guard listenerUID != uid else { return }
        listener?.remove()
        listenerUID = uid
        listener = db.collection("users").document(uid)
            .collection("hermes_relay_requests")
            .whereField("connectionId", isEqualTo: connectionID)
            .whereField("status", isEqualTo: HermesRelayRequestStatus.pending.rawValue)
            .addSnapshotListener { [weak self] snapshot, error in
                if let error {
                    AppLogger.network.error(
                        "hermes_relay_listener_failed",
                        metadata: ["error": error.localizedDescription]
                    )
                    Task { @MainActor [weak self] in
                        self?.listener?.remove()
                        self?.listener = nil
                        self?.listenerUID = nil
                    }
                    return
                }
                guard let documents = snapshot?.documents, !documents.isEmpty else { return }
                Task { @MainActor [weak self] in
                    self?.handlePendingRelayDocuments(documents, uid: uid)
                }
            }
    }

    private func handlePendingRelayDocuments(_ documents: [QueryDocumentSnapshot], uid: String) {
        for document in documents
        where !processingRequestIDs.contains(document.documentID) && requestTasks[document.documentID] == nil {
            let requestID = document.documentID
            processingRequestIDs.insert(requestID)
            let task = Task { @MainActor in
                defer {
                    processingRequestIDs.remove(requestID)
                    requestTasks.removeValue(forKey: requestID)
                }
                await processRelayRequest(reference: document.reference, uid: uid)
            }
            requestTasks[requestID] = task
        }
    }

    private func processRelayRequest(reference: DocumentReference, uid: String) async {
        var context: HermesRelayRequestContext?
        do {
            guard let data = try await claimRelayRequest(reference: reference) else { return }
            guard let operationText = data["operation"] as? String,
                  let operation = HermesRelayOperation(rawValue: operationText) else {
                try await failRelayRequest(reference: reference, requestID: reference.documentID, message: "Malformed relay request.")
                return
            }
            let requestID = (data["id"] as? String) ?? reference.documentID
            guard !isExpired(data["expiresAt"]) else {
                try await reference.setData([
                    "status": HermesRelayRequestStatus.expired.rawValue,
                    "updatedAt": Self.iso8601.string(from: Date())
                ], merge: true)
                return
            }
            let prepared = try decryptRelayRequest(data, uid: uid, requestID: requestID)
            context = prepared.context
            switch operation {
            case .chatCompletions:
                try await forwardStreamingRequest(
                    reference: reference,
                    context: prepared.context,
                    data: prepared.data
                )
            case .models, .sessions, .sessionDetail, .profiles, .jobs:
                try await forwardUnaryRequest(
                    reference: reference,
                    context: prepared.context,
                    operation: operation,
                    data: prepared.data
                )
            }
        } catch {
            try? await failRelayRequest(
                reference: reference,
                requestID: reference.documentID,
                message: error.localizedDescription,
                context: context
            )
        }
    }

    private func decryptRelayRequest(
        _ data: [String: Any],
        uid: String,
        requestID: String
    ) throws -> (data: [String: Any], context: HermesRelayRequestContext) {
        guard uid.isEmpty == false,
              data["relayEncryption"] as? String == HermesRelayCrypto.algorithm,
              let wrappedKey = data["wrappedKey"] as? String,
              let payloadCiphertext = data["payloadCiphertext"] as? String else {
            throw HermesRelayHostError.encryptionRequired
        }
        let connectionID = (data["connectionId"] as? String) ?? self.connectionID
        let privateKey = try relayKeyStore.privateKey()
        let keyData = try HermesRelayCrypto.unwrapSymmetricKey(
            wrappedKey,
            privateKey: privateKey,
            aad: HermesRelayCrypto.keyAAD(uid: uid, connectionID: connectionID, requestID: requestID)
        )
        let plaintext = try HermesRelayCrypto.openBase64(
            ciphertext: payloadCiphertext,
            keyData: keyData,
            aad: HermesRelayCrypto.requestAAD(uid: uid, connectionID: connectionID, requestID: requestID)
        )
        let payload = try JSONDecoder().decode(HermesRelayEncryptedRequestPayload.self, from: plaintext)
        var decrypted = data
        decrypted["path"] = payload.path
        decrypted["sessionId"] = payload.sessionId
        decrypted["body"] = payload.body
        return (
            decrypted,
            HermesRelayRequestContext(
                uid: uid,
                requestID: requestID,
                connectionID: connectionID,
                keyData: keyData
            )
        )
    }

    private func claimRelayRequest(reference: DocumentReference) async throws -> [String: Any]? {
        try await withCheckedThrowingContinuation { continuation in
            db.runTransaction({ transaction, errorPointer in
                let snapshot: DocumentSnapshot
                do {
                    snapshot = try transaction.getDocument(reference)
                } catch {
                    errorPointer?.pointee = error as NSError
                    return nil
                }
                guard var data = snapshot.data(),
                      data["status"] as? String == HermesRelayRequestStatus.pending.rawValue else {
                    return NSNull()
                }
                let now = Self.iso8601.string(from: Date())
                transaction.setData([
                    "status": HermesRelayRequestStatus.claimed.rawValue,
                    "claimedAt": now,
                    "claimedBy": self.connectionID,
                    "updatedAt": now
                ], forDocument: reference, merge: true)
                data["status"] = HermesRelayRequestStatus.claimed.rawValue
                data["claimedBy"] = self.connectionID
                return data as NSDictionary
            }) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if result is NSNull {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: result as? [String: Any])
            }
        }
    }

    private func forwardUnaryRequest(
        reference: DocumentReference,
        context: HermesRelayRequestContext,
        operation: HermesRelayOperation,
        data: [String: Any]
    ) async throws {
        let request = try makeForwardRequest(operation: operation, data: data)
        let (body, response) = try await urlSession.data(for: request)
        guard let statusCode = (response as? HTTPURLResponse)?.statusCode else {
            throw HermesRelayHostError.invalidResponse
        }
        guard (200..<300).contains(statusCode) else {
            throw HermesRelayHostError.httpStatus(statusCode)
        }
        let responseBody: Data
        if operation == .models {
            responseBody = await enrichedModelsBody(primaryBody: body)
        } else {
            responseBody = body
        }
        let bodyText = String(data: responseBody, encoding: .utf8) ?? ""
        let chunkCount = try await writeRelayChunk(
            reference: reference,
            context: context,
            sequence: 0,
            kind: .data,
            data: bodyText
        )
        try await completeRelayRequest(reference: reference, chunkCount: chunkCount)
    }

    private func forwardStreamingRequest(
        reference: DocumentReference,
        context: HermesRelayRequestContext,
        data: [String: Any]
    ) async throws {
        var request = try makeForwardRequest(operation: .chatCompletions, data: data)
        request.httpMethod = "POST"
        guard try await relayRequestCanReceiveOutput(reference: reference) else {
            throw HermesRelayHostError.requestNoLongerActive
        }
        let now = Self.iso8601.string(from: Date())
        try await reference.setData([
            "status": HermesRelayRequestStatus.streaming.rawValue,
            "updatedAt": now
        ], merge: true)

        let (bytes, response) = try await urlSession.bytes(for: request)
        guard let statusCode = (response as? HTTPURLResponse)?.statusCode else {
            throw HermesRelayHostError.invalidResponse
        }
        guard (200..<300).contains(statusCode) else {
            throw HermesRelayHostError.httpStatus(statusCode)
        }

        var eventLines: [String] = []
        var sequence = 0
        for try await line in bytes.lines {
            try Task.checkCancellation()
            for event in Self.consumeSSELine(line, eventLines: &eventLines) {
                let writtenChunks = try await writeRelayChunk(
                    reference: reference,
                    context: context,
                    sequence: sequence,
                    kind: .sse,
                    data: event
                )
                sequence += writtenChunks
            }
        }
        if !eventLines.isEmpty {
            let writtenChunks = try await writeRelayChunk(
                reference: reference,
                context: context,
                sequence: sequence,
                kind: .sse,
                data: eventLines.joined(separator: "\n")
            )
            sequence += writtenChunks
        }
        try await completeRelayRequest(reference: reference, chunkCount: sequence)
    }

    private func makeForwardRequest(operation: HermesRelayOperation, data: [String: Any]) throws -> URLRequest {
        let path = try relayPath(operation: operation, data: data)
        guard let url = URL(string: path, relativeTo: hermesBaseURLWithTrailingSlash())?.absoluteURL else {
            throw HermesRelayHostError.invalidPath
        }
        var request = URLRequest(url: url, timeoutInterval: operation == .chatCompletions ? 120 : 20)
        request.httpMethod = operation == .chatCompletions ? "POST" : "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let token = settingsManager.hermesBearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if operation == .chatCompletions {
            guard let body = data["body"] as? String,
                  let bodyData = body.data(using: .utf8) else {
                throw HermesRelayHostError.missingBody
            }
            request.httpBody = bodyData
        }
        return request
    }

    static func enrichedModelsBody(
        primaryBody: Data,
        settingsManager: SettingsManager,
        urlSession: URLSession
    ) async -> Data {
        let port = settingsManager.gatewayPort > 0 ? settingsManager.gatewayPort : 8317
        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/models") else {
            return primaryBody
        }
        var request = URLRequest(url: url, timeoutInterval: 5)
        let token = settingsManager.gatewayAuthToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (secondaryBody, response) = try await urlSession.data(for: request)
            guard let statusCode = (response as? HTTPURLResponse)?.statusCode,
                  (200..<300).contains(statusCode) else {
                return primaryBody
            }
            return mergedModelsResponseBodies(primaryBody, secondaryBody) ?? primaryBody
        } catch {
            return primaryBody
        }
    }

    private func enrichedModelsBody(primaryBody: Data) async -> Data {
        let port = settingsManager.gatewayPort > 0 ? settingsManager.gatewayPort : 8317
        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/models") else {
            return primaryBody
        }
        var request = URLRequest(url: url, timeoutInterval: 5)
        let token = settingsManager.gatewayAuthToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (secondaryBody, response) = try await urlSession.data(for: request)
            guard let statusCode = (response as? HTTPURLResponse)?.statusCode,
                  (200..<300).contains(statusCode) else {
                return primaryBody
            }
            return Self.mergedModelsResponseBodies(primaryBody, secondaryBody) ?? primaryBody
        } catch {
            return primaryBody
        }
    }

    private func relayPath(operation: HermesRelayOperation, data: [String: Any]) throws -> String {
        switch operation {
        case .chatCompletions:
            return "v1/chat/completions"
        case .models:
            return "v1/models"
        case .sessions:
            return "api/sessions"
        case .profiles:
            return "api/profiles"
        case .jobs:
            return "api/jobs"
        case .sessionDetail:
            guard let sessionID = data["sessionId"] as? String,
                  !sessionID.isEmpty else {
                throw HermesRelayHostError.invalidPath
            }
            let encoded = sessionID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionID
            return "api/sessions/\(encoded)"
        }
    }

    @discardableResult
    private func writeRelayChunk(
        reference: DocumentReference,
        context: HermesRelayRequestContext,
        sequence: Int,
        kind: HermesRelayChunkKind,
        data: String? = nil,
        error: String? = nil
    ) async throws -> Int {
        guard try await relayRequestCanReceiveOutput(reference: reference) else {
            throw HermesRelayHostError.requestNoLongerActive
        }

        if kind == .data, let data {
            let fragments = Self.relayDataFragments(data)
            for (offset, fragment) in fragments.enumerated() {
                try await writeRelayChunkDocument(
                    reference: reference,
                    context: context,
                    sequence: sequence + offset,
                    kind: kind,
                    data: fragment,
                    error: error
                )
            }
            return fragments.count
        }

        if let data, data.utf8.count > Self.maxRelayChunkDataBytes {
            throw HermesRelayHostError.payloadTooLarge
        }
        try await writeRelayChunkDocument(
            reference: reference,
            context: context,
            sequence: sequence,
            kind: kind,
            data: data,
            error: error.map { String($0.prefix(2_000)) }
        )
        return 1
    }

    private func writeRelayChunkDocument(
        reference: DocumentReference,
        context: HermesRelayRequestContext,
        sequence: Int,
        kind: HermesRelayChunkKind,
        data: String? = nil,
        error: String? = nil
    ) async throws {
        let now = Self.iso8601.string(from: Date())
        let chunkID = String(format: "%08d", sequence)
        var payload: [String: Any] = [
            "id": chunkID,
            "requestId": context.requestID,
            "sequence": sequence,
            "kind": kind.rawValue,
            "createdAt": now,
            "updatedAt": now,
            "schemaVersion": 2
        ]
        let plaintext = error ?? data ?? ""
        payload["ciphertext"] = try HermesRelayCrypto.sealToBase64(
            plaintext: Data(plaintext.utf8),
            keyData: context.keyData,
            aad: HermesRelayCrypto.chunkAAD(
                uid: context.uid,
                connectionID: context.connectionID,
                requestID: context.requestID,
                sequence: sequence,
                kind: kind.rawValue
            )
        )
        try await reference.collection("chunks").document(chunkID).setData(payload, merge: false)
    }

    private func completeRelayRequest(reference: DocumentReference, chunkCount: Int) async throws {
        guard try await relayRequestCanReceiveOutput(reference: reference) else {
            return
        }
        let now = Self.iso8601.string(from: Date())
        try await reference.setData([
            "status": HermesRelayRequestStatus.completed.rawValue,
            "chunkCount": chunkCount,
            "completedAt": now,
            "updatedAt": now
        ], merge: true)
    }

    private func failRelayRequest(
        reference: DocumentReference,
        requestID: String,
        message: String,
        context: HermesRelayRequestContext? = nil
    ) async throws {
        guard try await relayRequestCanReceiveOutput(reference: reference) else {
            return
        }
        let now = Self.iso8601.string(from: Date())
        var statusUpdate: [String: Any] = [
            "status": HermesRelayRequestStatus.failed.rawValue,
            "updatedAt": now
        ]
        if let context {
            try? await writeRelayChunk(
                reference: reference,
                context: context,
                sequence: 0,
                kind: .error,
                error: String(message.prefix(2_000))
            )
            statusUpdate["chunkCount"] = 1
        } else {
            let snapshot = try? await reference.getDocument()
            let isEncrypted = (snapshot?.data()?["schemaVersion"] as? Int ?? 1) >= 2
            if !isEncrypted {
                statusUpdate["error"] = String(message.prefix(2_000))
            }
        }
        try await reference.setData(statusUpdate, merge: true)
    }

    private func relayRequestCanReceiveOutput(reference: DocumentReference) async throws -> Bool {
        let snapshot = try await reference.getDocument()
        guard let statusText = snapshot.data()?["status"] as? String,
              let status = HermesRelayRequestStatus(rawValue: statusText) else {
            return false
        }
        return status == .claimed || status == .streaming
    }

    private func hermesBaseURL() -> URL {
        URL(string: settingsManager.hermesGatewayBaseURL.trimmingCharacters(in: .whitespacesAndNewlines))
            ?? URL(string: "http://127.0.0.1:8642")!
    }

    private func hermesBaseURLWithTrailingSlash() -> URL {
        let url = hermesBaseURL()
        if url.absoluteString.hasSuffix("/") { return url }
        return URL(string: "\(url.absoluteString)/") ?? url
    }

    private func isExpired(_ raw: Any?) -> Bool {
        guard let text = raw as? String,
              let date = Self.iso8601.date(from: text) ?? Self.iso8601NoFraction.date(from: text) else {
            return false
        }
        return date <= Date()
    }

    private static func safeIdentifier(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        let lowered = raw.lowercased()
        let scalars = lowered.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let collapsed = String(scalars).split(separator: "-").joined(separator: "-")
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-")).isEmpty ? "mac" : collapsed
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601NoFraction = ISO8601DateFormatter()

    nonisolated static let maxRelayChunkDataBytes = 72_000

    nonisolated static func relayDataFragments(_ text: String) -> [String] {
        guard text.utf8.count > maxRelayChunkDataBytes else {
            return [text]
        }
        var fragments: [String] = []
        var current = ""
        var currentBytes = 0
        for character in text {
            let bytes = String(character).utf8.count
            if currentBytes > 0, currentBytes + bytes > maxRelayChunkDataBytes {
                fragments.append(current)
                current = ""
                currentBytes = 0
            }
            current.append(character)
            currentBytes += bytes
        }
        if !current.isEmpty {
            fragments.append(current)
        }
        return fragments
    }

    nonisolated static func consumeSSELine(_ rawLine: String, eventLines: inout [String]) -> [String] {
        let line = rawLine.trimmingCharacters(in: .newlines)
        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            guard !eventLines.isEmpty else { return [] }
            let event = eventLines.joined(separator: "\n")
            eventLines.removeAll(keepingCapacity: true)
            return [event]
        }
        if line.hasPrefix("data:"),
           eventLines.contains(where: { $0.hasPrefix("data:") }) {
            let event = eventLines.joined(separator: "\n")
            eventLines.removeAll(keepingCapacity: true)
            eventLines.append(line)
            return [event]
        }
        eventLines.append(line)
        return []
    }

    nonisolated static func mergedModelsResponseBodies(_ primaryBody: Data, _ secondaryBody: Data) -> Data? {
        guard var primary = jsonObject(from: primaryBody),
              let secondary = jsonObject(from: secondaryBody) else {
            return nil
        }

        var seen = Set<String>()
        var merged: [[String: Any]] = []
        for item in (primary["data"] as? [[String: Any]] ?? []) + (secondary["data"] as? [[String: Any]] ?? []) {
            guard let id = item["id"] as? String, !id.isEmpty else { continue }
            if seen.insert(id).inserted {
                merged.append(item)
            }
        }
        primary["data"] = merged
        primary["object"] = primary["object"] ?? "list"
        return try? JSONSerialization.data(withJSONObject: primary, options: [.sortedKeys])
    }

    private nonisolated static func jsonObject(from data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

private enum HermesRelayHostError: LocalizedError {
    case invalidPath
    case missingBody
    case invalidResponse
    case httpStatus(Int)
    case requestNoLongerActive
    case payloadTooLarge
    case encryptionRequired

    var errorDescription: String? {
        switch self {
        case .invalidPath:
            return "Hermes relay request path is invalid."
        case .missingBody:
            return "Hermes relay chat request is missing a body."
        case .invalidResponse:
            return "Hermes returned an invalid relay response."
        case .httpStatus(let code):
            return "Hermes returned HTTP \(code)."
        case .requestNoLongerActive:
            return "Hermes relay request is no longer active."
        case .payloadTooLarge:
            return "Hermes relay response chunk is too large to relay safely."
        case .encryptionRequired:
            return "Hermes relay requests must be encrypted."
        }
    }
}

private struct HermesRelayRequestContext {
    let uid: String
    let requestID: String
    let connectionID: String
    let keyData: Data
}

struct HermesRelayKeyStore {
    private let keychain: KeychainStore
    private let account = "settings.chat.hermes.relay.p256.v1"

    init(
        keychain: KeychainStore = KeychainStore(
            service: "com.openburnbar.hermes-relay",
            legacyServices: []
        )
    ) {
        self.keychain = keychain
    }

    func privateKey() throws -> HermesRelayPrivateKey {
        if let stored = try keychain.string(for: account),
           let data = Data(base64Encoded: stored) {
            return try HermesRelayPrivateKey(rawRepresentation: data)
        }
        let key = HermesRelayCrypto.generatePrivateKey()
        try keychain.set(key.rawRepresentation.base64EncodedString(), for: account)
        return key
    }
}

// MARK: - Pi Agent Remote Relay Host

private enum PiAgentRealtimeRelayProtocol {
    static let version = 1
}

@MainActor
final class PiAgentCloudRelayHostService {
    private let db: Firestore
    private let accountManager: AccountManager
    private let settingsManager: SettingsManager
    private let urlSession: URLSession
    private let relayKeyStore: PiAgentRelayKeyStore
    private var heartbeatTask: Task<Void, Never>?
    private var listener: ListenerRegistration?
    private var listenerUID: String?
    private var requestTasks: [String: Task<Void, Never>] = [:]
    private var processingRequestIDs: Set<String> = []

    init(
        db: Firestore = Firestore.firestore(),
        accountManager: AccountManager = .shared,
        settingsManager: SettingsManager = .shared,
        urlSession: URLSession = .shared,
        relayKeyStore: PiAgentRelayKeyStore = PiAgentRelayKeyStore()
    ) {
        self.db = db
        self.accountManager = accountManager
        self.settingsManager = settingsManager
        self.urlSession = urlSession
        self.relayKeyStore = relayKeyStore
    }

    var connectionID: String {
        "pi-relay-\(Self.safeIdentifier(accountManager.deviceId))"
    }

    func start() {
        guard heartbeatTask == nil else { return }
        heartbeatTask = Task { @MainActor in
            while !Task.isCancelled {
                await refreshRelayHost()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    func stop() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        listener?.remove()
        listener = nil
        listenerUID = nil
        for task in requestTasks.values {
            task.cancel()
        }
        requestTasks.removeAll()
        processingRequestIDs.removeAll()
    }

    private func refreshRelayHost() async {
        guard accountManager.isFirebaseAvailable,
              accountManager.isSignedIn,
              accountManager.isCloudSyncEnabled,
              let uid = Auth.auth().currentUser?.uid else {
            listener?.remove()
            listener = nil
            listenerUID = nil
            for task in requestTasks.values {
                task.cancel()
            }
            requestTasks.removeAll()
            return
        }

        guard settingsManager.piRemoteRelayEnabled else {
            listener?.remove()
            listener = nil
            listenerUID = nil
            for task in requestTasks.values {
                task.cancel()
            }
            requestTasks.removeAll()
            await publishRelayOffline(uid: uid)
            return
        }

        await publishRelayConnection(uid: uid)
        ensureRequestListener(uid: uid)
    }

    private func publishRelayOffline(uid: String) async {
        let now = Self.iso8601.string(from: Date())
        let ref = db.collection("users").document(uid).collection("pi_agent_connections").document(connectionID)
        do {
            let snap = try await ref.getDocument()
            var data: [String: Any] = [
                "id": connectionID,
                "displayName": Host.current().localizedName.map { "\($0) Pi Relay" } ?? "Mac Pi Relay",
                "mode": PiConnectionMode.relayLink.rawValue,
                "status": PiConnectionStatus.offline.rawValue,
                "capabilities": ["chat_completions", "remote_relay"],
                "advertisedModel": FieldValue.delete(),
                "updatedAt": now,
                "schemaVersion": 2
            ]
            if let key = try? relayKeyStore.privateKey() {
                data["relayPublicKey"] = key.publicKeyBase64
                data["relayKeyVersion"] = PiAgentRelayCrypto.keyVersion
                data["relayEncryption"] = PiAgentRelayCrypto.algorithm
            }
            if !snap.exists {
                data["createdAt"] = now
            }
            try await ref.setData(data, merge: true)
        } catch {
            AppLogger.network.silentFailure("pi_agent_relay_offline_publish_failed", error: error)
        }
    }

    private func publishRelayConnection(uid: String) async {
        let relayPrivateKey: PiAgentRelayPrivateKey
        do {
            relayPrivateKey = try relayKeyStore.privateKey()
        } catch {
            AppLogger.network.error(
                "pi_agent_relay_key_unavailable",
                metadata: ["error": error.localizedDescription]
            )
            await publishRelayOffline(uid: uid)
            return
        }

        let baseURL = piAgentBaseURL()
        let bearerToken = resolvedBearerToken()
        let preferred = settingsManager.piAgentSelectedInstanceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let redisRaw = settingsManager.piAgentRedisURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let adapter = PiAgentRuntimeAdapter(
            preferredInstanceID: preferred.isEmpty ? nil : preferred,
            redisURL: redisRaw.isEmpty ? nil : URL(string: redisRaw)
        )
        let status = await adapter.refreshManagedStatus(baseURL: baseURL, bearerToken: bearerToken)
        let now = Self.iso8601.string(from: Date())
        var data: [String: Any] = [
            "id": connectionID,
            "displayName": Host.current().localizedName.map { "\($0) Pi Relay" } ?? "Mac Pi Relay",
            "mode": PiConnectionMode.relayLink.rawValue,
            "status": status.gatewayRunning ? PiConnectionStatus.online.rawValue : PiConnectionStatus.offline.rawValue,
            "endpointURL": baseURL.absoluteString,
            "capabilities": ["chat_completions", "models", "remote_relay"],
            "relayPublicKey": relayPrivateKey.publicKeyBase64,
            "relayKeyVersion": PiAgentRelayCrypto.keyVersion,
            "relayEncryption": PiAgentRelayCrypto.algorithm,
            "updatedAt": now,
            "schemaVersion": 2
        ]
        if status.gatewayRunning {
            data["lastSeenAt"] = now
        }
        if let modelName = status.modelName, !modelName.isEmpty {
            data["advertisedModel"] = modelName
            data["models"] = [[
                "id": "pi:\(modelName)",
                "providerID": "pi",
                "providerName": "Pi",
                "modelID": modelName,
                "displayName": modelName,
                "instanceID": status.selectedInstanceID ?? "default",
                "schemaVersion": 1
            ]]
        } else {
            data["advertisedModel"] = FieldValue.delete()
            data["models"] = FieldValue.delete()
        }
        if let selected = status.selectedInstanceID {
            data["selectedInstanceID"] = selected
        }
        if !redisRaw.isEmpty {
            data["redisURL"] = redisRaw
        }
        if !status.instances.isEmpty {
            data["instances"] = status.instances.map { instance in
                var record: [String: Any] = [
                    "id": instance.id,
                    "displayName": instance.displayName,
                    "endpointURL": instance.gatewayBaseURL?.absoluteString ?? baseURL.absoluteString,
                    "status": instance.isOnline ? PiConnectionStatus.online.rawValue : PiConnectionStatus.offline.rawValue,
                    "capabilities": ["chat_completions"],
                    "schemaVersion": 1
                ]
                if let modelName = status.modelName, !modelName.isEmpty {
                    record["modelName"] = modelName
                }
                if instance.isOnline {
                    record["lastSeenAt"] = now
                }
                return record
            }
        }
        if let realtimeURL = URL(string: settingsManager.piRealtimeRelayURL.trimmingCharacters(in: .whitespacesAndNewlines)),
           realtimeURL.scheme == "wss" {
            data["realtimeRelayURL"] = realtimeURL.absoluteString
            data["realtimeRelayStatus"] = "online"
            data["realtimeRelayProtocolVersion"] = PiAgentRealtimeRelayProtocol.version
        }

        let ref = db.collection("users").document(uid).collection("pi_agent_connections").document(connectionID)
        do {
            let snap = try await ref.getDocument()
            if !snap.exists {
                data["createdAt"] = now
            }
            try await ref.setData(data, merge: true)
        } catch {
            AppLogger.network.error(
                "pi_agent_relay_connection_publish_failed",
                metadata: ["error": error.localizedDescription]
            )
        }
    }

    private func ensureRequestListener(uid: String) {
        guard listenerUID != uid else { return }
        listener?.remove()
        listenerUID = uid
        listener = db.collection("users").document(uid)
            .collection("pi_agent_relay_requests")
            .whereField("connectionId", isEqualTo: connectionID)
            .whereField("status", isEqualTo: PiAgentRelayRequestStatus.pending.rawValue)
            .addSnapshotListener { [weak self] snapshot, error in
                if let error {
                    AppLogger.network.error(
                        "pi_agent_relay_listener_failed",
                        metadata: ["error": error.localizedDescription]
                    )
                    Task { @MainActor [weak self] in
                        self?.listener?.remove()
                        self?.listener = nil
                        self?.listenerUID = nil
                    }
                    return
                }
                guard let documents = snapshot?.documents, !documents.isEmpty else { return }
                Task { @MainActor [weak self] in
                    self?.handlePendingRelayDocuments(documents, uid: uid)
                }
            }
    }

    private func handlePendingRelayDocuments(_ documents: [QueryDocumentSnapshot], uid: String) {
        for document in documents
        where !processingRequestIDs.contains(document.documentID) && requestTasks[document.documentID] == nil {
            let requestID = document.documentID
            processingRequestIDs.insert(requestID)
            let task = Task { @MainActor in
                defer {
                    processingRequestIDs.remove(requestID)
                    requestTasks.removeValue(forKey: requestID)
                }
                await processRelayRequest(reference: document.reference, uid: uid)
            }
            requestTasks[requestID] = task
        }
    }

    private func processRelayRequest(reference: DocumentReference, uid: String) async {
        var context: PiAgentRelayRequestContext?
        do {
            guard let data = try await claimRelayRequest(reference: reference) else { return }
            guard let operationText = data["operation"] as? String,
                  let operation = PiAgentRelayOperation(rawValue: operationText) else {
                try await failRelayRequest(reference: reference, message: "Malformed relay request.")
                return
            }
            let requestID = (data["id"] as? String) ?? reference.documentID
            guard !isExpired(data["expiresAt"]) else {
                try await reference.setData([
                    "status": PiAgentRelayRequestStatus.expired.rawValue,
                    "updatedAt": Self.iso8601.string(from: Date())
                ], merge: true)
                return
            }
            let prepared = try decryptRelayRequest(data, uid: uid, requestID: requestID)
            context = prepared.context
            switch operation {
            case .chatCompletions:
                try await forwardStreamingRequest(reference: reference, context: prepared.context, data: prepared.data)
            case .models, .sessions, .sessionDetail:
                try await forwardUnaryRequest(reference: reference, context: prepared.context, operation: operation, data: prepared.data)
            }
        } catch {
            try? await failRelayRequest(reference: reference, message: error.localizedDescription, context: context)
        }
    }

    private func decryptRelayRequest(
        _ data: [String: Any],
        uid: String,
        requestID: String
    ) throws -> (data: [String: Any], context: PiAgentRelayRequestContext) {
        guard uid.isEmpty == false,
              data["relayEncryption"] as? String == PiAgentRelayCrypto.algorithm,
              let wrappedKey = data["wrappedKey"] as? String,
              let payloadCiphertext = data["payloadCiphertext"] as? String else {
            throw PiAgentRelayHostError.encryptionRequired
        }
        let connectionID = (data["connectionId"] as? String) ?? self.connectionID
        let privateKey = try relayKeyStore.privateKey()
        let keyData = try PiAgentRelayCrypto.unwrapSymmetricKey(
            wrappedKey,
            privateKey: privateKey,
            aad: PiAgentRelayCrypto.keyAAD(uid: uid, connectionID: connectionID, requestID: requestID)
        )
        let plaintext = try PiAgentRelayCrypto.openBase64(
            ciphertext: payloadCiphertext,
            keyData: keyData,
            aad: PiAgentRelayCrypto.requestAAD(uid: uid, connectionID: connectionID, requestID: requestID)
        )
        let payload = try JSONDecoder().decode(PiAgentRelayEncryptedRequestPayload.self, from: plaintext)
        var decrypted = data
        decrypted["path"] = payload.path
        decrypted["sessionId"] = payload.sessionId
        decrypted["body"] = payload.body
        return (
            decrypted,
            PiAgentRelayRequestContext(uid: uid, requestID: requestID, connectionID: connectionID, keyData: keyData)
        )
    }

    private func claimRelayRequest(reference: DocumentReference) async throws -> [String: Any]? {
        try await withCheckedThrowingContinuation { continuation in
            db.runTransaction({ transaction, errorPointer in
                let snapshot: DocumentSnapshot
                do {
                    snapshot = try transaction.getDocument(reference)
                } catch {
                    errorPointer?.pointee = error as NSError
                    return nil
                }
                guard var data = snapshot.data(),
                      data["status"] as? String == PiAgentRelayRequestStatus.pending.rawValue else {
                    return NSNull()
                }
                let now = Self.iso8601.string(from: Date())
                transaction.setData([
                    "status": PiAgentRelayRequestStatus.claimed.rawValue,
                    "claimedAt": now,
                    "claimedBy": self.connectionID,
                    "updatedAt": now
                ], forDocument: reference, merge: true)
                data["status"] = PiAgentRelayRequestStatus.claimed.rawValue
                data["claimedBy"] = self.connectionID
                return data as NSDictionary
            }) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if result is NSNull {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: result as? [String: Any])
            }
        }
    }

    private func forwardUnaryRequest(
        reference: DocumentReference,
        context: PiAgentRelayRequestContext,
        operation: PiAgentRelayOperation,
        data: [String: Any]
    ) async throws {
        let request = try makeForwardRequest(operation: operation, data: data)
        let (body, response) = try await urlSession.data(for: request)
        guard let statusCode = (response as? HTTPURLResponse)?.statusCode else {
            throw PiAgentRelayHostError.invalidResponse
        }
        guard (200..<300).contains(statusCode) else {
            throw PiAgentRelayHostError.httpStatus(statusCode)
        }
        let bodyText = String(data: body, encoding: .utf8) ?? ""
        let chunkCount = try await writeRelayChunk(reference: reference, context: context, sequence: 0, kind: .data, data: bodyText)
        try await completeRelayRequest(reference: reference, chunkCount: chunkCount)
    }

    private func forwardStreamingRequest(
        reference: DocumentReference,
        context: PiAgentRelayRequestContext,
        data: [String: Any]
    ) async throws {
        var request = try makeForwardRequest(operation: .chatCompletions, data: data)
        request.httpMethod = "POST"
        guard try await relayRequestCanReceiveOutput(reference: reference) else {
            throw PiAgentRelayHostError.requestNoLongerActive
        }
        let now = Self.iso8601.string(from: Date())
        try await reference.setData([
            "status": PiAgentRelayRequestStatus.streaming.rawValue,
            "updatedAt": now
        ], merge: true)

        let (bytes, response) = try await urlSession.bytes(for: request)
        guard let statusCode = (response as? HTTPURLResponse)?.statusCode else {
            throw PiAgentRelayHostError.invalidResponse
        }
        guard (200..<300).contains(statusCode) else {
            throw PiAgentRelayHostError.httpStatus(statusCode)
        }

        var eventLines: [String] = []
        var sequence = 0
        for try await line in bytes.lines {
            try Task.checkCancellation()
            for event in HermesRelayHostService.consumeSSELine(line, eventLines: &eventLines) {
                let writtenChunks = try await writeRelayChunk(reference: reference, context: context, sequence: sequence, kind: .sse, data: event)
                sequence += writtenChunks
            }
        }
        if !eventLines.isEmpty {
            let writtenChunks = try await writeRelayChunk(
                reference: reference,
                context: context,
                sequence: sequence,
                kind: .sse,
                data: eventLines.joined(separator: "\n")
            )
            sequence += writtenChunks
        }
        try await completeRelayRequest(reference: reference, chunkCount: sequence)
    }

    private func makeForwardRequest(operation: PiAgentRelayOperation, data: [String: Any]) throws -> URLRequest {
        let path = try relayPath(operation: operation, data: data)
        guard let url = URL(string: path, relativeTo: piAgentBaseURLWithTrailingSlash())?.absoluteURL else {
            throw PiAgentRelayHostError.invalidPath
        }
        var request = URLRequest(url: url, timeoutInterval: operation == .chatCompletions ? 120 : 20)
        request.httpMethod = operation == .chatCompletions ? "POST" : "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = resolvedBearerToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if operation == .chatCompletions {
            guard let body = data["body"] as? String,
                  let bodyData = body.data(using: .utf8) else {
                throw PiAgentRelayHostError.missingBody
            }
            request.httpBody = bodyData
        }
        return request
    }

    private func relayPath(operation: PiAgentRelayOperation, data: [String: Any]) throws -> String {
        switch operation {
        case .chatCompletions:
            return "v1/chat/completions"
        case .models:
            return "v1/models"
        case .sessions:
            return "api/sessions"
        case .sessionDetail:
            guard let sessionID = data["sessionId"] as? String,
                  !sessionID.isEmpty else {
                throw PiAgentRelayHostError.invalidPath
            }
            let encoded = sessionID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionID
            return "api/sessions/\(encoded)"
        }
    }

    @discardableResult
    private func writeRelayChunk(
        reference: DocumentReference,
        context: PiAgentRelayRequestContext,
        sequence: Int,
        kind: PiAgentRelayChunkKind,
        data: String? = nil,
        error: String? = nil
    ) async throws -> Int {
        guard try await relayRequestCanReceiveOutput(reference: reference) else {
            throw PiAgentRelayHostError.requestNoLongerActive
        }

        if kind == .data, let data {
            let fragments = HermesRelayHostService.relayDataFragments(data)
            for (offset, fragment) in fragments.enumerated() {
                try await writeRelayChunkDocument(reference: reference, context: context, sequence: sequence + offset, kind: kind, data: fragment, error: error)
            }
            return fragments.count
        }

        if let data, data.utf8.count > HermesRelayHostService.maxRelayChunkDataBytes {
            throw PiAgentRelayHostError.payloadTooLarge
        }
        try await writeRelayChunkDocument(reference: reference, context: context, sequence: sequence, kind: kind, data: data, error: error.map { String($0.prefix(2_000)) })
        return 1
    }

    private func writeRelayChunkDocument(
        reference: DocumentReference,
        context: PiAgentRelayRequestContext,
        sequence: Int,
        kind: PiAgentRelayChunkKind,
        data: String? = nil,
        error: String? = nil
    ) async throws {
        let now = Self.iso8601.string(from: Date())
        let chunkID = String(format: "%08d", sequence)
        let plaintext = error ?? data ?? ""
        let payload: [String: Any] = [
            "id": chunkID,
            "requestId": context.requestID,
            "sequence": sequence,
            "kind": kind.rawValue,
            "ciphertext": try PiAgentRelayCrypto.sealToBase64(
                plaintext: Data(plaintext.utf8),
                keyData: context.keyData,
                aad: PiAgentRelayCrypto.chunkAAD(
                    uid: context.uid,
                    connectionID: context.connectionID,
                    requestID: context.requestID,
                    sequence: sequence,
                    kind: kind.rawValue
                )
            ),
            "createdAt": now,
            "updatedAt": now,
            "schemaVersion": 2
        ]
        try await reference.collection("chunks").document(chunkID).setData(payload, merge: false)
    }

    private func completeRelayRequest(reference: DocumentReference, chunkCount: Int) async throws {
        guard try await relayRequestCanReceiveOutput(reference: reference) else { return }
        let now = Self.iso8601.string(from: Date())
        try await reference.setData([
            "status": PiAgentRelayRequestStatus.completed.rawValue,
            "chunkCount": chunkCount,
            "completedAt": now,
            "updatedAt": now
        ], merge: true)
    }

    private func failRelayRequest(
        reference: DocumentReference,
        message: String,
        context: PiAgentRelayRequestContext? = nil
    ) async throws {
        guard try await relayRequestCanReceiveOutput(reference: reference) else { return }
        let now = Self.iso8601.string(from: Date())
        var statusUpdate: [String: Any] = [
            "status": PiAgentRelayRequestStatus.failed.rawValue,
            "updatedAt": now
        ]
        if let context {
            try? await writeRelayChunk(
                reference: reference,
                context: context,
                sequence: 0,
                kind: .error,
                error: String(message.prefix(2_000))
            )
            statusUpdate["chunkCount"] = 1
        }
        try await reference.setData(statusUpdate, merge: true)
    }

    private func relayRequestCanReceiveOutput(reference: DocumentReference) async throws -> Bool {
        let snapshot = try await reference.getDocument()
        guard let statusText = snapshot.data()?["status"] as? String,
              let status = PiAgentRelayRequestStatus(rawValue: statusText) else {
            return false
        }
        return status == .claimed || status == .streaming
    }

    private func piAgentBaseURL() -> URL {
        URL(string: settingsManager.piAgentGatewayBaseURL.trimmingCharacters(in: .whitespacesAndNewlines))
            ?? URL(string: "http://127.0.0.1:8765")!
    }

    private func piAgentBaseURLWithTrailingSlash() -> URL {
        let url = piAgentBaseURL()
        if url.absoluteString.hasSuffix("/") { return url }
        return URL(string: "\(url.absoluteString)/") ?? url
    }

    private func resolvedBearerToken() -> String? {
        let token = settingsManager.piAgentBearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    private func isExpired(_ raw: Any?) -> Bool {
        guard let text = raw as? String,
              let date = Self.iso8601.date(from: text) ?? Self.iso8601NoFraction.date(from: text) else {
            return false
        }
        return date <= Date()
    }

    private static func safeIdentifier(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        let lowered = raw.lowercased()
        let scalars = lowered.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let collapsed = String(scalars).split(separator: "-").joined(separator: "-")
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-")).isEmpty ? "mac" : collapsed
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601NoFraction = ISO8601DateFormatter()
}

private enum PiAgentRelayHostError: LocalizedError {
    case invalidPath
    case missingBody
    case invalidResponse
    case httpStatus(Int)
    case requestNoLongerActive
    case payloadTooLarge
    case encryptionRequired

    var errorDescription: String? {
        switch self {
        case .invalidPath:
            return "Pi Agent relay request path is invalid."
        case .missingBody:
            return "Pi Agent relay chat request is missing a body."
        case .invalidResponse:
            return "Pi Agent returned an invalid relay response."
        case .httpStatus(let code):
            return "Pi Agent returned HTTP \(code)."
        case .requestNoLongerActive:
            return "Pi Agent relay request is no longer active."
        case .payloadTooLarge:
            return "Pi Agent relay response chunk is too large to relay safely."
        case .encryptionRequired:
            return "Pi Agent relay requests must be encrypted."
        }
    }
}

private struct PiAgentRelayRequestContext {
    let uid: String
    let requestID: String
    let connectionID: String
    let keyData: Data
}

struct PiAgentRelayKeyStore {
    private let keychain: KeychainStore
    private let account = "settings.chat.piagent.relay.p256.v1"

    init(
        keychain: KeychainStore = KeychainStore(
            service: "com.openburnbar.pi-agent-relay",
            legacyServices: []
        )
    ) {
        self.keychain = keychain
    }

    func privateKey() throws -> PiAgentRelayPrivateKey {
        if let stored = try keychain.string(for: account),
           let data = Data(base64Encoded: stored) {
            return try PiAgentRelayPrivateKey(rawRepresentation: data)
        }
        let key = PiAgentRelayCrypto.generatePrivateKey()
        try keychain.set(key.rawRepresentation.base64EncodedString(), for: account)
        return key
    }
}
