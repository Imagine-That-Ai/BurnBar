import OpenBurnBarCore
import XCTest

// MARK: - CodexSessionLogScannerTests

/// Coverage for the shared Codex rollout scanning engine introduced by the
/// 2026-07-16 resource-exhaustion fix: token semantics for legacy cumulative
/// events and current per-turn delta events, incremental append-only resume,
/// rewrite/truncation detection, and governed thread-row processing (budget
/// deferral, boundary deferral, heuristic fallback).
final class CodexSessionLogScannerTests: XCTestCase {

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

    private func totalAndDeltaUsageEvent(
        totalInput: Int,
        totalOutput: Int,
        totalCachedInput: Int = 0,
        deltaInput: Int,
        deltaOutput: Int,
        deltaCachedInput: Int = 0,
        model: String = "gpt-5.6-sol"
    ) -> String {
        #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(totalInput),"cached_input_tokens":\#(totalCachedInput),"output_tokens":\#(totalOutput)},"last_token_usage":{"input_tokens":\#(deltaInput),"cached_input_tokens":\#(deltaCachedInput),"output_tokens":\#(deltaOutput)},"model_context_window":258400},"model":"\#(model)"}}"#
    }

    private func deltaEvent(input: Int, output: Int, cachedInput: Int = 0) -> String {
        #"{"event_msg": {"last_token_usage": {"input_tokens": \#(input), "cached_input_tokens": \#(cachedInput), "output_tokens": \#(output)}}}"#
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

    func test_scanTokens_deltaBeforeCumulative_keepsDeltaTotals() throws {
        let content = [
            deltaEvent(input: 100, output: 50),
            cumulativeEvent(input: 1000, output: 500)
        ].joined(separator: "\n") + "\n"
        let url = try write(content, to: "cumulative_after_delta.jsonl")

        let result = try XCTUnwrap(try scan(url))
        assertUsage(result.usage, equals: (input: 100, output: 50, cacheRead: 0))
    }

    func test_scanTokens_deltaAfterCumulative_switchesToDeltaTotals() throws {
        let content = [
            cumulativeEvent(input: 1000, output: 500, cachedInput: 200),
            deltaEvent(input: 999, output: 999, cachedInput: 999)
        ].joined(separator: "\n") + "\n"
        let url = try write(content, to: "delta_after_cumulative.jsonl")

        let result = try XCTUnwrap(try scan(url))
        assertUsage(result.usage, equals: (input: 0, output: 999, cacheRead: 999))
    }

    func test_scanTokens_currentTotalAndDeltaEnvelope_usesPerTurnDeltas() throws {
        let content = [
            totalAndDeltaUsageEvent(
                totalInput: 5_003_825_525,
                totalOutput: 7_960_354,
                totalCachedInput: 4_913_935_104,
                deltaInput: 101_630,
                deltaOutput: 285,
                deltaCachedInput: 100_096
            ),
            totalAndDeltaUsageEvent(
                totalInput: 5_003_927_562,
                totalOutput: 7_960_626,
                totalCachedInput: 4_914_035_200,
                deltaInput: 102_037,
                deltaOutput: 272,
                deltaCachedInput: 100_096
            )
        ].joined(separator: "\n") + "\n"
        let url = try write(content, to: "current_codex.jsonl")

        let result = try XCTUnwrap(try scan(url))
        assertUsage(result.usage, equals: (input: 3_475, output: 557, cacheRead: 200_192))
        XCTAssertTrue(result.state.foundCumulative)
        XCTAssertTrue(result.state.foundDelta)
    }

    func test_scanTokens_duplicateTotalAndDeltaEnvelope_isNotDoubleCounted() throws {
        let event = totalAndDeltaUsageEvent(
            totalInput: 5_004_455_498,
            totalOutput: 7_965_804,
            totalCachedInput: 4_914_548_992,
            deltaInput: 109_188,
            deltaOutput: 1_672,
            deltaCachedInput: 106_240
        )
        let url = try write([event, event].joined(separator: "\n") + "\n", to: "duplicate_current_codex.jsonl")

        let result = try XCTUnwrap(try scan(url))
        assertUsage(result.usage, equals: (input: 2_948, output: 1_672, cacheRead: 106_240))
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
        XCTAssertEqual(state.lastTokenEventSignature, other.lastTokenEventSignature, file: file, line: line)
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
        // Segment A is delta-only; segment B introduces a cumulative window
        // counter followed by another delta. Deltas stay authoritative across
        // the resume boundary.
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

        assertUsage(resumed.usage, equals: (input: 130, output: 15, cacheRead: 20), "(resumed)")
        assertUsage(fresh.usage, equals: (input: 130, output: 15, cacheRead: 20), "(fresh)")
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
            schemaVersion: 3,
            logLabel: "CodexSessionLogScannerTests"
        )
    }

    private func makeRow(
        threadId: String,
        model: String = "openai/gpt-5.2-codex",
        tokensUsed: Int = 999,
        rolloutPath: String?
    ) -> CodexThreadRow {
        CodexThreadRow(
            threadId: threadId,
            model: model,
            rawTitle: "title-\(threadId)",
            projectName: "OpenBurnBar",
            tokensUsed: tokensUsed,
            startTime: Date(timeIntervalSince1970: 1_766_577_600),
            endTime: Date(timeIntervalSince1970: 1_766_577_660),
            expandedRolloutPath: rolloutPath
        )
    }

    func test_processThreadRows_budgetDeferral_uncachedRowUsesStateTotal_thenCatchesUp() throws {
        let file1 = try write(cumulativeEvent(input: 1000, output: 100) + "\n", to: "rollout-1.jsonl")
        let file2 = try write(cumulativeEvent(input: 2000, output: 200) + "\n", to: "rollout-2.jsonl")
        let rows = [
            makeRow(threadId: "thread-1", rolloutPath: file1.path),
            makeRow(threadId: "thread-2", rolloutPath: file2.path)
        ]
        let cacheStore = makeCacheStore()

        // Pass 1: a 1-byte budget admits only the first file (the admission
        // that crosses the budget is allowed). The deferred row must still
        // surface Codex's exact state-DB total using a cache-aware split.
        let governor = ParserResourceGovernor(limits: ParserResourceLimits(fileByteBudget: 1))
        let firstPass = try CodexSessionLogScanner.processThreadRows(
            rows,
            options: LogParseOptions(includeConversationBodies: false, resourceGovernor: governor),
            fileManager: fileManager,
            cacheStore: cacheStore
        )

        XCTAssertEqual(firstPass.usages.map(\.sessionId), ["thread-1", "thread-2"])
        XCTAssertEqual(firstPass.usages.first?.inputTokens, 1000)
        XCTAssertEqual(firstPass.usages.first?.provenanceMethod, .providerLog)
        let estimated = try XCTUnwrap(firstPass.usages.last)
        XCTAssertEqual(estimated.totalTokens, 999)
        XCTAssertEqual(estimated.provenanceMethod, .heuristicEstimate)
        XCTAssertEqual(estimated.provenanceConfidence, .lowConfidenceEstimate)
        XCTAssertEqual(estimated.estimatorVersion, "tokens-used-cache-split-v2")
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

    func test_processThreadRows_oversizedColdFileUsesStateTotalWithoutReading() throws {
        let file = try write(cumulativeEvent(input: 1000, output: 100) + "\n", to: "oversized-rollout.jsonl")
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64((16 * 1024 * 1024) + 1))
        try handle.close()
        let row = makeRow(threadId: "thread-oversized", tokensUsed: 10_000, rolloutPath: file.path)
        let governor = ParserResourceGovernor(limits: .unlimited)
        let cacheStore = makeCacheStore()

        let result = try CodexSessionLogScanner.processThreadRows(
            [row],
            options: LogParseOptions(includeConversationBodies: false, resourceGovernor: governor),
            fileManager: fileManager,
            cacheStore: cacheStore
        )

        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertEqual(usage.totalTokens, 10_000)
        XCTAssertEqual(usage.cacheReadTokens, 9_500)
        XCTAssertEqual(usage.provenanceMethod, .heuristicEstimate)
        XCTAssertEqual(governor.consumedBytes, 0)
        XCTAssertEqual(governor.deferredFileCount, 1)
        XCTAssertTrue(cacheStore.load().fileEntries.isEmpty)
    }

    func test_processThreadRows_exactRefinementIsBoundedAcrossFiles() throws {
        let first = try write(cumulativeEvent(input: 900, output: 100) + "\n", to: "bounded-first.jsonl")
        let second = try write(cumulativeEvent(input: 1_800, output: 200) + "\n", to: "bounded-second.jsonl")
        for file in [first, second] {
            let handle = try FileHandle(forWritingTo: file)
            try handle.truncate(atOffset: UInt64(9 * 1024 * 1024))
            try handle.close()
        }
        let rows = [
            makeRow(threadId: "thread-bounded-first", tokensUsed: 1_000, rolloutPath: first.path),
            makeRow(threadId: "thread-bounded-second", tokensUsed: 2_000, rolloutPath: second.path)
        ]
        let governor = ParserResourceGovernor(limits: .unlimited)
        let cacheStore = makeCacheStore()

        let result = try CodexSessionLogScanner.processThreadRows(
            rows,
            options: LogParseOptions(includeConversationBodies: false, resourceGovernor: governor),
            fileManager: fileManager,
            cacheStore: cacheStore
        )

        XCTAssertEqual(result.usages.map(\.totalTokens), [1_000, 2_000])
        XCTAssertEqual(result.usages.map(\.provenanceMethod), [.providerLog, .heuristicEstimate])
        XCTAssertEqual(governor.consumedBytes, 9 * 1024 * 1024)
        XCTAssertEqual(governor.deferredFileCount, 1)
        XCTAssertEqual(cacheStore.load().fileEntries.count, 1)
    }

    func test_processThreadRows_stateTotalAheadOfExactFileAddsEstimatedDelta() throws {
        let file = try write(cumulativeEvent(input: 1000, output: 100) + "\n", to: "state-ahead.jsonl")
        let row = makeRow(threadId: "thread-state-ahead", tokensUsed: 2_200, rolloutPath: file.path)

        let result = try CodexSessionLogScanner.processThreadRows(
            [row],
            options: LogParseOptions(includeConversationBodies: false),
            fileManager: fileManager,
            cacheStore: makeCacheStore()
        )

        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertEqual(usage.totalTokens, 2_200)
        XCTAssertEqual(usage.inputTokens, 1_050)
        XCTAssertEqual(usage.outputTokens, 105)
        XCTAssertEqual(usage.cacheReadTokens, 1_045)
        XCTAssertEqual(usage.provenanceMethod, .heuristicEstimate)
        XCTAssertEqual(usage.estimatorVersion, "tokens-used-cache-split-v2")
    }

    func test_processThreadRows_currentCodexGPT56Logs_areDeltaCountedAndPriced() throws {
        let file = try write(
            [
                totalAndDeltaUsageEvent(
                    totalInput: 5_003_825_525,
                    totalOutput: 7_960_354,
                    totalCachedInput: 4_913_935_104,
                    deltaInput: 101_630,
                    deltaOutput: 285,
                    deltaCachedInput: 100_096
                ),
                totalAndDeltaUsageEvent(
                    totalInput: 5_003_927_562,
                    totalOutput: 7_960_626,
                    totalCachedInput: 4_914_035_200,
                    deltaInput: 102_037,
                    deltaOutput: 272,
                    deltaCachedInput: 100_096
                )
            ].joined(separator: "\n") + "\n",
            to: "gpt56-sol-rollout.jsonl"
        )
        let rows = [makeRow(threadId: "thread-gpt56-sol", model: "gpt-5.6-sol", rolloutPath: file.path)]

        let result = try CodexSessionLogScanner.processThreadRows(
            rows,
            options: LogParseOptions(includeConversationBodies: false),
            fileManager: fileManager,
            cacheStore: makeCacheStore()
        )

        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertEqual(usage.inputTokens, 3_475)
        XCTAssertEqual(usage.outputTokens, 557)
        XCTAssertEqual(usage.cacheReadTokens, 200_192)
        XCTAssertEqual(usage.costUSD, 0.134181, accuracy: 0.000_001)
    }

    func test_processThreadRows_boundaryDefer_uncachedFileUsesStateTotalWithoutReading() throws {
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

        XCTAssertEqual(result.usages.map(\.sessionId), ["thread-boundary"])
        XCTAssertEqual(result.usages.first?.totalTokens, 999)
        XCTAssertEqual(result.usages.first?.provenanceMethod, .heuristicEstimate)
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
        XCTAssertEqual(usage.inputTokens, 45)
        XCTAssertEqual(usage.outputTokens, 5)
        XCTAssertEqual(usage.cacheReadTokens, 950)
        XCTAssertEqual(usage.provenanceMethod, .heuristicEstimate)
        XCTAssertEqual(usage.provenanceConfidence, .lowConfidenceEstimate)
        XCTAssertEqual(usage.estimatorVersion, "tokens-used-cache-split-v2")
    }
}
