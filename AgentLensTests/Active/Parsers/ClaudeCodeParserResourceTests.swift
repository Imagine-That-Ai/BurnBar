import OpenBurnBarCore
import XCTest
@testable import OpenBurnBarLogParsers

// MARK: - ClaudeCodeParserResourceTests

/// Coverage for the reworked `ClaudeCodeParser` (2026-07-16 resource-
/// exhaustion fix): usage parity between bodies-on/off passes, incremental
/// scan state for files at/above the 8MB threshold (including usage dedupe
/// across the resume boundary), the never-cache-conversation privacy
/// invariant, and byte-budget deferral with cached-usage fallback.
final class ClaudeCodeParserResourceTests: XCTestCase {

    private var tempRoot: URL!
    private var projectsRoot: URL!
    private var projectDir: URL!
    private let fileManager = FileManager.default
    private let encodedProjectName = "-Users-test-Documents-TestProject"
    private let decodedProjectName = "~/Documents/TestProject"

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("openburnbar-claude-resource-tests-\(UUID().uuidString)", isDirectory: true)
        projectsRoot = tempRoot.appendingPathComponent("projects", isDirectory: true)
        projectDir = projectsRoot.appendingPathComponent(encodedProjectName, isDirectory: true)
        try fileManager.createDirectory(at: projectDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: tempRoot)
        try super.tearDownWithError()
    }

    // MARK: - Fixture helpers

    private func assistantUsageLine(
        messageId: String,
        requestId: String,
        input: Int,
        output: Int,
        cacheCreation: Int = 0,
        cacheRead: Int = 0,
        timestamp: String = "2026-05-04T08:00:01Z",
        model: String = "claude-sonnet-4-20250514",
        text: String = "Done."
    ) -> String {
        #"{"type":"assistant","requestId":"\#(requestId)","timestamp":"\#(timestamp)","message":{"role":"assistant","id":"\#(messageId)","model":"\#(model)","content":[{"type":"text","text":"\#(text)"}],"usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_creation_input_tokens":\#(cacheCreation),"cache_read_input_tokens":\#(cacheRead)}}}"#
    }

    private func userLine(text: String, timestamp: String = "2026-05-04T08:00:00Z") -> String {
        #"{"type":"user","timestamp":"\#(timestamp)","message":{"role":"user","content":[{"type":"text","text":"\#(text)"}]}}"#
    }

    /// A filler line that can never contribute usage (no `"usage"` key) —
    /// used to pad session files past the incremental-scan threshold.
    private var fillerLine: String {
        #"{"type":"progress","pad":"\#(String(repeating: "x", count: 1024))"}"#
    }

    @discardableResult
    private func writeSession(_ lines: [String], name: String) throws -> URL {
        let url = projectDir.appendingPathComponent("\(name).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func append(_ lines: [String], to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    /// Pads a session file with filler lines until it crosses the parser's
    /// incremental-scan threshold (8MB), using bulk string repetition so the
    /// fixture builds in milliseconds.
    private func padPastIncrementalThreshold(_ url: URL) throws {
        let block = fillerLine + "\n"
        let targetBytes = Int(ClaudeCodeParser.incrementalScanThresholdBytes) + 512 * 1024
        let repeats = targetBytes / block.utf8.count + 1
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(String(repeating: block, count: repeats).utf8))
    }

    private func makeParser(supportName: String) -> (parser: ClaudeCodeParser, cacheURL: URL) {
        let appPaths = OpenBurnBarAppPaths(
            applicationSupportRoot: tempRoot.appendingPathComponent(supportName, isDirectory: true)
        )
        let parser = ClaudeCodeParser(
            fileManager: fileManager,
            appPaths: appPaths,
            projectsDirectoryOverride: projectsRoot
        )
        return (parser, appPaths.claudeCodeParserCacheURL)
    }

    /// Decodes the binary-plist parser cache and returns the raw `scanState`
    /// dictionary for `sessionFile`, or nil when the entry carries none.
    private func cachedScanState(cacheURL: URL, sessionFile: URL) throws -> [String: Any]? {
        let root = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: Data(contentsOf: cacheURL), options: [], format: nil
            ) as? [String: Any]
        )
        let entries = try XCTUnwrap(root["fileEntries"] as? [String: Any])
        let entry = try XCTUnwrap(
            entries[sessionFile.standardizedFileURL.path] as? [String: Any],
            "cache must contain an entry for \(sessionFile.lastPathComponent)"
        )
        return entry["scanState"] as? [String: Any]
    }

    private func assertUsagesMatch(
        _ lhs: [TokenUsage],
        _ rhs: [TokenUsage],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let sortedLHS = lhs.sorted { $0.sessionId < $1.sessionId }
        let sortedRHS = rhs.sorted { $0.sessionId < $1.sessionId }
        XCTAssertEqual(sortedLHS.map(\.sessionId), sortedRHS.map(\.sessionId), file: file, line: line)
        for (a, b) in zip(sortedLHS, sortedRHS) {
            XCTAssertEqual(a.inputTokens, b.inputTokens, "\(a.sessionId) input", file: file, line: line)
            XCTAssertEqual(a.outputTokens, b.outputTokens, "\(a.sessionId) output", file: file, line: line)
            XCTAssertEqual(a.cacheCreationTokens, b.cacheCreationTokens, "\(a.sessionId) cacheCreation", file: file, line: line)
            XCTAssertEqual(a.cacheReadTokens, b.cacheReadTokens, "\(a.sessionId) cacheRead", file: file, line: line)
            XCTAssertEqual(a.model, b.model, "\(a.sessionId) model", file: file, line: line)
            XCTAssertEqual(a.projectName, b.projectName, "\(a.sessionId) project", file: file, line: line)
            XCTAssertEqual(a.startTime, b.startTime, "\(a.sessionId) startTime", file: file, line: line)
            XCTAssertEqual(a.endTime, b.endTime, "\(a.sessionId) endTime", file: file, line: line)
            XCTAssertEqual(a.cost, b.cost, accuracy: 1e-9, "\(a.sessionId) cost", file: file, line: line)
        }
    }

    // MARK: - Usage parity: bodies on/off

    func test_usageOnlyPass_matchesBodiesPassUsages_andReturnsNoConversations() async throws {
        try writeSession(
            [
                userLine(text: "First request"),
                assistantUsageLine(messageId: "msg_a1", requestId: "req_a1", input: 100, output: 40),
                assistantUsageLine(
                    messageId: "msg_a2", requestId: "req_a2",
                    input: 60, output: 25, timestamp: "2026-05-04T08:00:05Z"
                )
            ],
            name: "session-a"
        )
        try writeSession(
            [
                userLine(text: "Second request"),
                assistantUsageLine(
                    messageId: "msg_b1", requestId: "req_b1",
                    input: 30, output: 10, cacheCreation: 1000, cacheRead: 5000
                )
            ],
            name: "session-b"
        )

        let (parser, _) = makeParser(supportName: "support-parity")

        let usageOnly = try await parser.parse(options: LogParseOptions(includeConversationBodies: false))
        XCTAssertTrue(usageOnly.conversations.isEmpty, "usage-only passes skip conversation accumulation entirely")
        XCTAssertEqual(usageOnly.usages.count, 2)

        let withBodies = try await parser.parse(options: LogParseOptions(includeConversationBodies: true))
        XCTAssertEqual(withBodies.conversations.count, 2)
        XCTAssertEqual(
            Set(withBodies.conversations.map(\.sessionId)),
            ["session-a", "session-b"]
        )

        // The usage-only prefilter ("usage"-key byte scan) must not change
        // any extracted number, model, or timestamp.
        assertUsagesMatch(usageOnly.usages, withBodies.usages)

        let sessionA = try XCTUnwrap(usageOnly.usages.first { $0.sessionId == "session-a" })
        XCTAssertEqual(sessionA.inputTokens, 160)
        XCTAssertEqual(sessionA.outputTokens, 65)
        XCTAssertEqual(sessionA.projectName, decodedProjectName)
        let sessionB = try XCTUnwrap(usageOnly.usages.first { $0.sessionId == "session-b" })
        XCTAssertEqual(sessionB.cacheCreationTokens, 1000)
        XCTAssertEqual(sessionB.cacheReadTokens, 5000)
    }

    // MARK: - Incremental scan state (>= 8MB)

    func test_dedupeByMessageAndRequestId_holdsAcrossIncrementalResumeBoundary() async throws {
        // A large transcript whose duplicate usage chunk (same
        // messageID:requestId) appears both BEFORE the first pass's persisted
        // offset and again in the appended tail: the persisted FNV-1a hash
        // set must suppress the re-sent chunk on the resumed pass.
        let sessionURL = try writeSession(
            [assistantUsageLine(messageId: "msg_dup", requestId: "req_dup", input: 100, output: 40)],
            name: "session-big-dedupe"
        )
        try padPastIncrementalThreshold(sessionURL)
        try append(
            [
                assistantUsageLine(
                    messageId: "msg_dup", requestId: "req_dup",
                    input: 100, output: 40, timestamp: "2026-05-04T08:00:02Z"
                )
            ],
            to: sessionURL
        )

        let (incrementalParser, cacheURL) = makeParser(supportName: "support-dedupe")
        let firstPass = try await incrementalParser.parse(options: LogParseOptions(includeConversationBodies: false))
        XCTAssertEqual(firstPass.usages.count, 1)
        XCTAssertEqual(firstPass.usages.first?.inputTokens, 100, "duplicate usage chunk counted once in the full scan")
        XCTAssertEqual(firstPass.usages.first?.outputTokens, 40)

        // Pin the incremental machinery on: a >=8MB file must persist scan
        // state whose offset covers the whole scanned file and whose dedupe
        // hash set carries exactly the one identity seen so far.
        let sizeAfterFirstPass = try XCTUnwrap(
            (fileManager.attributesOfItem(atPath: sessionURL.path))[.size] as? Int64
        )
        let persistedState = try XCTUnwrap(cachedScanState(cacheURL: cacheURL, sessionFile: sessionURL))
        XCTAssertEqual(persistedState["byteOffset"] as? Int64, sizeAfterFirstPass)
        XCTAssertEqual((persistedState["seenUsageKeyHashes"] as? [Any])?.count, 1)

        // Live writer re-sends the duplicate chunk and one genuinely new one.
        try append(
            [
                assistantUsageLine(
                    messageId: "msg_dup", requestId: "req_dup",
                    input: 100, output: 40, timestamp: "2026-05-04T08:00:03Z"
                ),
                assistantUsageLine(
                    messageId: "msg_2", requestId: "req_2",
                    input: 7, output: 3, timestamp: "2026-05-04T08:00:04Z"
                )
            ],
            to: sessionURL
        )

        let resumedPass = try await incrementalParser.parse(options: LogParseOptions(includeConversationBodies: false))
        XCTAssertEqual(resumedPass.usages.count, 1)
        XCTAssertEqual(resumedPass.usages.first?.inputTokens, 107, "resumed pass dedupes against hashes persisted before the boundary")
        XCTAssertEqual(resumedPass.usages.first?.outputTokens, 43)

        // Ground truth: a cold parser (fresh cache) full-scans the final file.
        let (freshParser, _) = makeParser(supportName: "support-dedupe-fresh")
        let freshPass = try await freshParser.parse(options: LogParseOptions(includeConversationBodies: false))
        assertUsagesMatch(resumedPass.usages, freshPass.usages)
    }

    func test_incrementalResumeOnLargeFile_equalsFreshFullScan() async throws {
        let sessionURL = try writeSession(
            [
                assistantUsageLine(
                    messageId: "msg_1", requestId: "req_1",
                    input: 50, output: 5, timestamp: "2026-05-04T08:00:01Z"
                )
            ],
            name: "session-big-append"
        )
        try padPastIncrementalThreshold(sessionURL)

        let (incrementalParser, _) = makeParser(supportName: "support-append")
        let firstPass = try await incrementalParser.parse(options: LogParseOptions(includeConversationBodies: false))
        XCTAssertEqual(firstPass.usages.first?.inputTokens, 50)

        try append(
            [
                assistantUsageLine(
                    messageId: "msg_2", requestId: "req_2",
                    input: 60, output: 6, timestamp: "2026-05-04T08:00:07Z"
                ),
                assistantUsageLine(
                    messageId: "msg_3", requestId: "req_3",
                    input: 70, output: 7, timestamp: "2026-05-04T08:00:09Z"
                )
            ],
            to: sessionURL
        )

        let resumedPass = try await incrementalParser.parse(options: LogParseOptions(includeConversationBodies: false))
        let (freshParser, _) = makeParser(supportName: "support-append-fresh")
        let freshPass = try await freshParser.parse(options: LogParseOptions(includeConversationBodies: false))

        XCTAssertEqual(resumedPass.usages.count, 1)
        XCTAssertEqual(resumedPass.usages.first?.inputTokens, 180)
        XCTAssertEqual(resumedPass.usages.first?.outputTokens, 18)
        XCTAssertEqual(
            resumedPass.usages.first?.startTime,
            ThreadSafeISO8601DateFormatter.parse("2026-05-04T08:00:01Z")
        )
        XCTAssertEqual(
            resumedPass.usages.first?.endTime,
            ThreadSafeISO8601DateFormatter.parse("2026-05-04T08:00:09Z")
        )
        assertUsagesMatch(resumedPass.usages, freshPass.usages)
    }

    // MARK: - Privacy: conversation bodies never reach the disk cache

    func test_bodiesPass_neverPersistsConversationContentToParserCache() async throws {
        let privatePrompt = "private-claude-prompt-\(UUID().uuidString)"
        let privateReply = "private-claude-reply-\(UUID().uuidString)"
        try writeSession(
            [
                userLine(text: privatePrompt),
                assistantUsageLine(
                    messageId: "msg_p1", requestId: "req_p1",
                    input: 120, output: 45, text: privateReply
                )
            ],
            name: "session-private"
        )

        let (parser, cacheURL) = makeParser(supportName: "support-privacy")
        let result = try await parser.parse(options: LogParseOptions(includeConversationBodies: true))

        // The conversation is returned in memory…
        XCTAssertEqual(result.conversations.count, 1)
        XCTAssertEqual(result.conversations.first?.fullText.contains(privatePrompt), true)
        XCTAssertEqual(result.conversations.first?.fullText.contains(privateReply), true)

        // …but the persisted cache carries usage + scan state only.
        let rawCache = try Data(contentsOf: cacheURL)
        XCTAssertFalse(rawCache.range(of: Data(privatePrompt.utf8)) != nil, "prompt text must never reach the parser cache")
        XCTAssertFalse(rawCache.range(of: Data(privateReply.utf8)) != nil, "assistant text must never reach the parser cache")

        let root = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: rawCache, options: [], format: nil) as? [String: Any]
        )
        XCTAssertEqual(root["schemaVersion"] as? Int, 3)
        let entries = try XCTUnwrap(root["fileEntries"] as? [String: Any])
        XCTAssertFalse(entries.isEmpty, "the pass must have cached the session's usage")
        for (path, value) in entries {
            let entry = try XCTUnwrap(value as? [String: Any], path)
            XCTAssertNil(entry["conversation"], "cache entries can no longer hold a conversation body (\(path))")
            XCTAssertNotNil(entry["usage"], "usage must still be cached (\(path))")
            XCTAssertNil(
                entry["scanState"],
                "files below the 8MB incremental threshold must not carry scan state (\(path))"
            )
        }
    }

    // MARK: - Byte-budget deferral

    func test_budgetDefer_uncachedSecondFileEmitsNothing_untilNextPass() async throws {
        try writeSession(
            [assistantUsageLine(messageId: "msg_s1", requestId: "req_s1", input: 100, output: 10)],
            name: "session-1"
        )
        try writeSession(
            [assistantUsageLine(messageId: "msg_s2", requestId: "req_s2", input: 200, output: 20)],
            name: "session-2"
        )

        let (parser, _) = makeParser(supportName: "support-budget")

        // 1-byte budget: exactly one of the two (directory enumeration order
        // is filesystem-defined) is admitted; the other, uncached, emits
        // nothing rather than a partial/heuristic row.
        let starvedGovernor = ParserResourceGovernor(limits: ParserResourceLimits(fileByteBudget: 1))
        let starved = try await parser.parse(options: LogParseOptions(
            includeConversationBodies: false,
            resourceGovernor: starvedGovernor
        ))
        XCTAssertEqual(starved.usages.count, 1, "budget admits exactly one uncached file")
        XCTAssertEqual(starvedGovernor.deferredFileCount, 1)

        // The next (ungoverned) pass converges on the full corpus.
        let caughtUp = try await parser.parse(options: LogParseOptions(includeConversationBodies: false))
        XCTAssertEqual(Set(caughtUp.usages.map(\.sessionId)), ["session-1", "session-2"])
    }

    func test_budgetDefer_changedFileFallsBackToCachedUsage_thenRefreshes() async throws {
        let session1 = try writeSession(
            [assistantUsageLine(messageId: "msg_c1", requestId: "req_c1", input: 100, output: 10)],
            name: "session-cached-1"
        )
        try writeSession(
            [assistantUsageLine(messageId: "msg_c2", requestId: "req_c2", input: 300, output: 30)],
            name: "session-cached-2"
        )

        let (parser, _) = makeParser(supportName: "support-cached-fallback")

        // Prime the cache with an ungoverned pass.
        let primed = try await parser.parse(options: LogParseOptions(includeConversationBodies: false))
        XCTAssertEqual(primed.usages.count, 2)

        // Grow one file, then run with a zero budget: the changed file cannot
        // be read, so its CACHED usage must still be emitted (stale values
        // beat a hole in the dashboard), and the unchanged file stays a pure
        // cache hit.
        try append(
            [
                assistantUsageLine(
                    messageId: "msg_c1b", requestId: "req_c1b",
                    input: 50, output: 5, timestamp: "2026-05-04T08:00:09Z"
                )
            ],
            to: session1
        )
        let starvedGovernor = ParserResourceGovernor(limits: ParserResourceLimits(fileByteBudget: 0))
        let starved = try await parser.parse(options: LogParseOptions(
            includeConversationBodies: false,
            resourceGovernor: starvedGovernor
        ))
        XCTAssertEqual(starved.usages.count, 2)
        let staleUsage = try XCTUnwrap(starved.usages.first { $0.sessionId == "session-cached-1" })
        XCTAssertEqual(staleUsage.inputTokens, 100, "budget-starved pass keeps the cached (pre-append) usage")
        XCTAssertEqual(starvedGovernor.deferredFileCount, 1, "only the changed file needs (and is denied) admission")

        // The next ungoverned pass picks the appended chunk up.
        let refreshed = try await parser.parse(options: LogParseOptions(includeConversationBodies: false))
        let refreshedUsage = try XCTUnwrap(refreshed.usages.first { $0.sessionId == "session-cached-1" })
        XCTAssertEqual(refreshedUsage.inputTokens, 150)
        XCTAssertEqual(refreshedUsage.outputTokens, 15)
    }
}
