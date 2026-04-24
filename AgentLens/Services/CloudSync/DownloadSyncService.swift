import FirebaseAuth
import FirebaseFirestore
import Foundation

/// Sync domain for downloading remote data from Firestore.
///
/// Handles cross-device replication with durable, per-account, per-collection watermark tracking.
/// Layout: `users/{uid}/usage`, `users/{uid}/conversations`, `users/{uid}/session_logs`
@MainActor
final class DownloadSyncService: CloudSyncDomain {
    private let context: CloudSyncContext

    private(set) var isSyncing = false
    private(set) var lastSyncError: String?
    private(set) var lastSyncDate: Date?

    init(context: CloudSyncContext) {
        self.context = context
    }

    /// Downloads remote data from Firestore with durable, per-account, per-collection watermark tracking.
    ///
    /// VAL-PERSIST-010: Watermark advances only after successful sync commit.
    /// VAL-PERSIST-011: Watermark scope is account-aware and collection-safe.
    func sync() async {
        guard context.accountManager.isFirebaseAvailable, context.accountManager.isSignedIn else { return }
        guard let resolvedUid = context.currentUID else { return }
        let localDeviceId = context.deviceId

        isSyncing = true
        lastSyncError = nil

        defer { isSyncing = false }

        await syncDeviceRegistry(uid: resolvedUid, localDeviceId: localDeviceId)
        await downloadRemoteUsage(uid: resolvedUid, localDeviceId: localDeviceId)
        let newConversationIds = await downloadRemoteConversations(uid: resolvedUid, localDeviceId: localDeviceId)
        await downloadRemoteSessionLogBodies(uid: resolvedUid, conversationIds: newConversationIds)
        enqueueProjectionForRemoteConversations(newConversationIds)

        lastSyncDate = Date()
        await context.dataStore.refresh()
    }

    /// Updates the local device name in Firestore (called from Settings).
    func updateLocalDeviceName(_ name: String) async {
        guard context.accountManager.isFirebaseAvailable, let uid = context.currentUID else { return }
        let devicesRef = context.db.collection("users").document(uid).collection("devices")
        try? await devicesRef.document(context.deviceId).setData(["deviceName": name], merge: true)
    }

    // MARK: - Device Registry

    private func syncDeviceRegistry(uid: String, localDeviceId: String) async {
        let devicesRef = context.db.collection("users").document(uid).collection("devices")
        let localName = Host.current().localizedName ?? "This Mac"
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"

        do {
            try await withCloudSyncRetry(
                policy: context.retryPolicy,
                circuitBreaker: context.circuitBreaker,
                domain: "download.deviceRegistry.write"
            ) {
                try await devicesRef.document(localDeviceId).setData([
                    "deviceName": localName, "platform": "macOS",
                    "lastActiveAt": FieldValue.serverTimestamp(), "appVersion": version,
                    "hardwareModel": DeviceHardwareIcon.localHardwareModel
                ], merge: true)
            }
        } catch { /* non-fatal */ }

        do {
            let snapshot = try await withCloudSyncRetry(
                policy: context.retryPolicy,
                circuitBreaker: context.circuitBreaker,
                domain: "download.deviceRegistry.read"
            ) {
                try await devicesRef.getDocuments()
            }
            for doc in snapshot.documents {
                let data = doc.data()
                let device = DeviceRecord(
                    deviceId: doc.documentID,
                    deviceName: data["deviceName"] as? String ?? doc.documentID,
                    isLocal: doc.documentID == localDeviceId,
                    lastSeenAt: (data["lastActiveAt"] as? Timestamp)?.dateValue(),
                    createdAt: Date(),
                    hardwareModel: data["hardwareModel"] as? String,
                    customIcon: nil
                )
                try context.dataStore.upsertDevice(device)
            }
        } catch { /* non-fatal */ }
    }

    // MARK: - Usage Download

    private func downloadRemoteUsage(uid: String, localDeviceId: String) async {
        // VAL-PERSIST-010: Use durable, per-account watermark from database
        let watermark: Date
        do {
            watermark = try context.dataStore.remoteSyncWatermarkStore.fetchWatermarkOrDefault(
                accountUid: uid,
                collectionKind: .usage
            )
        } catch {
            watermark = Calendar.current.date(byAdding: .day, value: -90, to: Date()) ?? Date()
        }

        let cutoff = Calendar.current.date(byAdding: .day, value: -90, to: Date()) ?? Date()

        // Create atomic transaction for durable watermark advancement
        let syncTx = AtomicRemoteSyncTransaction(
            dbQueue: context.dataStore.dbQueue,
            watermarkStore: context.dataStore.remoteSyncWatermarkStore,
            accountUid: uid,
            collectionKind: .usage
        )

        defer {
            if syncTx.processedCount > 0 {
                try? syncTx.commit()
            }
        }

        do {
            var query = context.db.collection("users").document(uid).collection("usage")
                .whereField("startTime", isGreaterThan: Timestamp(date: cutoff))
            if watermark > cutoff {
                query = query.whereField("updatedAt", isGreaterThan: Timestamp(date: watermark))
            }
            let snapshot = try await withCloudSyncRetry(
                policy: context.retryPolicy,
                circuitBreaker: context.circuitBreaker,
                domain: "download.usage"
            ) {
                try await query.getDocuments()
            }
            let devices = try context.dataStore.fetchDevices()
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
                try context.dataStore.insertRemoteUsage(usage)

                if let updatedAt = (data["updatedAt"] as? Timestamp)?.dateValue() {
                    syncTx.recordProcessedItem(remoteUpdatedAt: updatedAt)
                }
            }
        } catch { /* non-fatal */ }
    }

    // MARK: - Conversation Download

    /// Returns IDs of newly inserted remote conversations (for lazy body download).
    @discardableResult
    private func downloadRemoteConversations(uid: String, localDeviceId: String) async -> [String] {
        var insertedIds: [String] = []

        let watermark: Date
        do {
            watermark = try context.dataStore.remoteSyncWatermarkStore.fetchWatermarkOrDefault(
                accountUid: uid,
                collectionKind: .conversations
            )
        } catch {
            watermark = Date.distantPast
        }

        let syncTx = AtomicRemoteSyncTransaction(
            dbQueue: context.dataStore.dbQueue,
            watermarkStore: context.dataStore.remoteSyncWatermarkStore,
            accountUid: uid,
            collectionKind: .conversations
        )

        defer {
            if syncTx.processedCount > 0 {
                try? syncTx.commit()
            }
        }

        do {
            var query: Query
            if watermark > Date.distantPast {
                query = context.db.collection("users").document(uid).collection("conversations")
                    .whereField("updatedAt", isGreaterThan: Timestamp(date: watermark)).limit(to: 500)
            } else {
                query = context.db.collection("users").document(uid).collection("conversations")
                    .order(by: "updatedAt", descending: true).limit(to: 500)
            }
            let snapshot = try await withCloudSyncRetry(
                policy: context.retryPolicy,
                circuitBreaker: context.circuitBreaker,
                domain: "download.conversations"
            ) {
                try await query.getDocuments()
            }
            let devices = try context.dataStore.fetchDevices()
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
                try context.dataStore.insertRemoteConversation(record)
                insertedIds.append(stableId)

                if let updatedAt = (data["updatedAt"] as? Timestamp)?.dateValue() {
                    syncTx.recordProcessedItem(remoteUpdatedAt: updatedAt)
                }
            }
        } catch { /* non-fatal */ }
        return insertedIds
    }

    // MARK: - Session Log Body Download

    /// Downloads full Markdown bodies from session_logs for remote conversations
    /// and updates their fullText so FTS can index them.
    private func downloadRemoteSessionLogBodies(uid: String, conversationIds: [String]) async {
        guard !conversationIds.isEmpty else { return }
        let logsRef = context.db.collection("users").document(uid).collection("session_logs")

        for conversationId in conversationIds.prefix(20) {
            guard let colonIdx = conversationId.firstIndex(of: ":"),
                  conversationId.distance(from: conversationId.startIndex, to: colonIdx) > 0 else { continue }
            let devicePrefix = String(conversationId[conversationId.startIndex..<colonIdx])

            do {
                let snapshot = try await withCloudSyncRetry(
                    policy: context.retryPolicy,
                    circuitBreaker: context.circuitBreaker,
                    domain: "download.sessionLogBodies"
                ) {
                    try await logsRef
                        .whereField("deviceId", isEqualTo: devicePrefix)
                        .limit(to: 200)
                        .getDocuments()
                }

                for doc in snapshot.documents {
                    let data = doc.data()
                    guard let docConvId = data["id"] as? String else { continue }
                    let stableId = "\(devicePrefix):\(docConvId)"
                    guard conversationIds.contains(stableId) else { continue }

                    let body = try await fetchCloudSessionLogBody(docId: doc.documentID)
                    guard !body.isEmpty else { continue }

                    try context.dataStore.updateConversationFullText(id: stableId, fullText: body)
                }
            } catch { /* non-fatal */ }
        }
    }

    // MARK: - Session Log Body Reassembly

    /// Reassembles chunk sub-documents into the full Markdown body for a session log.
    func fetchCloudSessionLogBody(docId: String) async throws -> String {
        guard context.accountManager.isFirebaseAvailable, let uid = context.currentUID else { return "" }

        let snapshot = try await withCloudSyncRetry(
            policy: context.retryPolicy,
            circuitBreaker: context.circuitBreaker,
            domain: "download.sessionLogChunks"
        ) {
            try await context.db
                .collection("users")
                .document(uid)
                .collection("session_logs")
                .document(docId)
                .collection("chunks")
                .order(by: "index")
                .getDocuments()
        }

        return snapshot.documents
            .compactMap { $0.data()["body"] as? String }
            .joined()
    }

    // MARK: - Projection Enqueue

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
            do {
                try context.dataStore.enqueueProjectionJob(
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
            } catch {
                AppLogger.dataStore.silentFailure("enqueueProjectionJob", error: error)
            }
        }
    }
}
