import FirebaseFirestore
import Foundation
import OpenBurnBarCore

// MARK: - Memory cloud-sync domain (PR-E2 scheduling wiring, DEFAULT OFF)
//
// Schedules `MemoryCloudSyncService.syncApprovedMemories` into the existing
// post-persistence refresh cadence as one more `CloudSyncDomain`, mirroring
// `ConversationSyncService` / `SessionLogSyncService`. This file is *scheduling
// only*: it does not enable any new cloud egress path. Egress stays OFF out of
// the box because every lever it reads defaults to "no upload":
//
//   * `memoryApprovedCloudBackupEnabled` — the user opt-in (default OFF, PR-E2)
//     AND the Remote Config fleet ceiling (`remoteConfigExtractionEnabled`).
//     A single fleet flip clamps memory egress shut even if a user opted in.
//   * `accountManager.isCloudSyncEnabled` / signed-in / Firebase-available —
//     the same account gates every other sync domain honours.
//   * `memoryDeviceSyncEnabled` — the PULL sub-toggle (default OFF, Memory Blind
//     Sync PR-2), itself ANDed under the backup gate above. Backing memory up is
//     not the same consent as syncing it across devices, so reading facts back
//     down needs its own switch; with it off the upload half runs exactly as
//     before and no `memory_facts` read is issued at all.
//
// When any lever is off, `sync()` returns BEFORE reading a single candidate or
// touching a Firestore handle / vault key — so a dormant install performs zero
// reads, zero key resolution, and zero network I/O. Only when the user has
// explicitly opted in, the fleet ceiling allows, and the account is sync-ready
// does the wrapped service run; and that service itself replicates exclusively
// `reviewStatus == .approved`, scope-matched, sealed facts (the store-level
// `cloudSyncEligibleChatMemories` gate), with forget-receipt + tombstone
// propagation. The backend `firestore.rules` approved-only sealed-write contract
// is already deployed; this domain is the missing client-side scheduler.
//
// THREADING: this is a nonisolated `Sendable` domain (like its peers). It reads
// the user-facing gate via a single `@MainActor` hop (`gateSnapshot()`), then
// does its key resolution + uploads off the main actor. Reentrancy is guarded by
// the shared `Locked<CloudSyncDomainState>` box so a long upload cycle started by
// one refresh tick is not double-run by the next.
final class MemoryCloudSyncDomain: CloudSyncDomain, Sendable {
    private let syncService: MemoryCloudSyncService
    private let pullService: MemoryCloudPullService
    private let accountManager: any AccountManaging
    private let settingsManager: any SettingsManagerProtocol
    private let vaultKeyProvider: any ConversationCloudVaultKeyProviding
    private let now: @Sendable () -> Date

    private let state = Locked(CloudSyncDomainState())

    var isSyncing: Bool { state.read().isSyncing }
    var lastSyncError: String? { state.read().lastSyncError }
    var lastSyncDate: Date? { state.read().lastSyncDate }

    init(
        store: ControlPlaneStore,
        accountManager: any AccountManaging,
        settingsManager: any SettingsManagerProtocol,
        firestoreGateway: CloudSyncFirestoreGateway = CloudSyncFirestoreLiveGateway(),
        vaultKeyProvider: any ConversationCloudVaultKeyProviding = MacConversationCloudVaultKeyProvider(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.syncService = MemoryCloudSyncService(store: store, firestoreGateway: firestoreGateway)
        self.pullService = MemoryCloudPullService(store: store, firestoreGateway: firestoreGateway)
        self.accountManager = accountManager
        self.settingsManager = settingsManager
        self.vaultKeyProvider = vaultKeyProvider
        self.now = now
    }

    /// Immutable per-cycle gate read once on the main actor (mirrors the
    /// `CloudSyncContext.syncGate` pattern so the off-actor body reads no
    /// `@MainActor` state). `approvedCloudBackupEnabled` already folds the user
    /// opt-in under the Remote Config fleet ceiling inside `SettingsManager`.
    private struct GateSnapshot: Sendable {
        let isFirebaseAvailable: Bool
        let isSignedIn: Bool
        let isCloudSyncEnabled: Bool
        let approvedCloudBackupEnabled: Bool
        let deviceSyncEnabled: Bool
        let deviceId: String
        let uid: String?
    }

    @MainActor
    private func gateSnapshot() -> GateSnapshot {
        GateSnapshot(
            isFirebaseAvailable: accountManager.isFirebaseAvailable,
            isSignedIn: accountManager.isSignedIn,
            isCloudSyncEnabled: accountManager.isCloudSyncEnabled,
            approvedCloudBackupEnabled: settingsManager.memoryApprovedCloudBackupEnabled,
            deviceSyncEnabled: settingsManager.memoryDeviceSyncEnabled,
            deviceId: accountManager.deviceId,
            uid: accountManager.currentUID
        )
    }

    /// Replicate approved sealed memory facts (+ forget receipts) for the
    /// signed-in user, when every gate allows. No-op (returns immediately,
    /// untouched state) the instant any lever is off — the dormant default.
    func sync() async {
        let gate = await gateSnapshot()
        guard gate.isFirebaseAvailable,
              gate.isSignedIn,
              gate.isCloudSyncEnabled,
              gate.approvedCloudBackupEnabled,
              let uid = gate.uid else { return }

        // Atomic check-then-act so a slow upload cycle is never double-run by an
        // overlapping refresh tick (the standard domain reentrancy guard).
        guard state.beginSyncingIfIdle() else { return }
        defer { state.endSyncing() }

        let syncStartedAt = now()

        do {
            let resolvedKey = try await vaultKeyProvider.keyForWriting(uid: uid, deviceId: gate.deviceId)
            let result = try await syncService.syncApprovedMemories(
                uid: uid,
                vaultKey: resolvedKey.keyData,
                now: syncStartedAt
            )
            state.withLock {
                $0.lastSyncDate = self.now()
                $0.lastSyncError = nil
            }
            // The PULL half runs only after a successful push, behind its own
            // sub-toggle. It is deliberately in a nested do/catch: a pull failure
            // records the error like any other and must never undo, block, or
            // reorder the upload that already succeeded above.
            if gate.deviceSyncEnabled {
                do {
                    _ = try await pullService.pullRemoteFacts(
                        uid: uid,
                        vaultKey: resolvedKey.keyData,
                        now: syncStartedAt
                    )
                } catch {
                    recordSyncError(error)
                }
            }
            let durationBucket = AnalyticsBuckets.durationMs(Int(now().timeIntervalSince(syncStartedAt) * 1000))
            let itemCountBucket = AnalyticsBuckets.count(result.uploaded)
            Task { @MainActor in
                Analytics.shared.track(.cloudsyncCompleted, [
                    "domain": "memory_facts",
                    "outcome": "success",
                    "duration_ms_bucket": .string(durationBucket),
                    "item_count_bucket": .string(itemCountBucket)
                ])
            }
        } catch {
            recordSyncError(error)
        }
    }

    /// Records the failure on the domain's own error slot and emits the standard
    /// `cloudsync.failed` analytics, mirroring `ConversationSyncService`. The
    /// coordinator does not aggregate this domain (the orchestrator drives it
    /// directly), so there is no shared backoff box to update; the per-cycle gate
    /// re-evaluates on the next refresh tick, and the wrapped service is
    /// idempotent (`merge: true` / replicated-watermark), so a transient denial
    /// simply retries cleanly next cycle without duplicating work.
    private func recordSyncError(_ error: Error) {
        state.withLock { $0.lastSyncError = error.localizedDescription }

        let nsError = error as NSError
        let errorType = String(describing: type(of: error))
        let isPermissionDenied = nsError.domain == FirestoreErrorDomain
            && FirestoreErrorCode.Code(rawValue: nsError.code) == .permissionDenied
        AppLogger.sync.error(
            "memory_cloud_sync_failed",
            metadata: ["error_type": errorType, "is_permission_denied": String(isPermissionDenied)]
        )
        Task { @MainActor in
            Analytics.shared.track(.cloudsyncFailed, [
                "domain": "memory_facts",
                "error_type": .string(errorType),
                "is_permission_denied": .bool(isPermissionDenied)
            ])
        }
    }
}
