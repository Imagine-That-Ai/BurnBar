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
//   * `memoryDeviceSyncEnabled` — the PULL gate (default OFF, Memory Blind
//     Sync PR-2): the sub-toggle ANDed under the backup gate above AND the live
//     Data Vault entitlement. Backing memory up is not the same consent as
//     syncing it across devices, so reading facts back down needs its own
//     switch; with any lever off the upload half runs exactly as before and no
//     `memory_facts` read is issued at all. The entitlement is a client-side
//     lever by necessity: `firestore.rules` gates `memory_facts` *writes* on
//     `hasActiveDataVaultEntitlement(userId)`, but *reads* are granted by the
//     per-user namespace rule with no entitlement check, so a lapsed
//     entitlement is only stopped here.
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
/// Resolves the live Data Vault entitlement (the fourth lever of the device-sync
/// gate) for `MemoryCloudSyncDomain`. A seam, not an abstraction for its own
/// sake: the production resolver reads the shared `MacCloudEntitlementStore`
/// singleton, which a unit test cannot drive.
protocol MemoryDataVaultEntitlementResolving: Sendable {
    /// True only when the member's resolved tier satisfies `GatedFeature.dataVault`.
    /// Unresolved / lapsed ⇒ false (fail closed).
    @MainActor var isDataVaultEntitled: Bool { get }
}

/// Production resolver: the same `MacCloudEntitlementStore` tier check
/// `MemoryCloudModelsSection` unlocks against, so the pull's entitlement lever
/// and the Settings unlock veil can never disagree about who is entitled.
struct MacCloudDataVaultEntitlementResolver: MemoryDataVaultEntitlementResolving {
    @MainActor var isDataVaultEntitled: Bool {
        let store = MacCloudEntitlementStore.shared
        store.start()
        return store.cloudTier.satisfies(GatedFeature.gatedFeature(.dataVault).requiredTier)
    }
}

/// What one cycle's PULL half did, kept so it can be read rather than
/// recomputed — and so the `cloudsync.completed` outcome is decided by one
/// named, testable function instead of a literal at the emit site.
struct MemoryCloudPullReport: Equatable, Sendable {
    /// The pull never ran, because the device-sync gate was closed.
    static let skippedOutcome = "skipped"
    static let successOutcome = "success"
    static let failureOutcome = "failure"

    /// One of the three constants above.
    let outcome: String
    /// The counters, or nil when the pull was skipped or threw.
    let counters: MemoryCloudPullResult?

    /// The `cloudsync.completed` outcome for a cycle whose PUSH succeeded.
    ///
    /// A cycle whose pull failed is **not** a success. Reporting one was worse
    /// than reporting nothing: a device failing every pull on every cycle
    /// emitted an unbroken run of `success`, so the single dimension that would
    /// have shown a convergence feature was dead read perfectly healthy. A
    /// skipped pull is still a success — nothing was asked of it.
    static func completedOutcome(pullOutcome: String) -> String {
        pullOutcome == failureOutcome ? "partial" : "success"
    }
}

final class MemoryCloudSyncDomain: CloudSyncDomain, Sendable {
    private let syncService: MemoryCloudSyncService
    private let pullService: any MemoryCloudPulling
    private let store: ControlPlaneStore
    private let accountManager: any AccountManaging
    private let settingsManager: any SettingsManagerProtocol
    private let vaultKeyProvider: any ConversationCloudVaultKeyProviding
    private let entitlementResolver: any MemoryDataVaultEntitlementResolving
    private let now: @Sendable () -> Date

    private let state = Locked(CloudSyncDomainState())
    private let pullState = Locked(MemoryCloudPullReport?.none)

    var isSyncing: Bool { state.read().isSyncing }
    var lastSyncError: String? { state.read().lastSyncError }
    var lastSyncDate: Date? { state.read().lastSyncDate }

    /// What the last pull did, or nil while the pull has never run this launch.
    ///
    /// The pull is the half of this feature an operator cannot otherwise see:
    /// the upload's effects are visible in Firestore, but "did anything arrive
    /// on this Mac, and was any of it refused" was previously answerable from
    /// nowhere — the counters were computed, returned, and discarded at
    /// `_ = try await pullService.pullRemoteFacts(...)`.
    var lastPullReport: MemoryCloudPullReport? { pullState.read() }

    init(
        store: ControlPlaneStore,
        accountManager: any AccountManaging,
        settingsManager: any SettingsManagerProtocol,
        firestoreGateway: CloudSyncFirestoreGateway = CloudSyncFirestoreLiveGateway(),
        vaultKeyProvider: any ConversationCloudVaultKeyProviding = MacConversationCloudVaultKeyProvider(),
        entitlementResolver: any MemoryDataVaultEntitlementResolving = MacCloudDataVaultEntitlementResolver(),
        pullService: (any MemoryCloudPulling)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.syncService = MemoryCloudSyncService(store: store, firestoreGateway: firestoreGateway)
        self.pullService = pullService ?? MemoryCloudPullService(store: store, firestoreGateway: firestoreGateway)
        self.store = store
        self.accountManager = accountManager
        self.settingsManager = settingsManager
        self.vaultKeyProvider = vaultKeyProvider
        self.entitlementResolver = entitlementResolver
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
        /// The EFFECTIVE pull gate (`MemoryDeviceSyncGate`): the sub-toggle AND
        /// the backup opt-in AND the fleet ceiling AND the live Data Vault
        /// entitlement, resolved on this same main-actor hop. Read from
        /// `SettingsManager.memoryDeviceSyncEnabled` so the Settings row and
        /// this network gate are one computation, never two that can drift.
        let deviceSyncEnabled: Bool
        let deviceId: String
        let uid: String?

        /// The scope this cycle enforces, computed by `MemoryDeviceSyncScope.current`
        /// — the same function the Settings toggle handler calls, so the two
        /// paths cannot disagree about what consent means (they did: the toggle
        /// omitted the account levers).
        let scope: MemoryDeviceSyncScope

        /// Everything that must be true for a remote memory to reach this
        /// device's engine: the four-lever device-sync gate AND the account
        /// levers every sync domain honours. This — not `deviceSyncEnabled`
        /// alone — is what the inbox guard publishes as consent, because a
        /// member who turned account sync off has not consented to a drain
        /// either, and the marker is what the daemon enforces against.
        var pullConsentGranted: Bool { scope.consentGranted }
    }

    @MainActor
    private func gateSnapshot() -> GateSnapshot {
        // Refresh the entitlement lever from the live tier BEFORE reading the
        // gate: the pull must never depend on the member having opened Settings
        // for the entitlement to have been resolved, and an unresolved or lapsed
        // tier resolves to false, closing the gate (fail closed).
        settingsManager.memoryDeviceSyncEntitlementSatisfied = entitlementResolver.isDataVaultEntitled
        return GateSnapshot(
            isFirebaseAvailable: accountManager.isFirebaseAvailable,
            isSignedIn: accountManager.isSignedIn,
            isCloudSyncEnabled: accountManager.isCloudSyncEnabled,
            approvedCloudBackupEnabled: settingsManager.memoryApprovedCloudBackupEnabled,
            deviceSyncEnabled: settingsManager.memoryDeviceSyncEnabled,
            deviceId: accountManager.deviceId,
            uid: accountManager.currentUID,
            scope: MemoryDeviceSyncScope.current(account: accountManager, settings: settingsManager)
        )
    }

    /// Subscribe to account identity changes so the blind-sync inbox and its
    /// consent marker are brought in line the MOMENT the member signs in, signs
    /// out or switches — not on the next refresh tick.
    ///
    /// Called once at app wiring (`OpenBurnBarApp.makeMemoryServices`). The
    /// closure captures `self` weakly; `AccountManager` holds its observers for
    /// the process's lifetime, and this domain is app-lifetime too, so nothing
    /// accumulates.
    @MainActor
    func startObservingAccountIdentity() {
        accountManager.observeAccountIdentityChanges { [weak self] uid in
            guard let self else { return }
            Task { await self.handleAccountIdentityChange(to: uid) }
        }
    }

    /// The "account changed" entry point. Withdraws the consent marker and
    /// purges the unmerged inbox rows the new identity may not have — see
    /// `MemoryDeviceSyncInboxGuard.enforceAccountTransition` for which rows go
    /// on which transition.
    ///
    /// Deliberately does NOT republish the marker for the incoming member, even
    /// when their gate happens to be open: consent is a claim this app makes
    /// about a live, fully-resolved gate (entitlement included), and the next
    /// consenting `sync()` is where that gate is read. Failing closed for one
    /// refresh interval costs a delayed drain; failing open costs another
    /// member's memories.
    func handleAccountIdentityChange(to uid: String?) async {
        do {
            try await MemoryDeviceSyncInboxGuard.enforceAccountTransition(to: uid, store: store)
        } catch {
            // Same posture as the in-`sync()` call: a failure here means the
            // scope went unenforced on this transition, which is worth a log
            // rather than a swallow. The daemon's marker age bound is the
            // backstop that keeps a surviving marker from authorising drains
            // for ever.
            AppLogger.sync.error(
                "memory_device_sync_account_transition_guard_failed",
                metadata: ["error_type": String(describing: type(of: error))]
            )
        }
    }

    /// Replicate approved sealed memory facts (+ forget receipts) for the
    /// signed-in user, when every gate allows. No-op (returns immediately,
    /// untouched state) the instant any lever is off — the dormant default.
    func sync() async {
        // Generation BEFORE the gate: a withdrawal (sign-out, switch, toggle off)
        // that lands after this read and before the publish below refuses the
        // publish. Read the other way round it could slip between the two.
        let observedGeneration = MemoryDeviceSyncInboxGuard.observeGeneration(store: store)
        let gate = await gateSnapshot()

        // BEFORE any gate can return. This tick is where the app observes every
        // state transition that must empty the inbox — a sign-out, a uid change,
        // the sub-toggle or the backup opt-in closing, an entitlement lapse —
        // and each of those closes the gate, so enforcing after the guard below
        // would mean the one cycle that most needs to purge is the one that
        // never does. It also (re)publishes the consent marker the daemon's
        // drain filters on, so the scope the app owns is a predicate the daemon
        // can evaluate rather than an invariant it has to trust.
        do {
            try await MemoryDeviceSyncInboxGuard.enforce(
                scope: gate.scope,
                observedGeneration: observedGeneration,
                store: store,
                now: now()
            )
        } catch {
            // A guard failure must not stop the upload half, which needs no
            // inbox at all — but it does mean the scope is unenforced this
            // cycle, so it is logged rather than swallowed.
            AppLogger.sync.error(
                "memory_device_sync_inbox_guard_failed",
                metadata: ["error_type": String(describing: type(of: error))]
            )
        }

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
            var pullOutcome = MemoryCloudPullReport.skippedOutcome
            var pullResult: MemoryCloudPullResult?
            if gate.deviceSyncEnabled {
                do {
                    let pulled = try await pullService.pullRemoteFacts(
                        uid: uid,
                        vaultKey: resolvedKey.keyData,
                        since: nil,
                        now: syncStartedAt
                    )
                    pullResult = pulled
                    pullOutcome = MemoryCloudPullReport.successOutcome
                    // The pull's counters are the only operator signal a
                    // convergence feature has: without them "is anything
                    // arriving on this Mac" is unanswerable from the outside.
                    AppLogger.sync.info(
                        "memory_cloud_pull_completed",
                        metadata: [
                            "applied": String(pulled.applied),
                            "unchanged": String(pulled.unchanged),
                            "rejected": String(pulled.rejected),
                            "skipped": String(pulled.skipped),
                            "purged_other_account": String(pulled.purgedOtherAccount),
                            "swept_stale": String(pulled.sweptStale)
                        ]
                    )
                } catch {
                    pullOutcome = MemoryCloudPullReport.failureOutcome
                    recordSyncError(error)
                }
            }
            pullState.write(MemoryCloudPullReport(outcome: pullOutcome, counters: pullResult))
            let durationBucket = AnalyticsBuckets.durationMs(Int(now().timeIntervalSince(syncStartedAt) * 1000))
            let itemCountBucket = AnalyticsBuckets.count(result.uploaded)
            // A cycle whose pull failed is NOT a success. Reporting one was
            // worse than reporting nothing: a device that failed every pull
            // every cycle emitted an unbroken run of `success`, so the one
            // number that would have shown the feature was dead read healthy.
            let outcome = MemoryCloudPullReport.completedOutcome(pullOutcome: pullOutcome)
            let appliedBucket = AnalyticsBuckets.count(pullResult?.applied ?? 0)
            let rejectedBucket = AnalyticsBuckets.count((pullResult?.rejected ?? 0) + (pullResult?.skipped ?? 0))
            Task { @MainActor in
                Analytics.shared.track(.cloudsyncCompleted, [
                    "domain": "memory_facts",
                    "outcome": .string(outcome),
                    "duration_ms_bucket": .string(durationBucket),
                    "item_count_bucket": .string(itemCountBucket),
                    "pull_outcome": .string(pullOutcome),
                    "pull_applied_bucket": .string(appliedBucket),
                    "pull_rejected_bucket": .string(rejectedBucket)
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
