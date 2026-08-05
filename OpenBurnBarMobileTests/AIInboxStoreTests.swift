import XCTest
import Foundation
import FirebaseFirestore
import OpenBurnBarCore
@testable import OpenBurnBarMobile

/// Behavior contract for the mobile AI Inbox.
///
/// The failure mode this suite exists to prevent is a SILENT one: the inbox is
/// produced by another machine, so if the phone drops a document, ranks it
/// wrong, or writes a state field the rules reject, the user sees a plausible
/// list with the wrong things in it and no error anywhere. So the pins here are
/// the ones a human could not spot by looking at the screen:
///
///   1. an unreadable document produces no row rather than a blank one,
///   2. the rank matches the Mac's (`InboxModel.ranked`) — attention, unread,
///      recency — because the two are the same product,
///   3. the filters and sections agree with the Mac's about what "active",
///      "attention", and "today" mean,
///   4. a triage tap lands locally BEFORE the network, and clears a field by
///      deleting it rather than by omitting it.
///
/// No live Firestore: the store's snapshot-application and state-writer seams
/// are driven directly.
@MainActor
final class AIInboxStoreTests: XCTestCase {

    private let uid = "user-inbox-tests"
    private lazy var vaultKey = Data(repeating: 0x5C, count: 32)
    private lazy var vaultKeyID = (try? CloudVaultCrypto.vaultKeyID(for: vaultKey)) ?? ""

    // MARK: - Fixtures

    private func makeRecord(
        id: String,
        kind: BurnBarInboxItemKind = .ciWaste,
        priority: BurnBarInboxPriority = .p3,
        state: BurnBarInboxItemState = .new,
        lastSeenAt: Date = Date(),
        title: String = "Something happened",
        summaryMarkdown: String = "**38 of 40 runs** failed.",
        projectName: String? = "Ajnunezg/BurnBar",
        payload: BurnBarInboxItemPayload = BurnBarInboxItemPayload()
    ) -> AIInboxMirrorRecord {
        AIInboxMirrorRecord(
            id: id,
            fingerprint: "\(kind.rawValue):\(id)",
            kind: kind,
            priority: priority,
            state: state,
            firstSeenAt: lastSeenAt.addingTimeInterval(-3_600),
            lastSeenAt: lastSeenAt,
            title: title,
            summaryMarkdown: summaryMarkdown,
            projectName: projectName,
            payload: payload
        )
    }

    /// Captures every write instead of performing one, so the optimistic-first
    /// ordering is observable.
    @MainActor
    private final class StateWriterSpy {
        private(set) var writes: [(documentID: String, payload: [String: Any])] = []
        var failure: Error?
        /// Runs before the write resolves — the hook that proves local state was
        /// already updated when the network call began.
        var onWrite: (() -> Void)?

        /// Captured strongly on purpose: the store is the spy's only owner in
        /// the `makeStore()` default-argument case, and a weak capture there
        /// would silently drop every write instead of recording it.
        func writer() -> AIInboxStore.StateWriter {
            { [self] documentID, payload in
                onWrite?()
                if let failure { throw failure }
                writes.append((documentID, payload))
            }
        }
    }

    private func makeStore(_ spy: StateWriterSpy = StateWriterSpy()) -> AIInboxStore {
        AIInboxStore(stateWriter: spy.writer(), observeAuthChanges: false)
    }

    // MARK: - Decoding

    func test_decodeDocument_roundTripsASealedMirrorDocument() throws {
        let record = makeRecord(id: "inb_1", priority: .p1, title: "95% of nightly runs are wasted")
        let encoded = try AIInboxMirrorCodec.encodeSealed(
            record,
            vaultKey: vaultKey,
            vaultKeyID: vaultKeyID,
            uid: uid,
            documentID: record.id
        )

        let decoded = try XCTUnwrap(
            AIInboxStore.decodeDocument(
                documentID: record.id,
                uid: uid,
                data: encoded,
                vaultKey: vaultKey
            )
        )

        XCTAssertEqual(decoded.id, "inb_1")
        XCTAssertEqual(decoded.priority, .p1)
        XCTAssertEqual(decoded.title, "95% of nightly runs are wasted")
        XCTAssertEqual(decoded.projectName, "Ajnunezg/BurnBar")
    }

    /// The whole surface is sealed — there is no legacy plaintext form — so a
    /// device without the vault key must show nothing rather than a row with an
    /// empty body.
    func test_decodeDocument_withoutVaultKey_dropsTheRow() throws {
        let record = makeRecord(id: "inb_1")
        let encoded = try AIInboxMirrorCodec.encodeSealed(
            record,
            vaultKey: vaultKey,
            vaultKeyID: vaultKeyID,
            uid: uid,
            documentID: record.id
        )

        XCTAssertNil(
            AIInboxStore.decodeDocument(documentID: record.id, uid: uid, data: encoded, vaultKey: nil)
        )
    }

    func test_decodeDocument_withWrongVaultKey_dropsTheRow() throws {
        let record = makeRecord(id: "inb_1")
        let encoded = try AIInboxMirrorCodec.encodeSealed(
            record,
            vaultKey: vaultKey,
            vaultKeyID: vaultKeyID,
            uid: uid,
            documentID: record.id
        )

        XCTAssertNil(
            AIInboxStore.decodeDocument(
                documentID: record.id,
                uid: uid,
                data: encoded,
                vaultKey: Data(repeating: 0x11, count: 32)
            )
        )
    }

    // MARK: - Ranking

    /// Priority first, then unread, then recency — identical to the Mac's
    /// `InboxModel.ranked`. A phone that ordered these differently would make
    /// the same inbox look like two different inboxes.
    func test_ranking_putsAttentionFirst_thenUnread_thenRecency() {
        let store = makeStore()
        let now = Date()
        store.applyRecords([
            makeRecord(id: "p3-recent", priority: .p3, lastSeenAt: now),
            makeRecord(id: "p1-old", priority: .p1, lastSeenAt: now.addingTimeInterval(-86_400)),
            makeRecord(id: "p2-mid", priority: .p2, lastSeenAt: now.addingTimeInterval(-3_600))
        ])

        XCTAssertEqual(store.items.map(\.id), ["p1-old", "p2-mid", "p3-recent"])
    }

    func test_ranking_unreadOutranksReadAtTheSamePriority() {
        let store = makeStore()
        let now = Date()
        store.applyRecords([
            makeRecord(id: "read-newer", priority: .p3, lastSeenAt: now),
            makeRecord(id: "unread-older", priority: .p3, lastSeenAt: now.addingTimeInterval(-7_200))
        ])
        store.applyItemStates([
            AIInboxMirrorItemState(id: "read-newer", readAt: now)
        ])

        XCTAssertEqual(store.items.map(\.id), ["unread-older", "read-newer"])
    }

    func test_ranking_fallsBackToRecencyWhenPriorityAndUnreadMatch() {
        let store = makeStore()
        let now = Date()
        store.applyRecords([
            makeRecord(id: "older", priority: .p3, lastSeenAt: now.addingTimeInterval(-600)),
            makeRecord(id: "newer", priority: .p3, lastSeenAt: now)
        ])

        XCTAssertEqual(store.items.map(\.id), ["newer", "older"])
    }

    // MARK: - Filters

    func test_activeFilter_hidesArchivedAndSnoozedAndClosedItems() {
        let store = makeStore()
        let now = Date()
        store.applyRecords([
            makeRecord(id: "open", state: .new),
            makeRecord(id: "archived", state: .new),
            makeRecord(id: "snoozed", state: .new),
            makeRecord(id: "resolved", state: .resolved)
        ])
        store.applyItemStates([
            AIInboxMirrorItemState(id: "archived", archivedAt: now),
            AIInboxMirrorItemState(id: "snoozed", snoozedUntil: now.addingTimeInterval(3_600))
        ])

        store.filter = .active
        XCTAssertEqual(store.visibleItems.map(\.id), ["open"])
    }

    /// An expired snooze must return the item to the active list; otherwise
    /// "snooze for an hour" would be indistinguishable from "archive".
    func test_activeFilter_returnsAnItemWhoseSnoozeHasElapsed() {
        let store = makeStore()
        store.applyRecords([makeRecord(id: "snoozed", state: .new)])
        store.applyItemStates([
            AIInboxMirrorItemState(id: "snoozed", snoozedUntil: Date().addingTimeInterval(-60))
        ])

        store.filter = .active
        XCTAssertEqual(store.visibleItems.map(\.id), ["snoozed"])
    }

    func test_attentionFilter_keepsOnlyP1AndP2() {
        let store = makeStore()
        store.applyRecords([
            makeRecord(id: "p1", priority: .p1),
            makeRecord(id: "p2", priority: .p2),
            makeRecord(id: "p3", priority: .p3),
            makeRecord(id: "p4", priority: .p4)
        ])

        store.filter = .attention
        XCTAssertEqual(Set(store.visibleItems.map(\.id)), ["p1", "p2"])
    }

    func test_resolvedFilter_showsOnlyClosedItems() {
        let store = makeStore()
        store.applyRecords([
            makeRecord(id: "open", state: .updated),
            makeRecord(id: "resolved", state: .resolved),
            makeRecord(id: "expired", state: .expired)
        ])

        store.filter = .resolved
        XCTAssertEqual(Set(store.visibleItems.map(\.id)), ["resolved", "expired"])
    }

    /// Archived items must remain reachable — archive is not delete.
    func test_archivedFilter_showsArchivedItemsTheActiveFilterHides() {
        let store = makeStore()
        store.applyRecords([
            makeRecord(id: "open"),
            makeRecord(id: "archived")
        ])
        store.applyItemStates([AIInboxMirrorItemState(id: "archived", archivedAt: Date())])

        store.filter = .archived
        XCTAssertEqual(store.visibleItems.map(\.id), ["archived"])
    }

    func test_searchQuery_matchesTitleBodyAndProject() {
        let store = makeStore()
        store.applyRecords([
            makeRecord(id: "by-title", title: "Nightly matrix is wasting runners", summaryMarkdown: "x", projectName: "alpha"),
            makeRecord(id: "by-body", title: "x", summaryMarkdown: "The **runner** pool is saturated.", projectName: "beta"),
            makeRecord(id: "by-project", title: "x", summaryMarkdown: "y", projectName: "runner-lab"),
            makeRecord(id: "no-match", title: "x", summaryMarkdown: "y", projectName: "gamma")
        ])

        store.searchQuery = "RUNNER"
        XCTAssertEqual(Set(store.visibleItems.map(\.id)), ["by-title", "by-body", "by-project"])

        store.searchQuery = "   "
        XCTAssertEqual(store.visibleItems.count, 4, "A whitespace-only query must not filter anything out")
    }

    // MARK: - Sections

    func test_sections_splitAttentionFromTodayAndEarlier() {
        let store = makeStore()
        let now = Date()
        let startOfToday = Calendar.current.startOfDay(for: now)
        store.applyRecords([
            makeRecord(id: "urgent", priority: .p1, lastSeenAt: now),
            makeRecord(id: "today", priority: .p3, lastSeenAt: max(startOfToday, now.addingTimeInterval(-60))),
            makeRecord(id: "earlier", priority: .p3, lastSeenAt: startOfToday.addingTimeInterval(-7_200))
        ])

        let sections = store.sections
        XCTAssertEqual(sections.map(\.section), [.attention, .today, .earlier])
        XCTAssertEqual(sections[0].items.map(\.id), ["urgent"])
        XCTAssertEqual(sections[1].items.map(\.id), ["today"])
        XCTAssertEqual(sections[2].items.map(\.id), ["earlier"])
    }

    func test_sections_omitEmptyGroups() {
        let store = makeStore()
        store.applyRecords([makeRecord(id: "urgent", priority: .p1, lastSeenAt: Date())])

        XCTAssertEqual(store.sections.map(\.section), [.attention])
    }

    /// Resolved and archived are flat history, not a recency triage list.
    func test_sections_collapseToClosedForResolvedAndArchivedFilters() {
        let store = makeStore()
        store.applyRecords([
            makeRecord(id: "resolved-a", state: .resolved),
            makeRecord(id: "resolved-b", state: .expired)
        ])

        store.filter = .resolved
        XCTAssertEqual(store.sections.map(\.section), [.closed])
        XCTAssertEqual(store.sections.first?.items.count, 2)
    }

    // MARK: - Counts

    func test_unreadCount_countsOnlyOpenVisibleUnreadItems() {
        let store = makeStore()
        let now = Date()
        store.applyRecords([
            makeRecord(id: "unread-open", state: .new),
            makeRecord(id: "read-open", state: .new),
            makeRecord(id: "unread-archived", state: .new),
            makeRecord(id: "unread-snoozed", state: .new),
            makeRecord(id: "unread-resolved", state: .resolved)
        ])
        store.applyItemStates([
            AIInboxMirrorItemState(id: "read-open", readAt: now),
            AIInboxMirrorItemState(id: "unread-archived", archivedAt: now),
            AIInboxMirrorItemState(id: "unread-snoozed", snoozedUntil: now.addingTimeInterval(3_600))
        ])

        XCTAssertEqual(store.unreadCount, 1)
    }

    func test_attentionCount_ignoresHiddenAndClosedItems() {
        let store = makeStore()
        store.applyRecords([
            makeRecord(id: "p1-open", priority: .p1, state: .new),
            makeRecord(id: "p1-archived", priority: .p1, state: .new),
            makeRecord(id: "p1-resolved", priority: .p1, state: .resolved),
            makeRecord(id: "p3-open", priority: .p3, state: .new)
        ])
        store.applyItemStates([AIInboxMirrorItemState(id: "p1-archived", archivedAt: Date())])

        XCTAssertEqual(store.attentionCount, 1)
    }

    // MARK: - Snapshot lifecycle

    func test_applyRecords_marksTheStoreWarmAndClearsLoading() {
        let store = makeStore()
        XCTAssertFalse(store.hasLoadedOnce)

        store.applyRecords([])

        XCTAssertTrue(store.hasLoadedOnce, "An empty snapshot is still an answer — the store must read warm")
        XCTAssertFalse(store.isLoading)
        XCTAssertNotNil(store.lastRefreshedAt)
    }

    /// State can arrive before or after the items it annotates (two independent
    /// listeners), so the join must hold in either order.
    func test_itemStateArrivingBeforeItsItem_stillJoins() {
        let store = makeStore()
        store.applyItemStates([AIInboxMirrorItemState(id: "inb_1", readAt: Date())])
        store.applyRecords([makeRecord(id: "inb_1")])

        XCTAssertFalse(store.items.first?.isUnread ?? true)
    }

    func test_applyItemStates_keepsTheNewerOfTwoStatesForOneItem() {
        let store = makeStore()
        let older = Date(timeIntervalSince1970: 1_000)
        let newer = Date(timeIntervalSince1970: 2_000)
        store.applyRecords([makeRecord(id: "inb_1")])
        store.applyItemStates([
            AIInboxMirrorItemState(id: "inb_1", feedback: "wrong", updatedAt: older),
            AIInboxMirrorItemState(id: "inb_1", feedback: "useful", updatedAt: newer)
        ])

        XCTAssertEqual(store.items.first?.feedback, "useful")
    }

    /// A snapshot that no longer contains the selected item must move the
    /// selection rather than leave the detail column pointing at nothing.
    func test_selectionMovesWhenTheSelectedItemLeavesTheSnapshot() {
        let store = makeStore()
        store.applyRecords([makeRecord(id: "a"), makeRecord(id: "b")])
        store.selectedID = "a"

        store.applyRecords([makeRecord(id: "b")])

        XCTAssertEqual(store.selectedID, "b")
    }

    /// State documents outlive the items they annotate (archiving keeps a row),
    /// so the state window must be strictly larger than the item window — with
    /// equal caps, a long archive history would push the state for
    /// currently-visible rows out and their read marks would vanish.
    func test_stateWindowIsWiderThanTheItemWindow() {
        XCTAssertGreaterThan(AIInboxStore.stateLimit, AIInboxStore.itemLimit)
    }

    // MARK: - Sign-out

    /// One user's findings must never render under another's session, and a
    /// stale deep-link hold must not pin a selection against the next account's
    /// first snapshot.
    func test_reset_dropsEveryTraceOfTheSignedOutAccount() {
        let store = makeStore()
        store.applyRecords([makeRecord(id: "inb_1")])
        store.applyItemStates([AIInboxMirrorItemState(id: "inb_1", readAt: Date())])
        store.focus(itemID: "not-synced")
        store.filter = .archived
        store.searchQuery = "secret project"

        store.reset()

        XCTAssertTrue(store.items.isEmpty)
        XCTAssertFalse(store.hasLoadedOnce)
        XCTAssertNil(store.selectedID)
        XCTAssertNil(store.lastRefreshedAt)
        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.filter, .active)
        XCTAssertTrue(store.searchQuery.isEmpty)
        XCTAssertEqual(store.unreadCount, 0)

        // The focus hold must be gone: the next account's snapshot reconciles
        // normally instead of being pinned to the previous user's deep link.
        store.selectedID = "inb_a"
        store.applyRecords([makeRecord(id: "inb_b")])
        XCTAssertEqual(store.selectedID, "inb_b")
    }

    // MARK: - Deep-link focus

    /// A push names an item the current filter may legitimately exclude (an
    /// archived one, or one filtered out by a stale search). Focus must widen
    /// the view rather than land the user on a list that hides their item.
    func test_focus_widensTheFilterAndClearsAnyActiveSearch() {
        let store = makeStore()
        store.applyRecords([makeRecord(id: "inb_1", priority: .p3, title: "zzz")])
        store.filter = .archived
        store.searchQuery = "something else"

        store.focus(itemID: "inb_1")

        XCTAssertEqual(store.filter, .active)
        XCTAssertTrue(store.searchQuery.isEmpty)
        XCTAssertEqual(store.selectedID, "inb_1")
        XCTAssertEqual(store.visibleItems.map(\.id), ["inb_1"])
    }

    /// Two pushes for the SAME item must both navigate. A plain `String?` would
    /// make the second look like no change and silently do nothing.
    func test_focus_tokenAdvancesOnEveryRequestIncludingRepeats() {
        let store = makeStore()
        let start = store.focusRequestToken

        store.focus(itemID: "inb_1")
        store.focus(itemID: "inb_1")

        XCTAssertEqual(store.focusRequestToken, start + 2)
    }

    /// A push can outrun the sync that carries its item. The selection must
    /// survive the intervening snapshots instead of being reconciled onto an
    /// unrelated top row.
    func test_focus_holdsSelectionForAnItemThatHasNotSyncedYet() {
        let store = makeStore()
        store.applyRecords([makeRecord(id: "already-here")])

        store.focus(itemID: "not-yet-synced")
        XCTAssertEqual(store.selectedID, "not-yet-synced")

        // An intervening snapshot that still lacks the item must not steal it.
        store.applyRecords([makeRecord(id: "already-here")])
        XCTAssertEqual(store.selectedID, "not-yet-synced")

        // Once it lands, the selection resolves to the real row.
        store.applyRecords([makeRecord(id: "already-here"), makeRecord(id: "not-yet-synced")])
        XCTAssertEqual(store.selectedID, "not-yet-synced")
        XCTAssertNotNil(store.selectedItem)
    }

    /// The hold must not be permanent: once the focused item has been seen, a
    /// later snapshot that drops it reconciles normally again.
    func test_focus_holdReleasesAfterTheItemHasBeenSeen() {
        let store = makeStore()
        store.focus(itemID: "inb_1")
        store.applyRecords([makeRecord(id: "inb_1"), makeRecord(id: "inb_2")])
        XCTAssertEqual(store.selectedID, "inb_1")

        store.applyRecords([makeRecord(id: "inb_2")])
        XCTAssertEqual(store.selectedID, "inb_2")
    }

    /// The bare `burnbar://inbox` link carries no item; it must still surface
    /// the list rather than being dropped.
    func test_focus_withoutAnItemStillRequestsTheSurface() {
        let store = makeStore()
        let start = store.focusRequestToken

        store.focus(itemID: nil)

        XCTAssertEqual(store.focusRequestToken, start + 1)
        XCTAssertEqual(store.filter, .active)
    }

    // MARK: - Optimistic writes

    func test_markRead_appliesLocallyBeforeTheWriteResolves() async {
        let spy = StateWriterSpy()
        let store = makeStore(spy)
        store.applyRecords([makeRecord(id: "inb_1")])
        XCTAssertTrue(store.items.first?.isUnread ?? false)

        var wasUnreadDuringWrite = true
        spy.onWrite = { wasUnreadDuringWrite = store.items.first?.isUnread ?? true }

        await store.markRead("inb_1")

        XCTAssertFalse(wasUnreadDuringWrite, "The row must clear before the network call, not after it")
        XCTAssertFalse(store.items.first?.isUnread ?? true)
        XCTAssertEqual(spy.writes.count, 1)
        XCTAssertEqual(spy.writes.first?.documentID, "inb_1")
    }

    func test_select_marksReadAndSetsSelection() async {
        let spy = StateWriterSpy()
        let store = makeStore(spy)
        store.applyRecords([makeRecord(id: "inb_1")])

        await store.select("inb_1")

        XCTAssertEqual(store.selectedID, "inb_1")
        XCTAssertFalse(store.items.first?.isUnread ?? true)
        XCTAssertEqual(spy.writes.count, 1)
    }

    /// Selecting an already-read item must not re-write it; otherwise scrolling
    /// a detail column on iPad would write a document per row.
    func test_select_onAnAlreadyReadItem_writesNothing() async {
        let spy = StateWriterSpy()
        let store = makeStore(spy)
        store.applyRecords([makeRecord(id: "inb_1")])
        store.applyItemStates([AIInboxMirrorItemState(id: "inb_1", readAt: Date())])

        await store.select("inb_1")

        XCTAssertEqual(store.selectedID, "inb_1")
        XCTAssertTrue(spy.writes.isEmpty)
    }

    func test_toggleRead_flipsBothWays() async {
        let spy = StateWriterSpy()
        let store = makeStore(spy)
        store.applyRecords([makeRecord(id: "inb_1")])

        await store.toggleRead("inb_1")
        XCTAssertFalse(store.items.first?.isUnread ?? true)

        await store.toggleRead("inb_1")
        XCTAssertTrue(store.items.first?.isUnread ?? false)
        XCTAssertEqual(spy.writes.count, 2)
    }

    func test_archive_removesTheItemFromTheActiveListAndClearsSelection() async {
        let spy = StateWriterSpy()
        let store = makeStore(spy)
        store.applyRecords([makeRecord(id: "inb_1"), makeRecord(id: "inb_2")])
        store.selectedID = "inb_1"

        await store.archive("inb_1")

        XCTAssertEqual(store.visibleItems.map(\.id), ["inb_2"])
        XCTAssertEqual(store.selectedID, "inb_2", "Selection must fall through to a row that still exists")
        XCTAssertNotNil(spy.writes.first?.payload["archivedAt"])
    }

    /// Archiving the only remaining row must leave nothing selected rather than
    /// re-selecting the item that was just dismissed.
    func test_archive_ofTheLastVisibleItemLeavesNothingSelected() async {
        let store = makeStore()
        store.applyRecords([makeRecord(id: "inb_1")])
        store.selectedID = "inb_1"

        await store.archive("inb_1")

        XCTAssertTrue(store.visibleItems.isEmpty)
        XCTAssertNil(store.selectedID)
    }

    func test_snooze_hidesTheItemUntilTheDeadline() async {
        let spy = StateWriterSpy()
        let store = makeStore(spy)
        store.applyRecords([makeRecord(id: "inb_1")])

        await store.snooze("inb_1", for: 3_600)

        XCTAssertTrue(store.visibleItems.isEmpty)
        let until = try? XCTUnwrap(spy.writes.first?.payload["snoozedUntil"] as? Date)
        XCTAssertNotNil(until)
        XCTAssertGreaterThan(until ?? .distantPast, Date())
    }

    func test_setFeedback_writesOnlyRulesApprovedValues() async {
        let spy = StateWriterSpy()
        let store = makeStore(spy)
        store.applyRecords([makeRecord(id: "inb_1")])

        await store.setFeedback("inb_1", useful: true)
        XCTAssertEqual(store.items.first?.feedback, "useful")

        await store.setFeedback("inb_1", useful: false)
        XCTAssertEqual(store.items.first?.feedback, "not_useful")

        for write in spy.writes {
            if let value = write.payload["feedback"] as? String {
                XCTAssertTrue(
                    AIInboxMirrorCodec.allowedFeedbackValues.contains(value),
                    "The rules reject any feedback value outside the allowlist"
                )
            }
        }
    }

    /// Tapping the active rating again clears it.
    func test_setFeedback_repeatingTheSameRatingClearsIt() async {
        let spy = StateWriterSpy()
        let store = makeStore(spy)
        store.applyRecords([makeRecord(id: "inb_1")])

        await store.setFeedback("inb_1", useful: true)
        await store.setFeedback("inb_1", useful: true)

        XCTAssertNil(store.items.first?.feedback)
    }

    func test_markEverythingRead_coversOnlyTheVisibleSlice() async {
        let spy = StateWriterSpy()
        let store = makeStore(spy)
        store.applyRecords([
            makeRecord(id: "visible-a"),
            makeRecord(id: "visible-b"),
            makeRecord(id: "archived")
        ])
        store.applyItemStates([AIInboxMirrorItemState(id: "archived", archivedAt: Date())])

        await store.markEverythingRead()

        XCTAssertEqual(store.unreadCount, 0)
        XCTAssertEqual(
            Set(spy.writes.map(\.documentID)),
            ["visible-a", "visible-b"],
            "Hidden items must not be touched by a bulk action the user could not see"
        )
    }

    func test_writeFailure_surfacesAnErrorWithoutRevertingTheLocalEdit() async {
        let spy = StateWriterSpy()
        spy.failure = NSError(domain: "AIInboxTest", code: 7, userInfo: [NSLocalizedDescriptionKey: "offline"])
        let store = makeStore(spy)
        store.applyRecords([makeRecord(id: "inb_1")])

        await store.markRead("inb_1")

        XCTAssertEqual(store.lastError, "offline")
        // Firestore queues the write and replays it, so reverting the row would
        // make an eventually-successful write look like a failed one.
        XCTAssertFalse(store.items.first?.isUnread ?? true)
    }

    // MARK: - State payload shape

    /// `merge: true` cannot clear a field by omitting it, and the codec omits
    /// every `nil`. Without explicit deletes, un-archiving and clearing a rating
    /// would be silent no-ops on the server while looking correct on-device.
    func test_statePayload_deletesFieldsTheLocalStateNoLongerCarries() {
        let payload = AIInboxStore.statePayload(
            for: AIInboxMirrorItemState(id: "inb_1", readAt: Date(), updatedAt: Date())
        )

        XCTAssertNotNil(payload["readAt"])
        XCTAssertTrue(payload["archivedAt"] is FieldValue, "An absent archivedAt must be an explicit delete")
        XCTAssertTrue(payload["snoozedUntil"] is FieldValue)
        XCTAssertTrue(payload["feedback"] is FieldValue)
    }

    /// Every key must be in the rules allowlist, or the whole write is rejected.
    func test_statePayload_staysInsideTheRulesAllowlist() {
        let payload = AIInboxStore.statePayload(
            for: AIInboxMirrorItemState(
                id: "inb_1",
                readAt: Date(),
                archivedAt: Date(),
                snoozedUntil: Date(),
                feedback: "useful",
                updatedAt: Date(),
                updatedByDeviceID: "device-1"
            )
        )

        let allowed = Set(AIInboxMirrorCodec.stateDocumentKeys)
        XCTAssertTrue(
            Set(payload.keys).isSubset(of: allowed),
            "Unlisted keys: \(Set(payload.keys).subtracting(allowed))"
        )
    }

    func test_statePayload_carriesTheWritingDeviceForLastWriterWinsDebugging() async {
        let spy = StateWriterSpy()
        let store = makeStore(spy)
        store.applyRecords([makeRecord(id: "inb_1")])

        await store.markRead("inb_1")

        let deviceID = spy.writes.first?.payload["updatedByDeviceID"] as? String
        XCTAssertEqual(deviceID, MobileDeviceIdentity.loadOrCreateDeviceId())
    }

    // MARK: - Detail reference resolution

    /// Three of the six action kinds address things that exist only on the Mac.
    /// They must resolve to a copyable reference, never to a button that looks
    /// live and silently does nothing.
    func test_actionTarget_separatesWebLinksFromMacOnlyReferences() {
        let web = BurnBarInboxAction(id: "a", kind: .openURL, title: "Open PR", value: "https://github.com/x/y/pull/1")
        XCTAssertEqual(AIInboxDetailView.actionTarget(web), .web(URL(string: "https://github.com/x/y/pull/1")!))

        let resume = BurnBarInboxAction(id: "b", kind: .resumeConversation, title: "Resume", value: "conv-123")
        XCTAssertEqual(AIInboxDetailView.actionTarget(resume), .macReference("conv-123"))

        let project = BurnBarInboxAction(id: "c", kind: .openProject, title: "Open", value: "/Users/me/repo")
        XCTAssertEqual(AIInboxDetailView.actionTarget(project), .macReference("/Users/me/repo"))

        let command = BurnBarInboxAction(id: "d", kind: .runCommand, title: "Run", value: "git status")
        XCTAssertEqual(AIInboxDetailView.actionTarget(command), .macReference("git status"))

        let empty = BurnBarInboxAction(id: "e", kind: .openSettings, title: "Settings", value: "")
        XCTAssertEqual(AIInboxDetailView.actionTarget(empty), AIInboxDetailView.ReferenceTarget.unavailable)
    }

    /// A non-web scheme must never reach `openURL`: `openburnbar://` is not
    /// registered on iOS, so opening it would fail silently or, worse, hand the
    /// user to another app.
    func test_evidenceTarget_neverTreatsANonWebSchemeAsOpenable() {
        XCTAssertEqual(
            AIInboxDetailView.evidenceTarget("openburnbar://sessions/conv-9"),
            .macReference("conv-9")
        )
        XCTAssertEqual(
            AIInboxDetailView.evidenceTarget("https://github.com/x/y/issues/3"),
            .web(URL(string: "https://github.com/x/y/issues/3")!)
        )
        XCTAssertEqual(AIInboxDetailView.evidenceTarget(nil), AIInboxDetailView.ReferenceTarget.unavailable)
        XCTAssertEqual(AIInboxDetailView.evidenceTarget(""), AIInboxDetailView.ReferenceTarget.unavailable)
    }

    // MARK: - Presentation

    /// Every kind needs a glyph and a label. A missing case would ship a
    /// blank-iconed row rather than fail to compile, so enumerate them.
    func test_presentation_coversEveryItemKindAndPriority() {
        for kind in BurnBarInboxItemKind.allCases {
            XCTAssertFalse(AIInboxPresentation.icon(for: kind).isEmpty)
            XCTAssertFalse(AIInboxPresentation.kindLabel(kind).isEmpty)
        }
        for priority in BurnBarInboxPriority.allCases {
            XCTAssertFalse(AIInboxPresentation.priorityLabel(priority).isEmpty)
        }
        for kind in BurnBarInboxEvidence.Kind.allCases {
            XCTAssertFalse(AIInboxPresentation.evidenceIcon(for: kind).isEmpty)
        }
        for kind in BurnBarInboxAction.Kind.allCases {
            XCTAssertFalse(AIInboxPresentation.actionIcon(for: kind).isEmpty)
        }
    }

    func test_metricDisplay_humanizesRatesCostsAndDurations() {
        XCTAssertEqual(AIInboxPresentation.metricDisplay(key: "waste_rate", value: "0.95").label, "Waste rate")
        XCTAssertEqual(AIInboxPresentation.metricDisplay(key: "waste_rate", value: "0.95").value, "95%")
        XCTAssertEqual(AIInboxPresentation.metricDisplay(key: "spent_usd", value: "1.5").value, "$1.500")
        XCTAssertEqual(AIInboxPresentation.metricDisplay(key: "wasted_minutes", value: "304").value, "304m")
        // A non-numeric value must pass through untouched rather than become "0".
        XCTAssertEqual(AIInboxPresentation.metricDisplay(key: "branch", value: "main").value, "main")
    }

    func test_plainPreview_stripsMarkdownMarkers() {
        let preview = AIInboxPresentation.plainPreview("**38 of 40 runs** failed.\n\nSee `nightly.yml`.")
        XCTAssertFalse(preview.contains("**"))
        XCTAssertFalse(preview.contains("`"))
        XCTAssertFalse(preview.contains("\n"))
        XCTAssertTrue(preview.contains("38 of 40 runs"))
    }

    func test_friendlyModelNames_dropsProviderPrefixes() {
        XCTAssertEqual(
            AIInboxPresentation.friendlyModelNames("deepseek:deepseek-v4-flash+openai:gpt-5.6-luna"),
            "deepseek-v4-flash and gpt-5.6-luna"
        )
        XCTAssertEqual(AIInboxPresentation.friendlyModelNames("local-rules"), "local-rules")
    }
}
