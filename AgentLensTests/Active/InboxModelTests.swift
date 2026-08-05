import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

// MARK: - Harness

private struct MarkerFailure: LocalizedError {
    var errorDescription: String? { "no such table: ai_inbox_items" }
}

private struct MutationFailure: LocalizedError {
    var errorDescription: String? { "the write failed" }
}

/// Backs every injected closure. An actor rather than a class so the
/// `@Sendable` closures can mutate shared state without a lock.
private actor InboxModelHarness {
    private(set) var marker = "marker-1"
    private(set) var allRows: [ControlPlaneStore.AIInboxRow] = []
    private(set) var runs: [BurnBarInboxRunTelemetry] = []
    private(set) var loadRowsCallCount = 0
    private(set) var events: [String] = []
    private var markerFails = false
    private var mutationsFail = false

    func setRows(_ rows: [ControlPlaneStore.AIInboxRow]) { allRows = rows }
    func setMarker(_ value: String) { marker = value }
    func setRuns(_ value: [BurnBarInboxRunTelemetry]) { runs = value }
    func setMarkerFails(_ fails: Bool) { markerFails = fails }
    func setMutationsFail(_ fails: Bool) { mutationsFail = fails }

    func loadMarker() throws -> String {
        if markerFails { throw MarkerFailure() }
        return marker
    }

    func loadRows(_ states: [BurnBarInboxItemState]?) -> [ControlPlaneStore.AIInboxRow] {
        loadRowsCallCount += 1
        guard let states else { return allRows }
        return allRows.filter { states.contains($0.summary.state) }
    }

    func record(_ event: String) throws {
        if mutationsFail { throw MutationFailure() }
        events.append(event)
    }
}

/// Covers the AI Inbox view model end to end through its closure-injected
/// contract: marker-gated loading, filter/section derivation, ranking, the
/// optimistic mutations, and the friendly error mapping.
@MainActor
final class InboxModelTests: XCTestCase {

    private func makeModel(_ harness: InboxModelHarness) -> InboxModel {
        InboxModel(
            loadRows: { states in await harness.loadRows(states) },
            loadMarker: { try await harness.loadMarker() },
            markRead: { id in try await harness.record("read:\(id)") },
            markUnread: { id in try await harness.record("unread:\(id)") },
            setArchived: { id, archived in try await harness.record("archived:\(id):\(archived)") },
            snooze: { id, until in try await harness.record("snooze:\(id):\(until != nil)") },
            setFeedback: { id, feedback in try await harness.record("feedback:\(id):\(feedback ?? "nil")") },
            markAllRead: { try await harness.record("markAllRead") },
            loadRuns: { await harness.runs }
        )
    }

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
            snoozedUntil: snoozedUntil,
            feedback: feedback
        )
    }

    private func makeRun(
        tickID: String = "tick-1",
        gateResult: BurnBarInboxRunTelemetry.GateResult = .localChanged
    ) -> BurnBarInboxRunTelemetry {
        BurnBarInboxRunTelemetry(
            tickID: tickID,
            startedAt: Date(timeIntervalSince1970: 1_780_000_000),
            gateResult: gateResult,
            egressMode: .off
        )
    }

    // MARK: - Marker-gated loading

    func testLoadSkipsWhenMarkerUnchangedAndReloadsWhenItMoves() async throws {
        let harness = InboxModelHarness()
        await harness.setRows([makeRow(id: "a")])
        let model = makeModel(harness)

        await model.load()
        var callCount = await harness.loadRowsCallCount
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(model.rows.map(\.id), ["a"])
        XCTAssertEqual(model.lastMarker, "marker-1")
        XCTAssertNotNil(model.lastRefreshedAt)

        // Same marker, non-empty rows: the cadence pass must not re-fetch.
        await model.load()
        callCount = await harness.loadRowsCallCount
        XCTAssertEqual(callCount, 1)

        // The marker moved: the next pass re-reads.
        await harness.setRows([makeRow(id: "a"), makeRow(id: "b")])
        await harness.setMarker("marker-2")
        await model.load()
        callCount = await harness.loadRowsCallCount
        XCTAssertEqual(callCount, 2)
        XCTAssertEqual(model.rows.count, 2)

        // Forcing bypasses the marker even when it did not move.
        await model.load(force: true)
        callCount = await harness.loadRowsCallCount
        XCTAssertEqual(callCount, 3)
    }

    func testLoadErrorMapsToFriendlyMessage() async {
        let harness = InboxModelHarness()
        await harness.setMarkerFails(true)
        let model = makeModel(harness)

        await model.load()

        let message = model.errorMessage ?? ""
        XCTAssertTrue(message.contains("has not been set up yet"), "got: \(message)")
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertFalse(model.isLoading)
    }

    func testFriendlyMessagePassesUnknownErrorsThrough() {
        XCTAssertEqual(
            InboxModel.friendlyMessage(for: MutationFailure()),
            "the write failed"
        )
        XCTAssertTrue(
            InboxModel.friendlyMessage(for: MarkerFailure()).contains("has not been set up yet")
        )
    }

    func testLoadDropsStaleSelectionToFirstRow() async {
        let harness = InboxModelHarness()
        await harness.setRows([makeRow(id: "a"), makeRow(id: "b")])
        let model = makeModel(harness)
        await model.load()
        model.selectedID = "b"

        await harness.setRows([makeRow(id: "a")])
        await harness.setMarker("marker-2")
        await model.load()

        XCTAssertEqual(model.selectedID, "a")
    }

    // MARK: - Derived state

    func testVisibleRowsPerFilter() async {
        let now = Date()
        let plain = makeRow(id: "plain", priority: .p3, lastSeenAt: now)
        let urgent = makeRow(id: "urgent", priority: .p1, lastSeenAt: now)
        let archived = makeRow(id: "archived", priority: .p2, readAt: now, archivedAt: now)
        let snoozed = makeRow(id: "snoozed", snoozedUntil: now.addingTimeInterval(3_600))
        let harness = InboxModelHarness()
        await harness.setRows([plain, urgent, archived, snoozed])
        let model = makeModel(harness)
        await model.load()

        // Active hides archived and snoozed rows.
        XCTAssertEqual(Set(model.visibleRows.map(\.id)), ["plain", "urgent"])

        // Attention keeps only visible p1/p2 rows.
        model.filter = .attention
        XCTAssertEqual(model.visibleRows.map(\.id), ["urgent"])

        // Archived shows exactly the archived rows.
        model.filter = .archived
        XCTAssertEqual(model.visibleRows.map(\.id), ["archived"])

        // Resolved shows everything the loader returned, hidden or not.
        model.filter = .resolved
        XCTAssertEqual(model.visibleRows.count, 4)
    }

    func testRankedOrdersByPriorityThenUnreadThenRecency() {
        let older = Date(timeIntervalSince1970: 1_780_000_000)
        let newer = older.addingTimeInterval(600)
        let urgent = makeRow(id: "urgent", priority: .p1, lastSeenAt: older)
        let unread = makeRow(id: "unread", priority: .p3, lastSeenAt: older)
        let readNewer = makeRow(id: "readNewer", priority: .p3, lastSeenAt: newer, readAt: newer)
        let readOlder = makeRow(id: "readOlder", priority: .p3, lastSeenAt: older, readAt: newer)

        XCTAssertTrue(InboxModel.ranked(urgent, unread))
        XCTAssertTrue(InboxModel.ranked(unread, readNewer))
        XCTAssertTrue(InboxModel.ranked(readNewer, readOlder))
        XCTAssertFalse(InboxModel.ranked(readOlder, readNewer))
    }

    func testSectionsGroupByAttentionTodayAndEarlier() async {
        let today = Date()
        let lastWeek = Calendar.current.startOfDay(for: today).addingTimeInterval(-7 * 86_400)
        let urgent = makeRow(id: "urgent", priority: .p2, lastSeenAt: lastWeek)
        let fresh = makeRow(id: "fresh", priority: .p3, lastSeenAt: today)
        let stale = makeRow(id: "stale", priority: .p4, lastSeenAt: lastWeek)
        let harness = InboxModelHarness()
        await harness.setRows([urgent, fresh, stale])
        let model = makeModel(harness)
        await model.load()

        let sections = model.sections
        XCTAssertEqual(sections.map(\.section), [.attention, .today, .earlier])
        XCTAssertEqual(sections[0].rows.map(\.id), ["urgent"])
        XCTAssertEqual(sections[1].rows.map(\.id), ["fresh"])
        XCTAssertEqual(sections[2].rows.map(\.id), ["stale"])

        model.filter = .resolved
        let closed = model.sections
        XCTAssertEqual(closed.map(\.section), [.closed])
        XCTAssertEqual(closed[0].rows.count, 3)
    }

    func testEmptySectionsAreOmitted() async {
        let harness = InboxModelHarness()
        await harness.setRows([makeRow(id: "fresh", priority: .p3, lastSeenAt: Date())])
        let model = makeModel(harness)
        await model.load()

        XCTAssertEqual(model.sections.map(\.section), [.today])

        model.filter = .archived
        XCTAssertTrue(model.sections.isEmpty)
    }

    func testUnreadAndAttentionCounts() async {
        let now = Date()
        let unreadUrgent = makeRow(id: "a", priority: .p1)
        let readUrgent = makeRow(id: "b", priority: .p2, readAt: now)
        let unreadArchived = makeRow(id: "c", priority: .p1, archivedAt: now)
        let unreadPlain = makeRow(id: "d", priority: .p4)
        let harness = InboxModelHarness()
        await harness.setRows([unreadUrgent, readUrgent, unreadArchived, unreadPlain])
        let model = makeModel(harness)
        await model.load()

        XCTAssertEqual(model.unreadCount, 2)
        XCTAssertEqual(model.attentionCount, 2)
    }

    func testSelectedRowFollowsSelectedID() async {
        let harness = InboxModelHarness()
        await harness.setRows([makeRow(id: "a"), makeRow(id: "b")])
        let model = makeModel(harness)
        await model.load()

        XCTAssertNil(model.selectedRow)
        model.selectedID = "b"
        XCTAssertEqual(model.selectedRow?.id, "b")
        model.selectedID = "missing"
        XCTAssertNil(model.selectedRow)
    }

    // MARK: - Telemetry

    func testLoadTelemetryPopulatesRuns() async {
        let harness = InboxModelHarness()
        let model = makeModel(harness)
        XCTAssertFalse(model.hasEverRun)
        XCTAssertNil(model.latestRun)

        await harness.setRuns([makeRun(tickID: "tick-9")])
        await model.loadTelemetry()

        XCTAssertTrue(model.hasEverRun)
        XCTAssertEqual(model.latestRun?.tickID, "tick-9")
    }

    // MARK: - Actions

    func testSelectMarksReadOptimisticallyAndPersists() async {
        let harness = InboxModelHarness()
        await harness.setRows([makeRow(id: "a")])
        let model = makeModel(harness)
        await model.load()
        XCTAssertTrue(model.rows[0].isUnread)

        await model.select("a")

        XCTAssertEqual(model.selectedID, "a")
        XCTAssertFalse(model.rows[0].isUnread)
        let events = await harness.events
        XCTAssertEqual(events, ["read:a"])
        // A successful mutation invalidates the marker so the next pass re-reads.
        XCTAssertNil(model.lastMarker)
    }

    func testSelectingAnAlreadyReadRowDoesNotRewriteIt() async {
        let harness = InboxModelHarness()
        await harness.setRows([makeRow(id: "a", readAt: Date())])
        let model = makeModel(harness)
        await model.load()

        await model.select("a")

        XCTAssertEqual(model.selectedID, "a")
        let events = await harness.events
        XCTAssertTrue(events.isEmpty)
    }

    func testToggleReadFlipsBothWays() async {
        let harness = InboxModelHarness()
        await harness.setRows([makeRow(id: "a")])
        let model = makeModel(harness)
        await model.load()

        await model.toggleRead("a")
        XCTAssertNotNil(model.rows[0].readAt)

        await model.toggleRead("a")
        XCTAssertNil(model.rows[0].readAt)

        let events = await harness.events
        XCTAssertEqual(events, ["read:a", "unread:a"])
    }

    func testArchiveRemovesRowAndMovesSelection() async {
        let harness = InboxModelHarness()
        await harness.setRows([makeRow(id: "a", priority: .p1), makeRow(id: "b")])
        let model = makeModel(harness)
        await model.load()
        model.selectedID = "a"

        await model.archive("a")

        XCTAssertEqual(model.rows.map(\.id), ["b"])
        XCTAssertEqual(model.selectedID, "b")
        let events = await harness.events
        XCTAssertEqual(events, ["archived:a:true"])
    }

    func testUnarchiveReloads() async {
        let harness = InboxModelHarness()
        await harness.setRows([makeRow(id: "a")])
        let model = makeModel(harness)

        await model.unarchive("a")

        XCTAssertEqual(model.rows.map(\.id), ["a"])
        let events = await harness.events
        XCTAssertEqual(events, ["archived:a:false"])
    }

    func testSnoozeRemovesRowAndPassesAFutureDate() async {
        let harness = InboxModelHarness()
        await harness.setRows([makeRow(id: "a"), makeRow(id: "b")])
        let model = makeModel(harness)
        await model.load()
        model.selectedID = "a"

        await model.snooze("a", for: 3_600)

        XCTAssertEqual(model.rows.map(\.id), ["b"])
        XCTAssertEqual(model.selectedID, "b")
        let events = await harness.events
        XCTAssertEqual(events, ["snooze:a:true"])
    }

    func testSetFeedbackMapsTheTriState() async {
        let harness = InboxModelHarness()
        await harness.setRows([makeRow(id: "a")])
        let model = makeModel(harness)
        await model.load()

        await model.setFeedback("a", useful: true)
        XCTAssertEqual(model.rows[0].feedback, "useful")

        await model.setFeedback("a", useful: false)
        XCTAssertEqual(model.rows[0].feedback, "not_useful")

        await model.setFeedback("a", useful: nil)
        XCTAssertNil(model.rows[0].feedback)

        let events = await harness.events
        XCTAssertEqual(events, ["feedback:a:useful", "feedback:a:not_useful", "feedback:a:nil"])
    }

    func testMarkEverythingReadClearsEveryUnreadRow() async {
        let harness = InboxModelHarness()
        await harness.setRows([makeRow(id: "a"), makeRow(id: "b", readAt: Date())])
        let model = makeModel(harness)
        await model.load()
        XCTAssertEqual(model.unreadCount, 1)

        await model.markEverythingRead()

        XCTAssertEqual(model.unreadCount, 0)
        let events = await harness.events
        XCTAssertEqual(events, ["markAllRead"])
    }

    func testFailedMutationSurfacesTheFriendlyMessage() async {
        let harness = InboxModelHarness()
        await harness.setRows([makeRow(id: "a")])
        let model = makeModel(harness)
        await model.load()
        await harness.setMutationsFail(true)

        await model.select("a")

        XCTAssertEqual(model.errorMessage, "the write failed")
    }

    // MARK: - Deep-link selection

    func testSelectItemIDWidensToResolvedWhenTheItemIsNotLoaded() async {
        let resolved = makeRow(id: "gone", state: .resolved)
        let harness = InboxModelHarness()
        await harness.setRows([resolved])
        let model = makeModel(harness)
        await model.load()
        XCTAssertTrue(model.rows.isEmpty, "an open-states load must not contain a resolved item")

        await model.select(itemID: "gone")

        XCTAssertEqual(model.filter, .resolved)
        XCTAssertEqual(model.selectedID, "gone")
        XCTAssertTrue(model.rows.contains(where: { $0.id == "gone" }))
    }

    func testSelectItemIDWithoutLoadingIsANoOpForUnknownItems() async {
        let harness = InboxModelHarness()
        let model = makeModel(harness)
        await model.load()

        await model.select(itemID: "missing", loadingIfNeeded: false)

        XCTAssertNil(model.selectedID)
        XCTAssertEqual(model.filter, .active)
    }

    func testSelectItemIDPrefersTheAlreadyLoadedRow() async {
        let harness = InboxModelHarness()
        await harness.setRows([makeRow(id: "a")])
        let model = makeModel(harness)
        await model.load()
        let callsBefore = await harness.loadRowsCallCount

        await model.select(itemID: "a")

        XCTAssertEqual(model.selectedID, "a")
        XCTAssertEqual(model.filter, .active)
        let callsAfter = await harness.loadRowsCallCount
        XCTAssertEqual(callsAfter, callsBefore, "a loaded row must not trigger a widened re-fetch")
    }

    // MARK: - Vocabulary

    func testFilterVocabulary() {
        XCTAssertEqual(InboxModel.Filter.active.title, "Active")
        XCTAssertEqual(InboxModel.Filter.attention.title, "Needs attention")
        XCTAssertEqual(InboxModel.Filter.resolved.title, "Resolved")
        XCTAssertEqual(InboxModel.Filter.archived.title, "Archived")

        XCTAssertEqual(InboxModel.Filter.active.states, BurnBarInboxItemState.openStates)
        XCTAssertEqual(InboxModel.Filter.attention.states, BurnBarInboxItemState.openStates)
        XCTAssertEqual(InboxModel.Filter.archived.states, BurnBarInboxItemState.openStates)
        XCTAssertEqual(InboxModel.Filter.resolved.states, [.resolved, .expired])

        for filter in InboxModel.Filter.allCases {
            XCTAssertFalse(filter.emptyIcon.isEmpty)
            XCTAssertEqual(filter.id, filter.rawValue)
        }
    }

    func testSectionVocabulary() {
        XCTAssertEqual(InboxModel.Section.attention.title, "Needs attention")
        XCTAssertEqual(InboxModel.Section.today.title, "Today")
        XCTAssertEqual(InboxModel.Section.earlier.title, "Earlier")
        XCTAssertEqual(InboxModel.Section.closed.title, "Closed")
        for section in InboxModel.Section.allCases {
            XCTAssertEqual(section.id, section.rawValue)
        }
    }
}
