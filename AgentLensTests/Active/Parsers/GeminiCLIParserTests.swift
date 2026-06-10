import OpenBurnBarCore
import XCTest
@testable import OpenBurnBar

/// Gemini CLI parser — pins the session ingestion paths, with emphasis on the
/// cached `ThreadSafeISO8601DateFormatter.parseBasic` timestamp lanes (the
/// perf sweep replaced per-line `ISO8601DateFormatter()` allocations on the
/// `timestamp`-string and `createTime` branches).
final class GeminiCLIParserStandaloneTests: XCTestCase {
    private func makeChatsDir() throws -> (base: URL, chats: URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-gemini-parser-\(UUID().uuidString)", isDirectory: true)
        let chats = base
            .appendingPathComponent("project-hash-1", isDirectory: true)
            .appendingPathComponent("chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        return (base, chats)
    }

    func testProviderReturnsCorrectValue() {
        XCTAssertEqual(GeminiCLIParser().provider, .geminiCLI)
    }

    func testParseEmptyDirectoryYieldsNothing() async throws {
        let dirs = try makeChatsDir()
        defer { try? FileManager.default.removeItem(at: dirs.base) }

        let result = try await GeminiCLIParser(logDirectoryOverride: dirs.base.path).parse()
        XCTAssertTrue(result.usages.isEmpty)
        XCTAssertTrue(result.conversations.isEmpty)
    }

    func testJsonlSessionParsesISO8601StringTimestampsViaCachedFormatter() async throws {
        let dirs = try makeChatsDir()
        defer { try? FileManager.default.removeItem(at: dirs.base) }

        let jsonl = """
        {"role":"user","content":"Refactor this","timestamp":"2026-05-04T08:00:00Z"}
        {"role":"model","content":"Done.","timestamp":"2026-05-04T08:05:30Z","usage":{"input_tokens":120,"output_tokens":45}}
        """
        try jsonl.write(
            to: dirs.chats.appendingPathComponent("session-iso.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let result = try await GeminiCLIParser(logDirectoryOverride: dirs.base.path).parse()
        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertEqual(usage.inputTokens, 120)
        XCTAssertEqual(usage.outputTokens, 45)
        XCTAssertEqual(usage.provider, .geminiCLI)
        XCTAssertEqual(usage.projectName, "project-hash-1")

        // The basic (non-fractional) ISO strings must parse on the cached lane.
        XCTAssertEqual(usage.startTime, ThreadSafeISO8601DateFormatter.parseBasic("2026-05-04T08:00:00Z"))
        XCTAssertEqual(usage.endTime, ThreadSafeISO8601DateFormatter.parseBasic("2026-05-04T08:05:30Z"))
        XCTAssertLessThan(usage.startTime, usage.endTime)
    }

    func testJsonSessionParsesCreateTimeBranch() async throws {
        let dirs = try makeChatsDir()
        defer { try? FileManager.default.removeItem(at: dirs.base) }

        let json = """
        {"messages":[
          {"role":"user","content":"hello","createTime":"2026-05-05T10:00:00Z"},
          {"role":"model","content":"hi","createTime":"2026-05-05T10:00:05Z","usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":7}}
        ]}
        """
        try json.write(
            to: dirs.chats.appendingPathComponent("session-create-time.json"),
            atomically: true,
            encoding: .utf8
        )

        let result = try await GeminiCLIParser(logDirectoryOverride: dirs.base.path).parse()
        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertEqual(usage.inputTokens, 10)
        XCTAssertEqual(usage.outputTokens, 7)
        XCTAssertEqual(usage.startTime, ThreadSafeISO8601DateFormatter.parseBasic("2026-05-05T10:00:00Z"))
        XCTAssertEqual(usage.endTime, ThreadSafeISO8601DateFormatter.parseBasic("2026-05-05T10:00:05Z"))
    }
}
