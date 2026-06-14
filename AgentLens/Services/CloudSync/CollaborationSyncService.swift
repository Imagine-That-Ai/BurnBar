import FirebaseAuth
import FirebaseFirestore
import Foundation
import OpenBurnBarCore

/// Sync domain for synchronizing shared/team artifacts between local cache and Firestore.
///
/// Collaboration sync flow:
/// local shared source_artifacts
///   -> merge decision(local/synced/remote hash)
///   -> Firestore head write/read with optimistic concurrency checks
///   -> local sync state + permission snapshot + audit event update
///   -> enqueue reproject/purge to keep local retrieval parity
final class CollaborationSyncService: CloudSyncDomain, Sendable {
    private let context: CloudSyncContext

    private let state = Locked(CloudSyncDomainState())

    var isSyncing: Bool { state.read().isSyncing }
    var lastSyncError: String? { state.read().lastSyncError }
    var lastSyncDate: Date? { state.read().lastSyncDate }
    private let lastCollaborationNoticeBox = Locked<SharedArtifactCollaborationNotice?>(nil)
    var lastCollaborationNotice: SharedArtifactCollaborationNotice? { lastCollaborationNoticeBox.read() }

    /// Maximum remote artifacts to pull per sync cycle.
    private let maxRemoteArtifactsBox = Locked(300)
    var maxRemoteArtifacts: Int {
        get { maxRemoteArtifactsBox.read() }
        set { maxRemoteArtifactsBox.write(newValue) }
    }

    init(context: CloudSyncContext) {
        self.context = context
    }

    func sync() async {
        await syncSharedArtifacts(maxRemoteArtifacts: maxRemoteArtifacts)
    }

    func syncSharedArtifacts(maxRemoteArtifacts: Int = 300) async {
        guard !isSyncing else { return }

        let gate = await context.syncGate()
        guard !gate.syncSuppressed else { return }

        let firebaseAvailable = gate.account.isFirebaseAvailable
        let signedIn = gate.account.isSignedIn
        let cloudEnabled = gate.account.isCloudSyncEnabled
        let uid: String? = firebaseAvailable ? gate.account.uid : nil

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

            state.withLock { $0.lastSyncError = message }
            do {
                try upsertCollaborationHealth(
                    status: .degraded,
                    errorCode: errorCode,
                    errorMessage: message,
                    report: nil,
                    cloudAvailable: false
                )
            } catch {
                state.withLock { $0.lastSyncError = "\(message) Health persistence failed: \(error.localizedDescription)" }
            }
            return
        }

        guard state.beginSyncingIfIdle() else { return }
        let scope = SharedArtifactScope.defaultScope(for: uid)
        var report = SharedArtifactSyncReport(scope: scope)
        let deviceId = gate.account.deviceId

        defer {
            state.endSyncing()
        }

        do {
            try await pushLocalSharedArtifacts(scope: scope, deviceId: deviceId, report: &report)
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

            state.withLock {
                $0.lastSyncDate = Date()
                $0.lastSyncError = errorMessage
            }
        } catch {
            let syncError = error
            await recordSyncError(syncError)
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
                state.withLock { $0.lastSyncError = "\(syncError.localizedDescription) Health persistence failed: \(healthError.localizedDescription)" }
            }
        }
    }

    private func recordSyncError(_ error: Error) async {
        state.withLock { $0.lastSyncError = error.localizedDescription }

        let nsError = error as NSError
        guard nsError.domain == FirestoreErrorDomain,
              let code = FirestoreErrorCode.Code(rawValue: nsError.code),
              code == .permissionDenied || code == .unauthenticated else {
            return
        }
        await context.suppressSync(for: CloudSyncBackoffPolicy.permissionDeniedCooldown)
    }

    // MARK: - Shared Artifact Sync

    func pushLocalSharedArtifacts(scope: SharedArtifactScope, deviceId: String, report: inout SharedArtifactSyncReport) async throws {
        let localArtifacts = try context.dataStore.fetchSourceArtifacts(
            includeDeleted: false,
            rootPaths: nil,
            sourceKinds: [.sharedArtifact]
        )
        let collection = sharedArtifactsCollection(scope: scope)

        for artifact in localArtifacts {
            report.localArtifactsEvaluated += 1

            let existingState = try context.dataStore.fetchSharedArtifactSyncState(sourceArtifactID: artifact.id)
            let remoteArtifactID = resolveRemoteArtifactID(for: artifact, existingState: existingState)
            let remoteRef = collection.document(remoteArtifactID)
            let remoteData = try await remoteRef.getData()
            let remoteRecord = try decodeRemoteRecord(documentID: remoteArtifactID, data: remoteData)
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
                try context.dataStore.upsertSharedArtifactSyncState(
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
                    updatedByDeviceID: deviceId,
                    resolvedConflictRevisionID: resolvedConflict ? baseRevisionID : nil,
                    updatedAt: now
                )

                do {
                    _ = try await commitSharedArtifactHead(
                        artifactsCollection: collection,
                        remoteArtifactID: remoteArtifactID,
                        cloudRecord: cloudRecord,
                        expectedRevisionID: baseRevisionID
                    )
                } catch {
                    if let stale = SharedArtifactOptimisticWriteGate.conflict(from: error) {
                        var latestRemoteRecord = remoteRecord
                        do {
                            let latestData = try await remoteRef.getData()
                            latestRemoteRecord = try decodeRemoteRecord(documentID: remoteArtifactID, data: latestData)
                        } catch {
                            latestRemoteRecord = remoteRecord
                        }

                        let observedRevisionID = stale.observedRevisionID
                            ?? latestRemoteRecord?.revisionID
                            ?? existingState?.revisionID
                            ?? revisionID
                        try context.dataStore.upsertSharedArtifactSyncState(
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

                try context.dataStore.upsertSharedArtifactSyncState(
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
                try context.dataStore.upsertSharedArtifactSyncState(
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

    func pullRemoteSharedArtifacts(
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
            let existingState = try context.dataStore.fetchSharedArtifactSyncState(remoteArtifactID: remoteRecord.artifactID)
            let localSourceID = existingState?.sourceArtifactID ?? sourceArtifactID(scope: scope, remoteArtifactID: remoteRecord.artifactID)
            let existingArtifact = try context.dataStore.fetchSourceArtifact(id: localSourceID, includeDeleted: true)
            let now = Date()
            let resolvedConflict = existingState?.syncStatus == .conflicted
            if existingArtifact != nil {
                try ensureOwnerPermissionSnapshot(
                    sourceArtifactID: localSourceID,
                    remoteArtifactID: remoteRecord.artifactID,
                    workspaceID: remoteRecord.workspaceID,
                    teamID: remoteRecord.teamID,
                    ownerUserID: remoteRecord.ownerUserID ?? existingState?.ownerUserID ?? scope.ownerUserID,
                    visibility: remoteRecord.visibility,
                    occurredAt: now
                )
            }

            if remoteRecord.isDeleted {
                let localHash = existingArtifact?.status == .deleted ? nil : existingArtifact?.contentHash
                let baseline = existingState?.localContentHashAtSync

                if let localHash, let baseline, localHash != baseline {
                    try context.dataStore.upsertSharedArtifactSyncState(
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
                    if try context.dataStore.markSourceArtifactDeleted(id: existingArtifact.id, deletedAt: deletedAt) {
                        try enqueueSharedArtifactPurge(sourceArtifactID: existingArtifact.id, now: deletedAt)
                    }
                }

                try context.dataStore.upsertSharedArtifactSyncState(
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
                try context.dataStore.upsertSharedArtifactSyncState(
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

                let disposition = try context.dataStore.upsertSourceArtifact(artifact)
                try enqueueProjectionJobForSharedArtifact(artifact, disposition: disposition, now: now)
                try ensureOwnerPermissionSnapshot(
                    sourceArtifactID: localSourceID,
                    remoteArtifactID: remoteRecord.artifactID,
                    workspaceID: remoteRecord.workspaceID,
                    teamID: remoteRecord.teamID,
                    ownerUserID: remoteRecord.ownerUserID ?? existingState?.ownerUserID ?? scope.ownerUserID,
                    visibility: remoteRecord.visibility,
                    occurredAt: now
                )

                try context.dataStore.upsertSharedArtifactSyncState(
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
                try context.dataStore.upsertSharedArtifactSyncState(
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

        let ownerDisposition = try context.dataStore.upsertSharedArtifactPermission(
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

        let workspaceDisposition = try context.dataStore.upsertSharedArtifactPermission(
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

        let teamDisposition = try context.dataStore.upsertSharedArtifactPermission(
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
        artifactsCollection: CloudSyncCollectionGateway,
        remoteArtifactID: String,
        cloudRecord: SharedArtifactCloudRecord,
        expectedRevisionID: String?
    ) async throws -> String? {
        let headDoc = artifactsCollection.document(remoteArtifactID)
        let existingData = try await headDoc.getData()
        let observedRecord = try decodeRemoteRecord(documentID: remoteArtifactID, data: existingData)
        let observedRevisionID = observedRecord?.revisionID

        try SharedArtifactOptimisticWriteGate.validate(
            expectedRevisionID: expectedRevisionID,
            observedRevisionID: observedRevisionID
        )

        let payload = SharedArtifactCloudCodec.encode(cloudRecord, useServerTimestamp: true)
        try await headDoc.setData(payload, merge: true)
        try await headDoc.collection("versions").document(cloudRecord.revisionID).setData(payload, merge: true)
        return observedRevisionID
    }

    private func publishCollaborationNotice(
        kind: SharedArtifactCollaborationNoticeKind,
        sourceArtifactID: String,
        remoteArtifactID: String,
        message: String,
        occurredAt: Date
    ) {
        lastCollaborationNoticeBox.write(SharedArtifactCollaborationNotice(
            kind: kind,
            sourceArtifactID: sourceArtifactID,
            remoteArtifactID: remoteArtifactID,
            message: message,
            occurredAt: occurredAt
        ))
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
        try context.dataStore.appendSharedArtifactAuditEvent(
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

        try context.dataStore.enqueueProjectionJob(
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
           let syncState = try context.dataStore.fetchSharedArtifactSyncState(sourceArtifactID: artifact.id) {
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
        try context.dataStore.enqueueProjectionJob(
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
        if let syncState = try context.dataStore.fetchSharedArtifactSyncState(sourceArtifactID: sourceArtifactID) {
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

    private func sharedArtifactsCollection(scope: SharedArtifactScope) -> CloudSyncCollectionGateway {
        context.firestoreGateway
            .collection("workspaces")
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

    private func decodeRemoteRecord(documentID: String, data: [String: Any]?) throws -> SharedArtifactCloudRecord? {
        guard let data, data.isEmpty == false else { return nil }
        return try SharedArtifactCloudCodec.decode(documentID: documentID, data: data)
    }

    func upsertCollaborationHealth(
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

        try context.dataStore.upsertRetrievalHealth(
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
}
