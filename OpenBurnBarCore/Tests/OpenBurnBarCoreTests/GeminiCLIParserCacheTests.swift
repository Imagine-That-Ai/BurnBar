import XCTest
@testable import OpenBurnBarLogParsers

final class GeminiCLIParserCacheTests: XCTestCase {
    func test_parse_skipsUnchangedSessionOnUsageOnlySecondPass() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-gemini-cache-\(UUID().uuidString)", isDirectory: true)
        let chats = root
            .appendingPathComponent("project-hash-1", isDirectory: true)
            .appendingPathComponent("chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionURL = chats.appendingPathComponent("session-cache.jsonl")
        try """
        {"role":"user","content":"Refactor this","timestamp":"2026-05-04T08:00:00Z"}
        {"role":"model","content":"Done.","timestamp":"2026-05-04T08:05:30Z","usage":{"input_tokens":120,"output_tokens":45}}
        """.write(to: sessionURL, atomically: true, encoding: .utf8)

        let parser = GeminiCLIParser(logDirectoryOverride: root.path)
        let usageOnly = LogParseOptions(includeConversationBodies: false)

        let first = try await parser.parse(options: usageOnly)
        XCTAssertEqual(parser.lastSessionScanCount, 1)
        XCTAssertEqual(parser.lastSessionCacheHitCount, 0)
        let firstUsage = try XCTUnwrap(first.usages.first)
        XCTAssertEqual(firstUsage.inputTokens, 120)
        XCTAssertEqual(firstUsage.outputTokens, 45)
        XCTAssertTrue(first.conversations.isEmpty)

        let second = try await parser.parse(options: usageOnly)
        XCTAssertEqual(parser.lastSessionScanCount, 0)
        XCTAssertEqual(parser.lastSessionCacheHitCount, 1)
        XCTAssertEqual(second.usages.first?.inputTokens, firstUsage.inputTokens)
        XCTAssertEqual(second.usages.first?.outputTokens, firstUsage.outputTokens)
        XCTAssertEqual(second.usages.first?.startTime, firstUsage.startTime)
        XCTAssertEqual(second.usages.first?.costUSD, firstUsage.costUSD)
        XCTAssertEqual(second.usages.first?.provenanceConfidence, .exact)

        let existing = try String(contentsOf: sessionURL, encoding: .utf8)
        try (existing + "\n{\"role\":\"model\",\"content\":\"More.\",\"timestamp\":\"2026-05-04T08:06:00Z\",\"usage\":{\"input_tokens\":10,\"output_tokens\":5}}\n")
            .write(to: sessionURL, atomically: true, encoding: .utf8)

        let third = try await parser.parse(options: usageOnly)
        XCTAssertEqual(parser.lastSessionScanCount, 1)
        XCTAssertEqual(third.usages.first?.inputTokens, 130)
        XCTAssertEqual(third.usages.first?.outputTokens, 50)
    }

    func test_parse_watermarkSkipDoesNotDropUsageCache() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-gemini-watermark-\(UUID().uuidString)", isDirectory: true)
        let chats = root
            .appendingPathComponent("project-hash-1", isDirectory: true)
            .appendingPathComponent("chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try """
        {"role":"user","content":"Hi","timestamp":"2026-05-04T08:00:00Z"}
        {"role":"model","content":"Hello","timestamp":"2026-05-04T08:00:05Z","usage":{"input_tokens":8,"output_tokens":3}}
        """.write(
            to: chats.appendingPathComponent("session-watermark.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let parser = GeminiCLIParser(logDirectoryOverride: root.path)
        let usageOnly = LogParseOptions(includeConversationBodies: false)
        let first = try await parser.parse(options: usageOnly)
        XCTAssertEqual(first.usages.first?.inputTokens, 8)

        let deferred = try await parser.parse(options: LogParseOptions(
            includeConversationBodies: false,
            minimumFileModificationDate: Date.distantFuture
        ))
        XCTAssertTrue(deferred.usages.isEmpty)

        let second = try await parser.parse(options: usageOnly)
        XCTAssertEqual(parser.lastSessionScanCount, 0)
        XCTAssertEqual(parser.lastSessionCacheHitCount, 1)
        XCTAssertEqual(second.usages.first?.inputTokens, 8)
        XCTAssertEqual(second.usages.first?.outputTokens, 3)
    }

    func test_parse_usageOnlyMatchesIndexedTotalsWithoutBodies() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-gemini-bodies-\(UUID().uuidString)", isDirectory: true)
        let chats = root
            .appendingPathComponent("project-hash-1", isDirectory: true)
            .appendingPathComponent("chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try """
        {"role":"user","content":"Hello there","timestamp":"2026-05-04T08:00:00Z"}
        {"role":"model","content":"Hi.","timestamp":"2026-05-04T08:00:05Z","usage":{"input_tokens":8,"output_tokens":3}}
        """.write(
            to: chats.appendingPathComponent("session-bodies.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let parser = GeminiCLIParser(logDirectoryOverride: root.path)
        let indexed = try await parser.parse()
        let usageOnly = try await parser.parse(options: LogParseOptions(includeConversationBodies: false))

        XCTAssertEqual(indexed.usages.count, 1)
        XCTAssertEqual(indexed.conversations.count, 1)
        XCTAssertEqual(usageOnly.usages.count, 1)
        XCTAssertTrue(usageOnly.conversations.isEmpty)
        XCTAssertEqual(indexed.usages.first?.inputTokens, usageOnly.usages.first?.inputTokens)
        XCTAssertEqual(indexed.usages.first?.outputTokens, usageOnly.usages.first?.outputTokens)
        XCTAssertTrue(try XCTUnwrap(indexed.conversations.first?.fullText).contains("Hello there"))
    }
}
