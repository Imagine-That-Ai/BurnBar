import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import XCTest

/// Query, telemetry, and error-path behavior of the AI Inbox store.
///
/// `AIInboxStoreTests` proves the dedupe invariant; this suite exercises the
/// remaining read surface: run telemetry round trips, spend accounting,
/// fingerprint lookups, list filters, bounded body reads, and the SQLite error
/// paths that must throw typed errors instead of corrupting a tick.
final class AIInboxStoreQueryTests: XCTestCase {
    private var databaseURL: URL!
    private var store: BurnBarAIInboxStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-inbox-query-tests-\(UUID().uuidString).sqlite")
        store = try BurnBarAIInboxStore(
            databasePath: databaseURL.path,
            logger: BurnBarDaemonLogger(category: "test")
        )
    }

    override func tearDownWithError() throws {
        store = nil
        if let databaseURL { try? FileManager.default.removeItem(at: databaseURL) }
        try super.tearDownWithError()
    }

    // MARK: - Run telemetry

    func test_runTelemetryRoundTripsThroughBeginAndFinish() throws {
        let started = Date(timeIntervalSince1970: 1_754_300_000)
        try store.beginRun(
            BurnBarInboxRunTelemetry(
                tickID: "tick_a",
                startedAt: started,
                gateResult: .localChanged,
                egressMode: .cloud
            ),
            gateSignature: "sig-1"
        )

        // A begun-but-unfinished run reads back with zeroed counters.
        let pending = try XCTUnwrap(try store.recentRuns(limit: 5).first)
        XCTAssertEqual(pending.tickID, "tick_a")
        XCTAssertNil(pending.finishedAt)
        XCTAssertEqual(pending.gateResult, .localChanged)
        XCTAssertEqual(pending.llmCalls, 0)
        XCTAssertEqual(pending.costUSD, 0, accuracy: 0.000_1)

        try store.finishRun(
            BurnBarInboxRunTelemetry(
                tickID: "tick_a",
                startedAt: started,
                finishedAt: started.addingTimeInterval(2),
                gateResult: .remotePhase,
                egressMode: .cloud,
                llmCalls: 2,
                inputTokens: 1_200,
                outputTokens: 340,
                costUSD: 0.25,
                itemsNew: 1,
                itemsUpdated: 2,
                itemsResolved: 3,
                error: "partial failure"
            )
        )

        let finished = try XCTUnwrap(try store.recentRuns(limit: 5).first)
        XCTAssertEqual(finished.tickID, "tick_a")
        XCTAssertNotNil(finished.finishedAt)
        XCTAssertEqual(finished.gateResult, .remotePhase)
        XCTAssertEqual(finished.egressMode, .cloud)
        XCTAssertEqual(finished.llmCalls, 2)
        XCTAssertEqual(finished.inputTokens, 1_200)
        XCTAssertEqual(finished.outputTokens, 340)
        XCTAssertEqual(finished.costUSD, 0.25, accuracy: 0.000_1)
        XCTAssertEqual(finished.itemsNew, 1)
        XCTAssertEqual(finished.itemsUpdated, 2)
        XCTAssertEqual(finished.itemsResolved, 3)
        XCTAssertEqual(finished.error, "partial failure")
    }

    func test_recentRunsOrdersNewestFirstAndHonorsLimit() throws {
        let base = Date(timeIntervalSince1970: 1_754_300_000)
        for (index, tick) in ["tick_old", "tick_mid", "tick_new"].enumerated() {
            try store.beginRun(
                BurnBarInboxRunTelemetry(
                    tickID: tick,
                    startedAt: base.addingTimeInterval(Double(index) * 600),
                    gateResult: .skippedUnchanged,
                    egressMode: .off
                ),
                gateSignature: "sig"
            )
        }

        let page = try store.recentRuns(limit: 2)
        XCTAssertEqual(page.map(\.tickID), ["tick_new", "tick_mid"])
    }

    func test_spendSumsOnlyRunsStartedInsideTheWindow() throws {
        let now = Date()
        let old = now.addingTimeInterval(-3_600)
        try store.beginRun(
            BurnBarInboxRunTelemetry(tickID: "t_old", startedAt: old, gateResult: .forced, egressMode: .cloud),
            gateSignature: "s"
        )
        try store.finishRun(
            BurnBarInboxRunTelemetry(
                tickID: "t_old", startedAt: old, finishedAt: old.addingTimeInterval(1),
                gateResult: .forced, egressMode: .cloud, costUSD: 0.50
            )
        )
        try store.beginRun(
            BurnBarInboxRunTelemetry(tickID: "t_new", startedAt: now, gateResult: .forced, egressMode: .cloud),
            gateSignature: "s"
        )
        try store.finishRun(
            BurnBarInboxRunTelemetry(
                tickID: "t_new", startedAt: now, finishedAt: now.addingTimeInterval(1),
                gateResult: .forced, egressMode: .cloud, costUSD: 0.25
            )
        )

        XCTAssertEqual(try store.spend(since: now.addingTimeInterval(-60)), 0.25, accuracy: 0.000_1)
        XCTAssertEqual(try store.spend(since: now.addingTimeInterval(-7_200)), 0.75, accuracy: 0.000_1)
        XCTAssertEqual(try store.spend(since: now.addingTimeInterval(60)), 0, accuracy: 0.000_1)
    }

    // MARK: - Fingerprint lookup

    func test_itemDetailByFingerprintReturnsTheOpenRow() throws {
        let now = Date()
        let outcome = try store.upsertItem(
            AIInboxFixtures.itemWrite(fingerprint: "ci_waste:lookup", title: "waste"),
            now: now
        )

        let detail = try XCTUnwrap(try store.itemDetail(fingerprint: "ci_waste:lookup"))
        XCTAssertEqual(detail.summary.id, outcome.id)
        XCTAssertEqual(detail.summaryMarkdown, "summary for waste")
        XCTAssertEqual(detail.tickID, "tick_test")
        XCTAssertEqual(detail.summary.state, .new)
    }

    func test_itemDetailByFingerprintIgnoresResolvedRowsAndUnknownFingerprints() throws {
        let now = Date()
        let outcome = try store.upsertItem(
            AIInboxFixtures.itemWrite(fingerprint: "stuck_pr:done", title: "quiet PR"),
            now: now
        )
        XCTAssertTrue(try store.resolveItem(id: outcome.id, note: "merged", now: now))

        XCTAssertNil(try store.itemDetail(fingerprint: "stuck_pr:done"), "Resolved rows are not open")
        XCTAssertNil(try store.itemDetail(fingerprint: "never-written"))
    }

    // MARK: - List filters

    func test_listFiltersByProjectID() throws {
        let now = Date()
        for (index, project) in ["proj-a", "proj-a", "proj-b"].enumerated() {
            _ = try store.upsertItem(
                BurnBarAIInboxItemWrite(
                    fingerprint: "f\(index)",
                    kind: .ciWaste,
                    priority: .p2,
                    title: "item \(index)",
                    summaryMarkdown: "s",
                    payload: BurnBarInboxItemPayload(),
                    projectID: project,
                    projectName: project,
                    tickID: "tick_test"
                ),
                now: now.addingTimeInterval(Double(index) * 60)
            )
        }

        let filtered = try store.list(BurnBarInboxListRequest(projectID: "proj-a", limit: 10))
        XCTAssertEqual(filtered.items.count, 2)
        XCTAssertTrue(filtered.items.allSatisfy { $0.projectID == "proj-a" })
        XCTAssertEqual(filtered.openCount, 3, "openCount stays global even when the page is filtered")
    }

    func test_listBeforeCursorExcludesTheBoundaryTimestamp() throws {
        let base = Date(timeIntervalSince1970: 1_754_300_000)
        for index in 0..<3 {
            _ = try store.upsertItem(
                AIInboxFixtures.itemWrite(fingerprint: "f\(index)", title: "item \(index)"),
                now: base.addingTimeInterval(Double(index) * 600)
            )
        }

        let newest = base.addingTimeInterval(1_200)
        let page = try store.list(BurnBarInboxListRequest(limit: 10, before: newest))
        XCTAssertEqual(page.items.map(\.title), ["item 1", "item 0"], "Strictly-before keyset semantics")
    }

    // MARK: - Bounded body reads

    func test_conversationBodyIsTruncatedInSQL() throws {
        try seedConversation(id: "conv-body", fullText: "0123456789ABCDEF")

        XCTAssertEqual(try store.conversationBody(id: "conv-body", maxBytes: 4), "0123")
        XCTAssertNil(try store.conversationBody(id: "missing-row", maxBytes: 4))
    }

    func test_conversationBodyToleratesMissingAppTable() throws {
        XCTAssertNil(
            try store.conversationBody(id: "any", maxBytes: 10),
            "A profile whose app never created `conversations` must read as empty, not throw"
        )
    }

    // MARK: - Error paths

    func test_invalidSQLThrowsTypedSQLiteError() {
        XCTAssertThrowsError(try store.execute("CLEARLY NOT SQL", [])) { error in
            guard case BurnBarAIInboxStoreError.sqlite(let message) = error else {
                return XCTFail("Expected a typed sqlite error, got \(error)")
            }
            XCTAssertFalse(message.isEmpty)
            XCTAssertEqual(error.localizedDescription, message)
        }
        XCTAssertThrowsError(try store.queryRows("SELECT FROM", []))
    }

    func test_closedErrorDescriptionNamesTheDatabase() {
        XCTAssertTrue(BurnBarAIInboxStoreError.closed.localizedDescription.contains("closed"))
    }

    func test_openFailsWithTypedErrorWhenTheParentDirectoryIsMissing() {
        let missing = "/nonexistent-\(UUID().uuidString)/inbox.sqlite"
        XCTAssertThrowsError(
            try BurnBarAIInboxStore(databasePath: missing, logger: BurnBarDaemonLogger(category: "test"))
        ) { error in
            guard case BurnBarAIInboxStoreError.sqlite(let message) = error else {
                return XCTFail("Expected a typed sqlite error, got \(error)")
            }
            XCTAssertTrue(message.contains("Failed to open AI Inbox SQLite database"))
        }
    }

    func test_upsertRollsBackAndRethrowsWhenTheTableIsGone() throws {
        try store.execute("DROP TABLE ai_inbox_items", [])
        XCTAssertThrowsError(
            try store.upsertItem(AIInboxFixtures.itemWrite(fingerprint: "f", title: "t"), now: Date())
        )
        // The transaction must not be left open: a follow-up write on the same
        // connection still works.
        try store.execute("CREATE TABLE IF NOT EXISTS probe_after_rollback (id TEXT)", [])
    }

    // MARK: - Queue re-entrancy

    func test_databaseSyncIsReentrantInsteadOfDeadlocking() throws {
        // The inner call runs while the outer one already holds the serial
        // queue; without the queue-specific check this would deadlock forever.
        let value = try store.databaseSync {
            try store.databaseSync {
                try store.fetchInt("SELECT 42", [])
            }
        }
        XCTAssertEqual(value, 42)
    }

    // MARK: - Bind helpers

    func test_optionalDateBindsAsISOTextOrNull() {
        let date = Date(timeIntervalSince1970: 1_754_300_000)
        guard case .text(let bound) = BurnBarAIInboxStore.Bind.optionalDate(date) else {
            return XCTFail("A present date must bind as text")
        }
        XCTAssertEqual(bound, BurnBarAIInboxStore.string(from: date))

        guard case .null = BurnBarAIInboxStore.Bind.optionalDate(nil) else {
            return XCTFail("A missing date must bind as NULL")
        }
    }

    // MARK: - Conversation row model

    func test_conversationRowEvidenceIDPinsTheTranscriptRevision() {
        let row = makeConversationRow(
            id: "conv-9",
            messageCount: 7,
            inferredTaskTitle: "Fix the retry loop",
            summary: "session summary",
            sessionID: "sess-9"
        )
        XCTAssertEqual(row.evidenceID, "conv:conv-9:7")
        XCTAssertEqual(row.displayTitle, "Fix the retry loop")
    }

    func test_conversationRowDisplayTitleFallsThroughToSummaryThenSession() {
        let summaryOnly = makeConversationRow(
            id: "c", messageCount: 1, inferredTaskTitle: nil, summary: "the summary", sessionID: "sess"
        )
        XCTAssertEqual(summaryOnly.displayTitle, "the summary")

        let sessionOnly = makeConversationRow(
            id: "c", messageCount: 1, inferredTaskTitle: "", summary: nil, sessionID: "sess"
        )
        XCTAssertEqual(sessionOnly.displayTitle, "sess")

        let bare = makeConversationRow(
            id: "c", messageCount: 1, inferredTaskTitle: nil, summary: nil, sessionID: nil
        )
        XCTAssertEqual(bare.displayTitle, "Untitled session")
    }

    // MARK: - Hashing and timestamps

    func test_stableHasherHashesIntsAsTheirDecimalStrings() {
        var intHasher = BurnBarAIInboxStableHasher()
        intHasher.combine(12_345)
        var stringHasher = BurnBarAIInboxStableHasher()
        stringHasher.combine("12345")
        XCTAssertEqual(intHasher.finalize(), stringHasher.finalize())
    }

    func test_timestampParsingAcceptsSpaceSeparatedOffsetForm() throws {
        let parsed = try XCTUnwrap(
            BurnBarAIInboxTimestamp.date(from: "2026-08-04 12:00:00+00:00"),
            "A space-separated timestamp carrying an explicit offset must parse"
        )
        let canonical = try XCTUnwrap(BurnBarAIInboxTimestamp.date(from: "2026-08-04T12:00:00Z"))
        XCTAssertEqual(parsed.timeIntervalSince1970, canonical.timeIntervalSince1970, accuracy: 0.001)
    }

    // MARK: - Fixtures

    private func makeConversationRow(
        id: String,
        messageCount: Int,
        inferredTaskTitle: String?,
        summary: String?,
        sessionID: String?
    ) -> BurnBarAIInboxConversationRow {
        BurnBarAIInboxConversationRow(
            id: id,
            provider: "Claude Code",
            sessionID: sessionID,
            projectName: "BurnBar",
            startTime: nil,
            endTime: nil,
            messageCount: messageCount,
            inferredTaskTitle: inferredTaskTitle,
            lastAssistantMessage: nil,
            summary: summary,
            workingDirectory: nil,
            indexedAt: nil,
            keyFiles: [],
            keyCommands: [],
            fullTextByteCount: 0
        )
    }

    private func seedConversation(id: String, fullText: String) throws {
        try store.execute(
            """
            CREATE TABLE IF NOT EXISTS conversations (
                id TEXT PRIMARY KEY, provider TEXT, sessionId TEXT, projectName TEXT,
                startTime DATETIME, endTime DATETIME, messageCount INTEGER,
                inferredTaskTitle TEXT, lastAssistantMessage TEXT, summary TEXT,
                workingDirectory TEXT, indexedAt DATETIME, keyFiles TEXT,
                keyCommands TEXT, fullText TEXT
            )
            """,
            []
        )
        try store.execute(
            """
            INSERT INTO conversations (
                id, provider, sessionId, projectName, startTime, endTime, messageCount,
                inferredTaskTitle, lastAssistantMessage, summary, workingDirectory,
                indexedAt, keyFiles, keyCommands, fullText
            ) VALUES (?, 'Claude Code', 'sess-1', 'BurnBar', '2026-08-04 21:25:00.000',
                      '2026-08-04 21:25:00.000', 3, 'Refactor', '', '', '/tmp/burnbar',
                      '2026-08-04 21:25:00.000', '[]', '[]', ?)
            """,
            [.text(id), .text(fullText)]
        )
    }
}
