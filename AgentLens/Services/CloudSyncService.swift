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

    private(set) var isSyncing = false
    private(set) var lastSyncDate: Date?
    private(set) var lastSyncError: String?
    private(set) var cloudTotalCost: Double?
    private(set) var lastCollaborationNotice: SharedArtifactCollaborationNotice?
    private var suppressedSyncUntil: Date?

    // MARK: - Dependencies

    private let dataStore: DataStore
    private let accountManager: AccountManager
    private let settingsManager: SettingsManager

    /// `Firestore.firestore()` is only read from sync methods that guard `accountManager.isFirebaseAvailable` first.
    private var db: Firestore { Firestore.firestore() }

    private struct SharedArtifactSyncReport: Equatable, Sendable {
        var scope: SharedArtifactScope
        var localArtifactsEvaluated: Int = 0
        var remoteArtifactsEvaluated: Int = 0
        var pushed: Int = 0
        var pulled: Int = 0
        var conflicts: Int = 0
        var skipped: Int = 0
    }

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

    private func syncIsSuppressed(now: Date = Date()) -> Bool {
        guard let suppressedSyncUntil else { return false }
        if suppressedSyncUntil > now {
            return true
        }
        self.suppressedSyncUntil = nil
        return false
    }

    private func recordSyncError(_ error: Error) {
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

        do {
            let unsynced = try dataStore.fetchUnsynced()
            guard !unsynced.isEmpty else {
                isSyncing = false
                lastSyncDate = Date()
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

            await downloadRemoteData(uid: uid)
            await fetchCloudTotal(uid: uid)
        } catch {
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

    // MARK: - Shared Artifact Sync
    // Collaboration sync flow:
    // local shared source_artifacts
    //   -> merge decision(local/synced/remote hash)
    //   -> Firestore head write/read with optimistic concurrency checks
    //   -> local sync state + permission snapshot + audit event update
    //   -> enqueue reproject/purge to keep local retrieval parity

    private func pushLocalSharedArtifacts(scope: SharedArtifactScope, report: inout SharedArtifactSyncReport) async throws {
        let localArtifacts = try dataStore.fetchSourceArtifacts(
            includeDeleted: false,
            rootPaths: nil,
            sourceKinds: [.sharedArtifact]
        )
        let collection = sharedArtifactsCollection(scope: scope)

        for artifact in localArtifacts {
            report.localArtifactsEvaluated += 1

            let existingState = try dataStore.fetchSharedArtifactSyncState(sourceArtifactID: artifact.id)
            let remoteArtifactID = resolveRemoteArtifactID(for: artifact, existingState: existingState)
            let remoteRef = collection.document(remoteArtifactID)
            let remoteSnapshot = try await remoteRef.getDocument()
            let remoteRecord = try decodeRemoteRecord(snapshot: remoteSnapshot)
            let decision = SharedArtifactSyncResolver.mergeDecision(
                localContentHash: artifact.contentHash,
                syncedContentHash: existingState?.localContentHashAtSync,
                remoteContentHash: remoteRecord?.contentHash
            )
            let now = Date()
            let resolvedConflict = existingState?.syncStatus == .conflicted
            try ensureOwnerPermissionSnapshot(
                sourceArtifactID: artifact.id,
                remoteArtifactID: remoteArtifactID,
                workspaceID: scope.workspaceID,
                teamID: scope.teamID,
                ownerUserID: existingState?.ownerUserID ?? remoteRecord?.ownerUserID ?? scope.ownerUserID,
                visibility: remoteRecord?.visibility ?? .team,
                occurredAt: now
            )

            switch decision {
            case .noChange:
                try dataStore.upsertSharedArtifactSyncState(
                    SharedArtifactSyncStateRecord(
                        sourceArtifactID: artifact.id,
                        remoteArtifactID: remoteArtifactID,
                        workspaceID: scope.workspaceID,
                        teamID: scope.teamID,
                        ownerUserID: existingState?.ownerUserID ?? remoteRecord?.ownerUserID ?? scope.ownerUserID,
                        revisionID: remoteRecord?.revisionID ?? existingState?.revisionID ?? revisionID(for: artifact),
                        remoteContentHash: remoteRecord?.contentHash ?? artifact.contentHash,
                        localContentHashAtSync: artifact.contentHash,
                        remoteUpdatedAt: remoteRecord?.updatedAt ?? existingState?.remoteUpdatedAt,
                        lastPulledAt: existingState?.lastPulledAt,
                        lastSyncedAt: now,
                        syncStatus: .synced,
                        lastErrorCode: nil,
                        lastErrorMessage: nil,
                        createdAt: existingState?.createdAt ?? now,
                        updatedAt: now
                    )
                )
                if resolvedConflict {
                    try recordSharedArtifactAuditEvent(
                        sourceArtifactID: artifact.id,
                        remoteArtifactID: remoteArtifactID,
                        workspaceID: scope.workspaceID,
                        teamID: scope.teamID,
                        action: .conflictResolved,
                        actorUserID: scope.ownerUserID,
                        message: "Resolved version saved after conflict reconciliation.",
                        metadata: [
                            "resolution": "hash_converged",
                            "path": artifact.relativePath,
                            "revisionID": remoteRecord?.revisionID ?? existingState?.revisionID ?? "",
                            "baseRevisionID": existingState?.revisionID ?? ""
                        ],
                        occurredAt: now
                    )
                    publishCollaborationNotice(
                        kind: .resolvedVersionSaved,
                        sourceArtifactID: artifact.id,
                        remoteArtifactID: remoteArtifactID,
                        message: "Resolved version saved for \(artifact.title).",
                        occurredAt: now
                    )
                }
                report.skipped += 1

            case .pullRemote:
                report.skipped += 1

            case .pushLocal:
                let revisionID = revisionID(for: artifact)
                let baseRevisionID = existingState?.revisionID
                let isCreate = remoteRecord == nil
                let cloudRecord = SharedArtifactCloudRecord(
                    artifactID: remoteArtifactID,
                    workspaceID: scope.workspaceID,
                    teamID: scope.teamID,
                    ownerUserID: existingState?.ownerUserID ?? scope.ownerUserID,
                    visibility: remoteRecord?.visibility ?? .team,
                    revisionID: revisionID,
                    baseRevisionID: baseRevisionID,
                    title: artifact.title,
                    body: artifact.body,
                    contentHash: artifact.contentHash,
                    relativePath: artifact.relativePath,
                    isDeleted: false,
                    updatedByUserID: scope.ownerUserID,
                    updatedByDeviceID: accountManager.deviceId,
                    resolvedConflictRevisionID: resolvedConflict ? baseRevisionID : nil,
                    updatedAt: now
                )

                do {
                    _ = try await commitSharedArtifactHead(
                        remoteRef: remoteRef,
                        cloudRecord: cloudRecord,
                        expectedRevisionID: baseRevisionID
                    )
                } catch {
                    if let stale = SharedArtifactOptimisticWriteGate.conflict(from: error) {
                        var latestRemoteRecord = remoteRecord
                        do {
                            let latestSnapshot = try await remoteRef.getDocument()
                            latestRemoteRecord = try decodeRemoteRecord(snapshot: latestSnapshot)
                        } catch {
                            latestRemoteRecord = remoteRecord
                        }

                        let observedRevisionID = stale.observedRevisionID
                            ?? latestRemoteRecord?.revisionID
                            ?? existingState?.revisionID
                            ?? revisionID
                        try dataStore.upsertSharedArtifactSyncState(
                            SharedArtifactSyncStateRecord(
                                sourceArtifactID: artifact.id,
                                remoteArtifactID: remoteArtifactID,
                                workspaceID: scope.workspaceID,
                                teamID: scope.teamID,
                                ownerUserID: existingState?.ownerUserID ?? latestRemoteRecord?.ownerUserID ?? scope.ownerUserID,
                                revisionID: observedRevisionID,
                                remoteContentHash: latestRemoteRecord?.contentHash,
                                localContentHashAtSync: existingState?.localContentHashAtSync,
                                remoteUpdatedAt: latestRemoteRecord?.updatedAt ?? existingState?.remoteUpdatedAt,
                                lastPulledAt: existingState?.lastPulledAt,
                                lastSyncedAt: existingState?.lastSyncedAt,
                                syncStatus: .conflicted,
                                lastErrorCode: "SHARED_ARTIFACT_STALE_WRITE",
                                lastErrorMessage: "Remote head advanced before local write commit. Pull and resolve before retry.",
                                createdAt: existingState?.createdAt ?? now,
                                updatedAt: now
                            )
                        )
                        try recordSharedArtifactAuditEvent(
                            sourceArtifactID: artifact.id,
                            remoteArtifactID: remoteArtifactID,
                            workspaceID: scope.workspaceID,
                            teamID: scope.teamID,
                            action: .conflictDetected,
                            actorUserID: scope.ownerUserID,
                            message: "Concurrent edit race detected; stale write was rejected.",
                            metadata: [
                                "errorCode": "SHARED_ARTIFACT_STALE_WRITE",
                                "localRevisionID": revisionID,
                                "path": artifact.relativePath,
                                "revisionID": observedRevisionID,
                                "baseRevisionID": stale.expectedRevisionID ?? "",
                                "conflictRevisionID": observedRevisionID
                            ],
                            occurredAt: now
                        )
                        publishCollaborationNotice(
                            kind: .editConflicted,
                            sourceArtifactID: artifact.id,
                            remoteArtifactID: remoteArtifactID,
                            message: "Your edit conflicted for \(artifact.title). Pull remote changes and retry.",
                            occurredAt: now
                        )
                        report.conflicts += 1
                        continue
                    }
                    throw error
                }

                try dataStore.upsertSharedArtifactSyncState(
                    SharedArtifactSyncStateRecord(
                        sourceArtifactID: artifact.id,
                        remoteArtifactID: remoteArtifactID,
                        workspaceID: scope.workspaceID,
                        teamID: scope.teamID,
                        ownerUserID: cloudRecord.ownerUserID,
                        revisionID: revisionID,
                        remoteContentHash: artifact.contentHash,
                        localContentHashAtSync: artifact.contentHash,
                        remoteUpdatedAt: now,
                        lastPulledAt: existingState?.lastPulledAt,
                        lastSyncedAt: now,
                        syncStatus: .synced,
                        lastErrorCode: nil,
                        lastErrorMessage: nil,
                        createdAt: existingState?.createdAt ?? now,
                        updatedAt: now
                    )
                )
                if isCreate {
                    try recordSharedArtifactAuditEvent(
                        sourceArtifactID: artifact.id,
                        remoteArtifactID: remoteArtifactID,
                        workspaceID: scope.workspaceID,
                        teamID: scope.teamID,
                        action: .create,
                        actorUserID: scope.ownerUserID,
                        message: "Shared artifact created from local replica.",
                        metadata: [
                            "path": artifact.relativePath,
                            "sourceKind": artifact.sourceKind.rawValue,
                            "revisionID": revisionID,
                            "baseRevisionID": baseRevisionID ?? "",
                            "updateOrigin": "local"
                        ],
                        occurredAt: now
                    )
                    try recordSharedArtifactAuditEvent(
                        sourceArtifactID: artifact.id,
                        remoteArtifactID: remoteArtifactID,
                        workspaceID: scope.workspaceID,
                        teamID: scope.teamID,
                        action: .share,
                        actorUserID: scope.ownerUserID,
                        message: "Shared artifact visibility published to collaborators.",
                        metadata: [
                            "visibility": cloudRecord.visibility.rawValue,
                            "revisionID": revisionID
                        ],
                        occurredAt: now
                    )
                } else {
                    try recordSharedArtifactAuditEvent(
                        sourceArtifactID: artifact.id,
                        remoteArtifactID: remoteArtifactID,
                        workspaceID: scope.workspaceID,
                        teamID: scope.teamID,
                        action: .update,
                        actorUserID: scope.ownerUserID,
                        message: "Local edit replicated to shared artifact head.",
                        metadata: [
                            "path": artifact.relativePath,
                            "sourceKind": artifact.sourceKind.rawValue,
                            "revisionID": revisionID,
                            "baseRevisionID": baseRevisionID ?? "",
                            "updateOrigin": "local"
                        ],
                        occurredAt: now
                    )
                }
                if resolvedConflict {
                    try recordSharedArtifactAuditEvent(
                        sourceArtifactID: artifact.id,
                        remoteArtifactID: remoteArtifactID,
                        workspaceID: scope.workspaceID,
                        teamID: scope.teamID,
                        action: .conflictResolved,
                        actorUserID: scope.ownerUserID,
                        message: "Resolved version saved after conflict resolution.",
                        metadata: [
                            "resolution": "local_push",
                            "path": artifact.relativePath,
                            "revisionID": revisionID,
                            "baseRevisionID": baseRevisionID ?? "",
                            "conflictRevisionID": baseRevisionID ?? ""
                        ],
                        occurredAt: now
                    )
                    publishCollaborationNotice(
                        kind: .resolvedVersionSaved,
                        sourceArtifactID: artifact.id,
                        remoteArtifactID: remoteArtifactID,
                        message: "Resolved version saved for \(artifact.title).",
                        occurredAt: now
                    )
                }
                report.pushed += 1

            case .conflict:
                try dataStore.upsertSharedArtifactSyncState(
                    SharedArtifactSyncStateRecord(
                        sourceArtifactID: artifact.id,
                        remoteArtifactID: remoteArtifactID,
                        workspaceID: scope.workspaceID,
                        teamID: scope.teamID,
                        ownerUserID: existingState?.ownerUserID ?? remoteRecord?.ownerUserID ?? scope.ownerUserID,
                        revisionID: remoteRecord?.revisionID ?? existingState?.revisionID ?? revisionID(for: artifact),
                        remoteContentHash: remoteRecord?.contentHash,
                        localContentHashAtSync: existingState?.localContentHashAtSync,
                        remoteUpdatedAt: remoteRecord?.updatedAt ?? existingState?.remoteUpdatedAt,
                        lastPulledAt: existingState?.lastPulledAt,
                        lastSyncedAt: existingState?.lastSyncedAt,
                        syncStatus: .conflicted,
                        lastErrorCode: "SHARED_ARTIFACT_DIVERGED",
                        lastErrorMessage: "Local and remote content diverged from the last synced revision.",
                        createdAt: existingState?.createdAt ?? now,
                        updatedAt: now
                    )
                )
                try recordSharedArtifactAuditEvent(
                    sourceArtifactID: artifact.id,
                    remoteArtifactID: remoteArtifactID,
                    workspaceID: scope.workspaceID,
                    teamID: scope.teamID,
                    action: .conflictDetected,
                    actorUserID: scope.ownerUserID,
                    message: "Local and remote edits diverged from the last synced revision.",
                    metadata: [
                        "errorCode": "SHARED_ARTIFACT_DIVERGED",
                        "path": artifact.relativePath,
                        "revisionID": remoteRecord?.revisionID ?? existingState?.revisionID ?? "",
                        "baseRevisionID": existingState?.revisionID ?? "",
                        "conflictRevisionID": remoteRecord?.revisionID ?? ""
                    ],
                    occurredAt: now
                )
                publishCollaborationNotice(
                    kind: .editConflicted,
                    sourceArtifactID: artifact.id,
                    remoteArtifactID: remoteArtifactID,
                    message: "Your edit conflicted for \(artifact.title).",
                    occurredAt: now
                )
                report.conflicts += 1
            }
        }
    }

    private func pullRemoteSharedArtifacts(
        scope: SharedArtifactScope,
        maxRemoteArtifacts: Int,
        report: inout SharedArtifactSyncReport
    ) async throws {
        let snapshot = try await sharedArtifactsCollection(scope: scope)
            .limit(to: max(1, maxRemoteArtifacts))
            .getDocuments()

        for document in snapshot.documents {
            report.remoteArtifactsEvaluated += 1
            let remoteRecord = try SharedArtifactCloudCodec.decode(documentID: document.documentID, data: document.data())
            let existingState = try dataStore.fetchSharedArtifactSyncState(remoteArtifactID: remoteRecord.artifactID)
            let localSourceID = existingState?.sourceArtifactID ?? sourceArtifactID(scope: scope, remoteArtifactID: remoteRecord.artifactID)
            let existingArtifact = try dataStore.fetchSourceArtifact(id: localSourceID, includeDeleted: true)
            let now = Date()
            let resolvedConflict = existingState?.syncStatus == .conflicted
            try ensureOwnerPermissionSnapshot(
                sourceArtifactID: localSourceID,
                remoteArtifactID: remoteRecord.artifactID,
                workspaceID: remoteRecord.workspaceID,
                teamID: remoteRecord.teamID,
                ownerUserID: remoteRecord.ownerUserID ?? existingState?.ownerUserID ?? scope.ownerUserID,
                visibility: remoteRecord.visibility,
                occurredAt: now
            )

            if remoteRecord.isDeleted {
                let localHash = existingArtifact?.status == .deleted ? nil : existingArtifact?.contentHash
                let baseline = existingState?.localContentHashAtSync

                if let localHash, let baseline, localHash != baseline {
                    try dataStore.upsertSharedArtifactSyncState(
                        SharedArtifactSyncStateRecord(
                            sourceArtifactID: localSourceID,
                            remoteArtifactID: remoteRecord.artifactID,
                            workspaceID: remoteRecord.workspaceID,
                            teamID: remoteRecord.teamID,
                            ownerUserID: remoteRecord.ownerUserID ?? existingState?.ownerUserID ?? scope.ownerUserID,
                            revisionID: remoteRecord.revisionID,
                            remoteContentHash: nil,
                            localContentHashAtSync: baseline,
                            remoteUpdatedAt: remoteRecord.updatedAt,
                            lastPulledAt: existingState?.lastPulledAt,
                            lastSyncedAt: existingState?.lastSyncedAt,
                            syncStatus: .conflicted,
                            lastErrorCode: "SHARED_ARTIFACT_DELETE_CONFLICT",
                            lastErrorMessage: "Remote deletion conflicts with unsynced local edits.",
                            createdAt: existingState?.createdAt ?? now,
                            updatedAt: now
                        )
                    )
                    try recordSharedArtifactAuditEvent(
                        sourceArtifactID: localSourceID,
                        remoteArtifactID: remoteRecord.artifactID,
                        workspaceID: remoteRecord.workspaceID,
                        teamID: remoteRecord.teamID,
                        action: .conflictDetected,
                        actorUserID: scope.ownerUserID,
                        message: "Remote deletion conflicted with unsynced local edits.",
                        metadata: [
                            "errorCode": "SHARED_ARTIFACT_DELETE_CONFLICT",
                            "sourceArtifactID": localSourceID,
                            "revisionID": remoteRecord.revisionID,
                            "baseRevisionID": existingState?.revisionID ?? "",
                            "conflictRevisionID": remoteRecord.revisionID
                        ],
                        occurredAt: now
                    )
                    publishCollaborationNotice(
                        kind: .editConflicted,
                        sourceArtifactID: localSourceID,
                        remoteArtifactID: remoteRecord.artifactID,
                        message: "Your edit conflicted with a remote delete.",
                        occurredAt: now
                    )
                    report.conflicts += 1
                    continue
                }

                if let existingArtifact, existingArtifact.status != .deleted {
                    let deletedAt = remoteRecord.updatedAt ?? now
                    if try dataStore.markSourceArtifactDeleted(id: existingArtifact.id, deletedAt: deletedAt) {
                        try enqueueSharedArtifactPurge(sourceArtifactID: existingArtifact.id, now: deletedAt)
                    }
                }

                try dataStore.upsertSharedArtifactSyncState(
                    SharedArtifactSyncStateRecord(
                        sourceArtifactID: localSourceID,
                        remoteArtifactID: remoteRecord.artifactID,
                        workspaceID: remoteRecord.workspaceID,
                        teamID: remoteRecord.teamID,
                        ownerUserID: remoteRecord.ownerUserID ?? existingState?.ownerUserID ?? scope.ownerUserID,
                        revisionID: remoteRecord.revisionID,
                        remoteContentHash: nil,
                        localContentHashAtSync: nil,
                        remoteUpdatedAt: remoteRecord.updatedAt,
                        lastPulledAt: now,
                        lastSyncedAt: existingState?.lastSyncedAt,
                        syncStatus: .synced,
                        lastErrorCode: nil,
                        lastErrorMessage: nil,
                        createdAt: existingState?.createdAt ?? now,
                        updatedAt: now
                    )
                )
                try recordSharedArtifactAuditEvent(
                    sourceArtifactID: localSourceID,
                    remoteArtifactID: remoteRecord.artifactID,
                    workspaceID: remoteRecord.workspaceID,
                    teamID: remoteRecord.teamID,
                    action: .update,
                    actorUserID: remoteRecord.updatedByUserID ?? scope.ownerUserID,
                    message: "Remote update arrived: shared artifact was deleted.",
                    metadata: [
                        "isDeleted": "true",
                        "sourceArtifactID": localSourceID,
                        "revisionID": remoteRecord.revisionID,
                        "baseRevisionID": remoteRecord.baseRevisionID ?? "",
                        "updateOrigin": "remote"
                    ],
                    occurredAt: now
                )
                if resolvedConflict {
                    try recordSharedArtifactAuditEvent(
                        sourceArtifactID: localSourceID,
                        remoteArtifactID: remoteRecord.artifactID,
                        workspaceID: remoteRecord.workspaceID,
                        teamID: remoteRecord.teamID,
                        action: .conflictResolved,
                        actorUserID: scope.ownerUserID,
                        message: "Resolved version saved by accepting remote deletion.",
                        metadata: [
                            "resolution": "remote_delete",
                            "revisionID": remoteRecord.revisionID,
                            "baseRevisionID": existingState?.revisionID ?? "",
                            "conflictRevisionID": existingState?.revisionID ?? ""
                        ],
                        occurredAt: now
                    )
                    publishCollaborationNotice(
                        kind: .resolvedVersionSaved,
                        sourceArtifactID: localSourceID,
                        remoteArtifactID: remoteRecord.artifactID,
                        message: "Resolved version saved after remote delete reconciliation.",
                        occurredAt: now
                    )
                } else {
                    publishCollaborationNotice(
                        kind: .remoteUpdateArrived,
                        sourceArtifactID: localSourceID,
                        remoteArtifactID: remoteRecord.artifactID,
                        message: "Remote update arrived: a shared artifact was deleted.",
                        occurredAt: now
                    )
                }
                report.pulled += 1
                continue
            }

            let decision = SharedArtifactSyncResolver.mergeDecision(
                localContentHash: existingArtifact?.status == .deleted ? nil : existingArtifact?.contentHash,
                syncedContentHash: existingState?.localContentHashAtSync,
                remoteContentHash: remoteRecord.contentHash
            )

            switch decision {
            case .noChange:
                try dataStore.upsertSharedArtifactSyncState(
                    SharedArtifactSyncStateRecord(
                        sourceArtifactID: localSourceID,
                        remoteArtifactID: remoteRecord.artifactID,
                        workspaceID: remoteRecord.workspaceID,
                        teamID: remoteRecord.teamID,
                        ownerUserID: remoteRecord.ownerUserID ?? existingState?.ownerUserID ?? scope.ownerUserID,
                        revisionID: remoteRecord.revisionID,
                        remoteContentHash: remoteRecord.contentHash,
                        localContentHashAtSync: existingArtifact?.contentHash ?? existingState?.localContentHashAtSync,
                        remoteUpdatedAt: remoteRecord.updatedAt,
                        lastPulledAt: existingState?.lastPulledAt,
                        lastSyncedAt: existingState?.lastSyncedAt,
                        syncStatus: .synced,
                        lastErrorCode: nil,
                        lastErrorMessage: nil,
                        createdAt: existingState?.createdAt ?? now,
                        updatedAt: now
                    )
                )
                if resolvedConflict {
                    try recordSharedArtifactAuditEvent(
                        sourceArtifactID: localSourceID,
                        remoteArtifactID: remoteRecord.artifactID,
                        workspaceID: remoteRecord.workspaceID,
                        teamID: remoteRecord.teamID,
                        action: .conflictResolved,
                        actorUserID: scope.ownerUserID,
                        message: "Resolved version saved after local/remote convergence.",
                        metadata: [
                            "resolution": "hash_converged",
                            "sourceArtifactID": localSourceID,
                            "revisionID": remoteRecord.revisionID,
                            "baseRevisionID": existingState?.revisionID ?? "",
                            "conflictRevisionID": existingState?.revisionID ?? ""
                        ],
                        occurredAt: now
                    )
                    publishCollaborationNotice(
                        kind: .resolvedVersionSaved,
                        sourceArtifactID: localSourceID,
                        remoteArtifactID: remoteRecord.artifactID,
                        message: "Resolved version saved for \(remoteRecord.title).",
                        occurredAt: now
                    )
                }
                report.skipped += 1

            case .pushLocal:
                report.skipped += 1

            case .pullRemote:
                let rootPath = sharedRootPath(workspaceID: remoteRecord.workspaceID, teamID: remoteRecord.teamID)
                let relativePath = sharedRelativePath(for: remoteRecord)
                let canonicalPath = rootPath + "/" + relativePath
                let artifact = SourceArtifactRecord(
                    id: localSourceID,
                    sourceKind: .sharedArtifact,
                    canonicalPath: canonicalPath,
                    rootPath: rootPath,
                    relativePath: relativePath,
                    provenance: SharedArtifactCloudCodec.encodeProvenance(
                        workspaceID: remoteRecord.workspaceID,
                        teamID: remoteRecord.teamID,
                        remoteArtifactID: remoteRecord.artifactID,
                        ownerUserID: remoteRecord.ownerUserID ?? scope.ownerUserID
                    ),
                    title: remoteRecord.title,
                    body: remoteRecord.body,
                    contentHash: remoteRecord.contentHash,
                    fileSizeBytes: remoteRecord.body.utf8.count,
                    fileModifiedAt: remoteRecord.updatedAt,
                    status: .active,
                    discoveredAt: now,
                    deletedAt: nil,
                    createdAt: existingArtifact?.createdAt ?? now,
                    updatedAt: now
                )

                let disposition = try dataStore.upsertSourceArtifact(artifact)
                try enqueueProjectionJobForSharedArtifact(artifact, disposition: disposition, now: now)

                try dataStore.upsertSharedArtifactSyncState(
                    SharedArtifactSyncStateRecord(
                        sourceArtifactID: localSourceID,
                        remoteArtifactID: remoteRecord.artifactID,
                        workspaceID: remoteRecord.workspaceID,
                        teamID: remoteRecord.teamID,
                        ownerUserID: remoteRecord.ownerUserID ?? existingState?.ownerUserID ?? scope.ownerUserID,
                        revisionID: remoteRecord.revisionID,
                        remoteContentHash: remoteRecord.contentHash,
                        localContentHashAtSync: remoteRecord.contentHash,
                        remoteUpdatedAt: remoteRecord.updatedAt,
                        lastPulledAt: now,
                        lastSyncedAt: existingState?.lastSyncedAt,
                        syncStatus: .synced,
                        lastErrorCode: nil,
                        lastErrorMessage: nil,
                        createdAt: existingState?.createdAt ?? now,
                        updatedAt: now
                    )
                )
                let createdFromRemote = existingArtifact == nil || existingArtifact?.status == .deleted
                if createdFromRemote {
                    try recordSharedArtifactAuditEvent(
                        sourceArtifactID: localSourceID,
                        remoteArtifactID: remoteRecord.artifactID,
                        workspaceID: remoteRecord.workspaceID,
                        teamID: remoteRecord.teamID,
                        action: .create,
                        actorUserID: remoteRecord.updatedByUserID ?? scope.ownerUserID,
                        message: "Shared artifact created from remote replica.",
                        metadata: [
                            "sourceArtifactID": localSourceID,
                            "disposition": disposition.rawValue,
                            "revisionID": remoteRecord.revisionID,
                            "baseRevisionID": remoteRecord.baseRevisionID ?? "",
                            "updateOrigin": "remote"
                        ],
                        occurredAt: now
                    )
                    try recordSharedArtifactAuditEvent(
                        sourceArtifactID: localSourceID,
                        remoteArtifactID: remoteRecord.artifactID,
                        workspaceID: remoteRecord.workspaceID,
                        teamID: remoteRecord.teamID,
                        action: .share,
                        actorUserID: remoteRecord.updatedByUserID ?? scope.ownerUserID,
                        message: "Shared artifact visibility replicated from remote.",
                        metadata: [
                            "visibility": remoteRecord.visibility.rawValue,
                            "revisionID": remoteRecord.revisionID
                        ],
                        occurredAt: now
                    )
                } else {
                    try recordSharedArtifactAuditEvent(
                        sourceArtifactID: localSourceID,
                        remoteArtifactID: remoteRecord.artifactID,
                        workspaceID: remoteRecord.workspaceID,
                        teamID: remoteRecord.teamID,
                        action: .update,
                        actorUserID: remoteRecord.updatedByUserID ?? scope.ownerUserID,
                        message: "Remote update arrived and was applied to local replica.",
                        metadata: [
                            "sourceArtifactID": localSourceID,
                            "disposition": disposition.rawValue,
                            "revisionID": remoteRecord.revisionID,
                            "baseRevisionID": remoteRecord.baseRevisionID ?? "",
                            "updateOrigin": "remote"
                        ],
                        occurredAt: now
                    )
                }
                if resolvedConflict {
                    try recordSharedArtifactAuditEvent(
                        sourceArtifactID: localSourceID,
                        remoteArtifactID: remoteRecord.artifactID,
                        workspaceID: remoteRecord.workspaceID,
                        teamID: remoteRecord.teamID,
                        action: .conflictResolved,
                        actorUserID: scope.ownerUserID,
                        message: "Resolved version saved by applying the remote update.",
                        metadata: [
                            "resolution": "remote_pull",
                            "sourceArtifactID": localSourceID,
                            "revisionID": remoteRecord.revisionID,
                            "baseRevisionID": existingState?.revisionID ?? "",
                            "conflictRevisionID": existingState?.revisionID ?? ""
                        ],
                        occurredAt: now
                    )
                    publishCollaborationNotice(
                        kind: .resolvedVersionSaved,
                        sourceArtifactID: localSourceID,
                        remoteArtifactID: remoteRecord.artifactID,
                        message: "Resolved version saved after applying remote updates for \(remoteRecord.title).",
                        occurredAt: now
                    )
                } else {
                    publishCollaborationNotice(
                        kind: .remoteUpdateArrived,
                        sourceArtifactID: localSourceID,
                        remoteArtifactID: remoteRecord.artifactID,
                        message: "Remote update arrived for \(remoteRecord.title).",
                        occurredAt: now
                    )
                }
                report.pulled += 1

            case .conflict:
                try dataStore.upsertSharedArtifactSyncState(
                    SharedArtifactSyncStateRecord(
                        sourceArtifactID: localSourceID,
                        remoteArtifactID: remoteRecord.artifactID,
                        workspaceID: remoteRecord.workspaceID,
                        teamID: remoteRecord.teamID,
                        ownerUserID: remoteRecord.ownerUserID ?? existingState?.ownerUserID ?? scope.ownerUserID,
                        revisionID: remoteRecord.revisionID,
                        remoteContentHash: remoteRecord.contentHash,
                        localContentHashAtSync: existingState?.localContentHashAtSync,
                        remoteUpdatedAt: remoteRecord.updatedAt,
                        lastPulledAt: existingState?.lastPulledAt,
                        lastSyncedAt: existingState?.lastSyncedAt,
                        syncStatus: .conflicted,
                        lastErrorCode: "SHARED_ARTIFACT_DIVERGED",
                        lastErrorMessage: "Remote update conflicts with unsynced local edits.",
                        createdAt: existingState?.createdAt ?? now,
                        updatedAt: now
                    )
                )
                try recordSharedArtifactAuditEvent(
                    sourceArtifactID: localSourceID,
                    remoteArtifactID: remoteRecord.artifactID,
                    workspaceID: remoteRecord.workspaceID,
                    teamID: remoteRecord.teamID,
                    action: .conflictDetected,
                    actorUserID: scope.ownerUserID,
                    message: "Remote update conflicted with unsynced local edits.",
                    metadata: [
                        "errorCode": "SHARED_ARTIFACT_DIVERGED",
                        "sourceArtifactID": localSourceID,
                        "revisionID": remoteRecord.revisionID,
                        "baseRevisionID": existingState?.revisionID ?? "",
                        "conflictRevisionID": remoteRecord.revisionID
                    ],
                    occurredAt: now
                )
                publishCollaborationNotice(
                    kind: .editConflicted,
                    sourceArtifactID: localSourceID,
                    remoteArtifactID: remoteRecord.artifactID,
                    message: "Your edit conflicted for \(remoteRecord.title).",
                    occurredAt: now
                )
                report.conflicts += 1
            }
        }
    }

    private func ensureOwnerPermissionSnapshot(
        sourceArtifactID: String,
        remoteArtifactID: String,
        workspaceID: String,
        teamID: String,
        ownerUserID: String?,
        visibility: SharedArtifactVisibility,
        occurredAt: Date
    ) throws {
        guard
            let ownerUserID = ownerUserID?.trimmingCharacters(in: .whitespacesAndNewlines),
            ownerUserID.isEmpty == false
        else {
            return
        }

        var changedPrincipals: [String] = []

        let ownerDisposition = try dataStore.upsertSharedArtifactPermission(
            SharedArtifactPermissionRecord(
                sourceArtifactID: sourceArtifactID,
                workspaceID: workspaceID,
                teamID: teamID,
                principalType: .user,
                principalID: ownerUserID,
                role: .owner,
                visibility: visibility,
                canRead: true,
                canWrite: true,
                canShare: true,
                updatedAt: occurredAt
            )
        )
        if ownerDisposition != .unchanged {
            changedPrincipals.append("user:\(ownerUserID)")
        }

        let workspaceDisposition = try dataStore.upsertSharedArtifactPermission(
            SharedArtifactPermissionRecord(
                sourceArtifactID: sourceArtifactID,
                workspaceID: workspaceID,
                teamID: teamID,
                principalType: .workspace,
                principalID: workspaceID,
                role: .viewer,
                visibility: .workspace,
                canRead: visibility == .workspace,
                canWrite: false,
                canShare: false,
                updatedAt: occurredAt
            )
        )
        if workspaceDisposition != .unchanged {
            changedPrincipals.append("workspace:\(workspaceID)")
        }

        let teamDisposition = try dataStore.upsertSharedArtifactPermission(
            SharedArtifactPermissionRecord(
                sourceArtifactID: sourceArtifactID,
                workspaceID: workspaceID,
                teamID: teamID,
                principalType: .team,
                principalID: teamID,
                role: .viewer,
                visibility: .team,
                canRead: visibility == .team,
                canWrite: false,
                canShare: false,
                updatedAt: occurredAt
            )
        )
        if teamDisposition != .unchanged {
            changedPrincipals.append("team:\(teamID)")
        }

        guard changedPrincipals.isEmpty == false else { return }
        try recordSharedArtifactAuditEvent(
            sourceArtifactID: sourceArtifactID,
            remoteArtifactID: remoteArtifactID,
            workspaceID: workspaceID,
            teamID: teamID,
            action: .permissionChange,
            actorUserID: ownerUserID,
            message: "Shared artifact permission snapshot updated.",
            metadata: [
                "visibility": visibility.rawValue,
                "changedPrincipals": changedPrincipals.joined(separator: ",")
            ],
            occurredAt: occurredAt
        )
    }

    private func commitSharedArtifactHead(
        remoteRef: DocumentReference,
        cloudRecord: SharedArtifactCloudRecord,
        expectedRevisionID: String?
    ) async throws -> String? {
        let payload = SharedArtifactCloudCodec.encode(cloudRecord, useServerTimestamp: true)
        return try await withCheckedThrowingContinuation { continuation in
            db.runTransaction({ transaction, errorPointer in
                let snapshot: DocumentSnapshot
                do {
                    snapshot = try transaction.getDocument(remoteRef)
                } catch {
                    errorPointer?.pointee = error as NSError
                    return nil
                }

                let observedRevisionID: String?
                do {
                    let observed = try self.decodeRemoteRecord(snapshot: snapshot)
                    observedRevisionID = observed?.revisionID
                } catch {
                    errorPointer?.pointee = error as NSError
                    return nil
                }

                do {
                    try SharedArtifactOptimisticWriteGate.validate(
                        expectedRevisionID: expectedRevisionID,
                        observedRevisionID: observedRevisionID
                    )
                } catch {
                    errorPointer?.pointee = error as NSError
                    return nil
                }

                transaction.setData(payload, forDocument: remoteRef)
                transaction.setData(
                    payload,
                    forDocument: remoteRef.collection("versions").document(cloudRecord.revisionID)
                )
                return observedRevisionID ?? NSNull()
            }) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: result as? String)
            }
        }
    }

    private func publishCollaborationNotice(
        kind: SharedArtifactCollaborationNoticeKind,
        sourceArtifactID: String,
        remoteArtifactID: String,
        message: String,
        occurredAt: Date
    ) {
        lastCollaborationNotice = SharedArtifactCollaborationNotice(
            kind: kind,
            sourceArtifactID: sourceArtifactID,
            remoteArtifactID: remoteArtifactID,
            message: message,
            occurredAt: occurredAt
        )
    }

    private func recordSharedArtifactAuditEvent(
        sourceArtifactID: String?,
        remoteArtifactID: String?,
        workspaceID: String,
        teamID: String,
        action: SharedArtifactAuditAction,
        actorUserID: String?,
        message: String,
        metadata: [String: String],
        occurredAt: Date
    ) throws {
        var details = metadata
        details["message"] = message
        let detailsJSON = try encodeAuditMetadata(details)
        try dataStore.appendSharedArtifactAuditEvent(
            SharedArtifactAuditEventRecord(
                id: "shared-audit-\(UUID().uuidString.lowercased())",
                sourceArtifactID: sourceArtifactID,
                remoteArtifactID: remoteArtifactID,
                workspaceID: workspaceID,
                teamID: teamID,
                actorUserID: actorUserID,
                actorRole: nil,
                action: action,
                detailsJSON: detailsJSON,
                occurredAt: occurredAt,
                createdAt: occurredAt
            )
        )
    }

    private func encodeAuditMetadata(_ metadata: [String: String]) throws -> String? {
        guard metadata.isEmpty == false else { return nil }
        let data = try JSONEncoder().encode(metadata)
        return String(data: data, encoding: .utf8)
    }

    private func enqueueProjectionJobForSharedArtifact(
        _ artifact: SourceArtifactRecord,
        disposition: SourceArtifactWriteDisposition,
        now: Date
    ) throws {
        let jobType: ProjectionJobType
        switch disposition {
        case .inserted:
            jobType = .project
        case .updated, .restored:
            jobType = .reproject
        case .unchanged:
            return
        }

        let sourceVersionID = ProjectionIdentity.artifactSourceVersionID(contentHash: artifact.contentHash)
        let jobID = ProjectionIdentity.jobID(
            jobType: jobType,
            sourceKind: .sharedArtifact,
            sourceID: artifact.id,
            sourceVersionID: sourceVersionID
        )

        try dataStore.enqueueProjectionJob(
            ProjectionJobRecord(
                id: jobID,
                jobType: jobType,
                sourceKind: .sharedArtifact,
                sourceID: artifact.id,
                sourceVersionID: sourceVersionID,
                status: .queued,
                priority: 8,
                attempts: 0,
                maxAttempts: 5,
                scheduledAt: now,
                availableAt: now,
                createdAt: now,
                updatedAt: now
            )
        )
        if jobType == .reproject,
           let syncState = try dataStore.fetchSharedArtifactSyncState(sourceArtifactID: artifact.id) {
            try recordSharedArtifactAuditEvent(
                sourceArtifactID: artifact.id,
                remoteArtifactID: syncState.remoteArtifactID,
                workspaceID: syncState.workspaceID,
                teamID: syncState.teamID,
                action: .rebuild,
                actorUserID: syncState.ownerUserID,
                message: "Reproject job queued for shared artifact rebuild.",
                metadata: [
                    "jobType": jobType.rawValue,
                    "jobID": jobID,
                    "sourceVersionID": sourceVersionID
                ],
                occurredAt: now
            )
        }
    }

    private func enqueueSharedArtifactPurge(sourceArtifactID: String, now: Date) throws {
        let sourceVersionID = ProjectionIdentity.deletedSourceVersionID
        let jobID = ProjectionIdentity.jobID(
            jobType: .purge,
            sourceKind: .sharedArtifact,
            sourceID: sourceArtifactID,
            sourceVersionID: sourceVersionID
        )
        try dataStore.enqueueProjectionJob(
            ProjectionJobRecord(
                id: jobID,
                jobType: .purge,
                sourceKind: .sharedArtifact,
                sourceID: sourceArtifactID,
                sourceVersionID: sourceVersionID,
                status: .queued,
                priority: 3,
                attempts: 0,
                maxAttempts: 5,
                scheduledAt: now,
                availableAt: now,
                createdAt: now,
                updatedAt: now
            )
        )
        if let syncState = try dataStore.fetchSharedArtifactSyncState(sourceArtifactID: sourceArtifactID) {
            try recordSharedArtifactAuditEvent(
                sourceArtifactID: sourceArtifactID,
                remoteArtifactID: syncState.remoteArtifactID,
                workspaceID: syncState.workspaceID,
                teamID: syncState.teamID,
                action: .rebuild,
                actorUserID: syncState.ownerUserID,
                message: "Purge job queued for shared artifact rebuild.",
                metadata: [
                    "jobType": ProjectionJobType.purge.rawValue,
                    "jobID": jobID,
                    "sourceVersionID": sourceVersionID
                ],
                occurredAt: now
            )
        }
    }

    private func sharedArtifactsCollection(scope: SharedArtifactScope) -> CollectionReference {
        db.collection("workspaces")
            .document(scope.workspaceID)
            .collection("teams")
            .document(scope.teamID)
            .collection("artifacts")
    }

    private func resolveRemoteArtifactID(
        for artifact: SourceArtifactRecord,
        existingState: SharedArtifactSyncStateRecord?
    ) -> String {
        if let stateID = existingState?.remoteArtifactID, stateID.isEmpty == false {
            return stateID
        }
        if let decoded = SharedArtifactCloudCodec.decodeProvenance(artifact.provenance),
           decoded.remoteArtifactID.isEmpty == false {
            return decoded.remoteArtifactID
        }
        return artifact.id
    }

    private func sourceArtifactID(scope: SharedArtifactScope, remoteArtifactID: String) -> String {
        let seed = "\(scope.workspaceID)|\(scope.teamID)|\(remoteArtifactID)"
        return "shared-artifact-\(ProjectionIdentity.sha256Hex(seed))"
    }

    private func revisionID(for artifact: SourceArtifactRecord) -> String {
        let seed = "\(artifact.id)|\(artifact.contentHash)|\(artifact.updatedAt.timeIntervalSince1970)"
        return "rev-\(ProjectionIdentity.sha256Hex(seed))"
    }

    private func sharedRootPath(workspaceID: String, teamID: String) -> String {
        "shared://\(workspaceID)/\(teamID)"
    }

    private func sharedRelativePath(for remoteRecord: SharedArtifactCloudRecord) -> String {
        if let relativePath = remoteRecord.relativePath?.trimmingCharacters(in: .whitespacesAndNewlines),
           relativePath.isEmpty == false {
            return relativePath
        }
        return "\(remoteRecord.artifactID).md"
    }

    private func decodeRemoteRecord(snapshot: DocumentSnapshot) throws -> SharedArtifactCloudRecord? {
        guard snapshot.exists else { return nil }
        return try SharedArtifactCloudCodec.decode(documentID: snapshot.documentID, data: snapshot.data() ?? [:])
    }

    private struct CollaborationHealthDetails: Codable {
        let cloudAvailable: Bool
        let workspaceID: String?
        let teamID: String?
        let localArtifactsEvaluated: Int
        let remoteArtifactsEvaluated: Int
        let pushed: Int
        let pulled: Int
        let conflicts: Int
        let skipped: Int
    }

    private func upsertCollaborationHealth(
        status: RetrievalHealthStatus,
        errorCode: String?,
        errorMessage: String?,
        report: SharedArtifactSyncReport?,
        cloudAvailable: Bool
    ) throws {
        let details = CollaborationHealthDetails(
            cloudAvailable: cloudAvailable,
            workspaceID: report?.scope.workspaceID,
            teamID: report?.scope.teamID,
            localArtifactsEvaluated: report?.localArtifactsEvaluated ?? 0,
            remoteArtifactsEvaluated: report?.remoteArtifactsEvaluated ?? 0,
            pushed: report?.pushed ?? 0,
            pulled: report?.pulled ?? 0,
            conflicts: report?.conflicts ?? 0,
            skipped: report?.skipped ?? 0
        )
        let detailsJSON = String(data: try JSONEncoder().encode(details), encoding: .utf8)
        let now = Date()

        try dataStore.upsertRetrievalHealth(
            RetrievalHealthRecord(
                subsystem: .collaboration,
                status: status,
                errorCode: errorCode,
                errorMessage: errorMessage,
                detailsJSON: detailsJSON,
                observedAt: now,
                updatedAt: now
            )
        )
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

        await MainActor.run { dataStore.refresh() }
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

    // MARK: - Session Log Upload (full Markdown, chunked)

    /// Uploads full session-log Markdown bodies to Firestore.
    /// Layout: `users/{uid}/session_logs/{deviceId}_{escapedId}` (manifest)
    ///         `users/{uid}/session_logs/{docId}/chunks/{index}` (body chunks)
    ///
    /// Gated separately on `sessionLogCloudBackupEnabled`.
    /// Uses its own dirty flag (`logSyncedAt`) so it is independent of metadata sync.
    func uploadPendingSessionLogs() async {
        guard accountManager.isFirebaseAvailable,
              accountManager.isSignedIn,
              accountManager.isCloudSyncEnabled,
              settingsManager.sessionLogCloudBackupEnabled,
              !syncIsSuppressed(),
              !isSyncing,
              let uid = Auth.auth().currentUser?.uid else { return }

        isSyncing = true
        lastSyncError = nil

        do {
            let unsynced = try dataStore.fetchUnsyncedSessionLogs(limit: 50)
            guard !unsynced.isEmpty else {
                isSyncing = false
                lastSyncDate = Date()
                return
            }

            let deviceId = accountManager.deviceId
            let logsRef = db.collection("users").document(uid).collection("session_logs")

            for record in unsynced {
                let markdown = SessionLogMarkdownFormatter.markdown(for: record)
                let safeId = record.id
                    .replacingOccurrences(of: ":", with: "_")
                    .replacingOccurrences(of: "/", with: "_")
                let docId = "\(deviceId)_\(safeId)"
                let manifestRef = logsRef.document(docId)

                let chunks = Self.chunkUTF8String(markdown, maxBytes: 900_000)

                // Write manifest
                var manifest: [String: Any] = [
                    "id": record.id,
                    "deviceId": deviceId,
                    "provider": record.provider.rawValue,
                    "sourceType": record.sourceType.rawValue,
                    "projectName": record.projectName,
                    "inferredTaskTitle": record.inferredTaskTitle,
                    "messageCount": record.messageCount,
                    "chunkCount": chunks.count,
                    "byteCount": markdown.utf8.count,
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
                if let safeStart { manifest["startTime"] = Timestamp(date: safeStart) }
                if let safeEnd { manifest["endTime"] = Timestamp(date: safeEnd) }

                try await manifestRef.setData(manifest, merge: true)

                // Write chunks as sub-documents
                let chunksRef = manifestRef.collection("chunks")
                for (idx, chunk) in chunks.enumerated() {
                    try await chunksRef.document(String(idx)).setData([
                        "index": idx,
                        "body": chunk,
                        "updatedAt": FieldValue.serverTimestamp()
                    ], merge: true)
                }
            }

            let ids = unsynced.map(\.id)
            try dataStore.markSessionLogsSynced(ids: ids)
            lastSyncDate = Date()
            lastSyncError = nil
        } catch {
            recordSyncError(error)
        }

        isSyncing = false
    }

    // MARK: - Session Log Download (Firestore read-back)

    /// Fetches session log manifests from Firestore for the signed-in user.
    /// Returns ConversationRecords with empty fullText; body is fetched lazily via fetchCloudSessionLogBody(docId:).
    func fetchCloudSessionLogs(limit: Int = 200) async throws -> [ConversationRecord] {
        guard accountManager.isFirebaseAvailable,
              accountManager.isSignedIn,
              let uid = Auth.auth().currentUser?.uid else { return [] }

        let snapshot = try await db
            .collection("users")
            .document(uid)
            .collection("session_logs")
            .order(by: "updatedAt", descending: true)
            .limit(to: limit)
            .getDocuments()

        return snapshot.documents.compactMap { doc -> ConversationRecord? in
            let data = doc.data()
            guard let rawProvider = data["provider"] as? String,
                  let provider = AgentProvider(rawValue: rawProvider) else { return nil }

            let id = data["id"] as? String ?? doc.documentID
            let sourceTypeRaw = data["sourceType"] as? String ?? ConversationSourceType.providerLog.rawValue
            let sourceType = ConversationSourceType(rawValue: sourceTypeRaw) ?? .providerLog

            return ConversationRecord(
                id: id,
                provider: provider,
                // Store Firestore docId in sessionId so fetchCloudSessionLogBody can look up chunks
                sessionId: doc.documentID,
                projectName: data["projectName"] as? String ?? "",
                startTime: (data["startTime"] as? Timestamp)?.dateValue(),
                endTime: (data["endTime"] as? Timestamp)?.dateValue(),
                messageCount: data["messageCount"] as? Int ?? 0,
                userWordCount: 0,
                assistantWordCount: 0,
                keyFiles: [],
                keyCommands: [],
                keyTools: [],
                inferredTaskTitle: data["inferredTaskTitle"] as? String ?? "",
                lastAssistantMessage: "",
                fullText: "",
                indexedAt: Date(),
                fileModifiedAt: nil,
                summary: nil,
                sourceType: sourceType
            )
        }
    }

    /// Reassembles chunk sub-documents into the full Markdown body for a session log.
    /// - Parameter docId: The Firestore document ID (stored in `record.sessionId` for cloud-sourced records).
    func fetchCloudSessionLogBody(docId: String) async throws -> String {
        guard accountManager.isFirebaseAvailable,
              let uid = Auth.auth().currentUser?.uid else { return "" }

        let snapshot = try await db
            .collection("users")
            .document(uid)
            .collection("session_logs")
            .document(docId)
            .collection("chunks")
            .order(by: "index")
            .getDocuments()

        return snapshot.documents
            .compactMap { $0.data()["body"] as? String }
            .joined()
    }

    // MARK: - Chunking

    /// Splits a UTF-8 string into chunks each fitting within `maxBytes` bytes.
    private static func chunkUTF8String(_ string: String, maxBytes: Int) -> [String] {
        let data = Data(string.utf8)
        guard data.count > maxBytes else { return [string] }

        var chunks: [String] = []
        var offset = 0
        while offset < data.count {
            var end = min(offset + maxBytes, data.count)
            // Walk back until we find a valid UTF-8 boundary
            while end > offset, String(data: data[offset..<end], encoding: .utf8) == nil {
                end -= 1
            }
            if let chunk = String(data: data[offset..<end], encoding: .utf8) {
                chunks.append(chunk)
            }
            offset = end
        }
        return chunks.isEmpty ? [string] : chunks
    }
}
