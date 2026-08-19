import FirebaseFirestore
import Foundation
import OpenBurnBarKernel

// MARK: - Fleet cloud mirror (Mac publisher)
//
// The fleet snapshot is produced by the daemon (socket RPC + well-known file),
// but the daemon has no Firebase — the app is the only process with auth and a
// Firestore handle. So the publisher lives here, reading the snapshot the same
// way `FleetService` does and sealing it before Firestore sees it.
//
// One direction, one document. Unlike the AI Inbox there is no download half
// and no prune loop: mobile consumption is read-only in v1 (orchestrator
// designation and directives stay Mac/daemon-local — no write-back collection
// exists), and a single `current` document cannot leave ghosts behind.
//
// ## The watermark is load-bearing, not an optimization
//
// The refresh loop ticks far more often than the fleet changes, and most idle
// Macs produce byte-identical snapshots for hours. Without a gate, every cycle
// would re-seal and re-upload the same board — and because AES-GCM uses a
// fresh nonce per seal, each of those writes is a *different* ciphertext, so
// Firestore could not dedupe them either. Hashing the exact bytes that go
// inside the seal (`FleetMirrorCodec.snapshotJSONData`) lets a dead daemon or
// an unchanged board cost one local read and zero writes.

final class FleetSyncService: CloudSyncDomain, Sendable {
    /// User preference key controlling whether the mirror is active.
    ///
    /// Defaults to `true` once the user opts into cloud sync, matching
    /// `AIInboxSyncService.preferenceKey`: the mirror's whole purpose is to
    /// make the fleet board readable from a phone while the Mac is asleep, so
    /// a user who enabled cloud sync and then found an empty mobile dashboard
    /// would reasonably call that broken. Power users can flip it off next to
    /// the inbox mirror toggle in Settings.
    static let preferenceKey = "fleet.cloudMirror.enabled"

    private let context: CloudSyncContext
    private let vaultKeyProvider: any ConversationCloudVaultKeyProviding
    private let defaults: UserDefaults
    /// Snapshot acquisition (injectable for tests). `nil` means "nothing to
    /// publish right now" — daemon down and no well-known file — and skips the
    /// cycle silently rather than surfacing an error: a stopped daemon is a
    /// normal state, not a sync failure.
    private let fetchSnapshot: @Sendable () async -> BurnBarFleetSnapshot?
    private let now: @Sendable () -> Date

    private let state = Locked(CloudSyncDomainState())

    var isSyncing: Bool { state.read().isSyncing }
    var lastSyncError: String? { state.read().lastSyncError }
    var lastSyncDate: Date? { state.read().lastSyncDate }

    init(
        context: CloudSyncContext,
        vaultKeyProvider: any ConversationCloudVaultKeyProviding = MacConversationCloudVaultKeyProvider(),
        defaults: UserDefaults = .standard,
        fetchSnapshot: @escaping @Sendable () async -> BurnBarFleetSnapshot? = FleetSyncService.liveSnapshotFetch,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.context = context
        self.vaultKeyProvider = vaultKeyProvider
        self.defaults = defaults
        self.fetchSnapshot = fetchSnapshot
        self.now = now
    }

    /// Live preference value. Absent means enabled — see `preferenceKey`.
    var isEnabled: Bool {
        defaults.object(forKey: Self.preferenceKey) as? Bool ?? true
    }

    /// Default acquisition: the daemon socket RPC first (freshest), then the
    /// daemon's atomically-replaced `fleet-snapshot.json` — the same order
    /// `FleetService` documents. The file is written with `tmp` + rename, so a
    /// reader only ever observes a complete generation.
    static let liveSnapshotFetch: @Sendable () async -> BurnBarFleetSnapshot? = {
        let paths = OpenBurnBarDaemonRuntimePaths.live()
        // Blocking POSIX socket I/O — keep it off the calling actor.
        return await Task.detached(priority: .utility) {
            if let snapshot = try? OpenBurnBarDaemonSocketClient.fleetSnapshot(at: paths.socketURL) { // try?-ok(daemon down falls through to the well-known file)
                return snapshot
            }
            guard let data = try? Data(contentsOf: paths.fleetSnapshotFileURL) else { // try?-ok(no file means nothing to publish; the cycle skips silently)
                return nil
            }
            return try? JSONDecoder().decode(BurnBarFleetSnapshot.self, from: data) // try?-ok(an unreadable file must not fail the sync cycle; publishing waits for the next good generation)
        }.value
    }

    // MARK: - Sync

    func sync() async {
        let gate = await context.syncGate()
        guard gate.account.isFirebaseAvailable,
              gate.account.isSignedIn,
              gate.account.isCloudSyncEnabled,
              !gate.syncSuppressed,
              isEnabled,
              let uid = gate.account.uid else { return }
        guard state.beginSyncingIfIdle() else { return }
        defer { state.endSyncing() }

        // Daemon down and no file: nothing to publish. The cloud keeps the last
        // published document, whose `updatedAt` going stale is exactly how the
        // mobile dashboard learns the Mac is offline — deleting or blanking it
        // here would erase that honest signal.
        guard let snapshot = await fetchSnapshot() else { return }

        do {
            let encoded = try FleetMirrorCodec.snapshotJSONData(snapshot)
            let contentHash = CloudVaultCrypto.sha256Hex(encoded)
            if contentHash == storedWatermark(uid: uid) {
                // Same bytes already committed — a quiet fleet costs zero writes.
                state.withLock { $0.lastSyncDate = self.now() }
                return
            }

            // Resolved only when there is something to publish: key resolution
            // can hit the keychain and Firestore, and an unchanged board must
            // never pay for it.
            let resolvedKey = try await vaultKeyProvider.keyForWriting(uid: uid, deviceId: gate.account.deviceId)
            let payload = try FleetMirrorCodec.encodeSealed(
                snapshot,
                vaultKey: resolvedKey.keyData,
                vaultKeyID: resolvedKey.vaultKeyID,
                uid: uid,
                updatedAt: now()
            )
            let document = context.firestoreGateway
                .collection("users").document(uid)
                .collection(FleetMirrorCodec.collection)
                .document(FleetMirrorCodec.documentID)
            try await withCloudSyncRetry(
                policy: context.retryPolicy,
                circuitBreaker: context.circuitBreaker,
                domain: FleetMirrorCodec.collection
            ) {
                // `merge: false`: the envelope is rewritten whole each cycle,
                // so a field dropped from the codec must not linger remotely.
                try await document.setData(payload, merge: false)
            }

            // Persisted only after the write committed. A cycle that threw
            // leaves the stored watermark untouched, so the next run retries
            // the same snapshot rather than skipping bytes that never reached
            // the cloud.
            saveWatermark(contentHash, uid: uid)
            state.withLock { $0.lastSyncDate = self.now() }
        } catch {
            state.withLock { $0.lastSyncError = error.localizedDescription }
            if Self.isPermissionDenied(error) {
                await context.suppressSync(for: CloudSyncBackoffPolicy.permissionDeniedCooldown)
            }
        }
    }

    // MARK: - Watermark

    /// Keyed by uid so signing into a second account starts from an empty
    /// watermark rather than inheriting the first account's "already uploaded"
    /// claim — which would leave the new account's fleet mirror permanently
    /// empty in the cloud.
    static func watermarkDefaultsKey(uid: String) -> String {
        "OpenBurnBarFleetMirrorWatermark.\(uid)"
    }

    private func storedWatermark(uid: String) -> String? {
        defaults.string(forKey: Self.watermarkDefaultsKey(uid: uid))
    }

    private func saveWatermark(_ contentHash: String, uid: String) {
        defaults.set(contentHash, forKey: Self.watermarkDefaultsKey(uid: uid))
    }

    private static func isPermissionDenied(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == FirestoreErrorDomain,
              let code = FirestoreErrorCode.Code(rawValue: nsError.code) else {
            return false
        }
        return code == .permissionDenied || code == .unauthenticated
    }
}
