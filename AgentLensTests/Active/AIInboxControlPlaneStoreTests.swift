import XCTest
import GRDB
import OpenBurnBarCore
@testable import OpenBurnBar

/// Covers the app's half of the AI Inbox data contract on a real (in-memory)
/// migrated database, driven through the `DataStore` pass-throughs the views
/// actually call: reads with state filters, payload decoding, the unread badge,
/// the change marker, run telemetry, and every user-state write.
@MainActor
final class AIInboxControlPlaneStoreTests: XCTestCase {
    private var dataStore: DataStore!

    override func setUp() async throws {
        let queue = try DatabaseQueue()
        dataStore = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
    }

    override func tearDown() {
        dataStore = nil
        super.tearDown()
    }

    // MARK: - Reading items

    func testFetchRowsFiltersByStateAndOrdersNewestFirst() async throws {
        try await insertItem(id: "inb_old", state: "new", lastSeenAt: Date(timeIntervalSince1970: 1_780_000_000))
        try await insertItem(id: "inb_new", state: "updated", lastSeenAt: Date(timeIntervalSince1970: 1_780_000_900))
        try await insertItem(id: "inb_done", state: "resolved", lastSeenAt: Date(timeIntervalSince1970: 1_780_000_500))

        let open = try await dataStore.fetchAIInboxRows()
        XCTAssertEqual(open.map(\.id), ["inb_new", "inb_old"])

        let everything = try await dataStore.fetchAIInboxRows(states: nil)
        XCTAssertEqual(everything.map(\.id), ["inb_new", "inb_done", "inb_old"])

        let closed = try await dataStore.fetchAIInboxRows(states: [.resolved, .expired])
        XCTAssertEqual(closed.map(\.id), ["inb_done"])

        let limited = try await dataStore.fetchAIInboxRows(states: nil, limit: 1)
        XCTAssertEqual(limited.map(\.id), ["inb_new"])
    }

    func testFetchRowByIDDecodesTheFullPayload() async throws {
        let payload = BurnBarInboxItemPayload(
            evidence: [
                BurnBarInboxEvidence(
                    id: "conv:abc:12",
                    kind: .conversation,
                    label: "Yesterday's session",
                    detail: "The agent said it shipped."
                )
            ],
            memoryCandidates: [
                BurnBarInboxMemoryCandidate(
                    id: "cand-1",
                    text: "Deploys go through staging first.",
                    kind: "decision",
                    confidence: 0.8,
                    citationConversationIDs: ["conv-abc"]
                )
            ],
            actions: [
                BurnBarInboxAction(id: "act-1", kind: .openSessionLog, title: "Open the session", value: "conv-abc")
            ],
            metrics: ["idle_days": "9"]
        )
        try await insertItem(
            id: "inb_rich",
            title: "PR #1975 has stalled",
            summaryMarkdown: "It has not moved in **9 days**.",
            priority: 1,
            projectName: "BurnBar",
            payload: payload,
            lastSeenAt: Date(timeIntervalSince1970: 1_780_000_000)
        )

        let fetched = try await dataStore.fetchAIInboxRow(id: "inb_rich")
        let row = try XCTUnwrap(fetched)
        XCTAssertEqual(row.summary.title, "PR #1975 has stalled")
        XCTAssertEqual(row.summary.kind, .stuckPR)
        XCTAssertEqual(row.summary.priority, .p1)
        XCTAssertEqual(row.summary.state, .new)
        XCTAssertEqual(row.summary.projectName, "BurnBar")
        XCTAssertEqual(row.summary.occurrenceCount, 1)
        XCTAssertEqual(row.summary.modelProvenance, "local-rules")
        XCTAssertTrue(row.summary.hasMemoryCandidates)
        XCTAssertEqual(row.summaryMarkdown, "It has not moved in **9 days**.")
        XCTAssertEqual(row.payload.evidence.first?.id, "conv:abc:12")
        XCTAssertEqual(row.payload.memoryCandidates.first?.text, "Deploys go through staging first.")
        XCTAssertEqual(row.payload.actions.first?.kind, .openSessionLog)
        XCTAssertEqual(row.payload.metrics["idle_days"], "9")
        XCTAssertTrue(row.isUnread)
        XCTAssertFalse(row.isHidden)

        let missing = try await dataStore.fetchAIInboxRow(id: "inb_absent")
        XCTAssertNil(missing)
    }

    func testMalformedPayloadDecodesToAnEmptyPayloadInsteadOfFailing() async throws {
        try await insertItem(
            id: "inb_legacy",
            payloadJSONOverride: "{not valid json",
            lastSeenAt: Date(timeIntervalSince1970: 1_780_000_000)
        )

        let fetched = try await dataStore.fetchAIInboxRow(id: "inb_legacy")
        let row = try XCTUnwrap(fetched)
        XCTAssertEqual(row.payload, BurnBarInboxItemPayload())
        XCTAssertFalse(row.summary.hasMemoryCandidates)
    }

    func testUnknownKindAndOutOfRangePriorityClampToDefaults() async throws {
        try await insertItem(
            id: "inb_future",
            kind: "kind_from_a_newer_daemon",
            priority: 99,
            lastSeenAt: Date(timeIntervalSince1970: 1_780_000_000)
        )

        let fetched = try await dataStore.fetchAIInboxRow(id: "inb_future")
        let row = try XCTUnwrap(fetched)
        XCTAssertEqual(row.summary.kind, .system)
        XCTAssertEqual(row.summary.priority, .p4)
    }

    // MARK: - User state writes

    func testMarkReadAndUnreadRoundTrip() async throws {
        try await insertItem(id: "inb_a", lastSeenAt: Date(timeIntervalSince1970: 1_780_000_000))

        try await dataStore.markAIInboxItemRead(id: "inb_a")
        var fetched = try await dataStore.fetchAIInboxRow(id: "inb_a")
        var row = try XCTUnwrap(fetched)
        XCTAssertNotNil(row.readAt)
        XCTAssertFalse(row.isUnread)

        try await dataStore.markAIInboxItemUnread(id: "inb_a")
        fetched = try await dataStore.fetchAIInboxRow(id: "inb_a")
        row = try XCTUnwrap(fetched)
        XCTAssertNil(row.readAt)
        XCTAssertTrue(row.isUnread)
    }

    func testArchiveImpliesReadAndUnarchiveKeepsRead() async throws {
        try await insertItem(id: "inb_b", lastSeenAt: Date(timeIntervalSince1970: 1_780_000_000))

        try await dataStore.setAIInboxItemArchived(id: "inb_b", archived: true)
        var fetched = try await dataStore.fetchAIInboxRow(id: "inb_b")
        var row = try XCTUnwrap(fetched)
        XCTAssertTrue(row.isArchived)
        XCTAssertTrue(row.isHidden)
        XCTAssertNotNil(row.readAt, "archiving implies the user has seen the item")

        try await dataStore.setAIInboxItemArchived(id: "inb_b", archived: false)
        fetched = try await dataStore.fetchAIInboxRow(id: "inb_b")
        row = try XCTUnwrap(fetched)
        XCTAssertFalse(row.isArchived)
        XCTAssertNotNil(row.readAt, "unarchiving must not resurrect the unread dot")
    }

    func testSnoozeHidesUntilTheDatePassesAndImpliesRead() async throws {
        try await insertItem(id: "inb_c", lastSeenAt: Date(timeIntervalSince1970: 1_780_000_000))

        try await dataStore.snoozeAIInboxItem(id: "inb_c", until: Date().addingTimeInterval(3_600))
        var fetched = try await dataStore.fetchAIInboxRow(id: "inb_c")
        var row = try XCTUnwrap(fetched)
        XCTAssertTrue(row.isSnoozed)
        XCTAssertTrue(row.isHidden)
        XCTAssertNotNil(row.readAt)

        try await dataStore.snoozeAIInboxItem(id: "inb_c", until: nil)
        fetched = try await dataStore.fetchAIInboxRow(id: "inb_c")
        row = try XCTUnwrap(fetched)
        XCTAssertFalse(row.isSnoozed)
        XCTAssertFalse(row.isHidden)
    }

    func testAnExpiredSnoozeNoLongerHidesTheRow() async throws {
        try await insertItem(id: "inb_d", lastSeenAt: Date(timeIntervalSince1970: 1_780_000_000))

        try await dataStore.snoozeAIInboxItem(id: "inb_d", until: Date().addingTimeInterval(-60))

        let fetched = try await dataStore.fetchAIInboxRow(id: "inb_d")
        let row = try XCTUnwrap(fetched)
        XCTAssertFalse(row.isSnoozed)
        XCTAssertFalse(row.isHidden)
    }

    func testFeedbackRoundTripsAndClears() async throws {
        try await insertItem(id: "inb_e", lastSeenAt: Date(timeIntervalSince1970: 1_780_000_000))

        try await dataStore.setAIInboxItemFeedback(id: "inb_e", feedback: "useful")
        var fetched = try await dataStore.fetchAIInboxRow(id: "inb_e")
        var row = try XCTUnwrap(fetched)
        XCTAssertEqual(row.feedback, "useful")
        XCTAssertNil(row.readAt, "feedback alone must not mark the item read")

        try await dataStore.setAIInboxItemFeedback(id: "inb_e", feedback: nil)
        fetched = try await dataStore.fetchAIInboxRow(id: "inb_e")
        row = try XCTUnwrap(fetched)
        XCTAssertNil(row.feedback)
    }

    func testTwoRapidStateWritesDoNotLoseEachOthersField() async throws {
        try await insertItem(id: "inb_f", lastSeenAt: Date(timeIntervalSince1970: 1_780_000_000))

        try await dataStore.setAIInboxItemFeedback(id: "inb_f", feedback: "useful")
        try await dataStore.setAIInboxItemArchived(id: "inb_f", archived: true)

        let fetched = try await dataStore.fetchAIInboxRow(id: "inb_f")
        let row = try XCTUnwrap(fetched)
        XCTAssertEqual(row.feedback, "useful")
        XCTAssertTrue(row.isArchived)
    }

    // MARK: - Badge count

    func testUnreadCountCountsOnlyVisibleOpenUnreadItems() async throws {
        let seen = Date(timeIntervalSince1970: 1_780_000_000)
        try await insertItem(id: "inb_unread", lastSeenAt: seen)
        try await insertItem(id: "inb_read", lastSeenAt: seen)
        try await insertItem(id: "inb_archived", lastSeenAt: seen)
        try await insertItem(id: "inb_snoozed", lastSeenAt: seen)
        try await insertItem(id: "inb_resolved", state: "resolved", lastSeenAt: seen)

        try await dataStore.markAIInboxItemRead(id: "inb_read")
        try await dataStore.setAIInboxItemArchived(id: "inb_archived", archived: true)
        try await dataStore.snoozeAIInboxItem(id: "inb_snoozed", until: Date().addingTimeInterval(3_600))
        // Snoozing marked it read; flip it back so the snooze alone must hide it.
        try await dataStore.markAIInboxItemUnread(id: "inb_snoozed")

        let count = try await dataStore.aiInboxUnreadCount()
        XCTAssertEqual(count, 1)
    }

    func testMarkAllReadClearsTheBadgeWithoutTouchingClosedItems() async throws {
        let seen = Date(timeIntervalSince1970: 1_780_000_000)
        try await insertItem(id: "inb_one", lastSeenAt: seen)
        try await insertItem(id: "inb_two", state: "updated", lastSeenAt: seen)
        try await insertItem(id: "inb_closed", state: "resolved", lastSeenAt: seen)

        try await dataStore.markAllAIInboxItemsRead()

        let count = try await dataStore.aiInboxUnreadCount()
        XCTAssertEqual(count, 0)

        let everything = try await dataStore.fetchAIInboxRows(states: nil)
        let openRows = everything.filter { $0.summary.state.isOpen }
        XCTAssertEqual(openRows.count, 2)
        XCTAssertTrue(openRows.allSatisfy { $0.readAt != nil })
        let closedRow = try XCTUnwrap(everything.first(where: { $0.id == "inb_closed" }))
        XCTAssertNil(closedRow.readAt, "closed items never receive a synthetic read stamp")
    }

    // MARK: - Change marker

    func testChangeMarkerMovesOnItemAndStateWrites() async throws {
        let empty = try await dataStore.aiInboxChangeMarker()
        XCTAssertEqual(empty.split(separator: "|", omittingEmptySubsequences: false).count, 5)

        try await insertItem(id: "inb_m", lastSeenAt: Date(timeIntervalSince1970: 1_780_000_000))
        let afterInsert = try await dataStore.aiInboxChangeMarker()
        XCTAssertNotEqual(afterInsert, empty)

        try await dataStore.markAIInboxItemRead(id: "inb_m")
        let afterState = try await dataStore.aiInboxChangeMarker()
        XCTAssertNotEqual(afterState, afterInsert)

        let idle = try await dataStore.aiInboxChangeMarker()
        XCTAssertEqual(idle, afterState, "an idle inbox must produce a stable marker")
    }

    // MARK: - Run telemetry

    func testFetchRunsDecodesAndOrdersNewestFirst() async throws {
        try await insertRun(
            tickID: "tick_old",
            startedAt: Date(timeIntervalSince1970: 1_780_000_000),
            finishedAt: Date(timeIntervalSince1970: 1_780_000_030),
            gateResult: "local_changed",
            egressMode: "cloud",
            llmCalls: 2,
            inputTokens: 1_200,
            outputTokens: 300,
            costUSD: 0.0125,
            itemsNew: 1,
            itemsUpdated: 2,
            itemsResolved: 3
        )
        try await insertRun(
            tickID: "tick_new",
            startedAt: Date(timeIntervalSince1970: 1_780_000_600),
            gateResult: "not_a_real_gate_result",
            egressMode: "not_a_real_mode",
            error: "provider timeout"
        )

        let runs = try await dataStore.fetchAIInboxRuns()
        XCTAssertEqual(runs.map(\.tickID), ["tick_new", "tick_old"])

        let newest = runs[0]
        XCTAssertEqual(newest.gateResult, .failed, "an unknown gate result decodes as failed, never silently ok")
        XCTAssertEqual(newest.egressMode, .off, "an unknown egress mode decodes to the safest value")
        XCTAssertNil(newest.finishedAt)
        XCTAssertEqual(newest.error, "provider timeout")

        let oldest = runs[1]
        XCTAssertEqual(oldest.gateResult, .localChanged)
        XCTAssertEqual(oldest.egressMode, .cloud)
        XCTAssertEqual(oldest.llmCalls, 2)
        XCTAssertEqual(oldest.inputTokens, 1_200)
        XCTAssertEqual(oldest.outputTokens, 300)
        XCTAssertEqual(oldest.costUSD, 0.0125, accuracy: 0.000_1)
        XCTAssertEqual(oldest.itemsNew, 1)
        XCTAssertEqual(oldest.itemsUpdated, 2)
        XCTAssertEqual(oldest.itemsResolved, 3)
        XCTAssertNotNil(oldest.finishedAt)

        let limited = try await dataStore.fetchAIInboxRuns(limit: 1)
        XCTAssertEqual(limited.map(\.tickID), ["tick_new"])
    }

    // MARK: - Timestamp codec

    func testAIInboxTimestampRoundTripsAndAcceptsBasicISO8601() throws {
        let date = Date(timeIntervalSince1970: 1_780_000_000.25)
        let encoded = ControlPlaneStore.aiInboxTimestamp(date)
        let decoded = try XCTUnwrap(ControlPlaneStore.aiInboxDate(encoded))
        XCTAssertEqual(decoded.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 0.001)

        // A row written without fractional seconds must still parse.
        let basic = try XCTUnwrap(ControlPlaneStore.aiInboxDate("2026-08-05T12:00:00Z"))
        XCTAssertEqual(basic.timeIntervalSince1970, 1_785_931_200, accuracy: 1)

        XCTAssertNil(ControlPlaneStore.aiInboxDate(nil))
        XCTAssertNil(ControlPlaneStore.aiInboxDate(""))
    }

    // MARK: - Helpers

    /// Mirrors the daemon's writes: the daemon owns `ai_inbox_items`, so tests
    /// seed it with raw SQL exactly like `AIInboxSyncServiceTests` does.
    private func insertItem(
        id: String,
        title: String = "Item",
        summaryMarkdown: String = "Body.",
        kind: String = BurnBarInboxItemKind.stuckPR.rawValue,
        priority: Int = 2,
        state: String = "new",
        projectName: String? = nil,
        payload: BurnBarInboxItemPayload = BurnBarInboxItemPayload(),
        payloadJSONOverride: String? = nil,
        lastSeenAt: Date
    ) async throws {
        let payloadJSON: String
        if let payloadJSONOverride {
            payloadJSON = payloadJSONOverride
        } else {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            payloadJSON = String(decoding: try encoder.encode(payload), as: UTF8.self)
        }
        let stamp = ControlPlaneStore.aiInboxTimestamp(lastSeenAt)

        try await dataStore.actor.controlPlaneStore.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO ai_inbox_items (
                        id, fingerprint, kind, priority, state, title, summary_md, payload_json,
                        project_id, project_name, occurrence_count, first_seen_at, last_seen_at,
                        resolved_at, resolution_note, tick_id, model_provenance
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, 1, ?, ?, NULL, NULL, ?, 'local-rules')
                    """,
                arguments: [
                    id, "fp_\(id)", kind, priority, state, title, summaryMarkdown,
                    payloadJSON, projectName, stamp, stamp, "tick_1"
                ]
            )
        }
    }

    private func insertRun(
        tickID: String,
        startedAt: Date,
        finishedAt: Date? = nil,
        gateResult: String,
        egressMode: String,
        llmCalls: Int = 0,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        costUSD: Double = 0,
        itemsNew: Int = 0,
        itemsUpdated: Int = 0,
        itemsResolved: Int = 0,
        error: String? = nil
    ) async throws {
        let startedStamp = ControlPlaneStore.aiInboxTimestamp(startedAt)
        let finishedStamp = finishedAt.map(ControlPlaneStore.aiInboxTimestamp)
        try await dataStore.actor.controlPlaneStore.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO ai_inbox_runs (
                        tick_id, started_at, finished_at, gate_result, gate_signature, egress_mode,
                        llm_calls, input_tokens, output_tokens, cost_usd,
                        items_new, items_updated, items_resolved, error
                    ) VALUES (?, ?, ?, ?, 'sig', ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    tickID, startedStamp, finishedStamp, gateResult, egressMode,
                    llmCalls, inputTokens, outputTokens, costUSD,
                    itemsNew, itemsUpdated, itemsResolved, error
                ]
            )
        }
    }
}
