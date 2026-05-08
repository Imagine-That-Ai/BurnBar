import XCTest
@testable import OpenBurnBar

final class KimiParserStandaloneTests: XCTestCase {
    func testParseEmptyDirectory() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-kimi-parser-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let parser = KimiParser(logDirectoryOverride: tempDir.path)
        let result = try await parser.parse()

        XCTAssertTrue(result.usages.isEmpty, "Empty directory should yield no usages")
        XCTAssertTrue(result.conversations.isEmpty, "Empty directory should yield no conversations")
    }
    
    func testProviderReturnsCorrectValue() {
        let parser = KimiParser()
        XCTAssertEqual(parser.provider, .kimi)
    }

    func testWireUsageKeepsCacheBucketsDisjointAndIgnoresMessageIDAsModel() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-kimi-parser-\(UUID().uuidString)", isDirectory: true)
        let workspaceDir = tempDir.appendingPathComponent("workspace", isDirectory: true)
        let sessionDir = workspaceDir.appendingPathComponent("session-1", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let context = """
        {"role":"user","content":"Test","created_at":"2026-05-04T08:00:00Z"}
        {"role":"assistant","content":"Done","created_at":"2026-05-04T08:00:01Z"}
        """
        try context.write(
            to: sessionDir.appendingPathComponent("context.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let wire = """
        {"message":{"type":"StatusUpdate","payload":{"message_id":"chatcmpl-should-not-be-model","token_usage":{"model":"chatcmpl-token-usage-should-not-be-model","input_other":1000,"output":500,"input_cache_read":200,"input_cache_creation":50}}}}
        """
        try wire.write(
            to: sessionDir.appendingPathComponent("wire.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let result = try await KimiParser(logDirectoryOverride: tempDir.path).parse()
        let usage = try XCTUnwrap(result.usages.first)

        XCTAssertEqual(usage.inputTokens, 1000)
        XCTAssertEqual(usage.outputTokens, 500)
        XCTAssertEqual(usage.cacheCreationTokens, 50)
        XCTAssertEqual(usage.cacheReadTokens, 200)
        XCTAssertEqual(usage.totalTokens, 1750)
        XCTAssertEqual(usage.model, "kimi-for-coding")
    }
}
