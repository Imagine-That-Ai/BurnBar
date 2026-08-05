import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

/// Behavioural cover for `InboxModel`, the closure-injected view model behind the
/// AI Inbox surface.
///
/// The model is deliberately database-free (every dependency arrives as a
/// closure), so these tests pin the decisions the surface actually depends on
/// without a GRDB queue or a window server:
///
///   * marker-gated refresh — the property that makes a 30-second cadence cheap
///   * filter/section/ranking derivation
///   * optimistic mutation followed by marker invalidation
///   * error translation, including the "daemon has never run" case
@MainActor
final class InboxModelTests: XCTestCase {

    // MARK: - Fake backing store

    /// Records every call the model makes so tests can assert the write actually
    /// reached the store, not merely that local state changed.
    private final class Recorder {
        var rows: [ControlPlaneStore.AIInboxRow] = []
        var marker = "m1"
        var runs: [BurnBarInboxRunTelemetry] = []

        var markerError: Error?
        var rowsError: Error?
        var mutationError: Error?

        var markReadIDs: [String] = []
        var markUnreadIDs: [String] = []
        var archiveCalls: [(String, Bool)] = []
        var snoozeCalls: [(String, Date?)] = []
        var feedbackCalls: [(String, String?)] = []
        var markAllReadCount = 0
        var loadRowsStates: [[BurnBarInboxItemState]?] = []
        var loadRowsCount = 0
    }

    private struct FakeError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func makeModel(_ recorder: Recorder) -> InboxModel {
        InboxModel(
            loadRows: { states in
                recorder.loadRowsStates.append(states)
                recorder.loadRowsCount += 1
                if let error = recorder.rowsError { throw error }
                return recorder.rows
            },
            loadMarker: {
                if let error = recorder.markerError { throw error }
                return recorder.marker
            },
            markRead: { id in
                if let error = recorder.mutationError { throw error }
                recorder.markReadIDs.append(id)
            },
            markUnread: { id in
                if let error = recorder.mutationError { throw error }
                recorder.markUnreadIDs.append(id)
            },
            setArchived: { id, archived in
                if let error = recorder.mutationError { throw error }
                recorder.archiveCalls.append((id, archived))
            },
            snooze: { id, until in
                if let error = recorder.mutationError { throw error }
                recorder.snoozeCalls.append((id, until))
            },
            setFeedback: { id, value in
                if let error = recorder.mutationError { throw error }
                recorder.feedbackCalls.append((id, value))
            },
            markAllRead: {
                if let error = recorder.mutationError { throw error }
                recorder.markAllReadCount += 1
            },
            loadRuns: {
                if let error = recorder.rowsError { throw error }
                return recorder.runs
            }
        )
    }

    // MARK: - Row builder

    private func makeRow(
        id: String,
        priority: BurnBarInboxPriority = .p3,
        state: BurnBarInboxItemState = .new,
        lastSeenAt: Date = Date(),
        readAt: Date? = nil,
        archivedAt: Date? = nil,
        snoozedUntil: Date? = nil,
        feedback: String? = nil
    ) -> ControlPlaneStore.AIInboxRow {
        ControlPlaneStore.AIInboxRow(
            summary: BurnBarInboxItemSummary(
                id: id,
                fingerprint: "fp-\(id)",
                kind: .ciWaste,
                priority: priority,
                state: state,
                title: "Item \(id)",
                firstSeenAt: lastSeenAt.addingTimeInterval(-3600),
                lastSeenAt: lastSeenAt
            ),
            summaryMarkdown: "body \(id)",
            payload: BurnBarInboxItemPayload(),
            readAt: readAt,
            archivedAt: archivedAt,
            snoozedUntil: snoozedUntil,
            feedback: feedback
        )
    }

    // MARK: - Row state derivation

    func testUnreadRequiresAnOpenStateAndNoReadStamp() {
        XCTAssertTrue(makeRow(id: "a").isUnread)
        XCTAssertFalse(makeRow(id: "b", readAt: Date()).isUnread)
        // A resolved item is not "unread" even with no read stamp: it is history.
        XCTAssertFalse(makeRow(id: "c", state: .resolved).isUnread)
    }

    func testHiddenCoversArchivedAndActiveSnoozeButNotAnExpiredSnooze() {
        XCTAssertTrue(makeRow(id: "a", archivedAt: Date()).isHidden)
        XCTAssertTrue(makeRow(id: "b", snoozedUntil: Date().addingTimeInterval(600)).isHidden)
        // A snooze that has already elapsed must return the row to the list.
        XCTAssertFalse(makeRow(id: "c", snoozedUntil: Date().addingTimeInterval(-600)).isHidden)
        XCTAssertFalse(makeRow(id: "d").isHidden)
    }

    // MARK: - Marker-gated refresh

    func testLoadSkipsWorkWhenTheMarkerHasNotMoved() async {
        let recorder = Recorder()
        recorder.rows = [makeRow(id: "a")]
        let model = makeModel(recorder)

        await model.load()
        XCTAssertEqual(recorder.loadRowsCount, 1)
        XCTAssertEqual(model.lastMarker, "m1")

        // Same marker, rows already present: the expensive read must not run.
        await model.load()
        XCTAssertEqual(recorder.loadRowsCount, 1, "an idle inbox must not re-read rows")
    }

    func testLoadReReadsWhenTheMarkerMoves() async {
        let recorder = Recorder()
        recorder.rows = [makeRow(id: "a")]
        let model = makeModel(recorder)

        await model.load()
        recorder.marker = "m2"
        await model.load()

        XCTAssertEqual(recorder.loadRowsCount, 2)
        XCTAssertEqual(model.lastMarker, "m2")
    }

    func testForcedLoadIgnoresAnUnchangedMarker() async {
        let recorder = Recorder()
        recorder.rows = [makeRow(id: "a")]
        let model = makeModel(recorder)

        await model.load()
        await model.load(force: true)

        XCTAssertEqual(recorder.loadRowsCount, 2)
    }

    func testLoadPassesTheFilterStatesThrough() async {
        let recorder = Recorder()
        recorder.rows = [makeRow(id: "a")]
        let model = makeModel(recorder)

        await model.load()

        XCTAssertEqual(recorder.loadRowsStates.first ?? nil, BurnBarInboxItemState.openStates)
    }

    func testLoadRecordsRefreshTimeAndClearsAStaleError() async {
        let recorder = Recorder()
        recorder.rows = [makeRow(id: "a")]
        let model = makeModel(recorder)
        model.errorMessage = "stale failure"

        await model.load()

        XCTAssertNil(model.errorMessage)
        XCTAssertNotNil(model.lastRefreshedAt)
        XCTAssertFalse(model.isLoading)
    }

    func testLoadRepairsASelectionThatNoLongerExists() async {
        let recorder = Recorder()
        recorder.rows = [makeRow(id: "a"), makeRow(id: "b")]
        let model = makeModel(recorder)
        await model.load()

        model.selectedID = "gone"
        recorder.marker = "m2"
        await model.load()

        XCTAssertEqual(model.selectedID, "a", "a dangling selection falls back to the first row")
    }

    // MARK: - Derived collections

    func testVisibleRowsHideArchivedAndSnoozedForTheActiveFilter() async {
        let recorder = Recorder()
        recorder.rows = [
            makeRow(id: "keep"),
            makeRow(id: "archived", archivedAt: Date()),
            makeRow(id: "snoozed", snoozedUntil: Date().addingTimeInterval(900))
        ]
        let model = makeModel(recorder)
        await model.load()

        XCTAssertEqual(model.visibleRows.map(\.id), ["keep"])
    }

    func testAttentionFilterKeepsOnlyP1AndP2() async {
        let recorder = Recorder()
        recorder.rows = [
            makeRow(id: "p1", priority: .p1),
            makeRow(id: "p2", priority: .p2),
            makeRow(id: "p3", priority: .p3),
            makeRow(id: "p4", priority: .p4)
        ]
        let model = makeModel(recorder)
        await model.load()
        model.filter = .attention

        XCTAssertEqual(Set(model.visibleRows.map(\.id)), ["p1", "p2"])
    }

    func testArchivedFilterShowsOnlyArchivedRows() async {
        let recorder = Recorder()
        recorder.rows = [makeRow(id: "open"), makeRow(id: "gone", archivedAt: Date())]
        let model = makeModel(recorder)
        await model.load()
        model.filter = .archived

        XCTAssertEqual(model.visibleRows.map(\.id), ["gone"])
    }

    func testRankingPutsPriorityFirstThenUnreadThenRecency() {
        let now = Date()
        let p1 = makeRow(id: "p1", priority: .p1, lastSeenAt: now.addingTimeInterval(-9000))
        let p3 = makeRow(id: "p3", priority: .p3, lastSeenAt: now)
        XCTAssertTrue(InboxModel.ranked(p1, p3), "priority outranks recency")

        let unread = makeRow(id: "unread", lastSeenAt: now.addingTimeInterval(-9000))
        let read = makeRow(id: "read", lastSeenAt: now, readAt: now)
        XCTAssertTrue(InboxModel.ranked(unread, read), "unread outranks recency at equal priority")

        let newer = makeRow(id: "newer", lastSeenAt: now)
        let older = makeRow(id: "older", lastSeenAt: now.addingTimeInterval(-60))
        XCTAssertTrue(InboxModel.ranked(newer, older), "recency breaks the final tie")
    }

    func testSectionsSplitAttentionTodayAndEarlier() async {
        let now = Date()
        let yesterday = Calendar.current.startOfDay(for: now).addingTimeInterval(-3600)
        let recorder = Recorder()
        recorder.rows = [
            makeRow(id: "attention", priority: .p1, lastSeenAt: now),
            makeRow(id: "today", priority: .p4, lastSeenAt: now),
            makeRow(id: "earlier", priority: .p4, lastSeenAt: yesterday)
        ]
        let model = makeModel(recorder)
        await model.load()

        let sections = model.sections
        XCTAssertEqual(sections.map(\.section), [.attention, .today, .earlier])
        XCTAssertEqual(sections[0].rows.map(\.id), ["attention"])
        XCTAssertEqual(sections[1].rows.map(\.id), ["today"])
        XCTAssertEqual(sections[2].rows.map(\.id), ["earlier"])
    }

    func testSectionsCollapseToASingleClosedGroupForResolvedAndArchived() async {
        let recorder = Recorder()
        recorder.rows = [makeRow(id: "a", state: .resolved), makeRow(id: "b", state: .resolved)]
        let model = makeModel(recorder)
        await model.load()
        model.filter = .resolved

        XCTAssertEqual(model.sections.map(\.section), [.closed])
    }

    func testEmptySectionsAreOmitted() async {
        let recorder = Recorder()
        recorder.rows = [makeRow(id: "only", priority: .p1)]
        let model = makeModel(recorder)
        await model.load()

        XCTAssertEqual(model.sections.map(\.section), [.attention])
    }

    func testCountsIgnoreHiddenRows() async {
        let recorder = Recorder()
        recorder.rows = [
            makeRow(id: "unread-visible", priority: .p1),
            makeRow(id: "unread-archived", priority: .p1, archivedAt: Date()),
            makeRow(id: "read-visible", priority: .p1, readAt: Date())
        ]
        let model = makeModel(recorder)
        await model.load()

        XCTAssertEqual(model.unreadCount, 1)
        XCTAssertEqual(model.attentionCount, 2, "attention counts read rows but not hidden ones")
    }

    func testSelectedRowResolvesByIdentifier() async {
        let recorder = Recorder()
        recorder.rows = [makeRow(id: "a"), makeRow(id: "b")]
        let model = makeModel(recorder)
        await model.load()

        XCTAssertNil(model.selectedRow)
        model.selectedID = "b"
        XCTAssertEqual(model.selectedRow?.id, "b")
    }

    // MARK: - Selection

    func testSelectingAnUnreadRowMarksItReadOptimisticallyAndPersists() async {
        let recorder = Recorder()
        recorder.rows = [makeRow(id: "a")]
        let model = makeModel(recorder)
        await model.load()

        await model.select("a")

        XCTAssertEqual(model.selectedID, "a")
        XCTAssertNotNil(model.rows.first?.readAt, "the unread dot clears before the write returns")
        XCTAssertEqual(recorder.markReadIDs, ["a"])
        XCTAssertNil(model.lastMarker, "a successful write invalidates the marker")
    }

    func testSelectingAnAlreadyReadRowDoesNotWriteAgain() async {
        let recorder = Recorder()
        recorder.rows = [makeRow(id: "a", readAt: Date())]
        let model = makeModel(recorder)
        await model.load()

        await model.select("a")

        XCTAssertEqual(model.selectedID, "a")
        XCTAssertTrue(recorder.markReadIDs.isEmpty)
    }

    func testSelectByIdentifierWidensTheFilterToFindAResolvedItem() async {
        let recorder = Recorder()
        recorder.rows = []
        let model = makeModel(recorder)
        await model.load()

        // The item exists, but only outside the open-state filter.
        recorder.rows = [makeRow(id: "resolved-item", state: .resolved, readAt: Date())]
        await model.select(itemID: "resolved-item")

        XCTAssertEqual(model.selectedID, "resolved-item")
        XCTAssertEqual(model.filter, .resolved)
        XCTAssertTrue(recorder.loadRowsStates.contains { $0 == nil }, "widening queries every state")
    }

    func testSelectByIdentifierCanBeToldNotToLoad() async {
        let recorder = Recorder()
        let model = makeModel(recorder)
        await model.load()
        let callsBefore = recorder.loadRowsCount

        await model.select(itemID: "absent", loadingIfNeeded: false)

        XCTAssertNil(model.selectedID)
        XCTAssertEqual(recorder.loadRowsCount, callsBefore)
    }

    // MARK: - Mutations

    func testToggleReadFlipsBothDirectionsAndPersistsEachOne() async {
        let recorder = Recorder()
        recorder.rows = [makeRow(id: "a")]
        let model = makeModel(recorder)
        await model.load()

        await model.toggleRead("a")
        XCTAssertNotNil(model.rows.first?.readAt)
        XCTAssertEqual(recorder.markReadIDs, ["a"])

        await model.toggleRead("a")
        XCTAssertNil(model.rows.first?.readAt)
        XCTAssertEqual(recorder.markUnreadIDs, ["a"])
    }

    func testToggleReadIgnoresAnUnknownIdentifier() async {
        let recorder = Recorder()
        recorder.rows = [makeRow(id: "a")]
        let model = makeModel(recorder)
        await model.load()

        await model.toggleRead("missing")

        XCTAssertTrue(recorder.markReadIDs.isEmpty)
        XCTAssertTrue(recorder.markUnreadIDs.isEmpty)
    }

    func testArchiveRemovesTheRowImmediatelyAndMovesTheSelection() async {
        let recorder = Recorder()
        recorder.rows = [makeRow(id: "a"), makeRow(id: "b")]
        let model = makeModel(recorder)
        await model.load()
        model.selectedID = "a"

        await model.archive("a")

        XCTAssertEqual(model.rows.map(\.id), ["b"], "the gesture removes the row without waiting")
        XCTAssertEqual(model.selectedID, "b")
        XCTAssertEqual(recorder.archiveCalls.map(\.0), ["a"])
        XCTAssertEqual(recorder.archiveCalls.map(\.1), [true])
    }

    func testUnarchivePersistsFalseThenReloads() async {
        let recorder = Recorder()
        recorder.rows = [makeRow(id: "a", archivedAt: Date())]
        let model = makeModel(recorder)
        await model.load()
        let callsBefore = recorder.loadRowsCount

        await model.unarchive("a")

        XCTAssertEqual(recorder.archiveCalls.map(\.1), [false])
        XCTAssertGreaterThan(recorder.loadRowsCount, callsBefore, "unarchive forces a reload")
    }

    func testSnoozeRemovesTheRowAndPersistsAFutureDeadline() async {
        let recorder = Recorder()
        recorder.rows = [makeRow(id: "a"), makeRow(id: "b")]
        let model = makeModel(recorder)
        await model.load()
        model.selectedID = "a"

        await model.snooze("a", for: 3600)

        XCTAssertEqual(model.rows.map(\.id), ["b"])
        XCTAssertEqual(model.selectedID, "b")
        XCTAssertEqual(recorder.snoozeCalls.count, 1)
        let until = try? XCTUnwrap(recorder.snoozeCalls.first?.1)
        XCTAssertGreaterThan(until ?? .distantPast, Date(), "the deadline is in the future")
    }

    func testFeedbackMapsBooleanIntentOntoTheStoredVocabulary() async {
        let recorder = Recorder()
        recorder.rows = [makeRow(id: "a")]
        let model = makeModel(recorder)
        await model.load()

        await model.setFeedback("a", useful: true)
        XCTAssertEqual(model.rows.first?.feedback, "useful")

        await model.setFeedback("a", useful: false)
        XCTAssertEqual(model.rows.first?.feedback, "not_useful")

        await model.setFeedback("a", useful: nil)
        XCTAssertNil(model.rows.first?.feedback, "clearing feedback stores no value")

        XCTAssertEqual(recorder.feedbackCalls.map(\.1), ["useful", "not_useful", nil])
    }

    func testMarkEverythingReadStampsOnlyUnreadRowsAndPersistsOnce() async {
        let alreadyRead = Date(timeIntervalSince1970: 1_000)
        let recorder = Recorder()
        recorder.rows = [
            makeRow(id: "unread-a"),
            makeRow(id: "unread-b"),
            makeRow(id: "read", readAt: alreadyRead)
        ]
        let model = makeModel(recorder)
        await model.load()

        await model.markEverythingRead()

        XCTAssertEqual(model.unreadCount, 0)
        XCTAssertEqual(
            model.rows.first { $0.id == "read" }?.readAt,
            alreadyRead,
            "an existing read stamp is preserved rather than overwritten"
        )
        XCTAssertEqual(recorder.markAllReadCount, 1)
    }

    // MARK: - Telemetry

    func testTelemetryExposesLatestRunAndHasEverRun() async {
        let recorder = Recorder()
        let model = makeModel(recorder)

        await model.loadTelemetry()
        XCTAssertFalse(model.hasEverRun)
        XCTAssertNil(model.latestRun)

        recorder.runs = [makeRun(tickID: "t2"), makeRun(tickID: "t1")]
        await model.loadTelemetry()

        XCTAssertTrue(model.hasEverRun)
        XCTAssertEqual(model.latestRun?.tickID, "t2", "the newest run leads the list")
    }

    func testTelemetryFailureLeavesAnEmptyRunListRatherThanThrowing() async {
        let recorder = Recorder()
        recorder.runs = [makeRun(tickID: "t1")]
        let model = makeModel(recorder)
        await model.loadTelemetry()
        XCTAssertTrue(model.hasEverRun)

        recorder.rowsError = FakeError(message: "telemetry unavailable")
        await model.loadTelemetry()

        XCTAssertFalse(model.hasEverRun, "a telemetry failure degrades to empty, never crashes")
    }

    private func makeRun(tickID: String) -> BurnBarInboxRunTelemetry {
        BurnBarInboxRunTelemetry(
            tickID: tickID,
            startedAt: Date(),
            finishedAt: Date(),
            gateResult: .localChanged,
            egressMode: .off,
            llmCalls: 0,
            inputTokens: 0,
            outputTokens: 0,
            costUSD: 0,
            itemsNew: 0,
            itemsUpdated: 0,
            itemsResolved: 0,
            error: nil
        )
    }

    // MARK: - Failure handling

    func testAMissingTableIsTranslatedIntoSetupGuidance() {
        let message = InboxModel.friendlyMessage(
            for: FakeError(message: "SQLite error 1: no such table: ai_inbox_items")
        )
        XCTAssertTrue(
            message.contains("has not been set up yet"),
            "a first-run user is told to wait for the daemon, not shown SQL"
        )
    }

    func testAnUnrecognisedFailureIsSurfacedVerbatim() {
        let message = InboxModel.friendlyMessage(for: FakeError(message: "disk is on fire"))
        XCTAssertEqual(message, "disk is on fire")
    }

    func testALoadFailureSurfacesAMessageAndClearsTheLoadingFlag() async {
        let recorder = Recorder()
        recorder.rowsError = FakeError(message: "read failed")
        let model = makeModel(recorder)

        await model.load()

        XCTAssertEqual(model.errorMessage, "read failed")
        XCTAssertFalse(model.isLoading)
        XCTAssertTrue(model.rows.isEmpty)
    }

    func testAMarkerFailureSurfacesAMessageWithoutReadingRows() async {
        let recorder = Recorder()
        recorder.markerError = FakeError(message: "marker failed")
        let model = makeModel(recorder)

        await model.load()

        XCTAssertEqual(model.errorMessage, "marker failed")
        XCTAssertEqual(recorder.loadRowsCount, 0)
    }

    func testAFailedMutationReportsTheErrorAndKeepsTheMarker() async {
        let recorder = Recorder()
        recorder.rows = [makeRow(id: "a")]
        let model = makeModel(recorder)
        await model.load()
        XCTAssertEqual(model.lastMarker, "m1")

        recorder.mutationError = FakeError(message: "write failed")
        await model.select("a")

        XCTAssertEqual(model.errorMessage, "write failed")
        XCTAssertEqual(model.lastMarker, "m1", "a failed write must not claim fresh data")
    }

    // MARK: - Presentation metadata

    func testEveryFilterCarriesTitleStatesAndEmptyIcon() {
        for filter in InboxModel.Filter.allCases {
            XCTAssertFalse(filter.title.isEmpty)
            XCTAssertFalse(filter.emptyIcon.isEmpty)
            XCTAssertEqual(filter.id, filter.rawValue)
        }
        XCTAssertEqual(InboxModel.Filter.active.states, BurnBarInboxItemState.openStates)
        XCTAssertEqual(InboxModel.Filter.resolved.states, [.resolved, .expired])
    }

    func testEverySectionCarriesATitle() {
        for section in InboxModel.Section.allCases {
            XCTAssertFalse(section.title.isEmpty)
            XCTAssertEqual(section.id, section.rawValue)
        }
    }
}
