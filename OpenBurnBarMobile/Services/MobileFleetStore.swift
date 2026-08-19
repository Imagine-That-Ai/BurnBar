@preconcurrency import Foundation
@preconcurrency import FirebaseAuth
import FirebaseCore
@preconcurrency import FirebaseFirestore
import OpenBurnBarKernel
import OSLog

// MARK: - Mobile Fleet Store
//
// Mobile reader for the fleet snapshot the Mac mirrors into Firestore
// (`FleetMirrorCodec`, one sealed document at `users/{uid}/fleet_snapshot/
// current`). Symmetric with `AIInboxStore`: auth-driven, snapshot-driven,
// sealed content opened inside the listener with the device's cloud vault key.
//
// Read-only by design (v1): orchestrator designation and directives stay
// Mac/daemon-local, so unlike the inbox there is no state collection and no
// write path at all. What the store owes the UI instead is *honesty about
// freshness* — the snapshot is produced by another machine on a cadence, so
// "the Mac stopped publishing" is a first-class state (`macOffline`), never
// a stale board rendered as current.

@MainActor
@Observable
final class MobileFleetStore {

    // MARK: - State

    /// The typed load state. Mirrors the Mac's `FleetLoadState` shape with the
    /// transport swapped: the Mac's `daemonDown` becomes `macOffline`, because
    /// on a phone the honest failure is "the Mac stopped publishing", observed
    /// through a stale (or absent) mirror write time.
    enum State: Equatable {
        /// No listener delivery yet.
        case loading
        /// A fresh snapshot with at least one running agent.
        case ready(BurnBarFleetSnapshot)
        /// A fresh snapshot with zero running agents — or, with `nil`, a
        /// mirror document that exists but could not be opened on this device
        /// (`lastError` carries the reason). The Mac is publishing either way,
        /// so `macOffline` would be a lie here.
        case empty(BurnBarFleetSnapshot?)
        /// The document is missing, or its `updatedAt` is older than
        /// `offlineThresholdSeconds` — the Mac is asleep, offline, or has the
        /// mirror turned off. Carries the last known mirror write time so the
        /// pane can say how long ago the Mac was last heard from.
        case macOffline(lastUpdatedAt: Date?)

        /// The snapshot carried by the state, if any.
        var snapshot: BurnBarFleetSnapshot? {
            switch self {
            case .ready(let snapshot):
                return snapshot
            case .empty(let snapshot):
                return snapshot
            case .loading, .macOffline:
                return nil
            }
        }
    }

    /// One listener delivery, reduced to what state derivation needs. Kept as
    /// its own type — rather than feeding the raw Firestore snapshot through —
    /// so tests can drive the full state machine without Firestore in the loop.
    enum DocumentOutcome: Equatable, Sendable {
        /// The mirror document does not exist.
        case missing
        /// The document exists but could not be opened (no vault key, wrong
        /// key, future schema). The reason is user-facing.
        case undecodable(reason: String)
        /// The document opened cleanly.
        case decoded(FleetMirrorDocument)
    }

    /// Opens one raw document dictionary. Injected so decoding is swappable in
    /// tests; the default is `decodeDocument`, the store's only codec call.
    typealias DocumentDecoder = @MainActor (
        _ documentID: String,
        _ uid: String,
        _ data: [String: Any],
        _ vaultKey: Data?
    ) -> FleetMirrorDocument?

    // MARK: - Staleness contract

    /// `macOffline` triggers when `now - updatedAt` exceeds
    /// `max(3 × cadenceSeconds, 15 minutes)`. Three cadences forgives the
    /// publisher skipping a couple of cycles (unchanged-snapshot writes are
    /// hash-gated on the Mac); the 15-minute floor keeps a short cadence from
    /// declaring the Mac offline the moment it naps a lid-close.
    static let offlineCadenceMultiplier = 3
    static let minimumOfflineThresholdSeconds: TimeInterval = 15 * 60

    static func offlineThresholdSeconds(cadenceSeconds: Int) -> TimeInterval {
        max(
            TimeInterval(offlineCadenceMultiplier * max(0, cadenceSeconds)),
            minimumOfflineThresholdSeconds
        )
    }

    /// How often the derived state is re-checked while listening. Firestore
    /// only calls back on *writes*, so a Mac that silently stops publishing
    /// would otherwise leave a "fresh" board on screen forever.
    static let stalenessCheckIntervalSeconds: TimeInterval = 60

    // MARK: - Published state

    private(set) var state: State = .loading
    private(set) var isLoading = false
    private(set) var lastError: String?
    /// Mirror write time of the newest decoded document (the "Synced from
    /// your Mac …" provenance, and the staleness signal).
    private(set) var lastUpdatedAt: Date?
    /// Snapshot generation time on the Mac from the newest decoded document.
    private(set) var lastGeneratedAt: Date?
    /// True once a listener delivery landed. Hoisted stores use this so a tab
    /// return re-arms the listener instead of flashing the loading state over
    /// a board that is already correct.
    private(set) var hasLoadedOnce = false
    private(set) var isListening = false

    /// The newest decoded document, retained so `refreshDerivedState()` can
    /// re-derive staleness as time passes without a new Firestore write.
    /// Cleared on `.missing` (a deleted document must not be resurrected by
    /// the ticker) but kept across `.undecodable` (the retained board IS this
    /// document, and it must still age to `macOffline`).
    private var latestDocument: FleetMirrorDocument?

    // MARK: - Collaborators

    private let decoder: DocumentDecoder
    private let nowProvider: () -> Date
    private let logger = Logger(subsystem: "com.openburnbar.mobile", category: "MobileFleetStore")
    @ObservationIgnored private nonisolated(unsafe) var authListenerHandle: AuthStateDidChangeListenerHandle?
    @ObservationIgnored private nonisolated(unsafe) var snapshotListener: ListenerRegistration?
    @ObservationIgnored private nonisolated(unsafe) var stalenessTask: Task<Void, Never>?

    init(
        decoder: DocumentDecoder? = nil,
        now: (() -> Date)? = nil,
        observeAuthChanges: Bool? = nil
    ) {
        self.decoder = decoder ?? { documentID, uid, data, vaultKey in
            MobileFleetStore.decodeDocument(documentID: documentID, uid: uid, data: data, vaultKey: vaultKey)
        }
        self.nowProvider = now ?? { Date() }
        if observeAuthChanges ?? (decoder == nil && now == nil) {
            attachAuthListener()
        }
    }

    deinit {
        if let authListenerHandle {
            Auth.auth().removeStateDidChangeListener(authListenerHandle)
        }
        snapshotListener?.remove()
        stalenessTask?.cancel()
    }

    // MARK: - Lifecycle

    /// Idempotent mount hook, matching the hoisted-store convention
    /// (`AIInboxStore.loadIfNeeded`). Listener-only surface — a warm store
    /// keeps its board and only re-arms the listener `onDisappear` tore down.
    func loadIfNeeded() {
        if !hasLoadedOnce { isLoading = true }
        startListening()
    }

    func startListening() {
        guard !isListening else { return }
        guard FirebaseApp.app() != nil else { return }
        guard let uid = Auth.auth().currentUser?.uid, uid.isEmpty == false else { return }
        startListening(uid: uid)
    }

    func stopListening() {
        snapshotListener?.remove()
        snapshotListener = nil
        stalenessTask?.cancel()
        stalenessTask = nil
        isListening = false
        isLoading = false
    }

    /// Drops every trace of the signed-out account: one user's fleet must
    /// never render under another's session, and a retained `latestDocument`
    /// would let `refreshDerivedState()` resurrect the old board.
    func reset() {
        stopListening()
        state = .loading
        latestDocument = nil
        lastError = nil
        lastUpdatedAt = nil
        lastGeneratedAt = nil
        hasLoadedOnce = false
    }

    // MARK: - State derivation
    //
    // Separated from the listener so the whole state machine is exercisable
    // against fixtures without a Firestore in the loop.

    func apply(_ outcome: DocumentOutcome) {
        hasLoadedOnce = true
        isLoading = false

        switch outcome {
        case .missing:
            // Deliberately NOT clearing `lastUpdatedAt`: if the doc was seen
            // and then deleted, "last heard from the Mac at X" is still true
            // and is exactly what the offline pane should say. The retained
            // document IS cleared — the ticker must not resurrect a board the
            // mirror no longer carries.
            latestDocument = nil
            state = .macOffline(lastUpdatedAt: lastUpdatedAt)

        case .undecodable(let reason):
            // Surface the reason but never blank a healthy board over one bad
            // delivery (same rule as the Mac's `FleetService`). The retained
            // board still goes `macOffline` naturally as its `updatedAt` ages.
            // With no board to keep, `empty(nil)` is the honest floor: the
            // document exists — the Mac IS publishing — so `macOffline` would
            // point the user at the wrong machine.
            lastError = reason
            if state.snapshot == nil {
                state = .empty(nil)
            }

        case .decoded(let document):
            // Cleared only here: no delivery follows a decode failure until
            // the Mac writes again, so the message survives long enough to be
            // read — and a readable write is the proof it no longer applies.
            lastError = nil
            latestDocument = document
            lastUpdatedAt = document.updatedAt
            lastGeneratedAt = document.generatedAt
            state = derivedState(for: document)
        }
    }

    /// Re-derives the state from the newest decoded document with the current
    /// clock. This is what flips a quiet board to `macOffline` — Firestore
    /// will not call back just because time passed.
    func refreshDerivedState() {
        guard let latestDocument else { return }
        let derived = derivedState(for: latestDocument)
        if derived != state {
            state = derived
        }
    }

    private func derivedState(for document: FleetMirrorDocument) -> State {
        let age = nowProvider().timeIntervalSince(document.updatedAt)
        if age > Self.offlineThresholdSeconds(cadenceSeconds: document.snapshot.cadenceSeconds) {
            return .macOffline(lastUpdatedAt: document.updatedAt)
        }
        return document.snapshot.runningCount > 0
            ? .ready(document.snapshot)
            : .empty(document.snapshot)
    }

    // MARK: - Firestore

    private func attachAuthListener() {
        guard FirebaseApp.app() != nil else { return }
        authListenerHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in
                guard let self else { return }
                guard let uid = user?.uid, uid.isEmpty == false else {
                    self.reset()
                    return
                }
                self.stopListening()
                self.isLoading = true
                self.startListening(uid: uid)
            }
        }
    }

    private func startListening(uid: String) {
        isListening = true

        snapshotListener = FirestoreRepository.database
            .collection("users").document(uid)
            .collection(FleetMirrorCodec.collection)
            .document(FleetMirrorCodec.documentID)
            .addSnapshotListener { [weak self] snapshot, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let error {
                        self.isLoading = false
                        self.lastError = error.localizedDescription
                        self.logger.warning("Fleet mirror listener failed: \(String(describing: error), privacy: .public)")
                        return
                    }
                    guard let snapshot else { return }
                    guard snapshot.exists, let data = snapshot.data() else {
                        self.apply(.missing)
                        return
                    }
                    // The vault key is resolved per delivery rather than
                    // cached so a key rotation on another device takes effect
                    // on the next write instead of leaving the board
                    // permanently unreadable.
                    let key: MobileCloudVaultResolvedKey?
                    do {
                        key = try await MobileCloudVaultKeyAccess.keyForReading(uid: uid)
                    } catch {
                        self.logger.warning("Fleet vault key read failed: \(String(describing: error), privacy: .public)")
                        key = nil
                    }
                    if let document = self.decoder(snapshot.documentID, uid, data, key?.keyData) {
                        self.apply(.decoded(document))
                    } else {
                        self.apply(.undecodable(reason: "The fleet snapshot from your Mac can't be decoded on this device."))
                    }
                }
            }

        armStalenessTicker()
    }

    private func armStalenessTicker() {
        stalenessTask?.cancel()
        stalenessTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.stalenessCheckIntervalSeconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.refreshDerivedState()
            }
        }
    }

    // MARK: - Decoding

    /// Opens the single mirror document. The store's ONLY `FleetMirrorCodec`
    /// call site, and static so tests can round-trip real sealed fixtures.
    ///
    /// The whole board is sealed — there is no plaintext fallback — so a
    /// missing key means no board rather than a fabricated one.
    static func decodeDocument(
        documentID: String,
        uid: String,
        data: [String: Any],
        vaultKey: Data?
    ) -> FleetMirrorDocument? {
        guard let vaultKey else { return nil }
        return FleetMirrorCodec.decodeSealed(
            documentID: documentID,
            uid: uid,
            data: data,
            vaultKey: vaultKey
        )
    }
}
