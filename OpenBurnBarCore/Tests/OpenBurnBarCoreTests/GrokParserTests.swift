import XCTest
@testable import OpenBurnBarCore
@testable import OpenBurnBarLogParsers

final class GrokParserTests: XCTestCase {

    func test_parse_prefersExactCumulativeTurnUsageOverContextWindowSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-grok-exact-usage-\(UUID().uuidString)", isDirectory: true)
        let session = root
            .appendingPathComponent("%2Ftmp%2Fgrok-project", isDirectory: true)
            .appendingPathComponent("grok-exact-session", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try #"{"info":{"id":"grok-exact-session","cwd":"/tmp/grok-project"},"current_model_id":"grok-4.5","created_at":"2026-07-13T01:00:00Z","updated_at":"2026-07-13T01:05:00Z"}"#
            .write(to: session.appendingPathComponent("summary.json"), atomically: true, encoding: .utf8)
        try #"{"contextTokensUsed":42,"userMessageCount":1,"assistantMessageCount":1}"#
            .write(to: session.appendingPathComponent("signals.json"), atomically: true, encoding: .utf8)

        let updates = [
            #"{"method":"session/update","params":{"update":{"sessionUpdate":"turn_completed","prompt_id":"turn-1","usage":{"inputTokens":1000,"outputTokens":200,"totalTokens":1200,"cachedReadTokens":600,"reasoningTokens":50}}}}"#,
            #"{"method":"session/update","params":{"update":{"sessionUpdate":"turn_completed","prompt_id":"turn-2","usage":{"inputTokens":500,"outputTokens":100,"totalTokens":600,"cachedReadTokens":300,"reasoningTokens":20}}}}"#
        ].joined(separator: "\n")
        try updates.write(
            to: session.appendingPathComponent("updates.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let result = try await GrokParser(logDirectoryOverride: root.path).parse()
        let usage = try XCTUnwrap(result.usages.first)

        XCTAssertEqual(usage.inputTokens, 600)
        XCTAssertEqual(usage.outputTokens, 230)
        XCTAssertEqual(usage.cacheReadTokens, 900)
        XCTAssertEqual(usage.reasoningTokens, 70)
        XCTAssertEqual(usage.totalTokens, 1_800)
        XCTAssertEqual(usage.provenanceMethod, .providerLog)
        XCTAssertEqual(usage.provenanceConfidence, .exact)
    }

    func test_parse_doesNotDoubleCountChildUsageAggregatedIntoParent() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-grok-child-usage-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent("%2Ftmp%2Fgrok-project", isDirectory: true)
        let parent = workspace.appendingPathComponent("parent-session", isDirectory: true)
        let child = root
            .appendingPathComponent("%2Ftmp%2Fgrok-project%2Fworktree", isDirectory: true)
            .appendingPathComponent("child-session", isDirectory: true)
        let childMetadata = parent
            .appendingPathComponent("subagents", isDirectory: true)
            .appendingPathComponent("child-session", isDirectory: true)
        try FileManager.default.createDirectory(at: childMetadata, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for (directory, sessionID) in [(parent, "parent-session"), (child, "child-session")] {
            try """
            {"info":{"id":"\(sessionID)","cwd":"/tmp/grok-project"},"current_model_id":"grok-4.5"}
            """.write(to: directory.appendingPathComponent("summary.json"), atomically: true, encoding: .utf8)
            let usage = sessionID == "parent-session"
                ? #"{"inputTokens":1500,"outputTokens":300,"totalTokens":1800,"cachedReadTokens":900,"reasoningTokens":75}"#
                : #"{"inputTokens":1000,"outputTokens":200,"totalTokens":1200,"cachedReadTokens":600,"reasoningTokens":50}"#
            try """
            {"method":"session/update","params":{"update":{"sessionUpdate":"turn_completed","prompt_id":"turn-1","usage":\(usage)}}}
            """
                .write(to: directory.appendingPathComponent("updates.jsonl"), atomically: true, encoding: .utf8)
        }
        try #"{"parent_session_id":"parent-session","child_session_id":"child-session"}"#
            .write(to: childMetadata.appendingPathComponent("meta.json"), atomically: true, encoding: .utf8)

        let result = try await GrokParser(logDirectoryOverride: root.path).parse()

        XCTAssertEqual(Set(result.usages.map(\.sessionId)), ["parent-session", "child-session"])
        XCTAssertEqual(result.usages.map(\.totalTokens).reduce(0, +), 1_800)
        XCTAssertEqual(result.usages.first { $0.sessionId == "parent-session" }?.totalTokens, 600)
        XCTAssertEqual(result.usages.first { $0.sessionId == "child-session" }?.totalTokens, 1_200)
    }

    func test_parse_emitsExactZeroParentCorrectionWhenChildConsumesAllUsage() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-grok-zero-parent-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent("%2Ftmp%2Fgrok-project", isDirectory: true)
        let parent = workspace.appendingPathComponent("parent-session", isDirectory: true)
        let child = workspace.appendingPathComponent("child-session", isDirectory: true)
        let childMetadata = parent
            .appendingPathComponent("subagents", isDirectory: true)
            .appendingPathComponent("child-session", isDirectory: true)
        try FileManager.default.createDirectory(at: childMetadata, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for (directory, sessionID) in [(parent, "parent-session"), (child, "child-session")] {
            try """
            {"info":{"id":"\(sessionID)","cwd":"/tmp/grok-project"},"current_model_id":"grok-4.5"}
            """.write(to: directory.appendingPathComponent("summary.json"), atomically: true, encoding: .utf8)
            try #"{"method":"session/update","params":{"update":{"sessionUpdate":"turn_completed","prompt_id":"turn-1","usage":{"inputTokens":1000,"outputTokens":200,"totalTokens":1200,"cachedReadTokens":600,"reasoningTokens":50}}}}"#
                .write(to: directory.appendingPathComponent("updates.jsonl"), atomically: true, encoding: .utf8)
        }
        try #"{"parent_session_id":"parent-session","child_session_id":"child-session"}"#
            .write(to: childMetadata.appendingPathComponent("meta.json"), atomically: true, encoding: .utf8)

        let result = try await GrokParser(logDirectoryOverride: root.path).parse()

        let parentUsage = try XCTUnwrap(result.usages.first { $0.sessionId == "parent-session" })
        XCTAssertEqual(parentUsage.totalTokens, 0)
        XCTAssertEqual(parentUsage.provenanceConfidence, .exact)
        XCTAssertEqual(result.usages.first { $0.sessionId == "child-session" }?.totalTokens, 1_200)
    }

    // MARK: - ISO8601 timestamp parsing

    /// parseISO8601 routes through the shared ThreadSafeISO8601DateFormatter;
    /// it must accept both fractional and non-fractional internet date-times
    /// and produce the same Dates the previous per-call formatters did.
    func test_parseISO8601_fractionalAndBasicMatchPreviousBehavior() {
        let parser = GrokParser()

        // 2026-07-06T12:34:56Z == 1_783_341_296 since epoch.
        let fractional = parser.parseISO8601("2026-07-06T12:34:56.789Z")
        XCTAssertNotNil(fractional)
        XCTAssertEqual(fractional?.timeIntervalSince1970 ?? 0, 1_783_341_296.789, accuracy: 0.0005)

        let basic = parser.parseISO8601("2026-07-06T12:34:56Z")
        XCTAssertEqual(basic, Date(timeIntervalSince1970: 1_783_341_296))
    }

    func test_parseISO8601_acceptsOffsetsAndTrimsWhitespace() {
        let parser = GrokParser()

        // +08:00 offset resolves to the same instant as 04:34:56Z.
        XCTAssertEqual(
            parser.parseISO8601("2026-07-06T12:34:56+08:00"),
            Date(timeIntervalSince1970: 1_783_341_296 - 8 * 3600)
        )
        XCTAssertEqual(
            parser.parseISO8601("  2026-07-06T12:34:56Z\n"),
            Date(timeIntervalSince1970: 1_783_341_296)
        )
    }

    func test_sessionLooksIdle_skipsSessionsOlderThanTheLiveCutoff() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-grok-idle-\(UUID().uuidString)", isDirectory: true)
        let session = root.appendingPathComponent("idle-session", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let old = Date(timeIntervalSince1970: 1_600_000_000)
        let updates = session.appendingPathComponent("updates.jsonl")
        let summary = session.appendingPathComponent("summary.json")
        FileManager.default.createFile(atPath: updates.path, contents: Data("{}".utf8))
        FileManager.default.createFile(atPath: summary.path, contents: Data("{}".utf8))
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: updates.path)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: summary.path)

        XCTAssertTrue(
            GrokParser.sessionLooksIdle(
                session,
                cutoff: Date(timeIntervalSince1970: 1_700_000_000),
                fileManager: .default
            )
        )
        XCTAssertFalse(
            GrokParser.sessionLooksIdle(session, cutoff: nil, fileManager: .default)
        )
    }

    func test_sessionLooksIdle_treatsChatHistoryTouchAsLive() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-grok-idle-chat-\(UUID().uuidString)", isDirectory: true)
        let session = root.appendingPathComponent("idle-session", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let old = Date(timeIntervalSince1970: 1_600_000_000)
        let recent = Date(timeIntervalSince1970: 1_800_000_000)
        for name in ["updates.jsonl", "summary.json", "chat_history.jsonl"] {
            let file = session.appendingPathComponent(name)
            FileManager.default.createFile(atPath: file.path, contents: Data("{}".utf8))
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file.path)
        }
        try FileManager.default.setAttributes(
            [.modificationDate: recent],
            ofItemAtPath: session.appendingPathComponent("chat_history.jsonl").path
        )

        XCTAssertFalse(
            GrokParser.sessionLooksIdle(
                session,
                cutoff: Date(timeIntervalSince1970: 1_700_000_000),
                fileManager: .default
            )
        )
    }

    func test_sessionSignature_includesChatHistory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-grok-sig-chat-\(UUID().uuidString)", isDirectory: true)
        let session = root.appendingPathComponent("sig-session", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try #"{"ok":true}"#.write(to: session.appendingPathComponent("updates.jsonl"), atomically: true, encoding: .utf8)
        try #"{"ok":true}"#.write(to: session.appendingPathComponent("summary.json"), atomically: true, encoding: .utf8)
        try #"{"ok":true}"#.write(to: session.appendingPathComponent("signals.json"), atomically: true, encoding: .utf8)
        try #"{"turn":1}"#.write(to: session.appendingPathComponent("chat_history.jsonl"), atomically: true, encoding: .utf8)

        let before = GrokParser.sessionSignature(sessionDir: session)
        XCTAssertNotNil(before)
        XCTAssertNotNil(before?.transcript)

        try #"{"turn":1}\n{"turn":2}"#.write(
            to: session.appendingPathComponent("chat_history.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        let after = GrokParser.sessionSignature(sessionDir: session)
        XCTAssertNotEqual(before, after, "chat_history.jsonl growth must bust the Grok cache signature")
    }

    func test_parse_doesNotCacheSkipWhenOnlyChatHistoryChanges() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-grok-cache-chat-\(UUID().uuidString)", isDirectory: true)
        let session = root
            .appendingPathComponent("%2Ftmp%2Fgrok-project", isDirectory: true)
            .appendingPathComponent("chat-session", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try #"{"info":{"id":"chat-session","cwd":"/tmp/grok-project"},"current_model_id":"grok-4.5","created_at":"2026-07-13T01:00:00Z","updated_at":"2026-07-13T01:05:00Z"}"#
            .write(to: session.appendingPathComponent("summary.json"), atomically: true, encoding: .utf8)
        try #"{"method":"session/update","params":{"update":{"sessionUpdate":"turn_completed","prompt_id":"turn-1","usage":{"inputTokens":100,"outputTokens":20,"totalTokens":120,"cachedReadTokens":0,"reasoningTokens":0}}}}"#
            .write(to: session.appendingPathComponent("updates.jsonl"), atomically: true, encoding: .utf8)
        try #"{"role":"user","content":"hi"}"#
            .write(to: session.appendingPathComponent("chat_history.jsonl"), atomically: true, encoding: .utf8)

        let parser = GrokParser(logDirectoryOverride: root.path)
        let first = try await parser.parse(options: LogParseOptions(includeConversationBodies: false))
        XCTAssertEqual(first.usages.map(\.sessionId), ["chat-session"])

        try #"{"role":"user","content":"hi"}\n{"role":"assistant","content":"more spend"}"#
            .write(to: session.appendingPathComponent("chat_history.jsonl"), atomically: true, encoding: .utf8)

        let metrics = ParserPassMetrics()
        _ = try await parser.parse(options: LogParseOptions(
            includeConversationBodies: false,
            metrics: metrics,
            includeCachedUnchangedUsages: false
        ))
        XCTAssertGreaterThan(
            metrics.snapshot().contentReadCount,
            0,
            "chat_history.jsonl change must not cache-skip the Grok session"
        )
    }

    func test_parse_skipsUnchangedLeafSessionsOnTheSecondPass() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-grok-cache-\(UUID().uuidString)", isDirectory: true)
        let session = root
            .appendingPathComponent("%2Ftmp%2Fgrok-project", isDirectory: true)
            .appendingPathComponent("cached-session", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try #"{"info":{"id":"cached-session","cwd":"/tmp/grok-project"},"current_model_id":"grok-4.5","created_at":"2026-07-13T01:00:00Z","updated_at":"2026-07-13T01:05:00Z"}"#
            .write(to: session.appendingPathComponent("summary.json"), atomically: true, encoding: .utf8)
        try #"{"method":"session/update","params":{"update":{"sessionUpdate":"turn_completed","prompt_id":"turn-1","usage":{"inputTokens":100,"outputTokens":20,"totalTokens":120,"cachedReadTokens":0,"reasoningTokens":0}}}}"#
            .write(to: session.appendingPathComponent("updates.jsonl"), atomically: true, encoding: .utf8)

        let parser = GrokParser(logDirectoryOverride: root.path)
        let first = try await parser.parse(options: LogParseOptions(includeConversationBodies: false))
        XCTAssertEqual(first.usages.map(\.sessionId), ["cached-session"])

        let metrics = ParserPassMetrics()
        let second = try await parser.parse(options: LogParseOptions(
            includeConversationBodies: false,
            metrics: metrics,
            includeCachedUnchangedUsages: false
        ))
        XCTAssertTrue(second.usages.isEmpty)
        XCTAssertEqual(metrics.snapshot().contentReadCount, 0)

        let catchUp = try await parser.parse(options: LogParseOptions(
            includeConversationBodies: false,
            includeCachedUnchangedUsages: true
        ))
        XCTAssertEqual(catchUp.usages.map(\.sessionId), ["cached-session"])
        XCTAssertEqual(catchUp.usages.first?.inputTokens, 100)

        try #"{"method":"session/update","params":{"update":{"sessionUpdate":"turn_completed","prompt_id":"turn-2","usage":{"inputTokens":400,"outputTokens":80,"totalTokens":480,"cachedReadTokens":0,"reasoningTokens":0}}}}"#
            .write(to: session.appendingPathComponent("updates.jsonl"), atomically: true, encoding: .utf8)
        let grown = try await parser.parse(options: LogParseOptions(includeConversationBodies: false))
        XCTAssertEqual(grown.usages.first?.inputTokens, 400)
    }

    func test_parse_stillReconcilesAParentWhenTheChildIsCached() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-grok-cache-parent-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent("%2Ftmp%2Fgrok-project", isDirectory: true)
        let parent = workspace.appendingPathComponent("parent-session", isDirectory: true)
        let child = workspace.appendingPathComponent("child-session", isDirectory: true)
        let childMetadata = parent
            .appendingPathComponent("subagents", isDirectory: true)
            .appendingPathComponent("child-session", isDirectory: true)
        try FileManager.default.createDirectory(at: childMetadata, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for (directory, sessionID) in [(parent, "parent-session"), (child, "child-session")] {
            try """
            {"info":{"id":"\(sessionID)","cwd":"/tmp/grok-project"},"current_model_id":"grok-4.5"}
            """.write(to: directory.appendingPathComponent("summary.json"), atomically: true, encoding: .utf8)
            let usage = sessionID == "parent-session"
                ? #"{"inputTokens":1500,"outputTokens":300,"totalTokens":1800,"cachedReadTokens":900,"reasoningTokens":75}"#
                : #"{"inputTokens":1000,"outputTokens":200,"totalTokens":1200,"cachedReadTokens":600,"reasoningTokens":50}"#
            try """
            {"method":"session/update","params":{"update":{"sessionUpdate":"turn_completed","prompt_id":"turn-1","usage":\(usage)}}}
            """
                .write(to: directory.appendingPathComponent("updates.jsonl"), atomically: true, encoding: .utf8)
        }
        try #"{"parent_session_id":"parent-session","child_session_id":"child-session"}"#
            .write(to: childMetadata.appendingPathComponent("meta.json"), atomically: true, encoding: .utf8)

        let parser = GrokParser(logDirectoryOverride: root.path)
        _ = try await parser.parse(options: LogParseOptions(includeConversationBodies: false))

        try #"{"info":{"id":"parent-session","cwd":"/tmp/grok-project"},"current_model_id":"grok-4.5","updated_at":"2026-07-13T02:00:00Z"}"#
            .write(to: parent.appendingPathComponent("summary.json"), atomically: true, encoding: .utf8)

        let second = try await parser.parse(options: LogParseOptions(includeConversationBodies: false))
        XCTAssertEqual(second.usages.first { $0.sessionId == "parent-session" }?.totalTokens, 600)
        XCTAssertEqual(second.usages.first { $0.sessionId == "child-session" }?.totalTokens, 1_200)
    }

    func test_parseISO8601_rejectsNilEmptyAndGarbage() {
        let parser = GrokParser()
        XCTAssertNil(parser.parseISO8601(nil))
        XCTAssertNil(parser.parseISO8601(""))
        XCTAssertNil(parser.parseISO8601("   "))
        XCTAssertNil(parser.parseISO8601("not-a-timestamp"))
        XCTAssertNil(parser.parseISO8601("2026-07-06 12:34:56"))
    }
}
