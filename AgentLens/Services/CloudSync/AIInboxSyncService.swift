import FirebaseFirestore
import Foundation
import OpenBurnBarCore

// MARK: - AI Inbox cloud mirror (Mac publisher)
//
// The AI Inbox is produced by the daemon into local SQLite, but the daemon has
// no Firebase — the app is the only process with auth and a Firestore handle.
// So the publisher lives here, reading the daemon's tables through
// `ControlPlaneStore` and sealing each item before Firestore sees it.
//
// Two directions, deliberately asymmetric because ownership is:
//   • UP   — `ai_inbox_items`, Mac-owned. Sealed, upserted, and pruned.
//   • DOWN — `ai_inbox_item_state`, user-owned. Whichever device the user acted
//            on writes it; every other device converges by reading it.
//
// ## The watermark is load-bearing, not an optimization
//
// The daemon ticks every five minutes and most ticks change nothing. Without a
// gate, an idle inbox would re-seal and re-upload every row 288 times a day —
// and because AES-GCM uses a fresh nonce per seal, each of those writes is a
// *different* ciphertext, so Firestore could not dedupe them either. The
// watermark hashes the exact fields that reach the wire and skips a row whose
// hash is unchanged, so a quiet inbox costs one local read and zero writes.
//
// The download runs on every cycle regardless, because "nothing changed here"
// says nothing about whether the user archived something on their phone. It
// stays cheap by being watermarked on `updatedAt`: an idle account returns an
// empty result set, and — unlike the upload — it needs no vault key, because
// item state carries status flags rather than content.

final class AIInboxSyncService: CloudSyncDomain, Sendable {
    /// User preference key controlling whether the mirror is active.
    ///
    /// Defaults to `true` once the user opts into cloud sync, matching
    /// `CLIAgentSessionMirror.preferenceKey`: the inbox's whole purpose is to be
    /// readable from a phone while the Mac is asleep, so a user who enabled
    /// cloud sync and then found an empty phone inbox would reasonably call that
    /// broken. Power users can flip it off in Settings → Privacy.
    static let preferenceKey = "inbox.cloudMirror.enabled"

    /// Bounds one cycle. The inbox is a short, ranked list by construction; a
    /// profile with more open items than this has a detector problem, and
    /// draining it in one pass would be the wrong fix.
    private static let itemUploadLimit = 200
    private static let stateSyncLimit = 500

    /// Mirrored lifecycle states. Resolved and expired items ride along so a
    /// phone can show "this cleared itself" instead of having rows vanish.
    private static let mirroredStates: [BurnBarInboxItemState] = [.new, .updated, .resolved, .expired]

    private let context: CloudSyncContext
    private let vaultKeyProvider: any ConversationCloudVaultKeyProviding
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date

    private let state = Locked(CloudSyncDomainState())

    var isSyncing: Bool { state.read().isSyncing }
    var lastSyncError: String? { state.read().lastSyncError }
    var lastSyncDate: Date? { state.read().lastSyncDate }

    init(
        context: CloudSyncContext,
        vaultKeyProvider: any ConversationCloudVaultKeyProviding = MacConversationCloudVaultKeyProvider(),
        defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.context = context
        self.vaultKeyProvider = vaultKeyProvider
        self.defaults = defaults
        self.now = now
    }

    /// Live preference value. Absent means enabled — see `preferenceKey`.
    var isEnabled: Bool {
        defaults.object(forKey: Self.preferenceKey) as? Bool ?? true
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

        do {
            var watermark = loadWatermark(uid: uid)
            let itemCollection = context.firestoreGateway
                .collection("users").document(uid)
                .collection(AIInboxMirrorCodec.collection)
            let stateCollection = context.firestoreGateway
                .collection("users").document(uid)
                .collection(AIInboxMirrorCodec.stateCollection)

            try await uploadItems(uid: uid, gate: gate, collection: itemCollection, stateCollection: stateCollection, watermark: &watermark)
            try await uploadStates(deviceID: gate.account.deviceId, stateCollection: stateCollection, watermark: &watermark)
            try await downloadStates(stateCollection: stateCollection, watermark: &watermark)

            // Persisted only after every write in this cycle committed. A cycle
            // that threw partway leaves the stored watermark untouched, so the
            // next run retries the same rows rather than skipping work that
            // never reached the cloud.
            saveWatermark(watermark, uid: uid)
            state.withLock { $0.lastSyncDate = self.now() }
        } catch {
            state.withLock { $0.lastSyncError = error.localizedDescription }
            if Self.isPermissionDenied(error) {
                await context.suppressSync(for: CloudSyncBackoffPolicy.permissionDeniedCooldown)
            }
        }
    }

    // MARK: - Upload: items (Mac-owned)

    private func uploadItems(
        uid: String,
        gate: CloudSyncGate,
        collection: CloudSyncCollectionGateway,
        stateCollection: CloudSyncCollectionGateway,
        watermark: inout Watermark
    ) async throws {
        let rows = try await context.dataStore.fetchAIInboxRows(
            states: Self.mirroredStates,
            limit: Self.itemUploadLimit
        )
        let pending = rows.filter { watermark.items[$0.id] != Self.contentHash(for: $0) }

        // Pruning compares the mirror against the local set, so it is only sound
        // when that set is COMPLETE. At the page limit the tail is truncated,
        // and treating those rows as deleted would delete-then-reupload them on
        // every cycle. Below the limit we know we saw everything.
        let sawEveryLocalRow = rows.count < Self.itemUploadLimit
        let localIDs = Set(rows.map(\.id))
        let stale = sawEveryLocalRow
            ? watermark.items.keys.filter { localIDs.contains($0) == false }.sorted()
            : []

        guard pending.isEmpty == false || stale.isEmpty == false else { return }

        // Resolved lazily: key resolution can hit the keychain and Firestore, so
        // a cycle with nothing to publish must never pay for it.
        let resolvedKey = pending.isEmpty
            ? nil
            : try await vaultKeyProvider.keyForWriting(uid: uid, deviceId: gate.account.deviceId)
        let updatedAt = now()

        if let resolvedKey {
            for row in pending {
                let documentID = row.id
                let payload = try AIInboxMirrorCodec.encodeSealed(
                    Self.mirrorRecord(from: row),
                    vaultKey: resolvedKey.keyData,
                    vaultKeyID: resolvedKey.vaultKeyID,
                    uid: uid,
                    documentID: documentID,
                    updatedAt: updatedAt
                )
                try await withCloudSyncRetry(
                    policy: context.retryPolicy,
                    circuitBreaker: context.circuitBreaker,
                    domain: AIInboxMirrorCodec.collection
                ) {
                    try await collection.document(documentID).setData(payload, merge: true)
                }
                // Stamped per row, not after the loop: a failure partway through
                // must keep the rows that did land out of the next cycle.
                watermark.items[documentID] = Self.contentHash(for: row)
            }
        }

        try await prune(stale, collection: collection, stateCollection: stateCollection, watermark: &watermark)
    }

    /// Removes mirrored items whose local row is gone.
    ///
    /// Without this a phone would keep showing a finding the Mac has since
    /// dropped — a ghost that no local action can clear, because the row it
    /// would have to act on no longer exists.
    private func prune(
        _ documentIDs: [String],
        collection: CloudSyncCollectionGateway,
        stateCollection: CloudSyncCollectionGateway,
        watermark: inout Watermark
    ) async throws {
        for documentID in documentIDs {
            try await withCloudSyncRetry(
                policy: context.retryPolicy,
                circuitBreaker: context.circuitBreaker,
                domain: AIInboxMirrorCodec.collection
            ) {
                try await collection.document(documentID).deleteDocument()
            }
            // The sibling state doc is meaningless once its item is gone, and
            // leaving it behind would resurrect stale read/archive flags if the
            // same id were ever reused.
            try await withCloudSyncRetry(
                policy: context.retryPolicy,
                circuitBreaker: context.circuitBreaker,
                domain: AIInboxMirrorCodec.stateCollection
            ) {
                try await stateCollection.document(documentID).deleteDocument()
            }
            watermark.items.removeValue(forKey: documentID)
            watermark.states.removeValue(forKey: documentID)
        }
    }

    // MARK: - Upload: item state (user-owned)

    private func uploadStates(
        deviceID: String,
        stateCollection: CloudSyncCollectionGateway,
        watermark: inout Watermark
    ) async throws {
        let rows = try await context.dataStore.fetchAIInboxItemStates(limit: Self.stateSyncLimit)
        let pending = rows.filter { watermark.states[$0.id] != Self.stateStamp($0.updatedAt) }
        guard pending.isEmpty == false else { return }

        for row in pending {
            let payload = AIInboxMirrorCodec.encodeItemState(
                AIInboxMirrorItemState(
                    id: row.id,
                    readAt: row.readAt,
                    archivedAt: row.archivedAt,
                    snoozedUntil: row.snoozedUntil,
                    feedback: row.feedback,
                    updatedAt: row.updatedAt,
                    updatedByDeviceID: deviceID
                ),
                documentID: row.id
            )
            try await withCloudSyncRetry(
                policy: context.retryPolicy,
                circuitBreaker: context.circuitBreaker,
                domain: AIInboxMirrorCodec.stateCollection
            ) {
                // `merge: false` so clearing a flag locally (un-snooze, un-read)
                // actually clears it in the cloud. A merge would leave the old
                // field standing, because the codec omits nils rather than
                // writing explicit nulls.
                try await stateCollection.document(row.id).setData(payload, merge: false)
            }
            watermark.states[row.id] = Self.stateStamp(row.updatedAt)
        }
    }

    // MARK: - Download: item state (cloud → Mac)

    /// Pulls phone-written state so read/archive/snooze converge on the Mac.
    ///
    /// Conflicts resolve by `updatedAt` inside the store write, which compares
    /// and applies in one transaction — a UI action landing mid-sync cannot be
    /// clobbered by a download that read the row a moment earlier.
    private func downloadStates(
        stateCollection: CloudSyncCollectionGateway,
        watermark: inout Watermark
    ) async throws {
        // Ordered ASCENDING on the same field the watermark advances on, and
        // ordered on the unwatermarked first pass too.
        //
        // Both halves are load-bearing. An unordered `limit` returns an
        // ARBITRARY page, so a cycle that hits the cap could apply the newest
        // document while never seeing older unread ones — and the watermark,
        // advanced past them, would never query for them again. A phone-side
        // archive would be lost permanently rather than merely late.
        //
        // Ascending (not descending) is what makes truncation safe: the page is
        // a contiguous prefix of the unread window, so advancing to the newest
        // row in it leaves every row it did not return strictly greater than the
        // watermark, and therefore still queued for the next cycle.
        var query: any CloudSyncQueryGateway = stateCollection
            .order(by: "updatedAt", descending: false)
            .limit(to: Self.stateSyncLimit)
        if let since = watermark.statesDownloadedThrough {
            // Strictly-greater-than, so a doc already applied is not re-read
            // every cycle. Ties at the same second are re-read once and then
            // no-op in the store, which is cheaper than missing a write.
            query = stateCollection
                .whereField("updatedAt", isGreaterThan: Timestamp(date: since))
                .order(by: "updatedAt", descending: false)
                .limit(to: Self.stateSyncLimit)
        }

        let snapshot = try await withCloudSyncRetry(
            policy: context.retryPolicy,
            circuitBreaker: context.circuitBreaker,
            domain: AIInboxMirrorCodec.stateCollection
        ) {
            try await query.getDocuments()
        }

        // Advanced to the newest timestamp actually observed, never to `now()`:
        // a doc written while this query was in flight must still be picked up
        // by the next cycle rather than falling into a skipped window.
        var newest = watermark.statesDownloadedThrough
        for document in snapshot.documents {
            guard let remote = AIInboxMirrorCodec.decodeItemState(
                documentID: document.documentID,
                data: document.data()
            ) else {
                continue
            }
            let applied = try await context.dataStore.applyRemoteAIInboxItemState(remote)
            if applied {
                // The local row now carries the remote timestamp verbatim, so
                // stamping the watermark here keeps the next cycle from
                // re-uploading what it just downloaded.
                watermark.states[remote.id] = Self.stateStamp(remote.updatedAt)
            }
            if newest == nil || remote.updatedAt > (newest ?? .distantPast) {
                newest = remote.updatedAt
            }
        }
        watermark.statesDownloadedThrough = newest
    }

    // MARK: - Record mapping

    nonisolated static func mirrorRecord(from row: ControlPlaneStore.AIInboxRow) -> AIInboxMirrorRecord {
        AIInboxMirrorRecord(
            id: row.summary.id,
            fingerprint: row.summary.fingerprint,
            kind: row.summary.kind,
            priority: row.summary.priority,
            state: row.summary.state,
            occurrenceCount: row.summary.occurrenceCount,
            firstSeenAt: row.summary.firstSeenAt,
            lastSeenAt: row.summary.lastSeenAt,
            resolvedAt: row.summary.resolvedAt,
            modelProvenance: row.summary.modelProvenance,
            hasMemoryCandidates: row.summary.hasMemoryCandidates,
            title: row.summary.title,
            summaryMarkdown: row.summaryMarkdown,
            projectName: row.summary.projectName,
            resolutionNote: row.summary.resolutionNote,
            payload: row.payload
        )
    }

    // MARK: - Watermark

    /// Per-item upload fingerprints, keyed by account.
    ///
    /// Keyed by uid so signing into a second account starts from an empty
    /// watermark rather than inheriting the first account's "already uploaded"
    /// claims — which would leave the new account's inbox permanently empty in
    /// the cloud.
    struct Watermark: Codable, Sendable, Equatable {
        /// id → hash of the fields that reach the wire.
        var items: [String: String] = [:]
        /// id → last-synced `updatedAt`, as a stable stamp.
        var states: [String: String] = [:]
        /// Newest remote `updatedAt` already applied locally. `nil` until the
        /// first download, which then reads the whole (bounded) collection so a
        /// fresh Mac adopts a phone's existing read/archive flags.
        var statesDownloadedThrough: Date?
    }

    static func watermarkDefaultsKey(uid: String) -> String {
        "OpenBurnBarAIInboxMirrorWatermark.\(uid)"
    }

    private func loadWatermark(uid: String) -> Watermark {
        guard let data = defaults.data(forKey: Self.watermarkDefaultsKey(uid: uid)),
              let decoded = try? JSONDecoder().decode(Watermark.self, from: data) else { // try?-ok(corrupt cached watermark falls back to a fresh sync)
            return Watermark()
        }
        return decoded
    }

    private func saveWatermark(_ watermark: Watermark, uid: String) {
        guard let data = try? JSONEncoder().encode(watermark) else { return } // try?-ok(watermark cache is an optimisation; a failed write only costs a re-sync)
        defaults.set(data, forKey: Self.watermarkDefaultsKey(uid: uid))
    }

    /// Hashes exactly the fields the mirror writes.
    ///
    /// Local-only columns (`tick_id`, the user's own read/archive state) are
    /// excluded deliberately: they change without changing the document, and
    /// including them would defeat the gate they exist to serve.
    nonisolated static func contentHash(for row: ControlPlaneStore.AIInboxRow) -> String {
        let record = mirrorRecord(from: row)
        let payloadDigest = (try? JSONEncoder.aiInboxWatermark.encode(record.payload)) // try?-ok(unencodable payload hashes to empty so the row still mirrors)
            .map { CloudVaultCrypto.sha256Hex($0) } ?? ""
        let parts: [String] = [
            record.id,
            record.fingerprint,
            record.kind.rawValue,
            String(record.priority.rawValue),
            record.state.rawValue,
            String(record.occurrenceCount),
            stateStamp(record.firstSeenAt),
            stateStamp(record.lastSeenAt),
            record.resolvedAt.map(stateStamp) ?? "",
            record.modelProvenance,
            record.hasMemoryCandidates ? "1" : "0",
            String(record.schemaVersion),
            record.title,
            record.summaryMarkdown,
            record.projectName ?? "",
            record.resolutionNote ?? "",
            payloadDigest
        ]
        // `\u{1F}` is a unit separator, so a value containing the delimiter
        // cannot forge a different field split.
        return CloudVaultCrypto.sha256Hex(parts.joined(separator: "\u{1F}"))
    }

    /// Whole-second stamp. Firestore timestamps round-trip at sub-millisecond
    /// precision, so comparing raw `Date` bit patterns would report a change on
    /// every cycle; seconds is the resolution both sides genuinely agree on.
    nonisolated static func stateStamp(_ date: Date) -> String {
        String(Int64(date.timeIntervalSince1970.rounded()))
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

// Sorted keys + ISO-8601 dates so the same payload always hashes to the same
// digest; an unstable key order would make every cycle look like a change.
private extension JSONEncoder {
    static var aiInboxWatermark: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
