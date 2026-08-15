import XCTest
import CryptoKit
import GRDB
import OpenBurnBarCore
@testable import OpenBurnBar

/// PR4 of the usage-memory program: the incremental session-log miner and its
/// candidate-spool store surface. Fixtures are temp-dir rollout files written
/// by each test in the current payload-as-item shape (the response item lives
/// directly in `payload`; `event_msg` lines duplicate the message text and
/// must be skipped).
final class UsageSessionLogMinerTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("usage-session-miner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
    }

    // MARK: - Fixtures

    private func makeStore() throws -> (DatabaseQueue, ControlPlaneStore) {
        let queue = try DatabaseQueue()
        let database = OpenBurnBarDatabase(databaseQueue: queue)
        try database.runMigrationsSafely()
        return (queue, ControlPlaneStore(dbQueue: queue))
    }

    private func makeMiner(
        store: ControlPlaneStore,
        enabled: Bool = true,
        fileManager: FileManager = .default,
        openFileForReading: (@Sendable (String) -> FileHandle?)? = nil
    ) -> UsageSessionLogMiner {
        UsageSessionLogMiner(
            store: store,
            sessionsRootURL: tempRoot,
            isEnabled: { enabled },
            fileManager: fileManager,
            openFileForReading: openFileForReading ?? { FileHandle(forReadingAtPath: $0) }
        )
    }

    private func jsonLine(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private func userLine(_ text: String) throws -> String {
        try jsonLine([
            "timestamp": "2026-08-15T10:00:00.000Z",
            "type": "response_item",
            "payload": [
                "type": "message",
                "role": "user",
                "content": [["type": "input_text", "text": text]]
            ]
        ])
    }

    private func assistantLine(_ text: String) throws -> String {
        try jsonLine([
            "timestamp": "2026-08-15T10:00:01.000Z",
            "type": "response_item",
            "payload": [
                "type": "message",
                "role": "assistant",
                "content": [["type": "output_text", "text": text]]
            ]
        ])
    }

    /// Duplicates a user message the way live rollouts do — must be skipped.
    private func eventMsgLine(_ text: String) throws -> String {
        try jsonLine([
            "timestamp": "2026-08-15T10:00:00.000Z",
            "type": "event_msg",
            "payload": ["type": "user_message", "message": text]
        ])
    }

    private func toolLine(name: String, callID: String) throws -> String {
        try jsonLine([
            "timestamp": "2026-08-15T10:00:02.000Z",
            "type": "response_item",
            "payload": [
                "type": "function_call",
                "name": name,
                "arguments": "{}",
                "call_id": callID
            ]
        ])
    }

    @discardableResult
    private func writeRollout(
        named name: String,
        lines: [String],
        unterminatedTail: String? = nil
    ) throws -> URL {
        let url = tempRoot.appendingPathComponent("\(name).jsonl", isDirectory: false)
        var content = lines.map { $0 + "\n" }.joined()
        if let unterminatedTail {
            content += unterminatedTail
        }
        try Data(content.utf8).write(to: url)
        return url
    }

    private func appendToRollout(_ url: URL, _ text: String) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private func fileSize(_ url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? -1
    }

    private func sha256Hex(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func expectedSpoolID(thread: String, text: String) -> String {
        sha256Hex("codex:\(thread)|\(sha256Hex(text))")
    }

    private func candidateCount(_ queue: DatabaseQueue, text: String) async throws -> Int {
        let hash = sha256Hex(text)
        return try await queue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM memory_usage_candidates WHERE content_hash = ?",
                arguments: [hash]
            ) ?? 0
        }
    }

    private func decodeCursors(
        _ store: ControlPlaneStore
    ) async throws -> [String: UsageSessionLogMiner.MinerFileCursor] {
        let json = try await store.usageSessionMinerCursorJSON()
        return try JSONDecoder().decode(
            [String: UsageSessionLogMiner.MinerFileCursor].self,
            from: Data(try XCTUnwrap(json, "expected a persisted miner cursor row").utf8)
        )
    }

    // MARK: - Dormancy

    /// Counts per-file stats. (`enumerator(at:...)` lives in a Swift overlay
    /// extension and cannot be overridden, so directory listing itself is not
    /// countable — the zero-open + zero-stat pair below still proves no file
    /// was read.)
    private final class CountingFileManager: FileManager, @unchecked Sendable {
        private let lock = NSLock()
        private var _attributeCalls = 0

        var attributeCalls: Int { lock.withLock { _attributeCalls } }

        override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
            lock.withLock { _attributeCalls += 1 }
            return try super.attributesOfItem(atPath: path)
        }
    }

    private final class CountingOpener: @unchecked Sendable {
        private let lock = NSLock()
        private var _opens = 0

        var opens: Int { lock.withLock { _opens } }

        func open(_ path: String) -> FileHandle? {
            lock.withLock { _opens += 1 }
            return FileHandle(forReadingAtPath: path)
        }
    }

    func test_dormantMinerPerformsZeroFileAndDatabaseWork() async throws {
        let (_, store) = try makeStore()
        // A corpus that WOULD produce a candidate when enabled.
        try writeRollout(named: "rollout-dormant", lines: [
            try userLine("How do I pin a GRDB migration to v61?")
        ])

        let countingFileManager = CountingFileManager()
        let opener = CountingOpener()
        let dormant = makeMiner(
            store: store,
            enabled: false,
            fileManager: countingFileManager,
            openFileForReading: { opener.open($0) }
        )

        let report = try await dormant.mineTick(now: Date(timeIntervalSince1970: 1_800_000_000))

        XCTAssertEqual(report, UsageSessionLogMiner.TickReport())
        XCTAssertEqual(countingFileManager.attributeCalls, 0)
        XCTAssertEqual(opener.opens, 0)
        let cursorJSON = try await store.usageSessionMinerCursorJSON()
        XCTAssertNil(cursorJSON)
        let pending = try await store.pendingUsageCandidateCount()
        XCTAssertEqual(pending, 0)

        // Same corpus, same store, enabled: proves the fixture was minable
        // and dormancy (not a broken fixture) produced the zeros above.
        let enabled = makeMiner(
            store: store,
            enabled: true,
            fileManager: countingFileManager,
            openFileForReading: { opener.open($0) }
        )
        let enabledReport = try await enabled.mineTick(now: Date(timeIntervalSince1970: 1_800_000_001))
        XCTAssertEqual(enabledReport.candidatesInserted, 1)
        XCTAssertGreaterThan(opener.opens, 0)
    }

    // MARK: - Basic mine

    func test_basicMineInsertsGatedCandidateAndPersistsCursor() async throws {
        let (queue, store) = try makeStore()
        let question = "How do I pin a GRDB migration to v61?"
        let url = try writeRollout(named: "rollout-basic", lines: [
            try userLine(question),
            try eventMsgLine(question), // duplicate shape — must not double count
            try assistantLine("Register it after v60 in the migrator."),
            try userLine("ok") // 2 bytes — too_short drop
        ])
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let miner = makeMiner(store: store)

        let report = try await miner.mineTick(now: now)

        XCTAssertEqual(report.filesRead, 1)
        XCTAssertEqual(report.filesDeferred, 0)
        XCTAssertEqual(report.candidatesInserted, 1)
        XCTAssertEqual(report.dropsByReason["too_short"], 1)
        XCTAssertEqual(report.eventsScanned, 4)

        let expectedID = expectedSpoolID(thread: "rollout-basic", text: question)
        let row = try await queue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM memory_usage_candidates WHERE id = ?",
                arguments: [expectedID]
            )
        }
        let unwrapped = try XCTUnwrap(row)
        XCTAssertEqual(unwrapped["source_kind"] as String?, "agent_session")
        XCTAssertEqual(unwrapped["source_ref"] as String?, "codex:rollout-basic")
        XCTAssertEqual(unwrapped["thread_logical_id"] as String?, "codex:rollout-basic")
        XCTAssertEqual(unwrapped["content_hash"] as String?, sha256Hex(question))
        XCTAssertEqual(
            unwrapped["simhash"] as Int64?,
            UsageMemorySimHash.storageValue(UsageMemorySimHash.hash(question))
        )
        XCTAssertEqual(unwrapped["salience_hint"] as Double? ?? 0, 0.35, accuracy: 0.0001)
        XCTAssertEqual(unwrapped["status"] as String?, "pending")
        let payloadJSON = try XCTUnwrap(unwrapped["payload_json"] as String?)
        XCTAssertTrue(payloadJSON.contains("\"schemaVersion\":1"))
        XCTAssertTrue(payloadJSON.contains("\"role\":\"user\""))
        XCTAssertTrue(payloadJSON.contains("\"threadLogicalID\":\"codex:rollout-basic\""))
        XCTAssertTrue(payloadJSON.contains(question))
        // No raw line content beyond the gated text.
        XCTAssertFalse(payloadJSON.contains("response_item"))
        XCTAssertFalse(payloadJSON.contains("input_text"))

        let cursors = try await decodeCursors(store)
        XCTAssertEqual(cursors.count, 1)
        let cursor = try XCTUnwrap(cursors.values.first)
        XCTAssertEqual(cursor.byteOffset, try fileSize(url))
        XCTAssertNotNil(cursor.lastMtime)

        // Second tick with no growth: mtime/size pre-filter skips the file.
        let second = try await miner.mineTick(now: now.addingTimeInterval(60))
        XCTAssertEqual(second.filesRead, 0)
        XCTAssertEqual(second.candidatesInserted, 0)
        XCTAssertEqual(second.bytesRead, 0)
        let total = try await store.pendingUsageCandidateCount()
        XCTAssertEqual(total, 1)
    }

    // MARK: - Append resume

    func test_appendResumeProcessesOnlyNewLines() async throws {
        let (queue, store) = try makeStore()
        let first = "How do I pin a GRDB migration to v61?"
        let second = "Why does xcodegen regenerate the project file every run?"
        let url = try writeRollout(named: "rollout-append", lines: [try userLine(first)])
        let miner = makeMiner(store: store)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let tick1 = try await miner.mineTick(now: now)
        XCTAssertEqual(tick1.candidatesInserted, 1)
        let sizeAfterFirst = try fileSize(url)

        try appendToRollout(url, try userLine(second) + "\n")
        let sizeAfterAppend = try fileSize(url)

        let tick2 = try await miner.mineTick(now: now.addingTimeInterval(120))
        XCTAssertEqual(tick2.filesRead, 1)
        XCTAssertEqual(tick2.candidatesInserted, 1)
        // Head-digest probe + appended tail only — the consumed prefix is
        // never re-read.
        let headLength = Int64(min(4096, sizeAfterFirst))
        XCTAssertEqual(tick2.bytesRead, headLength + (sizeAfterAppend - sizeAfterFirst))

        let firstCount = try await candidateCount(queue, text: first)
        let secondCount = try await candidateCount(queue, text: second)
        XCTAssertEqual(firstCount, 1)
        XCTAssertEqual(secondCount, 1)

        let cursors = try await decodeCursors(store)
        XCTAssertEqual(cursors.values.first?.byteOffset, sizeAfterAppend)
    }

    // MARK: - Unterminated tail

    func test_unterminatedTailIsNeverCoveredUntilTerminated() async throws {
        let (queue, store) = try makeStore()
        let complete = "How do I pin a GRDB migration to v61?"
        let pending = "Should I split the miner cursor from the parser cache?"
        let pendingLine = try userLine(pending)
        let splitIndex = pendingLine.index(pendingLine.startIndex, offsetBy: pendingLine.count / 2)
        let head = String(pendingLine[..<splitIndex])
        let tail = String(pendingLine[splitIndex...])

        let url = try writeRollout(
            named: "rollout-tail",
            lines: [try userLine(complete)],
            unterminatedTail: head
        )
        let terminatedSpan = Int64(Data((try userLine(complete) + "\n").utf8).count)
        let miner = makeMiner(store: store)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let tick1 = try await miner.mineTick(now: now)
        XCTAssertEqual(tick1.candidatesInserted, 1)
        var cursors = try await decodeCursors(store)
        // The cursor stops at the last terminated line — the mid-append tail
        // is not covered.
        XCTAssertEqual(cursors.values.first?.byteOffset, terminatedSpan)
        let pendingBefore = try await candidateCount(queue, text: pending)
        XCTAssertEqual(pendingBefore, 0)

        // The writer finishes the line; the candidate appears exactly once.
        try appendToRollout(url, tail + "\n")
        let tick2 = try await miner.mineTick(now: now.addingTimeInterval(120))
        XCTAssertEqual(tick2.candidatesInserted, 1)
        let pendingAfter = try await candidateCount(queue, text: pending)
        XCTAssertEqual(pendingAfter, 1)
        cursors = try await decodeCursors(store)
        XCTAssertEqual(cursors.values.first?.byteOffset, try fileSize(url))

        // Re-tick: nothing new.
        let tick3 = try await miner.mineTick(now: now.addingTimeInterval(240))
        XCTAssertEqual(tick3.candidatesInserted, 0)
        let stillOnce = try await candidateCount(queue, text: pending)
        XCTAssertEqual(stillOnce, 1)
    }

    // MARK: - Rewrite detection

    func test_headDigestMismatchRestartsFromZero() async throws {
        let (queue, store) = try makeStore()
        let original = "How do I pin a GRDB migration to v61?"
        let rewriteA = "Where does the miner cursor map get persisted?"
        let rewriteB = "Which governor budget applies to rollout scans?"
        let url = try writeRollout(named: "rollout-rewrite", lines: [try userLine(original)])
        let miner = makeMiner(store: store)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let tick1 = try await miner.mineTick(now: now)
        XCTAssertEqual(tick1.candidatesInserted, 1)
        let staleOffset = try await decodeCursors(store).values.first?.byteOffset

        // Rewrite the file wholesale (different head bytes, larger than the
        // stale offset) — resuming at the stale offset would land mid-line.
        try Data((
            [try userLine(rewriteA), try userLine(rewriteB)].map { $0 + "\n" }.joined()
        ).utf8).write(to: url)
        XCTAssertLessThan(try XCTUnwrap(staleOffset), try fileSize(url))

        let tick2 = try await miner.mineTick(now: now.addingTimeInterval(120))
        XCTAssertEqual(tick2.filesRead, 1)
        XCTAssertEqual(tick2.candidatesInserted, 2)

        let countA = try await candidateCount(queue, text: rewriteA)
        let countB = try await candidateCount(queue, text: rewriteB)
        XCTAssertEqual(countA, 1, "restart from zero must recover the full first line, not a stale-offset fragment")
        XCTAssertEqual(countB, 1)

        let cursors = try await decodeCursors(store)
        let cursor = try XCTUnwrap(cursors.values.first)
        XCTAssertEqual(cursor.byteOffset, try fileSize(url))
        XCTAssertEqual(cursor.headDigestLength, Int(min(4096, try fileSize(url))))
    }

    // MARK: - Workflow synthesis

    func test_workflowSynthesisEmitsOneCandidateForRepeatedTool() async throws {
        let (queue, store) = try makeStore()
        try writeRollout(named: "rollout-workflow", lines: [
            try toolLine(name: "shell", callID: "c1"),
            try toolLine(name: "shell", callID: "c2"),
            try toolLine(name: "apply_patch", callID: "c3"),
            try toolLine(name: "shell", callID: "c4"),
            try toolLine(name: "apply_patch", callID: "c5")
        ])
        let miner = makeMiner(store: store)

        let report = try await miner.mineTick(now: Date(timeIntervalSince1970: 1_800_000_000))

        // shell ran 3x ⇒ exactly one workflow candidate; apply_patch (2x)
        // stays below the threshold.
        XCTAssertEqual(report.candidatesInserted, 1)
        let workflowText = "Repeatedly runs the shell tool (3x this session)."
        let workflowHash = sha256Hex(workflowText)
        let row = try await queue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM memory_usage_candidates WHERE content_hash = ?",
                arguments: [workflowHash]
            )
        }
        let unwrapped = try XCTUnwrap(row)
        XCTAssertEqual(unwrapped["source_ref"] as String?, "codex:rollout-workflow")
        XCTAssertEqual(unwrapped["salience_hint"] as Double? ?? 0, 0.40, accuracy: 0.0001)
        let payloadJSON = try XCTUnwrap(unwrapped["payload_json"] as String?)
        XCTAssertTrue(payloadJSON.contains("\"role\":\"workflow\""))
        XCTAssertTrue(payloadJSON.contains(workflowText))
    }

    // MARK: - Store surface

    func test_repetitionCountObservesWindowAndSourceKind() async throws {
        let (_, store) = try makeStore()
        let text = "How do I pin a GRDB migration to v61?"
        let simhash = UsageMemorySimHash.storageValue(UsageMemorySimHash.hash(text))
        let insertedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let contentHash = sha256Hex(text)
        try await store.insertUsageMemoryCandidates(
            [UsageMemoryCandidate(
                id: UsageMemoryCandidate.spoolID(sourceRef: "codex:thread-r", contentHash: contentHash),
                sourceKind: .agentSession,
                sourceRef: "codex:thread-r",
                threadLogicalID: "codex:thread-r",
                payloadJSON: "{\"schemaVersion\":1}",
                contentHash: contentHash,
                simhash: simhash,
                salienceHint: 0.35
            )],
            cursorKey: nil,
            cursorJSON: nil,
            now: insertedAt
        )

        let inWindow = try await store.usageCandidateRepetitionCount(
            sourceKind: .agentSession,
            simhash: simhash,
            since: insertedAt.addingTimeInterval(-1)
        )
        XCTAssertEqual(inWindow, 1)
        let afterWindow = try await store.usageCandidateRepetitionCount(
            sourceKind: .agentSession,
            simhash: simhash,
            since: insertedAt.addingTimeInterval(1)
        )
        XCTAssertEqual(afterWindow, 0)
        let otherKind = try await store.usageCandidateRepetitionCount(
            sourceKind: .safariAsk,
            simhash: simhash,
            since: insertedAt.addingTimeInterval(-1)
        )
        XCTAssertEqual(otherKind, 0)
    }

    func test_insertIsIdempotentAndCommitsCursorAtomically() async throws {
        let (queue, store) = try makeStore()
        let contentHash = sha256Hex("idempotent body")
        let candidate = UsageMemoryCandidate(
            id: UsageMemoryCandidate.spoolID(sourceRef: "codex:thread-i", contentHash: contentHash),
            sourceKind: .agentSession,
            sourceRef: "codex:thread-i",
            threadLogicalID: "codex:thread-i",
            payloadJSON: "{\"schemaVersion\":1}",
            contentHash: contentHash,
            simhash: 42,
            salienceHint: 0.5
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let first = try await store.insertUsageMemoryCandidates(
            [candidate], cursorKey: ControlPlaneStore.usageSessionMinerCursorKey,
            cursorJSON: "{\"a\":1}", now: now
        )
        XCTAssertEqual(first, 1)
        // Replay (re-mined event) collapses; the cursor still advances.
        let second = try await store.insertUsageMemoryCandidates(
            [candidate], cursorKey: ControlPlaneStore.usageSessionMinerCursorKey,
            cursorJSON: "{\"a\":2}", now: now.addingTimeInterval(1)
        )
        XCTAssertEqual(second, 0)
        let cursorJSON = try await store.usageSessionMinerCursorJSON()
        XCTAssertEqual(cursorJSON, "{\"a\":2}")
        let rows = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_usage_candidates") ?? 0
        }
        XCTAssertEqual(rows, 1)
    }

    // MARK: - TTL expiry

    func test_expireUsageCandidatesRemovesAgedPendingRows() async throws {
        let (queue, store) = try makeStore()
        let ttlDays = UsageMemoryCurationPolicy.defaults.caps.candidateTTLDays
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let aged = now.addingTimeInterval(-Double(ttlDays + 2) * 86_400)

        func candidate(_ suffix: String) -> UsageMemoryCandidate {
            let contentHash = sha256Hex("body-\(suffix)")
            return UsageMemoryCandidate(
                id: UsageMemoryCandidate.spoolID(sourceRef: "codex:thread-\(suffix)", contentHash: contentHash),
                sourceKind: .agentSession,
                sourceRef: "codex:thread-\(suffix)",
                threadLogicalID: "codex:thread-\(suffix)",
                payloadJSON: "{\"schemaVersion\":1}",
                contentHash: contentHash,
                simhash: 7,
                salienceHint: 0.3
            )
        }

        try await store.insertUsageMemoryCandidates(
            [candidate("old-1"), candidate("old-2")], cursorKey: nil, cursorJSON: nil, now: aged
        )
        try await store.insertUsageMemoryCandidates(
            [candidate("fresh")], cursorKey: nil, cursorJSON: nil, now: now
        )

        let removed = try await store.expireUsageCandidates(olderThan: ttlDays, now: now)
        XCTAssertEqual(removed, 2)
        let pending = try await store.pendingUsageCandidateCount()
        XCTAssertEqual(pending, 1)
        let total = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_usage_candidates") ?? 0
        }
        XCTAssertEqual(total, 1)
    }
}
