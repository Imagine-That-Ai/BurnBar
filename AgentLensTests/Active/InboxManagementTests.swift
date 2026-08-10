import AppKit
import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

// MARK: - Harness

/// Stands in for the two-process data contract: the app writes archive state
/// and reads rows back, so archiving here really does change what a subsequent
/// load returns. That is what makes "delete hides it from Archived too" a real
/// assertion rather than a check of in-memory bookkeeping.
@MainActor
private final class InboxManagementHarness {
    private(set) var marker = "marker-1"
    private(set) var archiveCalls: [(id: String, archived: Bool)] = []
    private(set) var loadRowsCallCount = 0

    private var order: [String] = []
    private var stored: [String: ControlPlaneStore.AIInboxRow] = [:]

    func setRows(_ rows: [ControlPlaneStore.AIInboxRow]) {
        order = rows.map(\.id)
        stored = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        marker = UUID().uuidString
    }

    var allRows: [ControlPlaneStore.AIInboxRow] { order.compactMap { stored[$0] } }

    func rows(for states: [BurnBarInboxItemState]?) -> [ControlPlaneStore.AIInboxRow] {
        loadRowsCallCount += 1
        guard let states else { return allRows }
        return allRows.filter { states.contains($0.summary.state) }
    }

    func setArchived(_ id: String, _ archived: Bool) {
        archiveCalls.append((id, archived))
        guard let row = stored[id] else { return }
        stored[id] = Self.rebuilt(row, archivedAt: archived ? Date(timeIntervalSince1970: 42) : nil)
        marker = UUID().uuidString
    }

    func noop() {}

    static func rebuilt(
        _ row: ControlPlaneStore.AIInboxRow,
        archivedAt: Date?
    ) -> ControlPlaneStore.AIInboxRow {
        ControlPlaneStore.AIInboxRow(
            summary: row.summary,
            summaryMarkdown: row.summaryMarkdown,
            payload: row.payload,
            readAt: row.readAt,
            archivedAt: archivedAt,
            snoozedUntil: row.snoozedUntil,
            feedback: row.feedback
        )
    }
}

// MARK: - Tests

/// Covers the mail-client management layer on top of the AI Inbox: delete with
/// undo, saved, pin, tag/category, manual ordering, and multi-select bulk
/// actions — all of it against an isolated shelf so the developer's own
/// arrangement is never touched.
@MainActor
final class InboxManagementTests: XCTestCase {
    private var suiteNames: [String] = []

    override func tearDown() {
        for name in suiteNames {
            UserDefaults.standard.removePersistentDomain(forName: name)
        }
        suiteNames.removeAll()
        super.tearDown()
    }

    private func makeDefaults() -> UserDefaults {
        let name = "inbox.management.tests.\(UUID().uuidString)"
        suiteNames.append(name)
        guard let defaults = UserDefaults(suiteName: name) else {
            fatalError("could not create a scratch UserDefaults suite")
        }
        return defaults
    }

    private func makeShelf(_ defaults: UserDefaults? = nil) -> InboxShelfStore {
        InboxShelfStore(defaults: defaults ?? makeDefaults(), persistDebounce: 0)
    }

    private func makeModel(
        _ harness: InboxManagementHarness,
        shelf: InboxShelfStore
    ) -> InboxModel {
        InboxModel(
            loadRows: { states in await harness.rows(for: states) },
            loadMarker: { await harness.marker },
            markRead: { _ in await harness.noop() },
            markUnread: { _ in await harness.noop() },
            setArchived: { id, archived in await harness.setArchived(id, archived) },
            snooze: { _, _ in await harness.noop() },
            setFeedback: { _, _ in await harness.noop() },
            markAllRead: { await harness.noop() },
            loadRuns: { return [] },
            shelf: shelf,
            // No auto-expiry: the undo window is wall-clock behaviour and a
            // sleeping test is a flaky test.
            undoWindow: 0
        )
    }

    private func makeRow(
        id: String,
        priority: BurnBarInboxPriority = .p3,
        state: BurnBarInboxItemState = .new,
        lastSeenAt: Date = Date(),
        readAt: Date? = nil,
        archivedAt: Date? = nil
    ) -> ControlPlaneStore.AIInboxRow {
        ControlPlaneStore.AIInboxRow(
            summary: BurnBarInboxItemSummary(
                id: id,
                fingerprint: "fp_\(id)",
                kind: .stuckPR,
                priority: priority,
                state: state,
                title: "Item \(id)",
                firstSeenAt: lastSeenAt,
                lastSeenAt: lastSeenAt
            ),
            summaryMarkdown: "Body of \(id)",
            payload: BurnBarInboxItemPayload(),
            readAt: readAt,
            archivedAt: archivedAt,
            snoozedUntil: nil,
            feedback: nil
        )
    }

    // MARK: - Delete hides everywhere, undo restores

    func testDeleteHidesFromEveryFilterAndUndoRestores() async {
        let now = Date()
        let harness = InboxManagementHarness()
        harness.setRows([
            makeRow(id: "doomed", priority: .p1, state: .new, lastSeenAt: now),
            makeRow(id: "keeper", priority: .p1, state: .new, lastSeenAt: now),
            makeRow(id: "shelved", state: .new, lastSeenAt: now, readAt: now, archivedAt: now),
            makeRow(id: "closed", state: .resolved, lastSeenAt: now)
        ])
        let shelf = makeShelf()
        let model = makeModel(harness, shelf: shelf)
        await model.load(force: true)

        await model.delete(["doomed"])

        for filter in InboxModel.Filter.allCases {
            model.filter = filter
            await model.load(force: true)
            XCTAssertFalse(
                model.visibleRows.contains { $0.id == "doomed" },
                "a deleted item must not appear under \(filter.title)"
            )
        }

        // It is genuinely archived in the store, which is the only durable
        // write a delete performs.
        let archiveCalls = harness.archiveCalls
        XCTAssertEqual(archiveCalls.map { $0.id }, ["doomed"])
        XCTAssertEqual(archiveCalls.map { $0.archived }, [true])

        // Nothing else moved.
        model.filter = .active
        await model.load(force: true)
        XCTAssertTrue(model.visibleRows.contains { $0.id == "keeper" })

        // Undo puts it back where it was, including its archive state.
        await model.undoDelete()
        XCTAssertFalse(shelf.isDeleted("doomed"))
        XCTAssertTrue(
            model.visibleRows.contains { $0.id == "doomed" },
            "undo must return the item to the active list"
        )
        let afterUndo = harness.archiveCalls
        XCTAssertEqual(afterUndo.last?.id, "doomed")
        XCTAssertEqual(afterUndo.last?.archived, false)
    }

    /// Deleting an item that was *already* archived must not unarchive it on
    /// undo — undo restores the previous state, it does not invent a new one.
    func testUndoRestoresPreviousArchiveStateRatherThanUnarchivingBlindly() async {
        let now = Date()
        let harness = InboxManagementHarness()
        harness.setRows([makeRow(id: "a", state: .new, lastSeenAt: now, readAt: now, archivedAt: now)])
        let shelf = makeShelf()
        let model = makeModel(harness, shelf: shelf)
        model.filter = .archived
        await model.load(force: true)

        await model.delete(["a"])
        XCTAssertTrue(model.visibleRows.isEmpty)

        await model.undoDelete()

        let calls = harness.archiveCalls
        XCTAssertTrue(calls.isEmpty, "an already-archived item needs no archive write in either direction")
        XCTAssertFalse(shelf.isDeleted("a"))
        XCTAssertEqual(model.visibleRows.map(\.id), ["a"])
    }

    func testDeleteBannerIsAnnouncedAndDismissable() async {
        let harness = InboxManagementHarness()
        harness.setRows([makeRow(id: "a"), makeRow(id: "b")])
        let model = makeModel(harness, shelf: makeShelf())
        await model.load(force: true)

        await model.delete(["a", "b"])
        XCTAssertEqual(model.deleteUndo?.count, 2)
        XCTAssertEqual(model.deleteUndo?.message, "2 items deleted")

        model.dismissUndo()
        XCTAssertNil(model.deleteUndo)

        await model.undoDelete()
        XCTAssertTrue(model.visibleRows.isEmpty, "a dismissed banner must make the delete final")
    }

    func testBulkDeleteAsksFirstButASingleDeleteDoesNot() {
        XCTAssertFalse(InboxModel.requiresDeleteConfirmation(count: 0))
        XCTAssertFalse(InboxModel.requiresDeleteConfirmation(count: 1))
        XCTAssertTrue(InboxModel.requiresDeleteConfirmation(count: 2))
        XCTAssertTrue(InboxModel.requiresDeleteConfirmation(count: 40))
    }

    // MARK: - Saved

    func testSavedFilterShowsSavedItemsInAnyStateAndHidesDeletedOnes() async {
        let now = Date()
        let harness = InboxManagementHarness()
        harness.setRows([
            makeRow(id: "open", state: .new, lastSeenAt: now),
            makeRow(id: "done", state: .resolved, lastSeenAt: now),
            makeRow(id: "plain", state: .new, lastSeenAt: now)
        ])
        let shelf = makeShelf()
        let model = makeModel(harness, shelf: shelf)
        await model.load(force: true)

        model.toggleSaved(["open", "done"])
        model.filter = .saved
        await model.load(force: true)

        XCTAssertEqual(Set(model.visibleRows.map(\.id)), ["open", "done"])
        XCTAssertEqual(model.savedCount, 2)

        await model.delete(["done"])
        await model.load(force: true)
        XCTAssertEqual(model.visibleRows.map(\.id), ["open"])

        // Toggling a fully-saved selection unsaves it.
        model.toggleSaved(["open"])
        XCTAssertFalse(shelf.isSaved("open"))
    }

    // MARK: - Sorting

    func testSortingPutsPinnedFirstThenTheChosenMode() {
        let old = Date(timeIntervalSince1970: 1_000)
        let mid = Date(timeIntervalSince1970: 2_000)
        let new = Date(timeIntervalSince1970: 3_000)
        let urgentOld = makeRow(id: "urgent-old", priority: .p1, lastSeenAt: old)
        let plainNew = makeRow(id: "plain-new", priority: .p4, lastSeenAt: new)
        let plainMid = makeRow(id: "plain-mid", priority: .p4, lastSeenAt: mid)
        let rows = [plainMid, urgentOld, plainNew]

        // Priority: urgent wins regardless of age.
        XCTAssertEqual(
            InboxModel.sorted(rows, ordering: .priority, entries: [:]).map(\.id),
            ["urgent-old", "plain-new", "plain-mid"]
        )

        // Newest: age wins regardless of priority.
        XCTAssertEqual(
            InboxModel.sorted(rows, ordering: .newest, entries: [:]).map(\.id),
            ["plain-new", "plain-mid", "urgent-old"]
        )

        // A pin outranks both modes.
        let pinned: [String: InboxShelfEntry] = ["plain-mid": InboxShelfEntry(pinned: true)]
        XCTAssertEqual(
            InboxModel.sorted(rows, ordering: .priority, entries: pinned).map(\.id),
            ["plain-mid", "urgent-old", "plain-new"]
        )
        XCTAssertEqual(
            InboxModel.sorted(rows, ordering: .newest, entries: pinned).map(\.id),
            ["plain-mid", "plain-new", "urgent-old"]
        )

        // Manual: placed rows lead in their placed order, unplaced rows fall to
        // the back in the default ranking rather than jumping into the middle.
        let placed: [String: InboxShelfEntry] = [
            "plain-new": InboxShelfEntry(sortIndex: 0),
            "plain-mid": InboxShelfEntry(sortIndex: 1)
        ]
        XCTAssertEqual(
            InboxModel.sorted(rows, ordering: .manual, entries: placed).map(\.id),
            ["plain-new", "plain-mid", "urgent-old"]
        )
    }

    func testPinnedRowsGetTheirOwnSection() async {
        let now = Date()
        let harness = InboxManagementHarness()
        harness.setRows([
            makeRow(id: "hot", priority: .p1, lastSeenAt: now),
            makeRow(id: "cool", priority: .p4, lastSeenAt: now)
        ])
        let model = makeModel(harness, shelf: makeShelf())
        await model.load(force: true)
        XCTAssertEqual(model.sections.map(\.section), [.attention, .today])

        model.togglePin(["cool"])

        XCTAssertEqual(model.sections.map(\.section), [.pinned, .attention])
        XCTAssertEqual(model.sections.first?.rows.map(\.id), ["cool"])
    }

    func testManualOrderingCollapsesTheRecencyGrouping() async {
        let harness = InboxManagementHarness()
        harness.setRows([makeRow(id: "a", priority: .p1), makeRow(id: "b", priority: .p4)])
        let model = makeModel(harness, shelf: makeShelf())
        await model.load(force: true)

        model.ordering = .manual
        XCTAssertEqual(model.sections.map(\.section), [.manual])
    }

    // MARK: - Manual reorder

    func testManualReorderIsStableAcrossAReload() async {
        let defaults = makeDefaults()
        let harness = InboxManagementHarness()
        harness.setRows([
            makeRow(id: "a", priority: .p1),
            makeRow(id: "b", priority: .p2),
            makeRow(id: "c", priority: .p3)
        ])
        let model = makeModel(harness, shelf: makeShelf(defaults))
        await model.load(force: true)
        model.ordering = .manual
        XCTAssertEqual(model.visibleRows.map(\.id), ["a", "b", "c"])

        model.moveManual("c", onto: "a")
        XCTAssertEqual(model.visibleRows.map(\.id), ["c", "a", "b"])

        // A fresh model over a fresh store reading the same persisted defaults
        // is the process-restart case.
        let reloaded = makeModel(harness, shelf: makeShelf(defaults))
        reloaded.ordering = .manual
        await reloaded.load(force: true)
        XCTAssertEqual(reloaded.visibleRows.map(\.id), ["c", "a", "b"])
    }

    func testKeyboardNudgeMatchesTheDragAndStopsAtTheEnds() async {
        let harness = InboxManagementHarness()
        harness.setRows([
            makeRow(id: "a", priority: .p1),
            makeRow(id: "b", priority: .p2),
            makeRow(id: "c", priority: .p3)
        ])
        let model = makeModel(harness, shelf: makeShelf())
        await model.load(force: true)
        model.ordering = .manual

        model.nudgeManual("a", offset: -1)
        XCTAssertEqual(model.visibleRows.map(\.id), ["a", "b", "c"], "the top row cannot move up")

        model.nudgeManual("a", offset: 1)
        XCTAssertEqual(model.visibleRows.map(\.id), ["b", "a", "c"])

        model.nudgeManual("c", offset: 1)
        XCTAssertEqual(model.visibleRows.map(\.id), ["b", "a", "c"], "the bottom row cannot move down")
    }

    func testReorderIsRefusedOutsideManualModeAndAcrossThePinnedBoundary() async {
        let harness = InboxManagementHarness()
        harness.setRows([
            makeRow(id: "a", priority: .p1),
            makeRow(id: "b", priority: .p2),
            makeRow(id: "c", priority: .p3)
        ])
        let shelf = makeShelf()
        let model = makeModel(harness, shelf: shelf)
        await model.load(force: true)

        // Default ordering: the grouping is the IA, so drag does nothing.
        model.moveManual("c", onto: "a")
        XCTAssertTrue(shelf.entries.isEmpty)
        XCTAssertEqual(model.visibleRows.map(\.id), ["a", "b", "c"])

        model.ordering = .manual
        model.togglePin(["a"])
        model.moveManual("c", onto: "a")
        XCTAssertEqual(
            model.visibleRows.map(\.id),
            ["a", "b", "c"],
            "an unpinned row must not be draggable into the pinned band"
        )
    }

    // MARK: - Multi-select and bulk actions

    func testModifierKeysMapToSelectionIntents() {
        XCTAssertEqual(InboxView.selectionIntent(for: []), .replace)
        XCTAssertEqual(InboxView.selectionIntent(for: .command), .toggle)
        XCTAssertEqual(InboxView.selectionIntent(for: .shift), .extend)
        XCTAssertEqual(
            InboxView.selectionIntent(for: [.shift, .command]),
            .extend,
            "shift wins so a range never silently becomes a toggle"
        )
        XCTAssertEqual(InboxView.selectionIntent(for: .option), .replace)
    }

    func testCommandClickTogglesAndShiftClickExtends() async {
        let harness = InboxManagementHarness()
        harness.setRows([
            makeRow(id: "a", priority: .p1),
            makeRow(id: "b", priority: .p2),
            makeRow(id: "c", priority: .p3),
            makeRow(id: "d", priority: .p4)
        ])
        let model = makeModel(harness, shelf: makeShelf())
        await model.load(force: true)

        model.click("a", intent: .replace)
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertEqual(model.actionTargets, ["a"], "with no multi-selection, actions apply to the open item")

        model.click("b", intent: .toggle)
        XCTAssertEqual(model.selection, ["a", "b"], "command-click promotes the open item into the selection")

        model.click("b", intent: .toggle)
        XCTAssertEqual(model.selection, ["a"])

        // The anchor is the last row clicked ("b"), so the range is b…d and it
        // is added to what was already selected rather than replacing it.
        model.click("d", intent: .extend)
        XCTAssertEqual(model.selection, ["a", "b", "c", "d"], "shift-click fills the range from the anchor")
        XCTAssertEqual(model.actionTargets, ["a", "b", "c", "d"], "targets come back in list order")

        model.click("b", intent: .replace)
        XCTAssertTrue(model.selection.isEmpty, "a plain click clears the multi-selection")
    }

    func testBulkApplyTouchesExactlyTheSelectedIDs() async {
        let harness = InboxManagementHarness()
        harness.setRows([
            makeRow(id: "a", priority: .p1),
            makeRow(id: "b", priority: .p2),
            makeRow(id: "c", priority: .p3),
            makeRow(id: "d", priority: .p4)
        ])
        let shelf = makeShelf()
        let model = makeModel(harness, shelf: shelf)
        await model.load(force: true)

        model.click("a", intent: .replace)
        model.click("c", intent: .toggle)
        let targets = model.actionTargets
        XCTAssertEqual(targets, ["a", "c"])

        model.setColorTag(.urgent, ids: targets)
        model.setCategory("Costs", ids: targets)
        model.togglePin(targets)

        XCTAssertEqual(shelf.colorTag("a"), .urgent)
        XCTAssertEqual(shelf.colorTag("c"), .urgent)
        XCTAssertNil(shelf.colorTag("b"))
        XCTAssertNil(shelf.colorTag("d"))
        XCTAssertEqual(shelf.category("a"), "Costs")
        XCTAssertNil(shelf.category("d"))
        XCTAssertTrue(shelf.isPinned("a") && shelf.isPinned("c"))
        XCTAssertFalse(shelf.isPinned("b") || shelf.isPinned("d"))

        await model.delete(targets)
        XCTAssertTrue(shelf.isDeleted("a") && shelf.isDeleted("c"))
        XCTAssertFalse(shelf.isDeleted("b") || shelf.isDeleted("d"))
        XCTAssertEqual(model.visibleRows.map(\.id), ["b", "d"])
        XCTAssertTrue(model.selection.isEmpty, "a bulk action consumes its selection")
    }

    func testBulkArchiveTouchesExactlyTheSelectedIDs() async {
        let harness = InboxManagementHarness()
        harness.setRows([makeRow(id: "a"), makeRow(id: "b"), makeRow(id: "c")])
        let model = makeModel(harness, shelf: makeShelf())
        await model.load(force: true)

        model.click("a", intent: .replace)
        model.click("b", intent: .toggle)
        await model.archive(ids: model.actionTargets)

        let calls = harness.archiveCalls
        XCTAssertEqual(calls.map { $0.id }.sorted(), ["a", "b"])
        XCTAssertEqual(model.visibleRows.map(\.id), ["c"])
    }

    func testMixedSelectionsPinEverythingRatherThanTogglingIndividually() async {
        let harness = InboxManagementHarness()
        harness.setRows([makeRow(id: "a"), makeRow(id: "b")])
        let shelf = makeShelf()
        let model = makeModel(harness, shelf: shelf)
        await model.load(force: true)

        model.togglePin(["a"])
        model.togglePin(["a", "b"])
        XCTAssertTrue(shelf.isPinned("a") && shelf.isPinned("b"), "a mixed selection resolves to pin-all")

        model.togglePin(["a", "b"])
        XCTAssertFalse(shelf.isPinned("a") || shelf.isPinned("b"))
    }

    func testSelectAllAndClearOperateOnTheVisibleListOnly() async {
        let now = Date()
        let harness = InboxManagementHarness()
        harness.setRows([
            makeRow(id: "a", lastSeenAt: now),
            makeRow(id: "hidden", lastSeenAt: now, readAt: now, archivedAt: now)
        ])
        let model = makeModel(harness, shelf: makeShelf())
        await model.load(force: true)

        model.selectAllVisible()
        XCTAssertEqual(model.selection, ["a"], "an archived row is not in the active list, so it is not selected")

        model.clearSelection()
        XCTAssertTrue(model.selection.isEmpty)
    }

    // MARK: - Categories

    func testCategoryChoicesMergePresetsWithWhatIsAlreadyInUse() {
        let merged = InboxView.categoryChoices(
            presets: ["Triage", "Costs"],
            inUse: ["costs", "Reliability"]
        )
        XCTAssertEqual(merged, ["Triage", "Costs", "Reliability"], "case-only duplicates collapse")
    }

    func testSettingACategoryIsHowAnItemMoves() async {
        let harness = InboxManagementHarness()
        harness.setRows([makeRow(id: "a")])
        let shelf = makeShelf()
        let model = makeModel(harness, shelf: shelf)
        await model.load(force: true)

        model.setCategory("  Reliability  ", ids: ["a"])
        XCTAssertEqual(shelf.category("a"), "Reliability")
        XCTAssertEqual(model.categoriesInUse, ["Reliability"])

        model.setCategory("Costs", ids: ["a"])
        XCTAssertEqual(shelf.category("a"), "Costs", "moving replaces rather than accumulates")
        XCTAssertEqual(model.categoriesInUse, ["Costs"])

        model.setCategory(nil, ids: ["a"])
        XCTAssertNil(shelf.category("a"))
        XCTAssertTrue(model.categoriesInUse.isEmpty)
    }

    // MARK: - Pruning through the model

    func testPruneShelfDropsRecordsForItemsTheInboxNoLongerHas() async {
        let harness = InboxManagementHarness()
        harness.setRows([makeRow(id: "a"), makeRow(id: "b")])
        let shelf = makeShelf()
        let model = makeModel(harness, shelf: shelf)
        await model.load(force: true)

        model.setColorTag(.idea, ids: ["a", "b", "long-gone"])
        XCTAssertEqual(shelf.entries.count, 3)

        await model.pruneShelf()

        XCTAssertEqual(Set(shelf.entries.keys), ["a", "b"])
    }

    /// A listing that reaches the page ceiling might be truncated, and pruning
    /// against a truncated listing would erase the arrangement of everything
    /// below the fold. The model must refuse.
    func testPruneShelfRefusesATruncatedListing() async {
        let harness = InboxManagementHarness()
        let rows = (0..<InboxModel.authoritativeIDCeiling).map { makeRow(id: "row-\($0)") }
        harness.setRows(rows)
        let shelf = makeShelf()
        let model = makeModel(harness, shelf: shelf)
        await model.load(force: true)

        model.setColorTag(.idea, ids: ["not-in-the-listing"])
        await model.pruneShelf()

        XCTAssertEqual(
            Set(shelf.entries.keys),
            ["not-in-the-listing"],
            "a full page is not proof the item is gone"
        )
    }

    func testPruneShelfCostsNothingWhenTheShelfIsEmpty() async {
        let harness = InboxManagementHarness()
        harness.setRows([makeRow(id: "a")])
        let model = makeModel(harness, shelf: makeShelf())
        await model.load(force: true)
        let before = harness.loadRowsCallCount

        await model.pruneShelf()

        let after = harness.loadRowsCallCount
        XCTAssertEqual(after, before, "an untouched inbox must not pay for garbage collection")
    }

    // MARK: - Vocabulary

    func testOrderingVocabulary() {
        for ordering in InboxModel.Ordering.allCases {
            XCTAssertEqual(ordering.id, ordering.rawValue)
            XCTAssertFalse(ordering.title.isEmpty)
            XCTAssertFalse(ordering.symbolName.isEmpty)
            XCTAssertFalse(ordering.explanation.isEmpty)
        }
        XCTAssertTrue(InboxModel.Ordering.manual.allowsManualReorder)
        XCTAssertFalse(InboxModel.Ordering.priority.allowsManualReorder)
        XCTAssertFalse(InboxModel.Ordering.newest.allowsManualReorder)
    }

    func testSavedFilterLoadsEveryStateWhileTheOthersStayNarrow() {
        XCTAssertNil(InboxModel.Filter.saved.states, "a saved item must survive being resolved")
        XCTAssertEqual(InboxModel.Filter.active.states, BurnBarInboxItemState.openStates)
        XCTAssertEqual(InboxModel.Filter.saved.title, "Saved")
        XCTAssertFalse(InboxModel.Filter.saved.emptyIcon.isEmpty)
    }

    func testSectionVocabularyCoversTheNewBands() {
        XCTAssertEqual(InboxModel.Section.pinned.title, "Pinned")
        XCTAssertEqual(InboxModel.Section.saved.title, "Saved")
        XCTAssertEqual(InboxModel.Section.manual.title, "Ordered by you")
        for section in InboxModel.Section.allCases {
            XCTAssertEqual(section.id, section.rawValue)
            XCTAssertFalse(section.title.isEmpty)
        }
    }
}
