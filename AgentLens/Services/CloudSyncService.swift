import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import Foundation

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
            let unsynced = try dataStore.fetchUnsynced()
            guard !unsynced.isEmpty else {
                isSyncing = false
                lastSyncDate = Date()
                TelemetryService.shared.record(feature: .cloudSync, outcome: .success, durationMs: Int(Date().timeIntervalSince(start) * 1000))
                return
            }

            let deviceId = accountManager.deviceId

            // Firestore batch limit is 500 ops; we fetch max 400 rows at a time
            let batch = db.batch()
            let collectionRef = db.collection("users").document(uid).collection("usage")

            for usage in unsynced {
                let docId = "\(deviceId)_\(usage.id.uuidString)"
                let docRef = collectionRef.document(docId)
                let data = encodeUsage(usage, deviceId: deviceId)
                batch.setData(data, forDocument: docRef, merge: true)
            }

            try await batch.commit()

            let syncedIds = unsynced.map { $0.id }
            try dataStore.markSynced(ids: syncedIds)

            lastSyncDate = Date()
            lastSyncError = nil

            TelemetryService.shared.record(feature: .cloudSync, outcome: .success, durationMs: Int(Date().timeIntervalSince(start) * 1000))
            await downloadRemoteData(uid: uid)
            await fetchCloudTotal(uid: uid)
        } catch {
            TelemetryService.shared.record(feature: .cloudSync, outcome: .failure, durationMs: Int(Date().timeIntervalSince(start) * 1000))
            recordSyncError(error)
        }

        isSyncing = false
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

    /// Uploads chat threads and messages to Firestore for cross-device resume.
    /// Layout: `users/{uid}/chat_threads/{deviceId}_{threadId}` (thread metadata + messages array).
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

            for thread in threads {
                let messages = (try? dataStore.fetchChatMessages(threadID: thread.id)) ?? []
                guard !messages.isEmpty else { continue }

                let docId = "\(deviceId)_\(thread.id)"
                let docRef = collectionRef.document(docId)

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

                let data: [String: Any] = [
                    "threadId": thread.id,
                    "title": thread.title,
                    "preview": String(thread.preview.prefix(500)),
                    "messageCount": thread.messageCount,
                    "createdAt": thread.lastActivityAt.timeIntervalSince1970,
                    "updatedAt": thread.lastActivityAt.timeIntervalSince1970,
                    "deviceId": deviceId,
                    "messages": encodedMessages,
                ]
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

        defer {
            // Commit the transaction to advance watermark
            // This happens even if some items fail, as long as we processed anything
            if syncTx.processedCount > 0 {
                try? syncTx.commit()
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
                    provenanceMethod: .cloudSync,
                    provenanceConfidence: .exact
                )
                try dataStore.insertRemoteUsage(usage)

                // Track the latest remote update timestamp for watermark
                if let updatedAt = (data["updatedAt"] as? Timestamp)?.dateValue() {
                    syncTx.recordProcessedItem(remoteUpdatedAt: updatedAt)
                }
            }
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

        defer {
            // Commit the transaction to advance watermark
            if syncTx.processedCount > 0 {
                try? syncTx.commit()
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

        return [
            "id": usage.id.uuidString,
            "deviceId": deviceId,
            "provider": usage.provider.rawValue,
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