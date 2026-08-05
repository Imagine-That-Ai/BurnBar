@preconcurrency import Foundation
@preconcurrency import FirebaseAuth
import FirebaseCore
@preconcurrency import FirebaseFirestore
import OpenBurnBarKernel
import OSLog

// MARK: - AI Inbox Store
//
// Mobile reader for the AI Inbox the Mac mirrors into Firestore
// (`AIInboxMirrorRecord`). Symmetric with `CLIAgentChatReader`: auth-driven,
// snapshot-driven, sealed content opened inside the listener with the device's
// cloud vault key.
//
// Two collections, joined here:
//   • `ai_inbox_items`      — Mac-owned. The finding itself, sealed.
//   • `ai_inbox_item_state` — user-owned. Read / archive / snooze / feedback.
//
// The split is what makes acting from a phone work at all: the phone never
// writes the item, so a Mac republish can never clobber the tap the user just
// made, and the Mac pulls the state back down so the two inboxes converge.
//
// Writes apply locally before they leave the device. The whole point of the
// surface is triage, and triage that waits on a network round trip per tap does
// not feel like triage.

@MainActor
@Observable
final class AIInboxStore {

    /// One mirrored item joined with this user's own state for it.
    ///
    /// The Mac's `ControlPlaneStore.AIInboxRow` is the same join done against
    /// SQLite; keeping the derived properties named identically is what lets the
    /// two surfaces share ranking and filter semantics without sharing code that
    /// would have to import a database on one side and Firestore on the other.
    struct Item: Identifiable, Hashable, Sendable {
        let record: AIInboxMirrorRecord
        let state: AIInboxMirrorItemState?

        var id: String { record.id }
        var isUnread: Bool { state?.readAt == nil && record.isOpen }
        var isArchived: Bool { state?.archivedAt != nil }
        var feedback: String? { state?.feedback }

        func isSnoozed(now: Date = Date()) -> Bool {
            guard let until = state?.snoozedUntil else { return false }
            return until > now
        }

        /// Hidden from the default list but still reachable through a filter.
        func isHidden(now: Date = Date()) -> Bool {
            state?.isSuppressed(now: now) ?? false
        }
    }

    /// Which slice of the inbox is on screen. Mirrors `InboxModel.Filter`.
    enum Filter: String, CaseIterable, Identifiable, Sendable {
        case active
        case attention
        case resolved
        case archived

        var id: String { rawValue }

        var title: String {
            switch self {
            case .active: return "Active"
            case .attention: return "Attention"
            case .resolved: return "Resolved"
            case .archived: return "Archived"
            }
        }

        var emptyIcon: String {
            switch self {
            case .active: return "tray"
            case .attention: return "checkmark.circle"
            case .resolved: return "checkmark.seal"
            case .archived: return "archivebox"
            }
        }
    }

    /// Section headings. Grouped by recency rather than by kind because that is
    /// how the list is actually read: "what is happening now" first.
    enum Section: String, CaseIterable, Identifiable, Sendable {
        case attention
        case today
        case earlier
        case closed

        var id: String { rawValue }

        var title: String {
            switch self {
            case .attention: return "Needs attention"
            case .today: return "Today"
            case .earlier: return "Earlier"
            case .closed: return "Closed"
            }
        }
    }

    /// Writes one `ai_inbox_item_state` document. Injected so the whole surface
    /// is testable without a live Firestore.
    typealias StateWriter = @MainActor (_ documentID: String, _ payload: [String: Any]) async throws -> Void

    /// Matches the Mac list cap (`fetchAIInboxRows`) so both surfaces truncate
    /// at the same depth.
    static let itemLimit = 200

    /// State documents outlive the items they annotate — archiving keeps a row
    /// rather than deleting it — so this is deliberately larger than
    /// `itemLimit`. A cap equal to it would let a long archive history push the
    /// state for currently-visible rows out of the window, making read and
    /// archive marks silently disappear from the list.
    static let stateLimit = 500

    // MARK: - Published state

    private(set) var isLoading = false
    private(set) var lastError: String?
    private(set) var lastRefreshedAt: Date?
    /// True once a snapshot landed. Hoisted stores (`RootTabView` /
    /// `RootNavigationView`) use this so a tab return re-arms the listener
    /// instead of flashing the loading state over rows that are already correct.
    private(set) var hasLoadedOnce = false
    private(set) var isListening = false

    var filter: Filter = .active
    /// Free-text narrowing, fed by the host surface's search field so the search
    /// bar is never dead while the inbox is on screen.
    var searchQuery: String = ""
    var selectedID: String?

    /// Incremented by `focus(itemID:)`. The host surface observes it to bring
    /// the inbox forward for a `burnbar://inbox` deep link.
    ///
    /// A counter rather than a flag because two pushes for the SAME item must
    /// both navigate — with a plain `String?` the second would look like no
    /// change and the tap would do nothing.
    private(set) var focusRequestToken = 0

    private var records: [AIInboxMirrorRecord] = []
    private var itemStates: [String: AIInboxMirrorItemState] = [:]
    /// A deep-linked id that has not arrived in a snapshot yet.
    ///
    /// A push can outrun the Firestore sync that carries the item it names, so
    /// without this the first snapshot would "reconcile" the selection onto some
    /// unrelated top row and the tap would land on the wrong thing.
    private var pendingFocusID: String?

    // MARK: - Collaborators

    private let stateWriter: StateWriter
    private let logger = Logger(subsystem: "com.openburnbar.mobile", category: "AIInboxStore")
    @ObservationIgnored private lazy var deviceID: String = MobileDeviceIdentity.loadOrCreateDeviceId()
    @ObservationIgnored private nonisolated(unsafe) var authListenerHandle: AuthStateDidChangeListenerHandle?
    @ObservationIgnored private nonisolated(unsafe) var itemsListener: ListenerRegistration?
    @ObservationIgnored private nonisolated(unsafe) var statesListener: ListenerRegistration?

    init(
        stateWriter: StateWriter? = nil,
        observeAuthChanges: Bool? = nil
    ) {
        self.stateWriter = stateWriter ?? { documentID, payload in
            try await AIInboxStore.writeLiveItemState(documentID: documentID, payload: payload)
        }
        if observeAuthChanges ?? (stateWriter == nil) {
            attachAuthListener()
        }
    }

    deinit {
        if let authListenerHandle {
            Auth.auth().removeStateDidChangeListener(authListenerHandle)
        }
        itemsListener?.remove()
        statesListener?.remove()
    }

    // MARK: - Derived state

    /// Every known item, ranked. Attention first, then unread, then recency.
    ///
    /// `AIInboxMirrorRecord.rank` is the cross-platform ordering, but it cannot
    /// see per-user state, so unread is layered in here exactly where the Mac's
    /// `InboxModel.ranked` puts it and the shared rank settles the rest.
    var items: [Item] {
        records
            .map { Item(record: $0, state: itemStates[$0.id]) }
            .sorted(by: Self.ranked)
    }

    static func ranked(_ lhs: Item, _ rhs: Item) -> Bool {
        if lhs.record.priority != rhs.record.priority {
            return lhs.record.priority < rhs.record.priority
        }
        if lhs.isUnread != rhs.isUnread {
            return lhs.isUnread
        }
        return AIInboxMirrorRecord.rank(lhs.record, rhs.record)
    }

    var visibleItems: [Item] {
        let now = Date()
        return items.filter { item in
            guard matchesSearch(item) else { return false }
            switch filter {
            case .active:
                return item.record.isOpen && !item.isHidden(now: now)
            case .attention:
                return item.record.isOpen && !item.isHidden(now: now) && item.record.priority <= .p2
            case .resolved:
                return !item.record.isOpen
            case .archived:
                return item.isArchived
            }
        }
    }

    var sections: [(section: Section, items: [Item])] {
        let visible = visibleItems
        guard filter != .resolved, filter != .archived else {
            return visible.isEmpty ? [] : [(.closed, visible)]
        }

        let startOfToday = Calendar.current.startOfDay(for: Date())
        var attention: [Item] = []
        var today: [Item] = []
        var earlier: [Item] = []

        for item in visible {
            if item.record.priority <= .p2 {
                attention.append(item)
            } else if item.record.lastSeenAt >= startOfToday {
                today.append(item)
            } else {
                earlier.append(item)
            }
        }

        return [
            (Section.attention, attention),
            (Section.today, today),
            (Section.earlier, earlier)
        ].filter { $0.1.isEmpty == false }
    }

    var unreadCount: Int {
        let now = Date()
        return items.filter { $0.isUnread && !$0.isHidden(now: now) }.count
    }

    var attentionCount: Int {
        let now = Date()
        return items.filter { $0.record.isOpen && !$0.isHidden(now: now) && $0.record.priority <= .p2 }.count
    }

    var selectedItem: Item? {
        guard let selectedID else { return nil }
        return items.first { $0.id == selectedID }
    }

    /// True once the Mac has mirrored anything at all. Distinguishes "nothing
    /// needs you" from "the inbox has never run", which deserve different copy.
    var hasEverReceivedAnItem: Bool { records.isEmpty == false }

    private func matchesSearch(_ item: Item) -> Bool {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard query.isEmpty == false else { return true }
        if item.record.title.lowercased().contains(query) { return true }
        if item.record.summaryMarkdown.lowercased().contains(query) { return true }
        if item.record.projectName?.lowercased().contains(query) == true { return true }
        return false
    }

    // MARK: - Lifecycle

    /// Idempotent mount hook, matching the hoisted-store convention
    /// (`DashboardStore.loadIfNeeded`). The inbox is listener-only — there is no
    /// separate fetch to skip — so a warm store keeps its rows and only re-arms
    /// the listener `onDisappear` tore down.
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
        itemsListener?.remove()
        itemsListener = nil
        statesListener?.remove()
        statesListener = nil
        isListening = false
        isLoading = false
    }

    /// Drops every trace of the signed-out account.
    ///
    /// Exhaustive by design: a surviving `pendingFocusID` would pin a stale
    /// selection against the NEXT user's first snapshot, and stale `records`
    /// would render one user's findings under another's session.
    func reset() {
        stopListening()
        records = []
        itemStates = [:]
        hasLoadedOnce = false
        lastRefreshedAt = nil
        lastError = nil
        selectedID = nil
        pendingFocusID = nil
        searchQuery = ""
        filter = .active
    }

    /// Arms the listener and asks the host to show the inbox.
    ///
    /// A deep link may name an item this device has not received yet, so the
    /// filter is widened to `.active` and any search narrowing is cleared —
    /// otherwise a push could land the user on a list that legitimately excludes
    /// the very item they tapped.
    func focus(itemID: String?) {
        filter = .active
        searchQuery = ""
        if let itemID {
            selectedID = itemID
            // Held until a snapshot actually contains it, so an in-flight sync
            // cannot cause the selection to be reconciled away.
            pendingFocusID = records.contains { $0.id == itemID } ? nil : itemID
        }
        loadIfNeeded()
        focusRequestToken &+= 1
    }

    // MARK: - Snapshot application
    //
    // Separated from the listeners so the ranking, sectioning, and filtering can
    // be exercised against fixtures without a Firestore in the loop.

    func applyRecords(_ decoded: [AIInboxMirrorRecord]) {
        records = decoded
        hasLoadedOnce = true
        isLoading = false
        lastRefreshedAt = Date()
        // Cleared only here: a failed write sets `lastError` and no item snapshot
        // follows a write that never landed, so the message survives long enough
        // to be read.
        lastError = nil
        reconcileSelection()
    }

    func applyItemStates(_ states: [AIInboxMirrorItemState]) {
        itemStates = Dictionary(states.map { ($0.id, $0) }, uniquingKeysWith: { lhs, rhs in
            lhs.updatedAt >= rhs.updatedAt ? lhs : rhs
        })
        reconcileSelection()
    }

    private func reconcileSelection() {
        guard let selectedID else { return }
        if let pendingFocusID {
            // A deep-linked item that has not synced yet. Hold the selection
            // until it lands (or until it arrives and clears the hold) rather
            // than redirecting the user to an unrelated row.
            guard records.contains(where: { $0.id == pendingFocusID }) else { return }
            self.pendingFocusID = nil
        }
        if visibleItems.contains(where: { $0.id == selectedID }) == false {
            self.selectedID = visibleItems.first?.id
        }
    }

    // MARK: - Actions

    /// Selecting is reading, so the unread dot clears on the tap rather than on
    /// the round trip.
    func select(_ id: String) async {
        selectedID = id
        guard items.first(where: { $0.id == id })?.isUnread == true else { return }
        await markRead(id)
    }

    func markRead(_ id: String) async {
        await mutateState(id: id) { state in
            var next = state
            next.readAt = state.readAt ?? Date()
            return next
        }
    }

    func toggleRead(_ id: String) async {
        let makeUnread = itemStates[id]?.readAt != nil
        await mutateState(id: id) { state in
            var next = state
            next.readAt = makeUnread ? nil : Date()
            return next
        }
    }

    func archive(_ id: String) async {
        await mutateState(id: id) { state in
            var next = state
            next.archivedAt = Date()
            return next
        }
        // Reconcile AFTER the mutation: the item only becomes invisible once the
        // new state is in, and clearing the selection first would make
        // `reconcileSelection` skip its own guard and leave the detail column
        // blank instead of advancing to the next row.
        reconcileSelection()
    }

    func unarchive(_ id: String) async {
        await mutateState(id: id) { state in
            var next = state
            next.archivedAt = nil
            return next
        }
    }

    func snooze(_ id: String, for interval: TimeInterval) async {
        await mutateState(id: id) { state in
            var next = state
            next.snoozedUntil = Date().addingTimeInterval(interval)
            return next
        }
        reconcileSelection()
    }

    /// `nil` clears the rating; the raw values are the only three the rules
    /// accept (`AIInboxMirrorCodec.allowedFeedbackValues`).
    func setFeedback(_ id: String, useful: Bool?) async {
        let value = useful.map { $0 ? "useful" : "not_useful" }
        let current = itemStates[id]?.feedback
        await mutateState(id: id) { state in
            var next = state
            next.feedback = current == value ? nil : value
            return next
        }
    }

    /// Bounded to what the user can currently see: "mark all read" should never
    /// mean "write two hundred documents".
    func markEverythingRead() async {
        for item in visibleItems where item.isUnread {
            await markRead(item.id)
        }
    }

    private func mutateState(
        id: String,
        _ transform: (AIInboxMirrorItemState) -> AIInboxMirrorItemState
    ) async {
        var next = transform(itemStates[id] ?? AIInboxMirrorItemState(id: id))
        next.updatedAt = Date()
        next.updatedByDeviceID = deviceID
        itemStates[id] = next

        do {
            try await stateWriter(id, Self.statePayload(for: next))
        } catch {
            lastError = error.localizedDescription
            logger.warning("AI inbox state write failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Builds the `merge: true` payload for one state document.
    ///
    /// `merge: true` cannot clear a field by omitting it and the codec omits
    /// every `nil`, so un-archiving, un-snoozing, and clearing a rating would all
    /// be silent no-ops. The local value is the complete description of the
    /// user's intent, so anything it does not carry is deleted explicitly.
    static func statePayload(for state: AIInboxMirrorItemState) -> [String: Any] {
        var payload = AIInboxMirrorCodec.encodeItemState(state, documentID: state.id)
        for key in AIInboxMirrorCodec.stateDocumentKeys where payload[key] == nil {
            payload[key] = FieldValue.delete()
        }
        return payload
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
        let root = Firestore.firestore().collection("users").document(uid)

        itemsListener = root
            .collection(AIInboxMirrorCodec.collection)
            .order(by: "lastSeenAt", descending: true)
            .limit(to: Self.itemLimit)
            .addSnapshotListener { [weak self] snapshot, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let error {
                        self.isLoading = false
                        self.lastError = error.localizedDescription
                        self.logger.warning("AI inbox listener failed: \(String(describing: error), privacy: .public)")
                        return
                    }
                    // The vault key is resolved per snapshot rather than cached so a
                    // key rotation on another device takes effect on the next
                    // delivery instead of leaving the list permanently unreadable.
                    let key: MobileCloudVaultResolvedKey?
                    do {
                        key = try await MobileCloudVaultKeyAccess.keyForReading(uid: uid)
                    } catch {
                        self.logger.warning("AI inbox vault key read failed: \(String(describing: error), privacy: .public)")
                        key = nil
                    }
                    let decoded = snapshot?.documents.compactMap { document in
                        Self.decodeDocument(
                            documentID: document.documentID,
                            uid: uid,
                            data: document.data(),
                            vaultKey: key?.keyData
                        )
                    } ?? []
                    self.applyRecords(decoded)
                }
            }

        statesListener = root
            .collection(AIInboxMirrorCodec.stateCollection)
            // Ordered, not just capped. State documents accumulate for the life
            // of the account (archives are kept, never deleted), so an unordered
            // `limit` would return an ARBITRARY slice — and read/archive state
            // for the rows actually on screen would appear to vanish at random.
            // Newest-touched-first is the right slice: those are the items the
            // user has most recently acted on.
            .order(by: "updatedAt", descending: true)
            .limit(to: Self.stateLimit)
            .addSnapshotListener { [weak self] snapshot, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let error {
                        self.logger.warning("AI inbox state listener failed: \(String(describing: error), privacy: .public)")
                        return
                    }
                    let decoded = snapshot?.documents.compactMap { document in
                        AIInboxMirrorCodec.decodeItemState(
                            documentID: document.documentID,
                            data: document.data()
                        )
                    } ?? []
                    self.applyItemStates(decoded)
                }
            }
    }

    /// Opens one mirror document.
    ///
    /// Unlike `cli_sessions` there is no legacy plaintext form to fall back to —
    /// the mirror has been sealed since its first write — so a missing key means
    /// the row is dropped rather than rendered with a blank body.
    static func decodeDocument(
        documentID: String,
        uid: String,
        data: [String: Any],
        vaultKey: Data?
    ) -> AIInboxMirrorRecord? {
        guard let vaultKey else { return nil }
        return AIInboxMirrorCodec.decodeSealed(
            documentID: documentID,
            uid: uid,
            data: data,
            vaultKey: vaultKey
        )
    }

    private static func writeLiveItemState(documentID: String, payload: [String: Any]) async throws {
        guard FirebaseApp.app() != nil else { return }
        guard let uid = Auth.auth().currentUser?.uid, uid.isEmpty == false else { return }
        try await Firestore.firestore()
            .collection("users").document(uid)
            .collection(AIInboxMirrorCodec.stateCollection).document(documentID)
            .setData(payload, merge: true)
    }
}
