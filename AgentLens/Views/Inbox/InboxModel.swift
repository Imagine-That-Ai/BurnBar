import Foundation
import Observation
import OpenBurnBarKernel

/// View model for the AI Inbox surface.
///
/// Deliberately closure-injected (the `MemoryReviewInboxModel` contract) so the
/// whole surface is testable without a database, and so the view never learns
/// what a `DataStore` is.
///
/// Freshness follows the repo's established idiom rather than inventing one:
/// there is no GRDB `ValueObservation` anywhere in this app, so the model
/// refreshes on a cheap **change marker** (`aiInboxChangeMarker`) driven by the
/// shared `BackgroundCadenceCoordinator`. An idle inbox costs one aggregate
/// query per cadence tick and re-renders nothing.
///
/// Management state (pin, colour tag, category, manual order, saved, deleted)
/// lives in `InboxShelfStore` rather than in the shared database: the daemon
/// never reads it, and a new column would drag a whole schema version behind it.
/// See that type for the full rationale.
@Observable
@MainActor
final class InboxModel {
    typealias LoadRows = @Sendable ([BurnBarInboxItemState]?) async throws -> [ControlPlaneStore.AIInboxRow]
    typealias LoadMarker = @Sendable () async throws -> String
    typealias MutateItem = @Sendable (String) async throws -> Void
    typealias SetArchived = @Sendable (String, Bool) async throws -> Void
    typealias Snooze = @Sendable (String, Date?) async throws -> Void
    typealias SetFeedback = @Sendable (String, String?) async throws -> Void
    typealias LoadRuns = @Sendable () async throws -> [BurnBarInboxRunTelemetry]

    /// Which slice of the inbox is on screen.
    enum Filter: String, CaseIterable, Identifiable, Sendable {
        case active
        case attention
        case saved
        case resolved
        case archived

        var id: String { rawValue }

        var title: String {
            switch self {
            case .active: return "Active"
            case .attention: return "Needs attention"
            case .saved: return "Saved"
            case .resolved: return "Resolved"
            case .archived: return "Archived"
            }
        }

        var states: [BurnBarInboxItemState]? {
            switch self {
            case .active, .attention, .archived: return BurnBarInboxItemState.openStates
            case .resolved: return [.resolved, .expired]
            // Saving is a deliberate keep-this decision, so the tab must not
            // lose an item the moment the daemon resolves it: load every state.
            case .saved: return nil
            }
        }

        var emptyIcon: String {
            switch self {
            case .active: return "tray"
            case .attention: return "checkmark.circle"
            case .saved: return "star"
            case .resolved: return "checkmark.seal"
            case .archived: return "archivebox"
            }
        }
    }

    /// How the list is ordered inside each section.
    ///
    /// `priority` is the default and reproduces the original behaviour exactly —
    /// the recency grouping is the information architecture and a reorder
    /// free-for-all would dissolve it. Dragging is therefore only enabled in
    /// `manual`, the mode whose entire point is that the user owns the order.
    enum Ordering: String, CaseIterable, Identifiable, Sendable {
        case priority
        case newest
        case manual

        var id: String { rawValue }

        var title: String {
            switch self {
            case .priority: return "Priority"
            case .newest: return "Newest"
            case .manual: return "Manual"
            }
        }

        var symbolName: String {
            switch self {
            case .priority: return "exclamationmark.triangle"
            case .newest: return "clock"
            case .manual: return "hand.draw"
            }
        }

        var explanation: String {
            switch self {
            case .priority: return "Urgent first, then unread, then most recent."
            case .newest: return "Most recently seen first, whatever its priority."
            case .manual: return "The order you dragged them into. Drag a row to move it."
            }
        }

        var allowsManualReorder: Bool { self == .manual }
    }

    /// Section headings in the list. Grouping by recency (rather than by kind)
    /// matches how the surface is actually read: "what is happening now" first.
    enum Section: String, CaseIterable, Identifiable, Sendable {
        case pinned
        case attention
        case today
        case earlier
        case closed
        case saved
        case manual

        var id: String { rawValue }

        var title: String {
            switch self {
            case .pinned: return "Pinned"
            case .attention: return "Needs attention"
            case .today: return "Today"
            case .earlier: return "Earlier"
            case .closed: return "Closed"
            case .saved: return "Saved"
            case .manual: return "Ordered by you"
            }
        }
    }

    /// What a click on a row means, once modifier keys are resolved.
    enum SelectionIntent: Sendable, Equatable {
        /// Plain click: this row and only this row.
        case replace
        /// Command-click: add or remove this row from the selection.
        case toggle
        /// Shift-click: select everything between the anchor and this row.
        case extend
    }

    /// Everything needed to put a delete back exactly as it was.
    struct DeleteUndo: Equatable, Sendable {
        struct Record: Equatable, Sendable {
            let id: String
            /// Whether the item was already archived before the delete. Undo
            /// must restore *that* state, not blanket-unarchive.
            let wasArchived: Bool
        }

        let records: [Record]
        let performedAt: Date

        var count: Int { records.count }

        var message: String {
            count == 1 ? "1 item deleted" : "\(count) items deleted"
        }
    }

    private(set) var rows: [ControlPlaneStore.AIInboxRow] = []
    private(set) var runs: [BurnBarInboxRunTelemetry] = []
    private(set) var isLoading = false
    private(set) var lastRefreshedAt: Date?
    private(set) var lastMarker: String?
    var errorMessage: String?
    var filter: Filter = .active {
        didSet {
            guard filter != oldValue else { return }
            Task { await load(force: true) }
        }
    }
    var ordering: Ordering = .priority
    var selectedID: String?

    /// Multi-selection for bulk actions. Empty means "act on the open item".
    private(set) var selection: Set<String> = []
    /// Where a shift-click range starts.
    private(set) var selectionAnchor: String?
    /// Non-nil while a delete can still be taken back.
    private(set) var deleteUndo: DeleteUndo?

    /// Local management state. Injected so tests get an isolated store instead
    /// of the user's real arrangement.
    let shelf: InboxShelfStore

    private let loadRows: LoadRows
    private let loadMarker: LoadMarker
    private let markRead: MutateItem
    private let markUnread: MutateItem
    private let setArchived: SetArchived
    private let snooze: Snooze
    private let setFeedback: SetFeedback
    private let markAllRead: @Sendable () async throws -> Void
    private let loadRuns: LoadRuns
    private let undoWindow: TimeInterval
    @ObservationIgnored private var undoExpiryTask: Task<Void, Never>?

    /// How long the undo banner survives before the delete becomes final.
    static let defaultUndoWindow: TimeInterval = 12

    /// Matches `ControlPlaneStore.fetchAIInboxRows(limit:)`'s default page size.
    /// A listing that reaches it may be truncated, so it cannot be treated as
    /// the authoritative id set for pruning.
    static let authoritativeIDCeiling = 200

    /// Anything above this asks before deleting. One item is a click you can
    /// undo; a batch is a click you cannot see the consequences of.
    static let bulkDeleteConfirmationThreshold = 1

    init(
        loadRows: @escaping LoadRows,
        loadMarker: @escaping LoadMarker,
        markRead: @escaping MutateItem,
        markUnread: @escaping MutateItem,
        setArchived: @escaping SetArchived,
        snooze: @escaping Snooze,
        setFeedback: @escaping SetFeedback,
        markAllRead: @escaping @Sendable () async throws -> Void,
        loadRuns: @escaping LoadRuns,
        shelf: InboxShelfStore,
        undoWindow: TimeInterval = InboxModel.defaultUndoWindow
    ) {
        self.loadRows = loadRows
        self.loadMarker = loadMarker
        self.markRead = markRead
        self.markUnread = markUnread
        self.setArchived = setArchived
        self.snooze = snooze
        self.setFeedback = setFeedback
        self.markAllRead = markAllRead
        self.loadRuns = loadRuns
        self.shelf = shelf
        self.undoWindow = undoWindow
    }

    // MARK: - Derived state

    /// Rows for the current filter, ranked.
    ///
    /// Deleted rows are subtracted **first**, before any filter branch, so a
    /// delete is a real hide-forever: it disappears from Archived and Resolved
    /// too, not just from the tab it was deleted from.
    var visibleRows: [ControlPlaneStore.AIInboxRow] {
        let entries = shelf.entries
        let live = rows.filter { entries[$0.id]?.isDeleted != true }
        let filtered: [ControlPlaneStore.AIInboxRow]
        switch filter {
        case .active:
            filtered = live.filter { $0.isHidden == false }
        case .attention:
            filtered = live.filter { $0.isHidden == false && $0.summary.priority <= .p2 }
        case .saved:
            filtered = live.filter { entries[$0.id]?.isSaved == true }
        case .resolved:
            filtered = live
        case .archived:
            filtered = live.filter(\.isArchived)
        }
        return Self.sorted(filtered, ordering: ordering, entries: entries)
    }

    var sections: [(section: Section, rows: [ControlPlaneStore.AIInboxRow])] {
        let visible = visibleRows
        guard visible.isEmpty == false else { return [] }
        let entries = shelf.entries

        var result: [(section: Section, rows: [ControlPlaneStore.AIInboxRow])] = []
        let pinned = visible.filter { entries[$0.id]?.pinned == true }
        if pinned.isEmpty == false {
            result.append((.pinned, pinned))
        }

        let rest = visible.filter { entries[$0.id]?.pinned != true }
        guard rest.isEmpty == false else { return result }

        // Manual is a single run by definition — the user's order IS the
        // grouping, and slicing it by recency would hide the thing they built.
        if ordering == .manual {
            result.append((.manual, rest))
            return result
        }

        switch filter {
        case .resolved, .archived:
            result.append((.closed, rest))
            return result
        case .saved:
            result.append((.saved, rest))
            return result
        case .active, .attention:
            break
        }

        let startOfToday = Calendar.current.startOfDay(for: Date())
        var attention: [ControlPlaneStore.AIInboxRow] = []
        var today: [ControlPlaneStore.AIInboxRow] = []
        var earlier: [ControlPlaneStore.AIInboxRow] = []

        for row in rest {
            if row.summary.priority <= .p2 {
                attention.append(row)
            } else if row.summary.lastSeenAt >= startOfToday {
                today.append(row)
            } else {
                earlier.append(row)
            }
        }

        result.append(contentsOf: [
            (Section.attention, attention),
            (Section.today, today),
            (Section.earlier, earlier)
        ].filter { $0.1.isEmpty == false })
        return result
    }

    var unreadCount: Int {
        let entries = shelf.entries
        return rows.filter { $0.isUnread && $0.isHidden == false && entries[$0.id]?.isDeleted != true }.count
    }

    var attentionCount: Int {
        let entries = shelf.entries
        return rows.filter {
            $0.isHidden == false && $0.summary.priority <= .p2 && entries[$0.id]?.isDeleted != true
        }.count
    }

    var savedCount: Int {
        let entries = shelf.entries
        return rows.filter { entries[$0.id]?.isSaved == true && entries[$0.id]?.isDeleted != true }.count
    }

    var selectedRow: ControlPlaneStore.AIInboxRow? {
        guard let selectedID else { return nil }
        return rows.first { $0.id == selectedID }
    }

    /// What a management action applies to: the multi-selection when there is
    /// one, otherwise the item currently open in the detail pane. Returned in
    /// list order so a bulk action reads top-to-bottom.
    var actionTargets: [String] {
        guard selection.isEmpty == false else {
            return selectedID.map { [$0] } ?? []
        }
        return visibleRows.map(\.id).filter { selection.contains($0) }
    }

    /// Categories the user has already used, offered alongside the presets so
    /// an existing label gets reused instead of respelled.
    var categoriesInUse: [String] { shelf.categoriesInUse }

    /// True when the daemon has run but produced nothing — distinguishable from
    /// "the daemon has never run", which deserves different copy.
    var hasEverRun: Bool { runs.isEmpty == false }

    var latestRun: BurnBarInboxRunTelemetry? { runs.first }

    /// Ranking: attention first, then unread, then recency. Mirrors
    /// `ThreadInboxItem.sortedForInbox()` so both inboxes in the product feel
    /// the same.
    static func ranked(
        _ lhs: ControlPlaneStore.AIInboxRow,
        _ rhs: ControlPlaneStore.AIInboxRow
    ) -> Bool {
        if lhs.summary.priority != rhs.summary.priority {
            return lhs.summary.priority < rhs.summary.priority
        }
        if lhs.isUnread != rhs.isUnread {
            return lhs.isUnread
        }
        return lhs.summary.lastSeenAt > rhs.summary.lastSeenAt
    }

    /// Pinned first, then the chosen mode. Pure so the ordering rules are
    /// testable without a view or a store.
    static func sorted(
        _ rows: [ControlPlaneStore.AIInboxRow],
        ordering: Ordering,
        entries: [String: InboxShelfEntry]
    ) -> [ControlPlaneStore.AIInboxRow] {
        rows.sorted { lhs, rhs in
            let lhsPinned = entries[lhs.id]?.pinned == true
            let rhsPinned = entries[rhs.id]?.pinned == true
            if lhsPinned != rhsPinned { return lhsPinned }

            switch ordering {
            case .priority:
                return ranked(lhs, rhs)
            case .newest:
                if lhs.summary.lastSeenAt != rhs.summary.lastSeenAt {
                    return lhs.summary.lastSeenAt > rhs.summary.lastSeenAt
                }
                return lhs.id < rhs.id
            case .manual:
                // Rows the user has never placed sort after the ones they have,
                // in the default ranking — a fresh item appears at the bottom
                // of a hand-built order rather than jumping into the middle.
                switch (entries[lhs.id]?.sortIndex, entries[rhs.id]?.sortIndex) {
                case let (lhsIndex?, rhsIndex?):
                    if lhsIndex != rhsIndex { return lhsIndex < rhsIndex }
                    return lhs.id < rhs.id
                case (.some, nil):
                    return true
                case (nil, .some):
                    return false
                case (nil, nil):
                    return ranked(lhs, rhs)
                }
            }
        }
    }

    /// Deleting more than one item at a time asks first. A single delete is
    /// undoable in place and does not deserve a modal.
    static func requiresDeleteConfirmation(count: Int) -> Bool {
        count > bulkDeleteConfirmationThreshold
    }

    // MARK: - Loading

    /// Refreshes when the marker moved (or when forced).
    ///
    /// The marker check is what makes a 30-second cadence acceptable: an idle
    /// inbox does one `COUNT` and returns without touching `rows`, so SwiftUI
    /// never re-diffs the list.
    func load(force: Bool = false) async {
        do {
            let marker = try await loadMarker()
            if force == false, marker == lastMarker, rows.isEmpty == false {
                return
            }
            isLoading = rows.isEmpty
            let loaded = try await loadRows(filter.states)
            rows = loaded
            lastMarker = marker
            lastRefreshedAt = Date()
            errorMessage = nil
            let loadedIDs = Set(loaded.map(\.id))
            selection.formIntersection(loadedIDs)
            if let selectedID, loadedIDs.contains(selectedID) == false {
                self.selectedID = visibleRows.first?.id
            }
        } catch {
            errorMessage = Self.friendlyMessage(for: error)
        }
        isLoading = false
    }

    /// Opens on a specific item, loading it into view if the current filter does
    /// not contain it (a notification can reference an item the user has since
    /// archived, or one that has already resolved).
    func select(itemID: String, loadingIfNeeded: Bool = true) async {
        if rows.contains(where: { $0.id == itemID }) {
            select(itemID)
            return
        }
        guard loadingIfNeeded else { return }
        // Widen to every state so a resolved or archived item still opens.
        if let all = try? await loadRows(nil), all.contains(where: { $0.id == itemID }) {
            rows = all
            filter = .resolved
            select(itemID)
        }
    }

    func loadTelemetry() async {
        runs = (try? await loadRuns()) ?? []
    }

    /// Drops shelf records for items the inbox no longer has.
    ///
    /// Called when the surface opens rather than on the refresh cadence: it is a
    /// full listing, and the arrangement of a few hundred rows does not need
    /// garbage collecting every thirty seconds.
    ///
    /// **Only prunes against a provably complete listing.** `loadRows` is paged,
    /// so a result at the page ceiling might be truncated — pruning against that
    /// would erase the arrangement of everything below the fold. In that case
    /// the store falls back to its own capacity ceiling for boundedness.
    func pruneShelf() async {
        guard shelf.entries.isEmpty == false else { return }
        guard let all = try? await loadRows(nil) else { return }
        guard all.count < Self.authoritativeIDCeiling else { return }
        shelf.prune(keeping: Set(all.map(\.id)))
    }

    // MARK: - Selection

    /// Synchronous selection so the detail pane updates in the same click
    /// event. Persistence (mark-read) is kicked off asynchronously and must
    /// never gate the UI — a busy MainActor used to make clicks feel dead.
    func select(_ id: String) {
        selectedID = id
        guard let index = rows.firstIndex(where: { $0.id == id }), rows[index].isUnread else { return }
        applyOptimistic(id: id) { row in
            ControlPlaneStore.AIInboxRow(
                summary: row.summary,
                summaryMarkdown: row.summaryMarkdown,
                payload: row.payload,
                readAt: Date(),
                archivedAt: row.archivedAt,
                snoozedUntil: row.snoozedUntil,
                feedback: row.feedback
            )
        }
        let markRead = self.markRead
        Task { await self.perform { try await markRead(id) } }
    }

    /// A click on a row, with its modifier keys already resolved into intent.
    func click(_ id: String, intent: SelectionIntent = .replace) {
        switch intent {
        case .replace:
            selection.removeAll()
            selectionAnchor = id
        case .toggle:
            if selection.isEmpty, let selectedID, selectedID != id {
                // Command-clicking a second row promotes the open item into the
                // selection rather than silently dropping it.
                selection.insert(selectedID)
            }
            if selection.contains(id) {
                selection.remove(id)
            } else {
                selection.insert(id)
            }
            selectionAnchor = id
        case .extend:
            let ordered = visibleRows.map(\.id)
            if let anchor = selectionAnchor ?? selectedID,
               let start = ordered.firstIndex(of: anchor),
               let end = ordered.firstIndex(of: id) {
                let range = start <= end ? start...end : end...start
                // Union, not replace: on macOS a shift-click after a
                // command-click adds the run to what is already selected rather
                // than throwing the earlier picks away.
                selection.formUnion(ordered[range])
            } else {
                selection = [id]
                selectionAnchor = id
            }
        }
        select(id)
    }

    func selectAllVisible() {
        let visible = visibleRows
        selection = Set(visible.map(\.id))
        if selectedID == nil { selectedID = visible.first?.id }
    }

    func clearSelection() {
        selection.removeAll()
        selectionAnchor = nil
    }

    /// The row after the given one in list order, used to keep something open
    /// after the current item leaves the list.
    private func neighbour(after id: String, in ordered: [String]) -> String? {
        guard let index = ordered.firstIndex(of: id) else { return ordered.first }
        if ordered.indices.contains(index + 1) { return ordered[index + 1] }
        if ordered.indices.contains(index - 1) { return ordered[index - 1] }
        return nil
    }

    // MARK: - Item actions

    func toggleRead(_ id: String) async {
        guard let row = rows.first(where: { $0.id == id }) else { return }
        let makeUnread = row.readAt != nil
        applyOptimistic(id: id) { existing in
            ControlPlaneStore.AIInboxRow(
                summary: existing.summary,
                summaryMarkdown: existing.summaryMarkdown,
                payload: existing.payload,
                readAt: makeUnread ? nil : Date(),
                archivedAt: existing.archivedAt,
                snoozedUntil: existing.snoozedUntil,
                feedback: existing.feedback
            )
        }
        await perform { makeUnread ? try await self.markUnread(id) : try await self.markRead(id) }
    }

    func archive(_ id: String) async {
        await archive(ids: [id])
    }

    /// Bulk archive. Removing from the list immediately is the whole point of
    /// the gesture.
    func archive(ids: [String]) async {
        guard ids.isEmpty == false else { return }
        let doomed = Set(ids)
        let successor = ids.last.flatMap { neighbour(after: $0, in: visibleRows.map(\.id)) }
        rows.removeAll { doomed.contains($0.id) }
        selection.subtract(doomed)
        if let selectedID, doomed.contains(selectedID) {
            self.selectedID = doomed.contains(successor ?? "") ? visibleRows.first?.id : successor
        }
        let setArchived = self.setArchived
        await perform {
            for id in ids { try await setArchived(id, true) }
        }
    }

    func unarchive(_ id: String) async {
        await perform { try await self.setArchived(id, false) }
        await load(force: true)
    }

    func snooze(_ id: String, for interval: TimeInterval) async {
        rows.removeAll { $0.id == id }
        selection.remove(id)
        if selectedID == id { selectedID = visibleRows.first?.id }
        let until = Date().addingTimeInterval(interval)
        await perform { try await self.snooze(id, until) }
    }

    func setFeedback(_ id: String, useful: Bool?) async {
        let value = useful.map { $0 ? "useful" : "not_useful" }
        applyOptimistic(id: id) { row in
            ControlPlaneStore.AIInboxRow(
                summary: row.summary,
                summaryMarkdown: row.summaryMarkdown,
                payload: row.payload,
                readAt: row.readAt,
                archivedAt: row.archivedAt,
                snoozedUntil: row.snoozedUntil,
                feedback: value
            )
        }
        await perform { try await self.setFeedback(id, value) }
    }

    func markEverythingRead() async {
        rows = rows.map { row in
            guard row.isUnread else { return row }
            return ControlPlaneStore.AIInboxRow(
                summary: row.summary,
                summaryMarkdown: row.summaryMarkdown,
                payload: row.payload,
                readAt: Date(),
                archivedAt: row.archivedAt,
                snoozedUntil: row.snoozedUntil,
                feedback: row.feedback
            )
        }
        await perform { try await self.markAllRead() }
    }

    // MARK: - Shelf actions

    func togglePin(_ ids: [String]) {
        guard ids.isEmpty == false else { return }
        // Mixed selections resolve to "pin everything", the same way a mixed
        // read state resolves to "mark all read".
        let shouldPin = ids.contains { shelf.isPinned($0) == false }
        shelf.setPinned(shouldPin, ids: ids)
    }

    func toggleSaved(_ ids: [String]) {
        guard ids.isEmpty == false else { return }
        let shouldSave = ids.contains { shelf.isSaved($0) == false }
        shelf.setSaved(shouldSave, ids: ids)
    }

    func setColorTag(_ tag: InboxColorTag?, ids: [String]) {
        guard ids.isEmpty == false else { return }
        shelf.setColorTag(tag, ids: ids)
    }

    /// "Move" in an inbox with no folders: change which category an item files
    /// under. `nil` files it back under nothing.
    func setCategory(_ category: String?, ids: [String]) {
        guard ids.isEmpty == false else { return }
        shelf.setCategory(category, ids: ids)
    }

    // MARK: - Delete and undo

    /// Hide-forever, with a way back.
    ///
    /// There is no destructive database write behind this: the item is archived
    /// (the existing app-owned write) and marked deleted on the shelf, and the
    /// shelf flag is what removes it from every tab. The daemon's own row is
    /// left untouched — it is the daemon's to own, and re-deriving it would
    /// resurrect the item anyway.
    func delete(_ ids: [String], at now: Date = Date()) async {
        let targets = ids.filter { shelf.isDeleted($0) == false }
        guard targets.isEmpty == false else { return }

        let records = targets.map { id in
            DeleteUndo.Record(
                id: id,
                wasArchived: rows.first { $0.id == id }?.isArchived ?? false
            )
        }
        let successor = targets.last.flatMap { neighbour(after: $0, in: visibleRows.map(\.id)) }

        shelf.markDeleted(ids: targets, at: now)
        selection.subtract(targets)
        if let selectedID, targets.contains(selectedID) {
            self.selectedID = targets.contains(successor ?? "") ? visibleRows.first?.id : successor
        }

        deleteUndo = DeleteUndo(records: records, performedAt: now)
        scheduleUndoExpiry()

        let setArchived = self.setArchived
        let toArchive = records.filter { $0.wasArchived == false }.map(\.id)
        await perform {
            for id in toArchive { try await setArchived(id, true) }
        }
    }

    func undoDelete() async {
        guard let undo = deleteUndo else { return }
        deleteUndo = nil
        undoExpiryTask?.cancel()
        undoExpiryTask = nil

        shelf.clearDeleted(ids: undo.records.map(\.id))
        let setArchived = self.setArchived
        let toUnarchive = undo.records.filter { $0.wasArchived == false }.map(\.id)
        await perform {
            for id in toUnarchive { try await setArchived(id, false) }
        }
        await load(force: true)
    }

    /// Lets the banner go away without taking the delete back.
    func dismissUndo() {
        deleteUndo = nil
        undoExpiryTask?.cancel()
        undoExpiryTask = nil
    }

    private func scheduleUndoExpiry() {
        undoExpiryTask?.cancel()
        guard undoWindow > 0 else { return }
        let window = undoWindow
        let deadline = deleteUndo?.performedAt
        undoExpiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(window * 1_000_000_000))
            guard Task.isCancelled == false else { return }
            guard let self, self.deleteUndo?.performedAt == deadline else { return }
            self.deleteUndo = nil
        }
    }

    // MARK: - Manual ordering

    /// Drag-to-reorder: put `id` where `targetID` currently sits.
    ///
    /// Refused across the pinned boundary for the same reason the Control Deck
    /// refuses cross-band moves — the sections are the map, and a row that
    /// could leave its section would take the section's meaning with it.
    func moveManual(_ id: String, onto targetID: String) {
        guard ordering.allowsManualReorder, id != targetID else { return }
        guard shelf.isPinned(id) == shelf.isPinned(targetID) else { return }
        var ordered = visibleRows.map(\.id)
        guard let from = ordered.firstIndex(of: id), let to = ordered.firstIndex(of: targetID) else { return }
        ordered.remove(at: from)
        ordered.insert(id, at: to)
        shelf.applyManualOrder(ordered)
    }

    /// Keyboard equivalent of dragging a whole selection.
    ///
    /// Moves up are applied top-first and moves down bottom-first, and a row
    /// never steps over another row that is moving with it — so a selection
    /// keeps its internal order instead of scrambling itself one keystroke at
    /// a time.
    func nudgeManual(ids: [String], offset: Int) {
        guard ordering.allowsManualReorder, offset != 0, ids.isEmpty == false else { return }
        let moving = Set(ids)
        let sequence = offset < 0 ? ids : Array(ids.reversed())
        for id in sequence {
            let ordered = visibleRows.map(\.id)
            guard let from = ordered.firstIndex(of: id) else { continue }
            let target = from + offset
            guard ordered.indices.contains(target), moving.contains(ordered[target]) == false else { continue }
            nudgeManual(id, offset: offset)
        }
    }

    /// Keyboard/VoiceOver equivalent of a drag: swap with the neighbour.
    /// Silently no-ops at the ends rather than wrapping.
    func nudgeManual(_ id: String, offset: Int) {
        guard ordering.allowsManualReorder, offset != 0 else { return }
        var ordered = visibleRows.map(\.id)
        guard let from = ordered.firstIndex(of: id) else { return }
        let to = from + offset
        guard ordered.indices.contains(to) else { return }
        guard shelf.isPinned(id) == shelf.isPinned(ordered[to]) else { return }
        ordered.remove(at: from)
        ordered.insert(id, at: to)
        shelf.applyManualOrder(ordered)
    }

    // MARK: - Private

    /// Applies a local edit immediately so the UI never waits on a database
    /// round trip for a click; the subsequent load reconciles.
    private func applyOptimistic(
        id: String,
        _ transform: (ControlPlaneStore.AIInboxRow) -> ControlPlaneStore.AIInboxRow
    ) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index] = transform(rows[index])
    }

    private func perform(_ work: @escaping @Sendable () async throws -> Void) async {
        do {
            try await work()
            // Invalidate the marker so the next cadence pass re-reads.
            lastMarker = nil
        } catch {
            errorMessage = Self.friendlyMessage(for: error)
        }
    }

    static func friendlyMessage(for error: Error) -> String {
        let description = error.localizedDescription
        if description.contains("no such table") {
            return "The inbox has not been set up yet. It appears once the OpenBurnBar daemon has run at least once."
        }
        return description
    }
}
