import XCTest
@testable import OpenBurnBar
import OpenBurnBarCore
import OpenBurnBarLogParsers

// MARK: - PrimeAgentParserTests
//
// Verifies Prime Agent (Prime Intellect) local JSONL parsing at
// `~/.prime/agent/sessions/*.jsonl`. The on-disk shape is flat-file:
// one JSONL per session with `type: "session"` metadata and
// `type: "message"` turns carrying `message.usage` buckets. Cost is
// taken from `usage.cost.total` when present, else falls back to the
// shared `ModelPricing` catalog.
//
// Findings documented from the reference parser and provider-ingestion
// catalog (contracts/provider-ingestion-catalog.json). Prime Intellect
// does not publish a public pricing page for the recursive-language-model
// backends the daemon routes to, so cost is authoritative from the log
// when present.

final class PrimeAgentParserTests: XCTestCase {

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-prime-parser-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeSessionFile(dir: URL, name: String = "session-001.jsonl", content: String) throws -> URL {
        let file = dir.appendingPathComponent(name)
        try content.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private func sessionEnvelope(id: String = "sess-001", cwd: String = "/tmp/demo", timestamp: String = "2026-08-01T12:00:00Z") -> String {
        """
        {"type":"session","id":"\(id)","cwd":"\(cwd)","timestamp":"\(timestamp)"}
        """
    }

    private func assistantMessage(model: String, input: Int, output: Int, cacheRead: Int = 0, cacheWrite: Int = 0, cost: Double? = nil, text: String = "hello") -> String {
        let costPart: String
        if let cost {
            costPart = "\"cost\":{\"total\":\(cost)}"
        } else {
            costPart = "\"cost\":{\"total\":0}"
        }
        return """
        {"type":"message","timestamp":"2026-08-01T12:00:01Z","message":{"role":"assistant","model":"\(model)","provider":"prime","content":[{"type":"text","text":"\(text)"}],"usage":{"input":\(input),"output":\(output),"cacheRead":\(cacheRead),"cacheWrite":\(cacheWrite),\(costPart)}}}
        """
    }

    private func userMessage(text: String = "hi") -> String {
        """
        {"type":"message","timestamp":"2026-08-01T12:00:00Z","message":{"role":"user","content":"\(text)"}}
        """
    }

    // MARK: - Provider identity

    func testProviderReturnsPrimeAgent() {
        let parser = PrimeAgentParser()
        XCTAssertEqual(parser.provider, .primeAgent)
        XCTAssertEqual(parser.provider.rawValue, "Prime Agent")
    }

    // MARK: - Empty / missing

    func testEmptyDirectoryYieldsNoUsages() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = try await PrimeAgentParser(logDirectoryOverride: dir.path).parse()
        XCTAssertTrue(result.usages.isEmpty)
        XCTAssertTrue(result.conversations.isEmpty)
    }

    func testMissingDirectoryYieldsNoUsages() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-prime-missing-\(UUID().uuidString)", isDirectory: true).path
        let result = try await PrimeAgentParser(logDirectoryOverride: missing).parse()
        XCTAssertTrue(result.usages.isEmpty)
        XCTAssertTrue(result.conversations.isEmpty)
    }

    func testEmptyLogFileYieldsNoUsages() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try writeSessionFile(dir: dir, content: "")
        let result = try await PrimeAgentParser(logDirectoryOverride: dir.path).parse()
        XCTAssertTrue(result.usages.isEmpty, "empty file should not produce a usage row")
    }

    func testSessionWithNoUsageProducesNoRow() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let content = [
            sessionEnvelope(),
            userMessage(text: "just a prompt, no assistant turn"),
        ].joined(separator: "\n")
        _ = try writeSessionFile(dir: dir, content: content)
        let result = try await PrimeAgentParser(logDirectoryOverride: dir.path).parse()
        XCTAssertTrue(result.usages.isEmpty, "session without assistant usage should be skipped")
    }

    // MARK: - Basic token + cost extraction

    func testSingleAssistantTurnExtractsExactTokensAndCost() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let content = [
            sessionEnvelope(id: "sess-exact", cwd: "/home/alice/project-x"),
            userMessage(text: "build me a parser"),
            assistantMessage(model: "muse-spark-1.2", input: 1200, output: 800, cacheRead: 100, cacheWrite: 50, cost: 0.042, text: "done"),
        ].joined(separator: "\n")
        _ = try writeSessionFile(dir: dir, content: content)
        let result = try await PrimeAgentParser(logDirectoryOverride: dir.path).parse()
        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertEqual(usage.provider, .primeAgent)
        XCTAssertEqual(usage.sessionId, "sess-exact")
        XCTAssertEqual(usage.projectName, "project-x")
        XCTAssertEqual(usage.model, "muse-spark-1.2")
        XCTAssertEqual(usage.inputTokens, 1200)
        XCTAssertEqual(usage.outputTokens, 800)
        XCTAssertEqual(usage.cacheReadTokens, 100)
        XCTAssertEqual(usage.cacheCreationTokens, 50)
        XCTAssertEqual(usage.costUSD, 0.042, accuracy: 0.0001)
        XCTAssertEqual(usage.provenanceMethod, .providerLog)
        XCTAssertEqual(usage.provenanceConfidence, .exact)
    }

    func testAggregatesMultipleAssistantTurnsInOneFile() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let content = [
            sessionEnvelope(id: "sess-agg"),
            userMessage(),
            assistantMessage(model: "muse-spark-1.2", input: 100, output: 50, cost: 0.01, text: "a"),
            userMessage(text: "more"),
            assistantMessage(model: "muse-spark-1.2", input: 200, output: 150, cacheRead: 30, cost: 0.02, text: "b"),
        ].joined(separator: "\n")
        _ = try writeSessionFile(dir: dir, content: content)
        let result = try await PrimeAgentParser(logDirectoryOverride: dir.path).parse()
        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertEqual(usage.inputTokens, 300)
        XCTAssertEqual(usage.outputTokens, 200)
        XCTAssertEqual(usage.cacheReadTokens, 30)
        XCTAssertEqual(usage.costUSD, 0.03, accuracy: 0.0001)
    }

    // MARK: - Cost fallback

    func testExplicitZeroCostStaysZeroForFreeTurns() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // An explicit `cost.total == 0` (e.g. cached `muse-spark-1.2-contributor`) must stay 0,
        // not be re-priced via the catalog. Only *missing* `cost` triggers fallback.
        let content = [
            sessionEnvelope(id: "sess-free"),
            assistantMessage(model: "gpt-4o", input: 1000, output: 500, cost: 0.0, text: "explicit free turn"),
        ].joined(separator: "\n")
        _ = try writeSessionFile(dir: dir, content: content)
        let result = try await PrimeAgentParser(logDirectoryOverride: dir.path).parse()
        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertEqual(usage.costUSD, 0, accuracy: 0.0001, "explicit 0 cost must not fall back to catalog")
    }

    func testMissingCostFallsBackToPricingCatalog() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // When `cost` is missing, fall back to catalog pricing for known models.
        let content = [
            sessionEnvelope(id: "sess-fallback"),
            """
            {"type":"message","timestamp":"2026-08-01T12:00:01Z","message":{"role":"assistant","model":"gpt-4o","provider":"prime","content":[{"type":"text","text":"no cost field"}],"usage":{"input":1000,"output":500,"cacheRead":0,"cacheWrite":0}}}
            """,
        ].joined(separator: "\n")
        _ = try writeSessionFile(dir: dir, content: content)
        let result = try await PrimeAgentParser(logDirectoryOverride: dir.path).parse()
        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertGreaterThan(usage.costUSD, 0, "missing cost should fall back to catalog pricing for known models")
    }

    // MARK: - Truncated / partial logs

    func testTruncatedLastLineIsSkippedGracefully() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let truncatedTail = "{\"type\":\"message\",\"message\":{\"role\":\"assistant\",\"model\":\"muse-spark-1.2\",\"usage\":{\"input\":999,"
        let content = [
            sessionEnvelope(id: "sess-trunc"),
            assistantMessage(model: "muse-spark-1.2", input: 400, output: 200, cost: 0.015, text: "good turn"),
            truncatedTail,
        ].joined(separator: "\n")
        _ = try writeSessionFile(dir: dir, content: content)
        let result = try await PrimeAgentParser(logDirectoryOverride: dir.path).parse()
        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertEqual(usage.inputTokens, 400, "truncated tail line should be skipped without discarding prior turns")
        XCTAssertEqual(usage.outputTokens, 200)
    }

    func testMalformedJsonLineIsSkippedIndependently() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let content = [
            sessionEnvelope(id: "sess-malformed"),
            "not json at all {",
            assistantMessage(model: "muse-spark-1.2", input: 10, output: 20, cost: 0.001, text: "still here"),
            "{\"type\":\"message\", \"oops\": }",
            assistantMessage(model: "muse-spark-1.2", input: 30, output: 40, cost: 0.002, text: "also here"),
        ].joined(separator: "\n")
        _ = try writeSessionFile(dir: dir, content: content)
        let result = try await PrimeAgentParser(logDirectoryOverride: dir.path).parse()
        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertEqual(usage.inputTokens, 40)
        XCTAssertEqual(usage.outputTokens, 60)
    }

    // MARK: - Multi-model session

    func testMultiModelSessionUsesLastModelAndSumsTokens() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let content = [
            sessionEnvelope(id: "sess-multi"),
            assistantMessage(model: "muse-spark-1.2", input: 100, output: 100, cost: 0.01, text: "first backend"),
            assistantMessage(model: "gpt-5.6-luna", input: 200, output: 300, cost: 0.05, text: "second backend"),
        ].joined(separator: "\n")
        _ = try writeSessionFile(dir: dir, content: content)
        let result = try await PrimeAgentParser(logDirectoryOverride: dir.path).parse()
        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertEqual(usage.model, "gpt-5.6-luna", "last model in the file should be the session model")
        XCTAssertEqual(usage.inputTokens, 300)
        XCTAssertEqual(usage.outputTokens, 400)
        XCTAssertEqual(usage.costUSD, 0.06, accuracy: 0.0001)
    }

    // MARK: - Cache buckets

    func testCacheReadAndCacheWriteBucketsAreDistinct() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let content = [
            sessionEnvelope(id: "sess-cache"),
            assistantMessage(model: "muse-spark-1.2", input: 1000, output: 500, cacheRead: 8000, cacheWrite: 2000, cost: 0.08, text: "cached"),
        ].joined(separator: "\n")
        _ = try writeSessionFile(dir: dir, content: content)
        let result = try await PrimeAgentParser(logDirectoryOverride: dir.path).parse()
        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertEqual(usage.cacheReadTokens, 8000)
        XCTAssertEqual(usage.cacheCreationTokens, 2000)
        XCTAssertNotEqual(usage.cacheReadTokens, usage.cacheCreationTokens)
    }

    // MARK: - Recursive enumeration

    func testNestedSessionsAreFoundViaRecursiveEnumerator() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let nested = dir.appendingPathComponent("2026/08/07/sess-nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let content = [
            sessionEnvelope(id: "sess-nested", cwd: "/tmp/nested"),
            assistantMessage(model: "muse-spark-1.2", input: 77, output: 33, cost: 0.009, text: "nested"),
        ].joined(separator: "\n")
        try content.write(to: nested.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
        let result = try await PrimeAgentParser(logDirectoryOverride: dir.path).parse()
        XCTAssertEqual(result.usages.count, 1, "enumerator must find nested *.jsonl")
        XCTAssertEqual(result.usages.first?.sessionId, "sess-nested")
    }

    // MARK: - Multiple files

    func testMultipleFilesProduceMultipleUsages() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for i in 1...3 {
            let content = [
                sessionEnvelope(id: "sess-\(i)", cwd: "/tmp/p\(i)"),
                assistantMessage(model: "muse-spark-1.2", input: 10*i, output: 5*i, cost: Double(i)*0.001, text: "hi-\(i)"),
            ].joined(separator: "\n")
            _ = try writeSessionFile(dir: dir, name: "sess-\(i).jsonl", content: content)
        }
        let result = try await PrimeAgentParser(logDirectoryOverride: dir.path).parse()
        XCTAssertEqual(result.usages.count, 3)
        XCTAssertEqual(result.conversations.count, 3)
    }

    // MARK: - Non-jsonl ignored, empty project fallback

    func testNonJsonlFilesAreIgnored() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let content = [
            sessionEnvelope(id: "sess-jsonl"),
            assistantMessage(model: "muse-spark-1.2", input: 100, output: 100, cost: 0.01, text: "ok"),
        ].joined(separator: "\n")
        _ = try writeSessionFile(dir: dir, name: "good.jsonl", content: content)
        try "noise".write(to: dir.appendingPathComponent("noise.txt"), atomically: true, encoding: .utf8)
        let result = try await PrimeAgentParser(logDirectoryOverride: dir.path).parse()
        XCTAssertEqual(result.usages.count, 1, "only *.jsonl should be scanned")
    }

    func testCwdFallbackForProjectName() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // no cwd in session envelope, file is named session-001.jsonl so sessionId derives from filename
        let content = [
            "{\"type\":\"session\",\"timestamp\":\"2026-08-01T12:00:00Z\"}",
            assistantMessage(model: "muse-spark-1.2", input: 50, output: 50, cost: 0.005, text: "x"),
        ].joined(separator: "\n")
        _ = try writeSessionFile(dir: dir, name: "my-session.jsonl", content: content)
        let result = try await PrimeAgentParser(logDirectoryOverride: dir.path).parse()
        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertFalse(usage.projectName.isEmpty)
    }

    // MARK: - Conversation extraction

    func testConversationBodyExtractedWhenAvailable() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let content = [
            sessionEnvelope(id: "conv-1", cwd: "/tmp/app"),
            userMessage(text: "What is prime?"),
            assistantMessage(model: "muse-spark-1.2", input: 20, output: 30, cost: 0.002, text: "A large prime is 997."),
        ].joined(separator: "\n")
        _ = try writeSessionFile(dir: dir, content: content)
        let result = try await PrimeAgentParser(logDirectoryOverride: dir.path).parse()
        let conv = try XCTUnwrap(result.conversations.first)
        XCTAssertEqual(conv.sessionId, "conv-1")
        XCTAssertEqual(conv.provider, .primeAgent)
        XCTAssertTrue(conv.fullText.contains("What is prime?"))
        XCTAssertTrue(conv.fullText.contains("997"))
        XCTAssertEqual(conv.messageCount, 2)
    }
}
