import FirebaseAuth
import FirebaseFirestore
import Foundation
import OpenBurnBarCore

/// Sync domain for uploading local TokenUsage rows to Firestore.
///
/// Firestore layout: `users/{uid}/usage/{deviceId}_{usageId}`
///
/// Project names are private text BurnBar must not be able to read. They are
/// sealed with the per-user Cloud Vault key (`sealedProjectName`) instead of
/// being written in plaintext. An opaque keyed `projectKeyHash` is also written
/// so on-device readers can group usage by project without decrypting every row.
extension Notification.Name {
    /// Posted by UsageAggregator.recountAll after the local usage table has
    /// been cleared and re-parsed, so the next usage sync reconciles
    /// now-orphaned cloud docs exactly once.
    static let usageRecountDidRebuildLocalRows = Notification.Name("OpenBurnBarUsageRecountDidRebuildLocalRows")
}

final class UsageSyncService: CloudSyncDomain, Sendable {
    private let context: CloudSyncContext
    private let vaultKeyProvider: any ConversationCloudVaultKeyProviding

    private let state = Locked(CloudSyncDomainState())

    var isSyncing: Bool { state.read().isSyncing }
    var lastSyncError: String? { state.read().lastSyncError }
    var lastSyncDate: Date? { state.read().lastSyncDate }

    /// Set when a Recount (or other full local rebuild) requests one-shot
    /// cloud reconciliation. Orphan cleanup is O(total same-device history)
    /// in Firestore reads, so it must not run on every incremental sync.
    private let orphanReconciliationRequested = Locked(false)

    init(
        context: CloudSyncContext,
        vaultKeyProvider: any ConversationCloudVaultKeyProviding = MacConversationCloudVaultKeyProvider()
    ) {
        self.context = context
        self.vaultKeyProvider = vaultKeyProvider
        NotificationCenter.default.addObserver(
            forName: .usageRecountDidRebuildLocalRows,
            object: nil,
            queue: nil
        ) { [orphanReconciliationRequested] _ in
            orphanReconciliationRequested.withLock { $0 = true }
        }
    }

    /// Request a one-shot orphaned-cloud-doc reconciliation on the next sync.
    func requestOrphanReconciliation() {
        orphanReconciliationRequested.withLock { $0 = true }
    }

    /// Upload all unsynced local usage rows to Firestore.
    /// Call after UsageAggregator.refreshAll().
    func sync() async {
        let gate = await context.syncGate()
        guard gate.account.isFirebaseAvailable,
              gate.account.isSignedIn,
              gate.account.isCloudSyncEnabled,
              !gate.syncSuppressed,
              let uid = gate.account.uid else { return }

        guard state.beginSyncingIfIdle() else { return }
        let deviceId = gate.account.deviceId
        let syncStartTime = Date()
        var syncedItemCount = 0

        defer { state.endSyncing() }

        do {
            await publishDeviceHeartbeatBestEffort(uid: uid, deviceId: deviceId)

            let collectionRef = context.firestoreGateway.collection("users").document(uid).collection("usage")
            let resolvedVaultKey = try await vaultKeyProvider.keyForWriting(uid: uid, deviceId: deviceId)

            while true {
                let unsynced = try await context.dataStore.fetchUnsynced()
                guard !unsynced.isEmpty else { break }
                syncedItemCount += unsynced.count

                let batch = context.firestoreGateway.batch()

                for usage in unsynced {
                    let docId = "\(deviceId)_\(usage.id.uuidString)"
                    let docRef = collectionRef.document(docId)
                    let data = try encodeUsage(
                        usage,
                        uid: uid,
                        deviceId: deviceId,
                        docID: docId,
                        vaultKey: resolvedVaultKey.keyData
                    )
                    batch.setData(data, forDocument: docRef, merge: true)
                }

                try await withCloudSyncRetry(
                    policy: context.retryPolicy,
                    circuitBreaker: context.circuitBreaker,
                    domain: "usage"
                ) {
                    try await batch.commit()
                }

                let syncedIds = unsynced.map { $0.id }
                try await context.dataStore.markSynced(ids: syncedIds)
            }

            // Orphan cleanup runs only AFTER the replacement upload committed
            // (never leaves the cloud with neither old nor new docs), only when
            // a recount explicitly requested reconciliation (bounds the
            // full-history scan to recount events, not every incremental
            // sync), and never against an empty local table (a failed recount
            // persist must not delete the device's entire cloud history).
            if orphanReconciliationRequested.read() {
                let keeping = Set(try await context.dataStore.fetchAllUsage().map { $0.id.uuidString })
                if keeping.isEmpty {
                    AppLogger.sync.error(
                        "usage_orphan_cleanup_refused_empty_local_table",
                        metadata: ["reason": "failed recount persist would delete entire cloud history"]
                    )
                } else {
                    try await deleteOrphanedUsageDocs(
                        collectionRef: collectionRef,
                        deviceId: deviceId,
                        keeping: keeping
                    )
                    orphanReconciliationRequested.withLock { $0 = false }
                }
            }

            state.withLock {
                $0.lastSyncDate = Date()
                $0.lastSyncError = nil
            }
            let durationBucket = AnalyticsBuckets.durationMs(Int(Date().timeIntervalSince(syncStartTime) * 1000))
            let itemCountBucket = AnalyticsBuckets.count(syncedItemCount)
            Task { @MainActor in
                Analytics.shared.track(.cloudsyncCompleted, [
                    "domain": "usage",
                    "outcome": "success",
                    "duration_ms_bucket": .string(durationBucket),
                    "item_count_bucket": .string(itemCountBucket)
                ])
            }
            try await publishSyncHeartbeat(uid: uid, deviceId: deviceId, collectionsInSync: ["usage"])
        } catch {
            await recordSyncError(error, uid: uid, deviceId: deviceId)
        }
    }

    private func deleteOrphanedUsageDocs(
        collectionRef: CloudSyncCollectionGateway,
        deviceId: String,
        keeping currentUsageIds: Set<String>
    ) async throws {
        let prefix = "\(deviceId)_"
        let snapshot = try await collectionRef.whereField("deviceId", isEqualTo: deviceId).getDocuments()
        let orphanDocIds = snapshot.documents.compactMap { document -> String? in
            let documentID = document.documentID
            guard documentID.hasPrefix(prefix) else { return nil }
            let usageID = String(documentID.dropFirst(prefix.count))
            return currentUsageIds.contains(usageID) ? nil : documentID
        }
        guard !orphanDocIds.isEmpty else { return }

        for batchStart in stride(from: 0, to: orphanDocIds.count, by: 400) {
            let batch = context.firestoreGateway.batch()
            for docId in orphanDocIds[batchStart..<min(batchStart + 400, orphanDocIds.count)] {
                batch.deleteDocument(collectionRef.document(docId))
            }
            try await withCloudSyncRetry(
                policy: context.retryPolicy,
                circuitBreaker: context.circuitBreaker,
                domain: "usage"
            ) {
                try await batch.commit()
            }
        }
    }

    private func publishDeviceHeartbeatBestEffort(uid: String, deviceId: String) async {
        do {
            try await publishDeviceHeartbeat(uid: uid, deviceId: deviceId, at: Date())
        } catch {
            AppLogger.sync.error(
                "usage_sync_heartbeat_failed",
                metadata: ["errorClass": "\(String(describing: type(of: error)))"]
            )
        }
    }

    private func publishSyncHeartbeat(uid: String, deviceId: String, collectionsInSync: [String]) async throws {
        let now = Date()
        try await publishDeviceHeartbeat(uid: uid, deviceId: deviceId, at: now)

        try await context.firestoreGateway.collection("users").document(uid)
            .collection("sync_status").document(deviceId).setData([
                "deviceId": deviceId,
                "isOnline": true,
                "lastSyncAt": Timestamp(date: now),
                "collectionsInSync": collectionsInSync,
                "lastErrorCode": FieldValue.delete(),
                "updatedAt": Timestamp(date: now)
            ], merge: true)
    }

    private func publishSyncFailureStatus(uid: String, deviceId: String, error: Error) async {
        let now = Date()
        do {
            try await context.firestoreGateway.collection("users").document(uid)
                .collection("sync_status").document(deviceId).setData([
                    "deviceId": deviceId,
                    "isOnline": true,
                    "lastAttemptAt": Timestamp(date: now),
                    "lastErrorCode": Self.syncBlockedCode(for: error),
                    "updatedAt": Timestamp(date: now)
                ], merge: true)
        } catch {
            AppLogger.sync.error(
                "usage_sync_failure_status_failed",
                metadata: ["errorClass": "\(String(describing: type(of: error)))"]
            )
        }
    }

    private func publishDeviceHeartbeat(uid: String, deviceId: String, at now: Date) async throws {
        let deviceName = Host.current().localizedName ?? "OpenBurnBar Mac"
        let userRef = context.firestoreGateway.collection("users").document(uid)

        try await userRef.collection("devices").document(deviceId).setData([
            "deviceId": deviceId,
            "deviceName": deviceName,
            "platform": "macOS",
            "isLocal": true,
            "lastSeenAt": Timestamp(date: now),
            "updatedAt": Timestamp(date: now)
        ], merge: true)
    }

    static func syncBlockedCode(for error: Error) -> String {
        if let cloudVaultError = error as? CloudVaultAccessError {
            switch cloudVaultError {
            case .vaultKeyUnavailable:
                return "vault_key_unavailable"
            case .vaultKeyMismatch:
                return "vault_key_mismatch"
            case .invalidWrappedKey:
                return "vault_key_invalid"
            }
        }

        let nsError = error as NSError
        if nsError.domain == FirestoreErrorDomain,
           let code = FirestoreErrorCode.Code(rawValue: nsError.code) {
            switch code {
            case .permissionDenied:
                return "permission_denied"
            case .unauthenticated:
                return "unauthenticated"
            default:
                break
            }
        }

        if nsError.domain == NSURLErrorDomain {
            return "network_unavailable"
        }

        return "other"
    }

    private func recordSyncError(_ error: Error, uid: String, deviceId: String) async {
        state.withLock { $0.lastSyncError = error.localizedDescription }
        await publishSyncFailureStatus(uid: uid, deviceId: deviceId, error: error)

        let nsError = error as NSError
        let errorType = String(describing: type(of: error))
        let isPermissionDenied = nsError.domain == FirestoreErrorDomain
            && FirestoreErrorCode.Code(rawValue: nsError.code) == .permissionDenied
        Task { @MainActor in
            Analytics.shared.track(.cloudsyncFailed, [
                "domain": "usage",
                "error_type": .string(errorType),
                "is_permission_denied": .bool(isPermissionDenied)
            ])
        }
        guard nsError.domain == FirestoreErrorDomain,
              let code = FirestoreErrorCode.Code(rawValue: nsError.code),
              code == .permissionDenied || code == .unauthenticated else {
            return
        }
        await context.suppressSync(for: CloudSyncBackoffPolicy.permissionDeniedCooldown)
    }

    private func encodeUsage(
        _ usage: TokenUsage,
        uid: String,
        deviceId: String,
        docID: String,
        vaultKey: Data
    ) throws -> [String: Any] {
        var data: [String: Any] = [
            "id": usage.id.uuidString,
            "deviceId": deviceId,
            "provider": usage.provider.rawValue,
            "providerID": usage.providerID.rawValue,
            "sessionId": usage.sessionId,
            "model": usage.model,
            "inputTokens": usage.inputTokens,
            "outputTokens": usage.outputTokens,
            "cacheCreationTokens": usage.cacheCreationTokens,
            "cacheReadTokens": usage.cacheReadTokens,
            "reasoningTokens": usage.reasoningTokens,
            "usageSource": usage.usageSource.rawValue,
            "totalTokens": usage.totalTokens,
            "cost": usage.cost,
            "startTime": Timestamp(date: usage.startTime),
            "endTime": Timestamp(date: usage.endTime),
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

        // Seal the project name instead of writing it in clear. The server stays a
        // blind store-and-forward: only on-device key holders can recover the name.
        // The deployed rules only accept a sealed envelope that carries the exact
        // per-document AAD context (`validCloudSealedTextAt`): schemaVersion >= 2
        // plus `aad == "OpenBurnBar-CloudVault-aad-v2|uid|usage|docID|sealedProjectName|2|sealedProjectName"`.
        // Sealing without the context omits both fields, so every usage create is
        // PERMISSION_DENIED — the writer must bind the seal to its document.
        let aadContext = try CloudVaultAADContext(
            uid: uid,
            collection: "usage",
            docID: docID,
            field: "sealedProjectName"
        )
        let sealedProjectName = try CloudVaultCrypto.sealText(
            usage.projectName,
            keyData: vaultKey,
            aadContext: aadContext
        )
        data["sealedProjectName"] = try CloudVaultCrypto.firestoreDictionary(sealedProjectName)
        // Opaque keyed group-by trapdoor so readers can bucket usage by project
        // without decrypting every row. Absent for empty/blank names. A real
        // crypto/derivation failure here is NOT coalesced into the "blank name"
        // nil: it throws so the row stays unsynced and is retried, instead of
        // silently uploading a usage doc missing its group-by key.
        if let projectKeyHash = try CloudVaultCrypto.projectKeyHashOrThrow(for: usage.projectName, keyData: vaultKey) {
            data["projectKeyHash"] = projectKeyHash
        }
        // Strip any legacy plaintext now that the sealed copy is written. The
        // firestore rule rejects a doc carrying BOTH plaintext + sealed
        // (`rejectsPlaintextWhenSealed`), and this is a `merge: true` batch write,
        // so a re-uploaded pre-migration usage row would otherwise merge into a
        // both-present doc and be denied. Mirrors the Android writer.
        data["projectName"] = FieldValue.delete()
        return data
    }
}

extension CloudVaultCrypto {
    /// Stable opaque group-by token for a project name (32 hex chars), derived via
    /// the existing keyed search trapdoor. Collapses the name to a single ASCII
    /// `[a-z0-9]` term, then HMACs it under the per-user search key. Returns `nil`
    /// for names that normalize to fewer than two characters.
    ///
    /// Reuses `CloudVaultCrypto.tokenHashes` only — no new crypto is introduced.
    /// The ASCII-only normalization is byte-identical to the Android writer
    /// (`FirestoreRepository.kt projectKeyHash`) so the SAME project name produces
    /// ONE cross-platform group-by bucket. (A previous `normalizedTokens().joined()`
    /// pre-step dropped stopwords/short tokens and diverged from Android — e.g.
    /// "The API v2" hashed `apiv2` here but `theapiv2` on Android.)
    ///
    /// This is the throwing primitive: it returns `nil` ONLY for the expected
    /// "too short to normalize" case; any crypto/derivation fault (e.g. a bad key
    /// length surfacing from `searchKey`) propagates so the caller can fail closed.
    /// Use this on write paths (usage upload) where a missing group-by trapdoor
    /// must NOT be papered over by silently omitting the field.
    static func projectKeyHashOrThrow(for projectName: String, keyData: Data) throws -> String? {
        let normalized = projectName.lowercased().filter { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
        guard normalized.count >= 2 else { return nil }
        return try tokenHashes(for: normalized, keyData: keyData, limit: 1).first
    }

    /// Non-throwing convenience preserved for cross-surface callers (budget /
    /// approval-policy sealing) that bucket on a best-effort basis. A crypto fault
    /// is no longer swallowed silently: it is logged (and the field omitted) so the
    /// loss is observable, while the <2-char case still returns `nil` quietly.
    static func projectKeyHash(for projectName: String, keyData: Data) -> String? {
        do {
            return try projectKeyHashOrThrow(for: projectName, keyData: keyData)
        } catch {
            AppLogger.sync.error(
                "projectKeyHash.derivationFailed",
                metadata: ["errorClass": "\(String(describing: type(of: error)))"]
            )
            return nil
        }
    }

    /// Opens a sealed project name from a Firestore document, falling back to the
    /// legacy plaintext `projectName` field for in-flight / pre-migration docs.
    /// Returns `nil` only when neither the sealed field nor a legacy field is present.
    static func openSealedProjectName(
        from data: [String: Any],
        sealedField: String = "sealedProjectName",
        legacyField: String = "projectName",
        keyData: Data?
    ) -> String? {
        if let raw = data[sealedField],
           let envelope = decodeSealedText(from: raw) {
            guard let keyData else {
                // No vault key on this device — sealed text stays opaque. Never
                // fall through to a legacy plaintext value.
                return nil
            }
            do {
                return try openText(envelope, keyData: keyData)
            } catch let error as CloudVaultCryptoError {
                // A structural fault (malformed envelope / non-UTF8 plaintext)
                // means the stored ciphertext is corrupt or schema-broken — surface
                // it so silent corruption is observable, then fail closed.
                AppLogger.sync.error(
                    "openSealedProjectName.envelopeInvalid",
                    metadata: ["errorClass": "\(String(describing: type(of: error)))"]
                )
                return nil
            } catch {
                // AEAD open failure: either this device holds the wrong vault key
                // (expected on a not-yet-keyed device) or the ciphertext/tag was
                // tampered with. Both are indistinguishable in the AEAD, so log at
                // notice and fail closed without ever leaking a legacy value.
                AppLogger.sync.notice(
                    "openSealedProjectName.unreadable",
                    metadata: ["errorClass": "\(String(describing: type(of: error)))"]
                )
                return nil
            }
        }
        return data[legacyField] as? String
    }
}
