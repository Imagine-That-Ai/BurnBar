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

    func testWireUsageDeduplicatesStreamingUpdatesByMessageID() async throws {
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

        // Simulate a streaming wire log where msg-1 has incremental updates,
        // and msg-2 has its own separate usage.
        let wire = """
        {"message":{"type":"StatusUpdate","payload":{"message_id":"msg-1","token_usage":{"model":"kimi-latest","input_other":100,"output":10,"input_cache_read":1000,"input_cache_creation":200}}}}
        {"message":{"type":"StatusUpdate","payload":{"message_id":"msg-1","token_usage":{"model":"kimi-latest","input_other":100,"output":25,"input_cache_read":1000,"input_cache_creation":200}}}}
        {"message":{"type":"StatusUpdate","payload":{"message_id":"msg-1","token_usage":{"model":"kimi-latest","input_other":100,"output":50,"input_cache_read":1000,"input_cache_creation":200}}}}
        {"message":{"type":"StatusUpdate","payload":{"message_id":"msg-2","token_usage":{"model":"kimi-latest","input_other":300,"output":80,"input_cache_read":0,"input_cache_creation":0}}}}
        """
        try wire.write(
            to: sessionDir.appendingPathComponent("wire.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let result = try await KimiParser(logDirectoryOverride: tempDir.path).parse()
        let usage = try XCTUnwrap(result.usages.first)

        // Expected counts:
        // msg-1: inputOther=100, output=max(10,25,50)=50, cacheRead=1000, cacheCreation=200
        // msg-2: inputOther=300, output=80, cacheRead=0, cacheCreation=0
        // Sums:
        // inputOther = 100 + 300 = 400
        // output = 50 + 80 = 130
        // cacheRead = 1000 + 0 = 1000
        // cacheCreation = 200 + 0 = 200
        XCTAssertEqual(usage.inputTokens, 400)
        XCTAssertEqual(usage.outputTokens, 130)
        XCTAssertEqual(usage.cacheReadTokens, 1000)
        XCTAssertEqual(usage.cacheCreationTokens, 200)
        XCTAssertEqual(usage.totalTokens, 1730)
        XCTAssertEqual(usage.model, "kimi-latest")
    }
}

final class GeminiCLIParserTests: XCTestCase {
    func test_parseCachedContentTokenCountStoresUncachedInputOnly() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-gemini-parser-\(UUID().uuidString)", isDirectory: true)
        let chatsDir = tempDir
            .appendingPathComponent("project", isDirectory: true)
            .appendingPathComponent("chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chatsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let session = """
        {"type":"message_update","timestamp":"2026-05-21T10:00:00Z","model":"gemini-3.1-pro-preview","role":"user","content":"Summarize cached context.","usageMetadata":{"promptTokenCount":2000,"candidatesTokenCount":86,"cachedContentTokenCount":1500}}
        """
        try session.write(
            to: chatsDir.appendingPathComponent("session-cache.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let result = try await GeminiCLIParser(logDirectoryOverride: tempDir.path).parse()
        let usage = try XCTUnwrap(result.usages.first)

        XCTAssertEqual(result.usages.count, 1)
        XCTAssertEqual(usage.inputTokens, 500)
        XCTAssertEqual(usage.outputTokens, 86)
        XCTAssertEqual(usage.cacheReadTokens, 1500)
        XCTAssertEqual(usage.totalTokens, 2086)
    }

    func test_parseTopLevelUsageDoesNotDoubleCountMessageUpdate() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-gemini-parser-\(UUID().uuidString)", isDirectory: true)
        let chatsDir = tempDir
            .appendingPathComponent("project", isDirectory: true)
            .appendingPathComponent("chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chatsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let session = """
        {"type":"message_update","timestamp":"2026-05-21T10:00:00Z","model":"gemini-3-flash-preview","role":"assistant","content":"Done.","usage":{"input_tokens":100,"output_tokens":20,"cache_read_input_tokens":30}}
        """
        try session.write(
            to: chatsDir.appendingPathComponent("session-usage.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let result = try await GeminiCLIParser(logDirectoryOverride: tempDir.path).parse()
        let usage = try XCTUnwrap(result.usages.first)

        XCTAssertEqual(result.usages.count, 1)
        XCTAssertEqual(usage.inputTokens, 100)
        XCTAssertEqual(usage.outputTokens, 20)
        XCTAssertEqual(usage.cacheReadTokens, 30)
        XCTAssertEqual(usage.totalTokens, 150)
    }
}
