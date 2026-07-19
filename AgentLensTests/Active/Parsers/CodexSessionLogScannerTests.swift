import OpenBurnBarCore
@testable import OpenBurnBarLogParsers
import XCTest

// MARK: - CodexSessionLogScannerTests

/// Coverage for the shared Codex rollout scanning engine introduced by the
/// 2026-07-16 resource-exhaustion fix: token semantics parity with the legacy
/// full-file loop (VAL-TOKEN-002 / VAL-TOKEN-010), incremental append-only
/// resume, rewrite/truncation detection, and governed thread-row processing
/// (budget deferral, boundary deferral, heuristic fallback).
final class CodexSessionLogScannerTests: XCTestCase {
    /// Models a rollout disappearing after metadata discovery but before the
    /// scanner opens it, while forwarding every other filesystem operation.
    private final class ScanFailingFileManager: FileManager, @unchecked Sendable {
        private let unreadablePath: String

        init(unreadablePath: String) {
            self.unreadablePath = unreadablePath
            super.init()
        }

        override func fileExists(atPath path: String) -> Bool {
            path == unreadablePath ? false : super.fileExists(atPath: path)
        }
    }

    /// Lets discovery capture real metadata, then fails the scanner's inner
    /// size lookup for the same path.
    private final class InnerStatFailingFileManager: FileManager, @unchecked Sendable {
        struct StatUnavailable: Error {}

        private let targetPath: String
        private(set) var targetStatCount = 0

        init(targetPath: String) {
            self.targetPath = targetPath
            super.init()
        }

        override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
            guard path == targetPath else { return try super.attributesOfItem(atPath: path) }
            targetStatCount += 1
            guard targetStatCount == 1 else { throw StatUnavailable() }
            return try super.attributesOfItem(atPath: path)
        }
    }

    /// Fails selected existence checks for one otherwise-readable rollout.
    /// This deterministically models open races at the token/conversation
    /// boundary without changing the real fixture on disk.
    private final class SequencedExistenceFileManager: FileManager, @unchecked Sendable {
        private let targetPath: String
        private let failingChecks: Set<Int>
        private(set) var targetCheckCount = 0

        init(targetPath: String, failingChecks: Set<Int>) {
            self.targetPath = targetPath
            self.failingChecks = failingChecks
            super.init()
        }

        override func fileExists(atPath path: String) -> Bool {
            guard path == targetPath else { return super.fileExists(atPath: path) }
            targetCheckCount += 1
            return failingChecks.contains(targetCheckCount) ? false : super.fileExists(atPath: path)
        }
    }

    private final class RecordingFileOpener {
        private let failingChecks: Set<Int>
        private(set) var openedPaths: [String] = []

        init(failingChecks: Set<Int> = []) {
            self.failingChecks = failingChecks
        }

        func open(path: String) -> FileHandle? {
            openedPaths.append(path)
            return failingChecks.contains(openedPaths.count) ? nil : FileHandle(forReadingAtPath: path)
        }
    }


    private var tempDirectory: URL!
    private let fileManager = FileManager.default

    override func setUp() {
        super.setUp()
        tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("openburnbar-codex-scanner-tests-\(UUID().uuidString)", isDirectory: true)
        try? fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? fileManager.removeItem(at: tempDirectory)
        super.tearDown()
    }

    // MARK: - Fixture helpers

    /// Legacy-envelope cumulative token event (`token_count`), same shape as
    /// `AgentLensTests/LegacyReference/Parsers/ParserTests.swift`.
    private func cumulativeEvent(input: Int, output: Int, cachedInput: Int = 0) -> String {
        #"{"event_msg": {"token_count": {"input_tokens": \#(input), "output_tokens": \#(output), "cached_input_tokens": \#(cachedInput)}}}"#
    }

    /// Current-envelope cumulative token event (`total_token_usage`).
    private func totalUsageEvent(input: Int, output: Int, cachedInput: Int = 0) -> String {
        #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cachedInput),"output_tokens":\#(output)},"model":"openai/gpt-5.2-codex"}}}"#
    }

    private func deltaEvent(input: Int, output: Int, cachedInput: Int = 0) -> String {
        #"{"event_msg": {"last_token_usage": {"input_tokens": \#(input), "cached_input_tokens": \#(cachedInput), "output_tokens": \#(output)}}}"#
    }

    private func messageEvent(role: String, text: String) -> String {
        #"{"item":{"role":"\#(role)","content":"\#(text)"}}"#
    }

    @discardableResult
    private func write(_ content: String, to filename: String) throws -> URL {
        let url = tempDirectory.appendingPathComponent(filename)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func append(_ content: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(content.utf8))
    }

    private func scan(
        _ url: URL,
        previousState: CodexTokenScanState? = nil
    ) throws -> CodexSessionLogScanner.TokenScanResult? {
        try CodexSessionLogScanner.scanTokens(
            path: url.path,
            fileManager: fileManager,
            previousState: previousState
        )
    }

    private func assertUsage(
        _ usage: (input: Int, output: Int, cacheRead: Int)?,
        equals expected: (input: Int, output: Int, cacheRead: Int),
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(usage?.input, expected.input, "input \(message)", file: file, line: line)
        XCTAssertEqual(usage?.output, expected.output, "output \(message)", file: file, line: line)
        XCTAssertEqual(usage?.cacheRead, expected.cacheRead, "cacheRead \(message)", file: file, line: line)
    }

    // MARK: - Legacy token semantics (VAL-TOKEN-002 / VAL-TOKEN-010)

    func test_scanTokens_cumulativeOnly_subtractsCachedInputFromInclusiveInput() throws {
        // Codex reports input_tokens inclusive of cached_input_tokens; the
        // non-cached and cached buckets must stay disjoint.
        let url = try write(cumulativeEvent(input: 1000, output: 500, cachedInput: 200) + "\n", to: "cumulative.jsonl")

        let result = try XCTUnwrap(try scan(url))
        assertUsage(result.usage, equals: (input: 800, output: 500, cacheRead: 200))
        XCTAssertTrue(result.state.foundCumulative)
        XCTAssertFalse(result.state.foundDelta)
    }

    func test_scanTokens_currentTotalUsageEnvelope_matchesLegacySemantics() throws {
        let url = try write(totalUsageEvent(input: 160, output: 16, cachedInput: 40) + "\n", to: "total_usage.jsonl")

        let result = try XCTUnwrap(try scan(url))
        assertUsage(result.usage, equals: (input: 120, output: 16, cacheRead: 40))
    }

    func test_scanTokens_deltaOnly_accumulatesAcrossEvents() throws {
        let content = [
            deltaEvent(input: 100, output: 50, cachedInput: 20),
            deltaEvent(input: 150, output: 75, cachedInput: 30)
        ].joined(separator: "\n") + "\n"
        let url = try write(content, to: "delta.jsonl")

        let result = try XCTUnwrap(try scan(url))
        // (100-20) + (150-30) input, 50+75 output, 20+30 cacheRead.
        assertUsage(result.usage, equals: (input: 200, output: 125, cacheRead: 50))
        XCTAssertTrue(result.state.foundDelta)
        XCTAssertFalse(result.state.foundCumulative)
    }

    func test_scanTokens_cumulativeAfterDelta_cumulativeWins() throws {
        let content = [
            deltaEvent(input: 100, output: 50),
            cumulativeEvent(input: 1000, output: 500)
        ].joined(separator: "\n") + "\n"
        let url = try write(content, to: "cumulative_after_delta.jsonl")

        let result = try XCTUnwrap(try scan(url))
        assertUsage(result.usage, equals: (input: 1000, output: 500, cacheRead: 0))
    }

    func test_scanTokens_deltaAfterCumulative_isIgnored() throws {
        let content = [
            cumulativeEvent(input: 1000, output: 500, cachedInput: 200),
            deltaEvent(input: 999, output: 999, cachedInput: 999)
        ].joined(separator: "\n") + "\n"
        let url = try write(content, to: "delta_after_cumulative.jsonl")

        let result = try XCTUnwrap(try scan(url))
        assertUsage(result.usage, equals: (input: 800, output: 500, cacheRead: 200))
    }

    func test_scanTokens_noTokenEvents_returnsNilUsage() throws {
        let content = """
        {"type": "other_event"}
        {"type": "another_event"}
        """
        let url = try write(content + "\n", to: "no_tokens.jsonl")

        let result = try XCTUnwrap(try scan(url))
        XCTAssertNil(result.usage)
        XCTAssertFalse(result.state.foundCumulative)
        XCTAssertFalse(result.state.foundDelta)
    }

    func test_scanTokens_emptyFile_returnsResultWithNilUsage() throws {
        let url = try write("", to: "empty.jsonl")

        let result = try XCTUnwrap(try scan(url))
        XCTAssertNil(result.usage)
        XCTAssertEqual(result.state.byteOffset, 0)
    }

    func test_scanTokens_missingFile_returnsNil() throws {
        let missing = tempDirectory.appendingPathComponent("does-not-exist.jsonl")
        XCTAssertNil(try scan(missing))
    }

    // MARK: - Incremental resume equality

    /// Field-wise state comparison excluding the head digest (a resumed scan
    /// legitimately keeps the digest captured when the file was smaller).
    private func assertAccumulatorState(
        _ state: CodexTokenScanState,
        matches other: CodexTokenScanState,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(state.byteOffset, other.byteOffset, file: file, line: line)
        XCTAssertEqual(state.inputTokens, other.inputTokens, file: file, line: line)
        XCTAssertEqual(state.outputTokens, other.outputTokens, file: file, line: line)
        XCTAssertEqual(state.cacheReadTokens, other.cacheReadTokens, file: file, line: line)
        XCTAssertEqual(state.foundCumulative, other.foundCumulative, file: file, line: line)
        XCTAssertEqual(state.foundDelta, other.foundDelta, file: file, line: line)
    }

    func test_scanTokens_incrementalResume_equalsFreshScan_deltaMix() throws {
        let url = try write(
            [
                deltaEvent(input: 100, output: 10, cachedInput: 20),
                deltaEvent(input: 60, output: 6, cachedInput: 20)
            ].joined(separator: "\n") + "\n",
            to: "incremental_delta.jsonl"
        )
        let first = try XCTUnwrap(try scan(url))
        assertUsage(first.usage, equals: (input: 120, output: 16, cacheRead: 40))

        try append(deltaEvent(input: 30, output: 4, cachedInput: 10) + "\n", to: url)

        let resumed = try XCTUnwrap(try scan(url, previousState: first.state))
        let fresh = try XCTUnwrap(try scan(url))

        assertUsage(resumed.usage, equals: (input: 140, output: 20, cacheRead: 50), "(resumed)")
        assertUsage(fresh.usage, equals: (input: 140, output: 20, cacheRead: 50), "(fresh)")
        assertAccumulatorState(resumed.state, matches: fresh.state)
    }

    func test_scanTokens_incrementalResume_equalsFreshScan_cumulativeMix() throws {
        // Segment A is delta-only; segment B introduces a cumulative total
        // (which must overwrite) followed by a post-cumulative delta (which
        // must be suppressed) — exercised across the resume boundary.
        let url = try write(deltaEvent(input: 100, output: 10, cachedInput: 20) + "\n", to: "incremental_cumulative.jsonl")
        let first = try XCTUnwrap(try scan(url))
        assertUsage(first.usage, equals: (input: 80, output: 10, cacheRead: 20))

        try append(
            [
                totalUsageEvent(input: 1000, output: 500, cachedInput: 200),
                deltaEvent(input: 50, output: 5)
            ].joined(separator: "\n") + "\n",
            to: url
        )

        let resumed = try XCTUnwrap(try scan(url, previousState: first.state))
        let fresh = try XCTUnwrap(try scan(url))

        assertUsage(resumed.usage, equals: (input: 800, output: 500, cacheRead: 200), "(resumed)")
        assertUsage(fresh.usage, equals: (input: 800, output: 500, cacheRead: 200), "(fresh)")
        assertAccumulatorState(resumed.state, matches: fresh.state)
    }

    func test_scanTokens_resume_trustsPreviousAccumulator_provingNoSilentFullRescan() throws {
        // A resumed scan must START from the persisted accumulator instead of
        // silently re-scanning from byte 0 (a full rescan would also satisfy
        // the equality tests, so this pins the actual resume machinery):
        // tamper the carried token count and verify it flows into the result.
        let url = try write(deltaEvent(input: 100, output: 10) + "\n", to: "resume_proof.jsonl")
        let first = try XCTUnwrap(try scan(url))
        assertUsage(first.usage, equals: (input: 100, output: 10, cacheRead: 0))

        try append(deltaEvent(input: 30, output: 3) + "\n", to: url)

        var tampered = first.state
        tampered.inputTokens += 5000
        let resumed = try XCTUnwrap(try scan(url, previousState: tampered))

        // 5000 (carried marker) + 100 (pre-offset, NOT re-read) + 30 (tail).
        assertUsage(resumed.usage, equals: (input: 5130, output: 13, cacheRead: 0))
    }

    // MARK: - Unterminated tail (live-writer double-count guard)

    func test_scanTokens_unterminatedTail_countedInUsageButNotPersistedState() throws {
        // L2 is a complete JSON record whose trailing newline has not been
        // written yet — exactly what a live Codex writer looks like mid-append.
        let terminated = deltaEvent(input: 100, output: 40) + "\n"
        let tail = deltaEvent(input: 7, output: 3)
        let url = try write(terminated + tail, to: "unterminated.jsonl")

        let first = try XCTUnwrap(try scan(url))
        // Returned usage includes the parsed tail…
        assertUsage(first.usage, equals: (input: 107, output: 43, cacheRead: 0))
        // …but persisted state stops at the last terminated line.
        XCTAssertEqual(first.state.byteOffset, Int64(terminated.utf8.count))
        XCTAssertEqual(first.state.inputTokens, 100)
        XCTAssertEqual(first.state.outputTokens, 40)

        // The writer finishes the line and appends one more event.
        try append("\n" + deltaEvent(input: 1, output: 1) + "\n", to: url)

        let resumed = try XCTUnwrap(try scan(url, previousState: first.state))
        let fresh = try XCTUnwrap(try scan(url))

        // The tail is re-read exactly once — no double count of L2.
        assertUsage(resumed.usage, equals: (input: 108, output: 44, cacheRead: 0), "(resumed)")
        assertUsage(fresh.usage, equals: (input: 108, output: 44, cacheRead: 0), "(fresh)")
        assertAccumulatorState(resumed.state, matches: fresh.state)
    }

    // MARK: - Rewrite + truncation detection

    func test_scanTokens_headRewriteSameSize_restartsFromScratch() throws {
        let original = cumulativeEvent(input: 1111, output: 11) + "\n"
        let url = try write(original, to: "rewrite_same_size.jsonl")
        let first = try XCTUnwrap(try scan(url))
        assertUsage(first.usage, equals: (input: 1111, output: 11, cacheRead: 0))

        // Same byte length, different leading digits → head digest mismatch.
        let rewritten = cumulativeEvent(input: 2222, output: 22) + "\n"
        XCTAssertEqual(rewritten.utf8.count, original.utf8.count)
        try rewritten.write(to: url, atomically: true, encoding: .utf8)

        let resumed = try XCTUnwrap(try scan(url, previousState: first.state))
        let fresh = try XCTUnwrap(try scan(url))
        assertUsage(resumed.usage, equals: (input: 2222, output: 22, cacheRead: 0), "(resumed)")
        assertUsage(fresh.usage, equals: (input: 2222, output: 22, cacheRead: 0), "(fresh)")
        assertAccumulatorState(resumed.state, matches: fresh.state)
    }

    func test_scanTokens_headRewriteLargerFile_restartsFromScratch() throws {
        let url = try write(cumulativeEvent(input: 1000, output: 100) + "\n", to: "rewrite_larger.jsonl")
        let first = try XCTUnwrap(try scan(url))

        // Larger rewritten file (old byteOffset would still be in range —
        // only the digest catches this).
        let rewritten = [
            cumulativeEvent(input: 4000, output: 400),
            #"{"type":"turn_context","payload":{"model":"openai/gpt-5.2-codex"}}"#
        ].joined(separator: "\n") + "\n"
        try rewritten.write(to: url, atomically: true, encoding: .utf8)

        let resumed = try XCTUnwrap(try scan(url, previousState: first.state))
        assertUsage(resumed.usage, equals: (input: 4000, output: 400, cacheRead: 0))
    }

    func test_scanTokens_truncatedFile_restartsFromScratch() throws {
        let lineA = deltaEvent(input: 100, output: 10)
        let lineB = deltaEvent(input: 200, output: 20)
        let lineC = deltaEvent(input: 300, output: 30)
        let url = try write([lineA, lineB, lineC].joined(separator: "\n") + "\n", to: "truncated.jsonl")
        let first = try XCTUnwrap(try scan(url))
        assertUsage(first.usage, equals: (input: 600, output: 60, cacheRead: 0))

        // Truncate to just the first line: previous byteOffset > new size.
        try (lineA + "\n").write(to: url, atomically: true, encoding: .utf8)

        let resumed = try XCTUnwrap(try scan(url, previousState: first.state))
        let fresh = try XCTUnwrap(try scan(url))
        assertUsage(resumed.usage, equals: (input: 100, output: 10, cacheRead: 0), "(resumed)")
        assertUsage(fresh.usage, equals: (input: 100, output: 10, cacheRead: 0), "(fresh)")
        assertAccumulatorState(resumed.state, matches: fresh.state)
    }

    // MARK: - processThreadRows

    private func makeCacheStore(name: String = "codex_cache.json") -> ParserDiskCacheStore<CodexCacheEntry> {
        ParserDiskCacheStore<CodexCacheEntry>(
            cacheURL: tempDirectory.appendingPathComponent(name),
            fileManager: fileManager,
            schemaVersion: 2,
            logLabel: "CodexSessionLogScannerTests"
        )
    }

    private func makeRow(
        threadId: String,
        tokensUsed: Int = 999,
        rolloutPath: String?
    ) -> CodexThreadRow {
        CodexThreadRow(
            threadId: threadId,
            model: "openai/gpt-5.2-codex",
            rawTitle: "title-\(threadId)",
            projectName: "OpenBurnBar",
            tokensUsed: tokensUsed,
            startTime: Date(timeIntervalSince1970: 1_766_577_600),
            endTime: Date(timeIntervalSince1970: 1_766_577_660),
            expandedRolloutPath: rolloutPath
        )
    }

    func test_processThreadRows_budgetDeferral_uncachedRowEmitsNothing_thenCatchesUp() throws {
        let file1 = try write(cumulativeEvent(input: 1000, output: 100) + "\n", to: "rollout-1.jsonl")
        let file2 = try write(cumulativeEvent(input: 2000, output: 200) + "\n", to: "rollout-2.jsonl")
        let rows = [
            makeRow(threadId: "thread-1", rolloutPath: file1.path),
            makeRow(threadId: "thread-2", rolloutPath: file2.path)
        ]
        let cacheStore = makeCacheStore()

        // Pass 1: a 1-byte budget admits only the first file (the admission
        // that crosses the budget is allowed); the second row is uncached and
        // must emit NOTHING — not a heuristic row that could overwrite
        // previously persisted exact values downstream.
        let governor = ParserResourceGovernor(limits: ParserResourceLimits(fileByteBudget: 1))
        let firstPass = try CodexSessionLogScanner.processThreadRows(
            rows,
            options: LogParseOptions(includeConversationBodies: false, resourceGovernor: governor),
            fileManager: fileManager,
            cacheStore: cacheStore
        )

        XCTAssertEqual(firstPass.usages.map(\.sessionId), ["thread-1"])
        XCTAssertEqual(firstPass.usages.first?.inputTokens, 1000)
        XCTAssertEqual(firstPass.usages.first?.provenanceMethod, .providerLog)
        XCTAssertEqual(governor.deferredFileCount, 1)
        XCTAssertTrue(firstPass.conversations.isEmpty)

        let cachedEntries = cacheStore.load().fileEntries
        XCTAssertNotNil(cachedEntries[file1.standardizedFileURL.path], "admitted file persists tokens + scan state")
        XCTAssertNil(cachedEntries[file2.standardizedFileURL.path], "deferred file must not gain a cache entry")

        // Pass 2: a fresh unlimited governor catches the deferred row up with
        // exact tokens.
        let secondGovernor = ParserResourceGovernor(limits: .unlimited)
        let secondPass = try CodexSessionLogScanner.processThreadRows(
            rows,
            options: LogParseOptions(includeConversationBodies: false, resourceGovernor: secondGovernor),
            fileManager: fileManager,
            cacheStore: cacheStore
        )

        XCTAssertEqual(secondPass.usages.map(\.sessionId), ["thread-1", "thread-2"])
        let caughtUp = try XCTUnwrap(secondPass.usages.last)
        XCTAssertEqual(caughtUp.inputTokens, 2000)
        XCTAssertEqual(caughtUp.outputTokens, 200)
        XCTAssertEqual(caughtUp.provenanceMethod, .providerLog)
        XCTAssertEqual(caughtUp.provenanceConfidence, .exact)
        XCTAssertEqual(secondGovernor.deferredFileCount, 0)
    }

    func test_processThreadRows_budgetDeferralWithCachedTokens_keepsCachedValues() throws {
        let file1 = try write(cumulativeEvent(input: 1000, output: 100) + "\n", to: "rollout-cached.jsonl")
        let rows = [makeRow(threadId: "thread-cached", rolloutPath: file1.path)]
        let cacheStore = makeCacheStore()

        // Warm the cache.
        _ = try CodexSessionLogScanner.processThreadRows(
            rows,
            options: LogParseOptions(includeConversationBodies: false),
            fileManager: fileManager,
            cacheStore: cacheStore
        )

        // Grow the file (signature mismatch forces a re-scan attempt), then
        // run with a zero budget: the row must keep its cached exact values.
        try append(cumulativeEvent(input: 5000, output: 500) + "\n", to: file1)
        let starved = ParserResourceGovernor(limits: ParserResourceLimits(fileByteBudget: 0))
        let starvedPass = try CodexSessionLogScanner.processThreadRows(
            rows,
            options: LogParseOptions(includeConversationBodies: false, resourceGovernor: starved),
            fileManager: fileManager,
            cacheStore: cacheStore
        )

        XCTAssertEqual(starvedPass.usages.map(\.sessionId), ["thread-cached"])
        XCTAssertEqual(starvedPass.usages.first?.inputTokens, 1000, "budget-starved pass keeps last known exact values")
        XCTAssertEqual(starved.deferredFileCount, 1)

        // Next unlimited pass picks up the appended cumulative totals.
        let recovered = try CodexSessionLogScanner.processThreadRows(
            rows,
            options: LogParseOptions(includeConversationBodies: false),
            fileManager: fileManager,
            cacheStore: cacheStore
        )
        XCTAssertEqual(recovered.usages.first?.inputTokens, 5000)
    }

    func test_processThreadRows_sameSizeHeadRewriteChargesFullRescanBeforeDeferringNextFile() throws {
        let rewrittenFile = try write(cumulativeEvent(input: 1111, output: 11) + "\n", to: "rollout-rewritten.jsonl")
        let deferredFile = try write(cumulativeEvent(input: 3333, output: 33) + "\n", to: "rollout-deferred.jsonl")
        let rewrittenRow = makeRow(threadId: "thread-rewritten", rolloutPath: rewrittenFile.path)
        let cacheStore = makeCacheStore()

        _ = try CodexSessionLogScanner.processThreadRows(
            [rewrittenRow],
            options: LogParseOptions(includeConversationBodies: false),
            fileManager: fileManager,
            cacheStore: cacheStore
        )

        let originalAttributes = try fileManager.attributesOfItem(atPath: rewrittenFile.path)
        let originalModificationDate = try XCTUnwrap(originalAttributes[.modificationDate] as? Date)
        let originalSize = try XCTUnwrap(originalAttributes[.size] as? NSNumber).int64Value
        let rewrittenContent = cumulativeEvent(input: 2222, output: 22) + "\n"
        XCTAssertEqual(Int64(rewrittenContent.utf8.count), originalSize)

        let handle = try FileHandle(forWritingTo: rewrittenFile)
        try handle.write(contentsOf: Data(rewrittenContent.utf8))
        try handle.close()
        try fileManager.setAttributes(
            [.modificationDate: originalModificationDate.addingTimeInterval(1)],
            ofItemAtPath: rewrittenFile.path
        )

        let governor = ParserResourceGovernor(limits: ParserResourceLimits(fileByteBudget: 1))
        let result = try CodexSessionLogScanner.processThreadRows(
            [rewrittenRow, makeRow(threadId: "thread-deferred", rolloutPath: deferredFile.path)],
            options: LogParseOptions(includeConversationBodies: false, resourceGovernor: governor),
            fileManager: fileManager,
            cacheStore: cacheStore
        )

        XCTAssertEqual(result.usages.map(\.sessionId), ["thread-rewritten"])
        XCTAssertEqual(result.usages.first?.inputTokens, 2222, "head mismatch must rescan instead of reusing cached tokens")
        XCTAssertEqual(governor.consumedBytes, originalSize, "a rewrite has no append tail, so the full file is new work")
        XCTAssertEqual(governor.deferredFileCount, 1, "the full-rescan charge exhausts the pass budget before the next file")
        XCTAssertNil(cacheStore.load().fileEntries[deferredFile.standardizedFileURL.path])
    }


    func test_processThreadRows_boundaryDefer_uncachedFileEmitsNothingAndIsNeverRead() throws {
        let file = try write(cumulativeEvent(input: 1000, output: 100) + "\n", to: "rollout-boundary.jsonl")
        let rows = [makeRow(threadId: "thread-boundary", rolloutPath: file.path)]
        let cacheStore = makeCacheStore()
        let governor = ParserResourceGovernor(limits: .unlimited)

        let result = try CodexSessionLogScanner.processThreadRows(
            rows,
            options: LogParseOptions(
                includeConversationBodies: false,
                minimumFileModificationDate: .distantFuture,
                resourceGovernor: governor
            ),
            fileManager: fileManager,
            cacheStore: cacheStore
        )

        XCTAssertTrue(result.usages.isEmpty, "uncached row below the boundary emits nothing (no heuristic row)")
        XCTAssertTrue(result.conversations.isEmpty)
        XCTAssertTrue(cacheStore.load().fileEntries.isEmpty, "boundary-deferred file must not gain a cache entry")
        XCTAssertEqual(governor.consumedBytes, 0, "boundary-deferred file content is never admitted for reading")
    }

    func test_processThreadRows_boundaryDeferWithCachedTokens_reusesCacheWithoutContentRead() throws {
        let file = try write(cumulativeEvent(input: 1000, output: 100) + "\n", to: "rollout-boundary-cached.jsonl")
        let rows = [makeRow(threadId: "thread-boundary-cached", rolloutPath: file.path)]
        let cacheStore = makeCacheStore()

        _ = try CodexSessionLogScanner.processThreadRows(
            rows,
            options: LogParseOptions(includeConversationBodies: false),
            fileManager: fileManager,
            cacheStore: cacheStore
        )

        // Touch the file so the signature changes, then defer it by boundary:
        // the cached exact tokens must surface without a content read.
        try append(cumulativeEvent(input: 9999, output: 999) + "\n", to: file)
        let governor = ParserResourceGovernor(limits: .unlimited)
        let result = try CodexSessionLogScanner.processThreadRows(
            rows,
            options: LogParseOptions(
                includeConversationBodies: false,
                minimumFileModificationDate: .distantFuture,
                resourceGovernor: governor
            ),
            fileManager: fileManager,
            cacheStore: cacheStore
        )

        XCTAssertEqual(result.usages.map(\.sessionId), ["thread-boundary-cached"])
        XCTAssertEqual(result.usages.first?.inputTokens, 1000, "boundary defer surfaces cached values, not the new content")
        XCTAssertEqual(governor.consumedBytes, 0)
    }

    func test_processThreadRows_scanFailureWithoutCacheRemainsDeferredAndUncheckpointable() throws {
        let file = try write(cumulativeEvent(input: 1000, output: 100) + "\n", to: "rollout-read-race.jsonl")
        let tracker = ParserFileDiscoveryTracker()
        let governor = ParserResourceGovernor(limits: .unlimited)
        let cacheStore = makeCacheStore()

        let result = try CodexSessionLogScanner.processThreadRows(
            [makeRow(threadId: "thread-read-race", tokensUsed: 10_000, rolloutPath: file.path)],
            options: LogParseOptions(
                includeConversationBodies: false,
                fileDiscoveryTracker: tracker,
                resourceGovernor: governor
            ),
            fileManager: ScanFailingFileManager(unreadablePath: file.path),
            cacheStore: cacheStore
        )

        XCTAssertTrue(result.usages.isEmpty, "a failed exact scan must not masquerade as a successful heuristic row")
        XCTAssertEqual(governor.deferredFileCount, 1)
        XCTAssertTrue(tracker.partialCheckpointFiles.isEmpty, "failed content must remain eligible for retry")
        XCTAssertFalse(tracker.hasAdmittedFiles)
        XCTAssertTrue(cacheStore.load().fileEntries.isEmpty)
    }

    func test_processThreadRows_innerMetadataFailureDoesNotReadChargeOrCheckpoint() throws {
        let file = try write(cumulativeEvent(input: 1_234, output: 56) + "\n", to: "rollout-inner-stat-race.jsonl")
        let faultingFileManager = InnerStatFailingFileManager(targetPath: file.path)
        let tracker = ParserFileDiscoveryTracker()
        let governor = ParserResourceGovernor(limits: .unlimited)
        let metrics = ParserPassMetrics()
        let cacheStore = makeCacheStore(name: "inner-stat-cache.json")

        let result = try CodexSessionLogScanner.processThreadRows(
            [makeRow(threadId: "thread-inner-stat-race", rolloutPath: file.path)],
            options: LogParseOptions(
                includeConversationBodies: false,
                fileDiscoveryTracker: tracker,
                resourceGovernor: governor,
                metrics: metrics
            ),
            fileManager: faultingFileManager,
            cacheStore: cacheStore
        )

        XCTAssertEqual(faultingFileManager.targetStatCount, 2, "the second, scanner-local metadata lookup must hit the injected race")
        XCTAssertTrue(result.usages.isEmpty, "unknown size must defer rather than read the file as zero bytes")
        XCTAssertEqual(governor.consumedBytes, 0, "unread content must never be charged as a zero-byte admission")
        XCTAssertEqual(governor.deferredFileCount, 1)
        XCTAssertEqual(metrics.snapshot().contentReadCount, 0)
        XCTAssertFalse(tracker.hasAdmittedFiles)
        XCTAssertTrue(tracker.partialCheckpointFiles.isEmpty, "metadata races must remain retryable")
        XCTAssertTrue(cacheStore.load().fileEntries.isEmpty)
    }

    func test_processThreadRows_appendAndRewriteChargeOnlyTheBytesActuallyScanned() throws {
        let appendFile = try write(cumulativeEvent(input: 100, output: 10) + "\n", to: "rollout-accounting-append.jsonl")
        let appendRow = makeRow(threadId: "thread-accounting-append", rolloutPath: appendFile.path)
        let appendCache = makeCacheStore(name: "append-accounting-cache.json")
        _ = try CodexSessionLogScanner.processThreadRows(
            [appendRow],
            options: LogParseOptions(includeConversationBodies: false),
            fileManager: fileManager,
            cacheStore: appendCache
        )
        let appendProbeBytes = Int64(try XCTUnwrap(
            appendCache.load().fileEntries[appendFile.standardizedFileURL.path]?.scanState
        ).headDigestLength)

        let appendedTail = cumulativeEvent(input: 200, output: 20) + "\n"
        try append(appendedTail, to: appendFile)
        let appendGovernor = ParserResourceGovernor(limits: .unlimited)
        let appendResult = try CodexSessionLogScanner.processThreadRows(
            [appendRow],
            options: LogParseOptions(includeConversationBodies: false, resourceGovernor: appendGovernor),
            fileManager: fileManager,
            cacheStore: appendCache
        )

        XCTAssertEqual(appendResult.usages.first?.inputTokens, 200)
        XCTAssertEqual(
            appendGovernor.consumedBytes,
            appendProbeBytes + Int64(appendedTail.utf8.count),
            "append resume charges its cached-head validation probe and newly scanned tail"
        )

        let originalRewrite = cumulativeEvent(input: 1_111, output: 11) + "\n"
        let rewriteFile = try write(originalRewrite, to: "rollout-accounting-rewrite.jsonl")
        let rewriteRow = makeRow(threadId: "thread-accounting-rewrite", rolloutPath: rewriteFile.path)
        let rewriteCache = makeCacheStore(name: "rewrite-accounting-cache.json")
        _ = try CodexSessionLogScanner.processThreadRows(
            [rewriteRow],
            options: LogParseOptions(includeConversationBodies: false),
            fileManager: fileManager,
            cacheStore: rewriteCache
        )

        let originalAttributes = try fileManager.attributesOfItem(atPath: rewriteFile.path)
        let originalModificationDate = try XCTUnwrap(originalAttributes[.modificationDate] as? Date)
        let rewrittenContent = cumulativeEvent(input: 2_222, output: 22) + "\n"
        XCTAssertEqual(rewrittenContent.utf8.count, originalRewrite.utf8.count)
        let rewriteHandle = try FileHandle(forWritingTo: rewriteFile)
        try rewriteHandle.write(contentsOf: Data(rewrittenContent.utf8))
        try rewriteHandle.close()
        try fileManager.setAttributes(
            [.modificationDate: originalModificationDate.addingTimeInterval(1)],
            ofItemAtPath: rewriteFile.path
        )

        let rewriteGovernor = ParserResourceGovernor(limits: .unlimited)
        let rewriteResult = try CodexSessionLogScanner.processThreadRows(
            [rewriteRow],
            options: LogParseOptions(includeConversationBodies: false, resourceGovernor: rewriteGovernor),
            fileManager: fileManager,
            cacheStore: rewriteCache
        )

        XCTAssertEqual(rewriteResult.usages.first?.inputTokens, 2_222)
        XCTAssertEqual(rewriteGovernor.consumedBytes, Int64(rewrittenContent.utf8.count), "same-size rewrite charges the full restarted scan")
    }

    func test_processThreadRows_transientTokenScanFailurePreservesCachedExactUsageAndRetries() throws {
        let file = try write(cumulativeEvent(input: 1_000, output: 100) + "\n", to: "rollout-cached-read-race.jsonl")
        let row = makeRow(threadId: "thread-cached-read-race", rolloutPath: file.path)
        let cacheStore = makeCacheStore(name: "cached-read-race-cache.json")
        _ = try CodexSessionLogScanner.processThreadRows(
            [row],
            options: LogParseOptions(includeConversationBodies: false),
            fileManager: fileManager,
            cacheStore: cacheStore
        )
        let cacheBeforeFailure = cacheStore.load()

        try append(cumulativeEvent(input: 5_000, output: 500) + "\n", to: file)
        let faultingFileManager = SequencedExistenceFileManager(targetPath: file.path, failingChecks: [1])
        let tracker = ParserFileDiscoveryTracker()
        let governor = ParserResourceGovernor(limits: .unlimited)
        let failedPass = try CodexSessionLogScanner.processThreadRows(
            [row],
            options: LogParseOptions(
                includeConversationBodies: false,
                fileDiscoveryTracker: tracker,
                resourceGovernor: governor
            ),
            fileManager: faultingFileManager,
            cacheStore: cacheStore
        )

        let preserved = try XCTUnwrap(failedPass.usages.first)
        XCTAssertEqual(preserved.inputTokens, 1_000)
        XCTAssertEqual(preserved.outputTokens, 100)
        XCTAssertEqual(preserved.provenanceMethod, .providerLog)
        XCTAssertEqual(preserved.provenanceConfidence, .exact)
        XCTAssertEqual(cacheStore.load(), cacheBeforeFailure, "a transient read race must not destroy the last exact state")
        XCTAssertEqual(governor.deferredFileCount, 1)
        XCTAssertFalse(tracker.hasAdmittedFiles)
        XCTAssertTrue(tracker.partialCheckpointFiles.isEmpty)

        let recoveredPass = try CodexSessionLogScanner.processThreadRows(
            [row],
            options: LogParseOptions(includeConversationBodies: false),
            fileManager: fileManager,
            cacheStore: cacheStore
        )
        XCTAssertEqual(recoveredPass.usages.first?.inputTokens, 5_000, "the preserved scan state must remain eligible for a later tail retry")
        XCTAssertGreaterThan(
            try XCTUnwrap(cacheStore.load().fileEntries[file.standardizedFileURL.path]?.scanState?.byteOffset),
            try XCTUnwrap(cacheBeforeFailure.fileEntries[file.standardizedFileURL.path]?.scanState?.byteOffset)
        )
    }

    func test_processThreadRows_knownUnchangedBodyDoesNotStarveNewlyDiscoveredConversation() throws {
        let oldContent = [
            cumulativeEvent(input: 100, output: 10),
            messageEvent(role: "user", text: String(repeating: "old ", count: 1_000))
        ].joined(separator: "\n") + "\n"
        let oldFile = try write(oldContent, to: "rollout-known-body.jsonl")
        let oldRow = makeRow(threadId: "thread-known-body", rolloutPath: oldFile.path)
        let cacheStore = makeCacheStore(name: "known-body-cache.json")
        let warmTracker = ParserFileDiscoveryTracker()
        _ = try CodexSessionLogScanner.processThreadRows(
            [oldRow],
            options: LogParseOptions(includeConversationBodies: false, fileDiscoveryTracker: warmTracker),
            fileManager: fileManager,
            cacheStore: cacheStore
        )

        let newContent = [
            cumulativeEvent(input: 200, output: 20),
            messageEvent(role: "user", text: "newly admitted body")
        ].joined(separator: "\n") + "\n"
        let newFile = try write(newContent, to: "rollout-new-body.jsonl")
        let newSize = Int64(newContent.utf8.count)
        XCTAssertGreaterThan(Int64(oldContent.utf8.count), newSize * 2, "fixture must expose starvation if the known body is reread")

        let tracker = ParserFileDiscoveryTracker(knownFiles: warmTracker.discoveredFiles)
        let governor = ParserResourceGovernor(limits: ParserResourceLimits(fileByteBudget: newSize * 2))
        let metrics = ParserPassMetrics()
        let result = try CodexSessionLogScanner.processThreadRows(
            [oldRow, makeRow(threadId: "thread-new-body", rolloutPath: newFile.path)],
            options: LogParseOptions(
                includeConversationBodies: true,
                fileDiscoveryTracker: tracker,
                resourceGovernor: governor,
                metrics: metrics
            ),
            fileManager: fileManager,
            cacheStore: cacheStore
        )

        XCTAssertEqual(result.usages.map(\.sessionId), ["thread-known-body", "thread-new-body"])
        XCTAssertEqual(result.conversations.map(\.sessionId), ["thread-new-body"], "known manifest content stays skipped while newly admitted content emits its body")
        XCTAssertEqual(result.conversations.first?.fullText, "## User\n\nnewly admitted body")
        XCTAssertEqual(governor.consumedBytes, newSize * 2, "only the new file's token and conversation scans consume the pass")
        XCTAssertEqual(governor.deferredFileCount, 0)
        XCTAssertEqual(metrics.snapshot().contentReadCount, 2)
    }

    func test_processThreadRows_conversationOpenFailureAfterExactTokensRemainsUncheckpointableAndRetries() throws {
        let content = [
            cumulativeEvent(input: 700, output: 70),
            messageEvent(role: "user", text: "retry this conversation")
        ].joined(separator: "\n") + "\n"
        let file = try write(content, to: "rollout-conversation-open-race.jsonl")
        let row = makeRow(threadId: "thread-conversation-open-race", rolloutPath: file.path)
        let cacheStore = makeCacheStore(name: "conversation-open-race-cache.json")
        let tracker = ParserFileDiscoveryTracker()
        let governor = ParserResourceGovernor(limits: .unlimited)
        let metrics = ParserPassMetrics()
        let faultingOpener = RecordingFileOpener(failingChecks: [2])

        let failedPass = try CodexSessionLogScanner.processThreadRows(
            [row],
            options: LogParseOptions(
                includeConversationBodies: true,
                fileDiscoveryTracker: tracker,
                resourceGovernor: governor,
                metrics: metrics
            ),
            fileManager: fileManager,
            cacheStore: cacheStore,
            openFileForReading: faultingOpener.open(path:)
        )

        XCTAssertEqual(faultingOpener.openedPaths, [file.path, file.path], "token open succeeds before the requested conversation open fails")
        XCTAssertEqual(failedPass.usages.first?.inputTokens, 700, "the successful token scan remains visible")
        XCTAssertEqual(failedPass.usages.first?.provenanceMethod, .providerLog)
        XCTAssertTrue(failedPass.conversations.isEmpty)
        XCTAssertNotNil(cacheStore.load().fileEntries[file.standardizedFileURL.path]?.tokenUsage, "exact token progress may be cached independently")
        XCTAssertEqual(governor.deferredFileCount, 1)
        XCTAssertEqual(metrics.snapshot().contentReadFailedDeferredCount, 1)
        XCTAssertFalse(tracker.hasAdmittedFiles)
        XCTAssertTrue(tracker.partialCheckpointFiles.isEmpty, "a missing requested body must keep the rollout out of the checkpoint")

        let retryTracker = ParserFileDiscoveryTracker(knownFiles: tracker.partialCheckpointFiles)
        let recoveredPass = try CodexSessionLogScanner.processThreadRows(
            [row],
            options: LogParseOptions(includeConversationBodies: true, fileDiscoveryTracker: retryTracker),
            fileManager: fileManager,
            cacheStore: cacheStore
        )
        XCTAssertEqual(recoveredPass.conversations.map(\.sessionId), ["thread-conversation-open-race"])
        XCTAssertEqual(recoveredPass.conversations.first?.fullText, "## User\n\nretry this conversation")
    }

    func test_processThreadRows_emptyConversationIsSuccessfulAndCheckpointable() throws {
        let file = try write(
            cumulativeEvent(input: 900, output: 90) + "\n",
            to: "rollout-token-only.jsonl"
        )
        let tracker = ParserFileDiscoveryTracker()
        let governor = ParserResourceGovernor(limits: .unlimited)
        let metrics = ParserPassMetrics()
        let result = try CodexSessionLogScanner.processThreadRows(
            [makeRow(threadId: "thread-token-only", rolloutPath: file.path)],
            options: LogParseOptions(
                includeConversationBodies: true,
                fileDiscoveryTracker: tracker,
                resourceGovernor: governor,
                metrics: metrics
            ),
            fileManager: fileManager,
            cacheStore: makeCacheStore(name: "token-only-cache.json")
        )

        XCTAssertEqual(result.usages.first?.inputTokens, 900)
        XCTAssertTrue(result.conversations.isEmpty, "a token-only rollout has no conversation to emit")
        XCTAssertEqual(governor.deferredFileCount, 0)
        XCTAssertEqual(metrics.snapshot().contentReadFailedDeferredCount, 0)
        XCTAssertEqual(
            tracker.partialCheckpointFiles.map(\.path),
            [file.standardizedFileURL.path],
            "a readable rollout with no message turns must advance the manifest"
        )
    }

    func test_processThreadRows_zeroOrExhaustedBudgetNeverOpensFileForHeadProbe() throws {
        let file = try write(cumulativeEvent(input: 1_000, output: 100) + "\n", to: "rollout-head-probe-budget.jsonl")
        let row = makeRow(threadId: "thread-head-probe-budget", rolloutPath: file.path)
        let cacheStore = makeCacheStore(name: "head-probe-budget-cache.json")
        _ = try CodexSessionLogScanner.processThreadRows(
            [row],
            options: LogParseOptions(includeConversationBodies: false),
            fileManager: fileManager,
            cacheStore: cacheStore
        )
        let cacheBeforeDeferral = cacheStore.load()
        try append(cumulativeEvent(input: 5_000, output: 500) + "\n", to: file)

        let zeroBudget = ParserResourceGovernor(limits: ParserResourceLimits(fileByteBudget: 0))
        let exhaustedBudget = ParserResourceGovernor(limits: ParserResourceLimits(fileByteBudget: 1))
        XCTAssertTrue(exhaustedBudget.admitFile(estimatedBytes: 1), "fixture exhausts the second governor before scanning")

        for (name, governor) in [("zero", zeroBudget), ("exhausted", exhaustedBudget)] {
            let opener = RecordingFileOpener()
            let tracker = ParserFileDiscoveryTracker()
            let metrics = ParserPassMetrics()
            let result = try CodexSessionLogScanner.processThreadRows(
                [row],
                options: LogParseOptions(
                    includeConversationBodies: false,
                    fileDiscoveryTracker: tracker,
                    resourceGovernor: governor,
                    metrics: metrics
                ),
                fileManager: fileManager,
                cacheStore: cacheStore,
                openFileForReading: opener.open(path:)
            )

            XCTAssertTrue(opener.openedPaths.isEmpty, "\(name) budget must reject before the rewrite-detection handle is opened")
            XCTAssertEqual(result.usages.first?.inputTokens, 1_000, "\(name) budget keeps cached exact usage")
            XCTAssertEqual(result.usages.first?.provenanceMethod, .providerLog)
            XCTAssertEqual(metrics.snapshot().contentReadCount, 0)
            XCTAssertEqual(metrics.snapshot().contentReadBytes, 0)
            XCTAssertEqual(governor.deferredFileCount, 1)
            XCTAssertFalse(tracker.hasAdmittedFiles)
            XCTAssertTrue(tracker.partialCheckpointFiles.isEmpty)
            XCTAssertEqual(cacheStore.load(), cacheBeforeDeferral)
        }
    }

    func test_processThreadRows_rowWithoutRolloutPath_emitsHeuristicSplit() throws {
        let rows = [makeRow(threadId: "thread-heuristic", tokensUsed: 1000, rolloutPath: nil)]
        let result = try CodexSessionLogScanner.processThreadRows(
            rows,
            options: LogParseOptions(includeConversationBodies: false),
            fileManager: fileManager,
            cacheStore: makeCacheStore()
        )

        XCTAssertEqual(result.usages.count, 1)
        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertEqual(usage.inputTokens, 950, "Codex sessions are heavily input-weighted (~95/5)")
        XCTAssertEqual(usage.outputTokens, 50)
        XCTAssertEqual(usage.provenanceMethod, .heuristicEstimate)
        XCTAssertEqual(usage.provenanceConfidence, .lowConfidenceEstimate)
        XCTAssertEqual(usage.estimatorVersion, "tokens-used-split-v1")
    }
}
