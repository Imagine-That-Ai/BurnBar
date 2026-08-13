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

    func test_parse_skipsUnchangedUpdatesJsonlOnSecondPass() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-grok-cache-\(UUID().uuidString)", isDirectory: true)
        let session = root
            .appendingPathComponent("%2Ftmp%2Fgrok-project", isDirectory: true)
            .appendingPathComponent("grok-cache-session", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try #"{"info":{"id":"grok-cache-session","cwd":"/tmp/grok-project"},"current_model_id":"grok-4.5","created_at":"2026-07-13T01:00:00Z","updated_at":"2026-07-13T01:05:00Z"}"#
            .write(to: session.appendingPathComponent("summary.json"), atomically: true, encoding: .utf8)
        let updatesURL = session.appendingPathComponent("updates.jsonl")
        try #"{"method":"session/update","params":{"update":{"sessionUpdate":"turn_completed","prompt_id":"turn-1","usage":{"inputTokens":1000,"outputTokens":200,"totalTokens":1200,"cachedReadTokens":600,"reasoningTokens":50}}}}"#
            .write(to: updatesURL, atomically: true, encoding: .utf8)

        let parser = GrokParser(logDirectoryOverride: root.path)
        let first = try await parser.parse()
        XCTAssertEqual(parser.lastUpdatesScanCount, 1)
        XCTAssertEqual(parser.lastUpdatesCacheHitCount, 0)
        let firstUsage = try XCTUnwrap(first.usages.first)
        XCTAssertEqual(firstUsage.totalTokens, 1_800)

        let second = try await parser.parse()
        XCTAssertEqual(parser.lastUpdatesScanCount, 0)
        XCTAssertEqual(parser.lastUpdatesCacheHitCount, 1)
        XCTAssertEqual(second.usages.first?.totalTokens, firstUsage.totalTokens)
        XCTAssertEqual(second.usages.first?.inputTokens, firstUsage.inputTokens)
        XCTAssertEqual(second.usages.first?.provenanceConfidence, .exact)

        let extraTurn = #"{"method":"session/update","params":{"update":{"sessionUpdate":"turn_completed","prompt_id":"turn-2","usage":{"inputTokens":500,"outputTokens":100,"totalTokens":600,"cachedReadTokens":300,"reasoningTokens":20}}}}"#
        let existing = try String(contentsOf: updatesURL, encoding: .utf8)
        try (existing + "\n" + extraTurn).write(to: updatesURL, atomically: true, encoding: .utf8)

        let third = try await parser.parse()
        XCTAssertEqual(parser.lastUpdatesScanCount, 1)
        XCTAssertEqual(third.usages.first?.totalTokens, 2_400)
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

    func test_parseISO8601_rejectsNilEmptyAndGarbage() {
        let parser = GrokParser()
        XCTAssertNil(parser.parseISO8601(nil))
        XCTAssertNil(parser.parseISO8601(""))
        XCTAssertNil(parser.parseISO8601("   "))
        XCTAssertNil(parser.parseISO8601("not-a-timestamp"))
        XCTAssertNil(parser.parseISO8601("2026-07-06 12:34:56"))
    }
}
