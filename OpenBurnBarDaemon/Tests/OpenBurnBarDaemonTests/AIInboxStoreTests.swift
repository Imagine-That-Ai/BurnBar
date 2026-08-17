import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import XCTest

/// Durability and dedupe invariants for the AI Inbox store.
///
/// The dedupe rule is the one that decides whether the inbox stays usable: a
/// condition that recurs every 5 minutes must update one row, not mint 288 a day.
final class AIInboxStoreTests: XCTestCase {
    private var databaseURL: URL!
    private var store: BurnBarAIInboxStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-inbox-tests-\(UUID().uuidString).sqlite")
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

    // MARK: - Dedupe

    func test_repeatedConditionUpdatesOneRowInsteadOfDuplicating() throws {
        let now = Date()
        let write = AIInboxFixtures.itemWrite(fingerprint: "ci_waste:abc", title: "95% of ci runs are wasted")

        let first = try store.upsertItem(write, now: now)
        XCTAssertTrue(first.wasCreated)
        XCTAssertEqual(first.occurrenceCount, 1)

        let second = try store.upsertItem(write, now: now.addingTimeInterval(300))
        XCTAssertFalse(second.wasCreated, "Same fingerprint must reuse the open row")
        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(second.occurrenceCount, 2)
        XCTAssertFalse(second.contentChanged, "Identical content must not mark the item unread again")

        XCTAssertEqual(try store.openItems().count, 1)
    }

    func test_changedContentMarksItemUpdated() throws {
        let now = Date()
        _ = try store.upsertItem(
            AIInboxFixtures.itemWrite(fingerprint: "ci_waste:abc", title: "60% of ci runs are wasted"),
            now: now
        )
        let second = try store.upsertItem(
            AIInboxFixtures.itemWrite(fingerprint: "ci_waste:abc", title: "95% of ci runs are wasted"),
            now: now.addingTimeInterval(300)
        )

        XCTAssertTrue(second.contentChanged)
        let item = try XCTUnwrap(try store.openItems().first)
        XCTAssertEqual(item.state, .updated)
        XCTAssertEqual(item.title, "95% of ci runs are wasted")
    }

    /// The partial unique index means "one OPEN item per fingerprint" — resolved
    /// history is preserved, and a recurrence after resolution opens a fresh row.
    func test_conditionCanRecurAfterResolution() throws {
        let now = Date()
        let write = AIInboxFixtures.itemWrite(fingerprint: "stuck_pr:xyz", title: "PR #12 has been quiet")

        let first = try store.upsertItem(write, now: now)
        XCTAssertTrue(try store.resolveItem(id: first.id, note: "PR merged", now: now.addingTimeInterval(60)))
        XCTAssertTrue(try store.openItems().isEmpty)

        let second = try store.upsertItem(write, now: now.addingTimeInterval(86_400))
        XCTAssertTrue(second.wasCreated, "A recurrence after resolution is a new row")
        XCTAssertNotEqual(second.id, first.id)

        let all = try store.list(BurnBarInboxListRequest(states: nil, limit: 50))
        XCTAssertEqual(all.items.count, 2, "Resolved history is retained")
        XCTAssertEqual(all.openCount, 1)
    }

    func test_resolveIsIdempotent() throws {
        let outcome = try store.upsertItem(AIInboxFixtures.itemWrite(fingerprint: "f", title: "t"), now: Date())
        XCTAssertTrue(try store.resolveItem(id: outcome.id, note: nil, now: Date()))
        XCTAssertFalse(
            try store.resolveItem(id: outcome.id, note: nil, now: Date()),
            "Resolving an already-resolved item reports no change"
        )
    }

    // MARK: - Payload round trip

    func test_payloadSurvivesRoundTrip() throws {
        let payload = BurnBarInboxItemPayload(
            evidence: [
                BurnBarInboxEvidence(
                    id: "run:o/r#1",
                    kind: .workflowRun,
                    label: "nightly · failure",
                    detail: "abc123 on main · 8m",
                    url: "https://github.com/o/r/actions/runs/1"
                )
            ],
            memoryCandidates: [
                BurnBarInboxMemoryCandidate(
                    id: "mem_1",
                    text: "The nightly matrix workflow double-triggers on push and PR.",
                    kind: "gotcha",
                    confidence: 0.8,
                    citationConversationIDs: ["conv-1"]
                )
            ],
            actions: [
                BurnBarInboxAction(id: "a", kind: .openURL, title: "Open", value: "https://example.com", isPrimary: true)
            ],
            metrics: ["waste_rate": "0.950"],
            verification: BurnBarInboxVerification(verdict: .deterministic, reason: "arithmetic", checkedAt: Date())
        )

        let outcome = try store.upsertItem(
            AIInboxFixtures.itemWrite(fingerprint: "f", title: "t", payload: payload),
            now: Date()
        )
        let detail = try XCTUnwrap(try store.item(id: outcome.id))

        XCTAssertEqual(detail.payload.evidence.first?.id, "run:o/r#1")
        XCTAssertEqual(detail.payload.memoryCandidates.first?.kind, "gotcha")
        XCTAssertEqual(detail.payload.metrics["waste_rate"], "0.950")
        XCTAssertEqual(detail.payload.verification?.verdict, .deterministic)
        XCTAssertTrue(detail.summary.hasMemoryCandidates)
    }

    /// A payload written by a newer daemon must degrade to an empty body rather
    /// than making the whole row unreadable.
    func test_unreadablePayloadDegradesGracefully() {
        let payload = BurnBarAIInboxStore.decodePayload("{ not json at all")
        XCTAssertTrue(payload.evidence.isEmpty)
        XCTAssertEqual(payload.version, BurnBarInboxItemPayload.currentVersion)
    }

    // MARK: - Listing

    func test_listFiltersAndPaginates() throws {
        let now = Date()
        for index in 0..<5 {
            _ = try store.upsertItem(
                AIInboxFixtures.itemWrite(
                    fingerprint: "f\(index)",
                    title: "item \(index)",
                    kind: index.isMultiple(of: 2) ? .ciWaste : .stuckPR
                ),
                now: now.addingTimeInterval(Double(index) * 60)
            )
        }

        let ciOnly = try store.list(BurnBarInboxListRequest(kinds: [.ciWaste], limit: 10))
        XCTAssertEqual(ciOnly.items.count, 3)
        XCTAssertTrue(ciOnly.items.allSatisfy { $0.kind == .ciWaste })

        let page = try store.list(BurnBarInboxListRequest(limit: 2))
        XCTAssertEqual(page.items.count, 2)
        XCTAssertNotNil(page.nextBefore, "A truncated page must expose a cursor")
        // Newest first.
        XCTAssertEqual(page.items.first?.title, "item 4")
        XCTAssertEqual(page.openCount, 5, "openCount is global, not page-local")
    }

    func test_expireStaleItemsSkipsExcludedKinds() throws {
        let now = Date()
        _ = try store.upsertItem(AIInboxFixtures.itemWrite(fingerprint: "old", title: "old", kind: .stuckPR), now: now)
        _ = try store.upsertItem(AIInboxFixtures.itemWrite(fingerprint: "brief", title: "brief", kind: .brief), now: now)

        let expired = try store.expireStaleItems(
            olderThan: 60,
            now: now.addingTimeInterval(3_600),
            excluding: [.brief]
        )
        XCTAssertEqual(expired, 1)

        let open = try store.openItems()
        XCTAssertEqual(open.count, 1)
        XCTAssertEqual(open.first?.kind, .brief)
    }

    // MARK: - State KV

    func test_stateRoundTripsTypedValues() throws {
        let config = BurnBarInboxConfig(enabled: true, egressMode: .cloud, tickSeconds: 300)
        try store.setState(BurnBarAIInboxSchema.StateKey.config, value: config)
        let loaded = try XCTUnwrap(try store.state(BurnBarAIInboxSchema.StateKey.config, as: BurnBarInboxConfig.self))

        XCTAssertTrue(loaded.enabled)
        XCTAssertEqual(loaded.egressMode, .cloud)
        XCTAssertEqual(loaded.tickSeconds, 300)
    }

    func test_stateOverwritesPreviousValue() throws {
        try store.setState("k", value: ["a"])
        try store.setState("k", value: ["b", "c"])
        XCTAssertEqual(try store.state("k", as: [String].self), ["b", "c"])
    }

    // MARK: - Cross-writer tolerance

    /// The daemon may start before the app has ever run migration v58 and
    /// created its own table. Reading it must degrade, never throw.
    func test_itemUserStatesToleratesMissingAppTable() throws {
        try store.execute("DROP TABLE IF EXISTS ai_inbox_item_state", [])
        XCTAssertEqual(try store.itemUserStates(), [:])
    }

    func test_itemUserStatesReadsAppWrittenRows() throws {
        let now = Date()
        try store.execute(
            """
            INSERT INTO ai_inbox_item_state (item_id, read_at, archived_at, snoozed_until, feedback, updated_at)
            VALUES (?, ?, NULL, NULL, 'useful', ?)
            """,
            [
                .text("inb_1"),
                .text(BurnBarAIInboxStore.string(from: now)),
                .text(BurnBarAIInboxStore.string(from: now))
            ]
        )

        let states = try store.itemUserStates()
        let state = try XCTUnwrap(states["inb_1"])
        XCTAssertNotNil(state.readAt)
        XCTAssertEqual(state.feedback, "useful")
        XCTAssertFalse(state.isSuppressed)
    }

    func test_snoozedItemIsSuppressed() {
        let state = BurnBarAIInboxStore.ItemUserState(
            itemID: "x",
            readAt: nil,
            archivedAt: nil,
            snoozedUntil: Date().addingTimeInterval(3_600),
            feedback: nil
        )
        XCTAssertTrue(state.isSuppressed)
    }

    // MARK: - Schema

    /// Reopening must be a no-op: both the daemon and the app migration create
    /// these tables `IF NOT EXISTS`, in either order.
    func test_schemaBootstrapIsIdempotent() throws {
        let second = try BurnBarAIInboxStore(
            databasePath: databaseURL.path,
            logger: BurnBarDaemonLogger(category: "test")
        )
        _ = try second.upsertItem(AIInboxFixtures.itemWrite(fingerprint: "f", title: "t"), now: Date())
        XCTAssertEqual(try second.openItems().count, 1)
    }

    // MARK: - Reading app-owned tables (the format contract)

    /// The bug this suite exists to prevent.
    ///
    /// `conversations` and `token_usage` are written by the APP through GRDB,
    /// which serializes `Date` as `yyyy-MM-dd HH:mm:ss.SSS`. SQLite compares
    /// those columns as plain TEXT. An ISO-8601 bound (`...T19:30:00.000Z`) is
    /// lexicographically GREATER than every same-day GRDB value, because `'T'`
    /// (0x54) sorts after every digit — so `WHERE startTime >= ?` matches
    /// nothing, silently, forever.
    ///
    /// That single mismatch made the entire feature inert: no conversations, so
    /// no workspaces, so no GitHub slugs, so no detectors and no analyst. These
    /// tests insert rows in the real on-disk format and assert the store reads
    /// them back.
    func test_recentConversationsReadsGRDBFormattedRows() throws {
        try seedConversation(
            id: "conv-grdb",
            storedTimestamp: "2026-08-04 21:25:00.000",
            messageCount: 12
        )

        let since = try XCTUnwrap(Self.date("2026-08-04 19:30:00.000"))
        let rows = try store.recentConversations(since: since, limit: 10)

        XCTAssertEqual(rows.count, 1, "A GRDB-written row must be visible to the daemon")
        XCTAssertEqual(rows.first?.id, "conv-grdb")
    }

    /// The five-minute change gate only needs workspace paths. A minimal table
    /// makes this test fail if the query ever starts selecting transcript
    /// lengths, message bodies, summaries, or other evidence-pack columns.
    func test_recentConversationWorkingDirectoriesUsesMetadataOnlyQuery() throws {
        try store.execute(
            """
            CREATE TABLE conversations (
                startTime DATETIME,
                endTime DATETIME,
                workingDirectory TEXT
            )
            """,
            []
        )
        try store.execute(
            """
            INSERT INTO conversations (startTime, endTime, workingDirectory)
            VALUES (?, ?, ?), (?, ?, NULL)
            """,
            [
                .text("2026-08-04 21:25:00.000"),
                .text("2026-08-04 21:25:00.000"),
                .text("/tmp/burnbar"),
                .text("2026-08-04 21:20:00.000"),
                .text("2026-08-04 21:20:00.000")
            ]
        )

        let since = try XCTUnwrap(Self.date("2026-08-04 19:30:00.000"))
        let paths = try store.recentConversationWorkingDirectories(since: since, limit: 10)

        XCTAssertEqual(paths, ["/tmp/burnbar"])
    }

    func test_conversationWatermarkSeesGRDBFormattedRows() throws {
        try seedConversation(id: "c1", storedTimestamp: "2026-08-04 21:25:00.000", messageCount: 3)
        let since = try XCTUnwrap(Self.date("2026-08-04 19:30:00.000"))

        let before = try store.conversationWatermark(since: since)
        try seedConversation(id: "c2", storedTimestamp: "2026-08-04 21:40:00.000", messageCount: 5)
        let after = try store.conversationWatermark(since: since)

        XCTAssertNotEqual(
            before.contentHash,
            after.contentHash,
            "The change gate must notice new conversations, or every tick reports 'nothing changed'"
        )
    }

    func test_usageAggregatesReadGRDBFormattedRows() throws {
        try store.execute(
            """
            CREATE TABLE IF NOT EXISTS token_usage (
                id TEXT PRIMARY KEY, provider TEXT, projectName TEXT, model TEXT,
                totalTokens INTEGER, cost REAL, startTime DATETIME
            )
            """,
            []
        )
        try store.execute(
            """
            INSERT INTO token_usage (id, provider, projectName, model, totalTokens, cost, startTime)
            VALUES ('u1', 'anthropic', 'BurnBar', 'claude-fable-5', 12000, 2.35, ?)
            """,
            [.text("2026-08-04 21:25:00.000")]
        )

        let since = try XCTUnwrap(Self.date("2026-08-04 19:30:00.000"))
        let aggregates = try store.usageAggregates(since: since)

        XCTAssertEqual(aggregates.count, 1, "Cost detectors must be able to see real usage rows")
        XCTAssertEqual(try XCTUnwrap(aggregates.first).costUSD, 2.35, accuracy: 0.001)
    }

    /// Pins the exact byte-level reason the original bug existed, so a future
    /// refactor back to the ISO form fails loudly here rather than silently in
    /// production.
    func test_grdbAndISOTimestampFormatsAreNotInterchangeable() throws {
        let date = try XCTUnwrap(Self.date("2026-08-04 19:30:00.000"))
        let grdb = BurnBarAIInboxTimestamp.grdbString(from: date)
        let iso = BurnBarAIInboxTimestamp.string(from: date)

        XCTAssertEqual(grdb, "2026-08-04 19:30:00.000")
        XCTAssertNotEqual(grdb, iso)
        XCTAssertTrue(iso.contains("T"), "The ISO form separates with 'T'")
        XCTAssertFalse(grdb.contains("T"), "The GRDB form separates with a space")
        // The comparison that breaks: a same-day GRDB row sorts BELOW an ISO bound.
        XCTAssertLessThan("2026-08-04 21:25:00.000", iso)
        XCTAssertGreaterThan("2026-08-04 21:25:00.000", grdb)
    }

    // MARK: - Timestamps

    func test_timestampParsingAcceptsLegacyFormats() {
        XCTAssertNotNil(BurnBarAIInboxTimestamp.date(from: "2026-08-04T12:00:00.123Z"))
        XCTAssertNotNil(BurnBarAIInboxTimestamp.date(from: "2026-08-04T12:00:00Z"))
        // SQLite `datetime()` output, which appears in older token_usage rows.
        XCTAssertNotNil(BurnBarAIInboxTimestamp.date(from: "2026-08-04 12:00:00"))
        XCTAssertNil(BurnBarAIInboxTimestamp.date(from: ""))
        XCTAssertNil(BurnBarAIInboxTimestamp.date(from: nil))
    }

    // MARK: - The cost invariant

    /// The gate runs on EVERY tick — 288 a day — so its workspace signal must be
    /// `stat`-only. If someone swaps `gateFingerprint` for the full
    /// `snapshots(for:)`, the "free" path starts spawning ~6 git subprocesses per
    /// workspace per wake, which is the single easiest way to make this feature
    /// a tax instead of a service.
    func test_gateFingerprintSpawnsNoSubprocesses() {
        let runner = CountingProcessRunner()
        let scout = BurnBarAIInboxWorkspaceScout(
            runner: runner,
            logger: BurnBarDaemonLogger(category: "test")
        )

        let fingerprint = scout.gateFingerprint(for: ["/tmp", NSTemporaryDirectory()])

        XCTAssertEqual(runner.callCount.value, 0, "The change gate must never shell out")
        XCTAssertFalse(fingerprint.isEmpty)
    }

    /// Same inputs must hash identically; a moved file must change the hash.
    func test_gateFingerprintReactsToGitStateChanges() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-inbox-git-\(UUID().uuidString)")
        let gitDirectory = root.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let head = gitDirectory.appendingPathComponent("HEAD")
        try "ref: refs/heads/main".write(to: head, atomically: true, encoding: .utf8)

        let scout = BurnBarAIInboxWorkspaceScout(
            runner: CountingProcessRunner(),
            logger: BurnBarDaemonLogger(category: "test")
        )
        let before = scout.gateFingerprint(for: [root.path])
        XCTAssertEqual(before, scout.gateFingerprint(for: [root.path]), "Stable for unchanged state")

        // Simulate a branch switch by moving HEAD's mtime forward.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)],
            ofItemAtPath: head.path
        )
        XCTAssertNotEqual(before, scout.gateFingerprint(for: [root.path]), "A HEAD change must open the gate")
    }

    /// The gate hash must be stable across processes — `Hasher` is per-process
    /// seeded and would make every daemon restart look like a change.
    func test_stableHasherIsDeterministic() {
        XCTAssertEqual(
            BurnBarAIInboxStableHasher.hash(["a", "b"]),
            BurnBarAIInboxStableHasher.hash(["a", "b"])
        )
        XCTAssertNotEqual(
            BurnBarAIInboxStableHasher.hash(["ab", "c"]),
            BurnBarAIInboxStableHasher.hash(["a", "bc"]),
            "Field separators must prevent boundary collisions"
        )
    }

    // MARK: - Fixtures

    /// Inserts a conversation exactly as GRDB writes it, so the test exercises
    /// the real on-disk format rather than the daemon's own convention.
    private func seedConversation(
        id: String,
        storedTimestamp: String,
        messageCount: Int
    ) throws {
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
            ) VALUES (?, 'Claude Code', 'sess-1', 'BurnBar', ?, ?, ?, 'Refactor', '', '',
                      '/tmp/burnbar', ?, '[]', '[]', 'transcript')
            """,
            [
                .text(id),
                .text(storedTimestamp),
                .text(storedTimestamp),
                .int(messageCount),
                .text(storedTimestamp)
            ]
        )
    }

    /// Parses a GRDB-format literal into a `Date` for use as a query bound.
    private static func date(_ stored: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.date(from: stored)
    }
}
