import Foundation
import Observation
import OpenBurnBarCore

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
        case resolved
        case archived

        var id: String { rawValue }

        var title: String {
            switch self {
            case .active: return "Active"
            case .attention: return "Needs attention"
            case .resolved: return "Resolved"
            case .archived: return "Archived"
            }
        }

        var states: [BurnBarInboxItemState]? {
            switch self {
            case .active, .attention, .archived: return BurnBarInboxItemState.openStates
            case .resolved: return [.resolved, .expired]
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

    /// Section headings in the list. Grouping by recency (rather than by kind)
    /// matches how the surface is actually read: "what is happening now" first.
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
    var selectedID: String?

    private let loadRows: LoadRows
    private let loadMarker: LoadMarker
    private let markRead: MutateItem
    private let markUnread: MutateItem
    private let setArchived: SetArchived
    private let snooze: Snooze
    private let setFeedback: SetFeedback
    private let markAllRead: @Sendable () async throws -> Void
    private let loadRuns: LoadRuns

    init(
        loadRows: @escaping LoadRows,
        loadMarker: @escaping LoadMarker,
        markRead: @escaping MutateItem,
        markUnread: @escaping MutateItem,
        setArchived: @escaping SetArchived,
        snooze: @escaping Snooze,
        setFeedback: @escaping SetFeedback,
        markAllRead: @escaping @Sendable () async throws -> Void,
        loadRuns: @escaping LoadRuns
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
    }

    // MARK: - Derived state

    /// Rows for the current filter, ranked.
    var visibleRows: [ControlPlaneStore.AIInboxRow] {
        let filtered: [ControlPlaneStore.AIInboxRow]
        switch filter {
        case .active:
            filtered = rows.filter { $0.isHidden == false }
        case .attention:
            filtered = rows.filter { $0.isHidden == false && $0.summary.priority <= .p2 }
        case .resolved:
            filtered = rows
        case .archived:
            filtered = rows.filter(\.isArchived)
        }
        return filtered.sorted(by: Self.ranked)
    }

    var sections: [(section: Section, rows: [ControlPlaneStore.AIInboxRow])] {
        let visible = visibleRows
        guard filter != .resolved, filter != .archived else {
            return visible.isEmpty ? [] : [(.closed, visible)]
        }

        let startOfToday = Calendar.current.startOfDay(for: Date())
        var attention: [ControlPlaneStore.AIInboxRow] = []
        var today: [ControlPlaneStore.AIInboxRow] = []
        var earlier: [ControlPlaneStore.AIInboxRow] = []

        for row in visible {
            if row.summary.priority <= .p2 {
                attention.append(row)
            } else if row.summary.lastSeenAt >= startOfToday {
                today.append(row)
            } else {
                earlier.append(row)
            }
        }

        return [
            (Section.attention, attention),
            (Section.today, today),
            (Section.earlier, earlier)
        ].filter { $0.1.isEmpty == false }
    }

    var unreadCount: Int {
        rows.filter { $0.isUnread && $0.isHidden == false }.count
    }

    var attentionCount: Int {
        rows.filter { $0.isHidden == false && $0.summary.priority <= .p2 }.count
    }

    var selectedRow: ControlPlaneStore.AIInboxRow? {
        guard let selectedID else { return nil }
        return rows.first { $0.id == selectedID }
    }

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
            if let selectedID, loaded.contains(where: { $0.id == selectedID }) == false {
                self.selectedID = loaded.first?.id
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
            await select(itemID)
            return
        }
        guard loadingIfNeeded else { return }
        // Widen to every state so a resolved or archived item still opens.
        if let all = try? await loadRows(nil), all.contains(where: { $0.id == itemID }) {
            rows = all
            filter = .resolved
            await select(itemID)
        }
    }

    func loadTelemetry() async {
        runs = (try? await loadRuns()) ?? []
    }

    // MARK: - Actions

    func select(_ id: String) async {
        selectedID = id
        // Selecting is reading. Do it optimistically so the row's unread dot
        // clears the instant it is clicked.
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
        await perform { try await self.markRead(id) }
    }

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
        // Removing from the list immediately is the whole point of the gesture.
        let previousSelection = selectedID
        rows.removeAll { $0.id == id }
        if previousSelection == id { selectedID = visibleRows.first?.id }
        await perform { try await self.setArchived(id, true) }
    }

    func unarchive(_ id: String) async {
        await perform { try await self.setArchived(id, false) }
        await load(force: true)
    }

    func snooze(_ id: String, for interval: TimeInterval) async {
        rows.removeAll { $0.id == id }
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
