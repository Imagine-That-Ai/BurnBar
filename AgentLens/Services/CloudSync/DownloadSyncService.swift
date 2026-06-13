import FirebaseAuth
import FirebaseFirestore
import Foundation
import OpenBurnBarCore

/// Sync domain for downloading remote data from Firestore.
///
/// Handles cross-device replication with durable, per-account, per-collection watermark tracking.
/// Layout: `users/{uid}/usage`, `users/{uid}/conversations`, `users/{uid}/session_logs`
final class DownloadSyncService: CloudSyncDomain, @unchecked Sendable {
    private let context: CloudSyncContext
    private let conversationVaultKeyProvider: any ConversationCloudVaultKeyProviding

    private let state = Locked(CloudSyncDomainState())

    var isSyncing: Bool { state.read().isSyncing }
    var lastSyncError: String? { state.read().lastSyncError }
    var lastSyncDate: Date? { state.read().lastSyncDate }
    private(set) var cloudTotalCost: Double?

    init(
        context: CloudSyncContext,
        conversationVaultKeyProvider: any ConversationCloudVaultKeyProviding = MacConversationCloudVaultKeyProvider()
    ) {
        self.context = context
        self.conversationVaultKeyProvider = conversationVaultKeyProvider
    }

    /// Downloads remote data from Firestore with durable, per-account, per-collection watermark tracking.
    ///
    /// VAL-PERSIST-010: Watermark advances only after successful sync commit.
    /// VAL-PERSIST-011: Watermark scope is account-aware and collection-safe.
    func sync() async {
        let gate = await context.syncGate()
        guard gate.account.isFirebaseAvailable,
              gate.account.isSignedIn,
              let resolvedUid = gate.account.uid else { return }
        let localDeviceId = gate.account.deviceId

        state.beginSyncing()

        defer { state.endSyncing() }

        await syncDeviceRegistry(uid: resolvedUid, localDeviceId: localDeviceId)
        await downloadRemoteProviderAccounts(uid: resolvedUid, localDeviceId: localDeviceId)
        await downloadRemoteUsage(uid: resolvedUid, localDeviceId: localDeviceId)
        let newConversationIds = await downloadRemoteConversations(uid: resolvedUid, localDeviceId: localDeviceId)
        enqueueProjectionForRemoteConversations(newConversationIds)

        state.withLock { $0.lastSyncDate = Date() }
        await fetchCloudTotal()
        await context.refreshPresentationLayer()
    }

    /// Fetch sum of cost across all devices for this user (last 90 days).
    func fetchCloudTotal(uid: String? = nil) async {
        let gate = await context.syncGate()
        guard gate.account.isFirebaseAvailable else { return }
        let resolvedUid = uid ?? gate.account.uid
        guard let resolvedUid else { return }

        let cutoff = Calendar.current.date(byAdding: .day, value: -90, to: Date()) ?? Date()

        do {
            let snapshot = try await withCloudSyncRetry(
                policy: context.retryPolicy,
                circuitBreaker: context.circuitBreaker,
                domain: "download.usageAggregate"
            ) {
                try await context.firestoreGateway
                    .collection("users")
                    .document(resolvedUid)
                    .collection("usage")
                    .whereField("startTime", isGreaterThan: Timestamp(date: cutoff))
                    .getDocuments()
            }

            cloudTotalCost = snapshot.documents.compactMap { doc -> Double? in
                doc.data()["cost"] as? Double
            }.reduce(0, +)
        } catch {
            AppLogger.sync.error("download_sync_aggregate_failed", metadata: ["error": error.localizedDescription])
        }
    }

    /// Updates the local device name in Firestore (called from Settings).
    func updateLocalDeviceName(_ name: String) async {
        let gate = await context.syncGate()
        guard gate.account.isFirebaseAvailable, let uid = gate.account.uid else { return }
        let devicesRef = context.firestoreGateway.collection("users").document(uid).collection("devices")
        try? await devicesRef.document(gate.account.deviceId).setData(["deviceName": name], merge: true)
    }

    // MARK: - Device Registry

    private func syncDeviceRegistry(uid: String, localDeviceId: String) async {
        let devicesRef = context.firestoreGateway.collection("users").document(uid).collection("devices")
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
        } catch {
            AppLogger.sync.error("download_sync_nonfatal_failure", metadata: ["error": error.localizedDescription])
        }

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
        } catch {
            AppLogger.sync.error("download_sync_nonfatal_failure", metadata: ["error": error.localizedDescription])
        }
    }

    // MARK: - Provider Account Download

    private func downloadRemoteProviderAccounts(uid: String, localDeviceId: String) async {
        do {
            let snapshot = try await withCloudSyncRetry(
                policy: context.retryPolicy,
                circuitBreaker: context.circuitBreaker,
                domain: "download.providerAccounts"
            ) {
                try await context.firestoreGateway
                    .collection("users")
                    .document(uid)
                    .collection("provider_accounts")
                    .getDocuments()
            }

            for doc in snapshot.documents {
                let data = doc.data()
                guard let account = providerAccount(from: data, documentID: doc.documentID) else { continue }

                if account.sourceDeviceID == localDeviceId,
                   account.storageScope == .deviceKeychain || account.storageScope == .localOnly {
                    continue
                }

                let accountForLocalStore = try appendSafeRemoteAccount(account, localDeviceId: localDeviceId)
                try context.dataStore.providerAccountStore.upsert(accountForLocalStore)
            }
        } catch {
            AppLogger.sync.error("download_sync_nonfatal_failure", metadata: ["error": error.localizedDescription])
        }
    }

    private func appendSafeRemoteAccount(
        _ account: ProviderAccountDoc,
        localDeviceId: String
    ) throws -> ProviderAccountDoc {
        guard let existing = try context.dataStore.providerAccountStore.fetch(id: account.id),
              shouldNamespaceRemoteAccount(account, existing: existing, localDeviceId: localDeviceId) else {
            return account
        }

        let sourcePart = sanitizeDocumentIDPart(
            (account.sourceDeviceID?.isEmpty == false ? account.sourceDeviceID : nil) ?? "remote"
        )
        return ProviderAccountDoc(
            id: "\(account.id)__remote_\(sourcePart)",
            providerID: account.providerID,
            label: account.label,
            identityHint: account.identityHint,
            status: account.status,
            credentialKind: account.credentialKind,
            storageScope: account.storageScope,
            redactedLabel: account.redactedLabel,
            sourceDeviceID: account.sourceDeviceID,
            linkedSwitcherProfileID: account.linkedSwitcherProfileID,
            isDefault: false,
            sortKey: account.sortKey,
            lastValidatedAt: account.lastValidatedAt,
            lastRefreshAt: account.lastRefreshAt,
            lastErrorCode: account.lastErrorCode,
            schemaVersion: account.schemaVersion,
            createdAt: account.createdAt,
            updatedAt: account.updatedAt
        )
    }

    private func shouldNamespaceRemoteAccount(
        _ account: ProviderAccountDoc,
        existing: ProviderAccountDoc,
        localDeviceId: String
    ) -> Bool {
        let localOnlyScopes: Set<ProviderAccountStorageScope> = [.deviceKeychain, .localOnly]
        guard localOnlyScopes.contains(existing.storageScope),
              localOnlyScopes.contains(account.storageScope) else {
            return false
        }
        let existingSource = existing.sourceDeviceID ?? localDeviceId
        guard existingSource == localDeviceId else { return false }
        guard let remoteSource = account.sourceDeviceID, !remoteSource.isEmpty else { return false }
        return remoteSource != localDeviceId
    }

    private func providerAccount(from data: [String: Any], documentID: String) -> ProviderAccountDoc? {
        guard let providerIDRaw = data["providerID"] as? String,
              let label = data["label"] as? String,
              let statusRaw = data["status"] as? String,
              let status = ProviderAccountStatus(rawValue: statusRaw),
              let credentialKindRaw = data["credentialKind"] as? String,
              let credentialKind = CredentialKind(rawValue: credentialKindRaw),
              let storageScopeRaw = data["storageScope"] as? String,
              let storageScope = ProviderAccountStorageScope(rawValue: storageScopeRaw),
              let redactedLabel = data["redactedLabel"] as? String else {
            return nil
        }

        let now = Date()
        return ProviderAccountDoc(
            id: data["id"] as? String ?? documentID,
            providerID: ProviderID(rawValue: providerIDRaw),
            label: label,
            identityHint: data["identityHint"] as? String,
            status: status,
            credentialKind: credentialKind,
            storageScope: storageScope,
            redactedLabel: redactedLabel,
            sourceDeviceID: data["sourceDeviceID"] as? String ?? data["deviceId"] as? String,
            linkedSwitcherProfileID: data["linkedSwitcherProfileID"] as? String,
            isDefault: data["isDefault"] as? Bool ?? false,
            sortKey: data["sortKey"] as? Double ?? Double(data["sortKey"] as? Int ?? 0),
            lastValidatedAt: dateValue(data["lastValidatedAt"]),
            lastRefreshAt: dateValue(data["lastRefreshAt"]),
            lastErrorCode: data["lastErrorCode"] as? String,
            schemaVersion: data["schemaVersion"] as? Int ?? 1,
            createdAt: dateValue(data["createdAt"]) ?? now,
            updatedAt: dateValue(data["updatedAt"]) ?? now
        )
    }

    private func dateValue(_ value: Any?) -> Date? {
        if let timestamp = value as? Timestamp {
            return timestamp.dateValue()
        }
        return value as? Date
    }

    private func sanitizeDocumentIDPart(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: " ", with: "_")
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
            AppLogger.sync.error("download_usage_watermark_fetch_failed", metadata: ["error": error.localizedDescription])
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
        var completedDownload = false

        defer {
            if completedDownload, syncTx.processedCount > 0 {
                do {
                    try syncTx.commit()
                } catch {
                    AppLogger.sync.error("download_sync_tx_commit_failed", metadata: ["accountUid": uid, "collectionKind": "usage", "error": String(describing: error)])
                }
            }
        }

        do {
            var query = context.firestoreGateway.collection("users").document(uid).collection("usage")
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
            // Peer usage rows seal the project name (`sealedProjectName`); resolve the
            // read vault key once so we can open it. Legacy plaintext rows fall back
            // inside `openSealedProjectName`; an un-approved device returns "".
            let usageVaultKey = try? await conversationVaultKeyProvider.keyForReading(uid: uid, deviceId: localDeviceId)

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
                    projectName: CloudVaultCrypto.openSealedProjectName(from: data, keyData: usageVaultKey?.keyData) ?? "",
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
                try context.dataStore.insertRemoteUsage(usage)

                if let updatedAt = (data["updatedAt"] as? Timestamp)?.dateValue() {
                    syncTx.recordProcessedItem(remoteUpdatedAt: updatedAt)
                }
            }
            completedDownload = true
        } catch {
            AppLogger.sync.error("download_sync_nonfatal_failure", metadata: ["error": error.localizedDescription])
        }
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
            AppLogger.sync.error("download_conversation_watermark_fetch_failed", metadata: ["error": error.localizedDescription])
            watermark = Date.distantPast
        }

        let syncTx = AtomicRemoteSyncTransaction(
            dbQueue: context.dataStore.dbQueue,
            watermarkStore: context.dataStore.remoteSyncWatermarkStore,
            accountUid: uid,
            collectionKind: .conversations
        )
        var completedDownload = false

        defer {
            if completedDownload, syncTx.processedCount > 0 {
                do {
                    try syncTx.commit()
                } catch {
                    AppLogger.sync.error("download_sync_tx_commit_failed", metadata: ["accountUid": uid, "collectionKind": "conversations", "error": String(describing: error)])
                }
            }
        }

        do {
            var query: any CloudSyncQueryGateway
            if watermark > Date.distantPast {
                query = context.firestoreGateway.collection("users").document(uid).collection("conversations")
                    .whereField("updatedAt", isGreaterThan: Timestamp(date: watermark)).limit(to: 500)
            } else {
                query = context.firestoreGateway.collection("users").document(uid).collection("conversations")
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
            var vaultKey: CloudVaultResolvedKey?
            // Resolved once per cycle: the PINNED trusted-sender public keys so a conversation
            // written by ANOTHER trusted device verifies its sender signature cross-device
            // (without this, only self-authored docs verify and peer docs fall back to legacy).
            var trustedSenders: [String: Data] = [:]
            var trustedSendersResolved = false

            for doc in snapshot.documents {
                let data = doc.data()
                guard let remoteDeviceId = data["deviceId"] as? String, remoteDeviceId != localDeviceId,
                      let rawProvider = data["provider"] as? String, let provider = AgentProvider(rawValue: rawProvider),
                      let sessionId = data["sessionId"] as? String else { continue }
                guard data["contentSealed"] as? Bool == true,
                      data["sealedPayload"] != nil else {
                    continue
                }
                if vaultKey == nil {
                    vaultKey = try? await conversationVaultKeyProvider.keyForReading(uid: uid, deviceId: localDeviceId)
                }
                if !trustedSendersResolved, let identity = vaultKey?.signalIdentity {
                    trustedSenders = await MacCloudVaultSignalPayloads.trustedSenderPublicKeys(
                        uid: uid, firestore: Firestore.firestore(), localIdentity: identity
                    )
                    trustedSendersResolved = true
                }
                guard let privatePayload = ConversationCloudSealer.open(
                    data, keyData: vaultKey?.keyData,
                    uid: uid, docId: doc.documentID, signalIdentity: vaultKey?.signalIdentity,
                    trustedSenderPublicKeys: trustedSenders
                ) else { continue }
                let id = data["id"] as? String ?? doc.documentID
                let stableId = "\(remoteDeviceId):\(id)"
                let deviceName = nameMap[remoteDeviceId] ?? remoteDeviceId
                let sourceTypeRaw = data["sourceType"] as? String ?? ConversationSourceType.providerLog.rawValue
                let record = ConversationRecord(
                    id: stableId, provider: provider, sessionId: sessionId,
                    projectName: privatePayload.projectName,
                    startTime: (data["startTime"] as? Timestamp)?.dateValue(),
                    endTime: (data["endTime"] as? Timestamp)?.dateValue(),
                    messageCount: data["messageCount"] as? Int ?? 0,
                    userWordCount: data["userWordCount"] as? Int ?? 0,
                    assistantWordCount: data["assistantWordCount"] as? Int ?? 0,
                    keyFiles: privatePayload.keyFiles,
                    keyCommands: privatePayload.keyCommands,
                    keyTools: privatePayload.keyTools,
                    inferredTaskTitle: privatePayload.inferredTaskTitle,
                    lastAssistantMessage: privatePayload.lastAssistantMessage,
                    fullText: "",
                    indexedAt: Date(),
                    workingDirectory: privatePayload.workingDirectory,
                    fileModifiedAt: nil,
                    summary: privatePayload.summary,
                    summaryTitle: privatePayload.summaryTitle,
                    summaryProvider: privatePayload.summaryProvider,
                    summaryModel: privatePayload.summaryModel,
                    sourceType: ConversationSourceType(rawValue: sourceTypeRaw) ?? .providerLog,
                    sourceDeviceId: remoteDeviceId, sourceDeviceName: deviceName, isRemote: true,
                    // Honor a remote tombstone: if device A soft-deleted this
                    // conversation, carry `deletedAt` through so the local copy is
                    // tombstoned too (B-DATA-2 cross-device delete propagation).
                    deletedAt: (data["deletedAt"] as? Timestamp)?.dateValue(),
                    version: data["version"] as? Int ?? 1
                )
                try context.dataStore.insertRemoteConversation(record)
                insertedIds.append(stableId)

                if let updatedAt = (data["updatedAt"] as? Timestamp)?.dateValue() {
                    syncTx.recordProcessedItem(remoteUpdatedAt: updatedAt)
                }
            }
            completedDownload = true
        } catch {
            AppLogger.sync.error("download_sync_nonfatal_failure", metadata: ["error": error.localizedDescription])
        }
        return insertedIds
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
