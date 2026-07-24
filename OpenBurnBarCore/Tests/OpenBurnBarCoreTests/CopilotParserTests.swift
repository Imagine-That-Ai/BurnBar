import Foundation
import XCTest
@testable import OpenBurnBarLogParsers

final class CopilotParserTests: XCTestCase {
    func testRotatedSegmentsDeduplicateOverlapButPreserveLegitimateIdenticalTurns() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = try fixture.session("session-a")
        let repeatedTurn = #"{"type":"user_message","role":"user","content":"repeat","timestamp":"2026-07-20T10:00:00Z"}"#
        let firstUsage = #"{"id":"usage-1","type":"assistant.usage","model":"gpt-5","usage":{"input_tokens":10,"output_tokens":1},"timestamp":"2026-07-20T10:00:01Z"}"#
        let older = session.appendingPathComponent("events.jsonl.1")
        try (["not-json", repeatedTurn, repeatedTurn, firstUsage].joined(separator: "\n") + "\n")
            .write(to: older, atomically: true, encoding: .utf8)
        let current = session.appendingPathComponent("events.jsonl")
        try ([
            repeatedTurn,
            firstUsage,
            #"{"id":"usage-2","type":"assistant.usage","model":"gpt-5","data":{"input_tokens":20,"output_tokens":2},"timestamp":"2026-07-20T10:00:02Z"}"#,
            #"{"id":"shutdown","type":"session.shutdown","usage":{"input_tokens":999,"output_tokens":999},"timestamp":"2026-07-20T10:00:03Z"}"#
        ].joined(separator: "\n") + "\n")
            .write(to: current, atomically: true, encoding: .utf8)
        try fixture.setModificationDate(Date(timeIntervalSince1970: 100), for: older)
        try fixture.setModificationDate(Date(timeIntervalSince1970: 200), for: current)

        let result = try await fixture.parser().parse(options: .default)

        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertEqual(result.usages.count, 1)
        XCTAssertEqual(usage.inputTokens, 30)
        XCTAssertEqual(usage.outputTokens, 3)
        XCTAssertEqual(usage.model, "gpt-5")
        let conversation = try XCTUnwrap(result.conversations.first)
        XCTAssertEqual(conversation.messageCount, 2)
        XCTAssertEqual(conversation.userWordCount, 2)
    }

    func testRotatedProcessLogsUseOrderedUniqueCheckpointsAsLegacyFallback() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = try fixture.session("legacy-session")
        try #"{"type":"user_message","role":"user","content":"legacy","timestamp":"2026-07-20T10:00:00Z"}"#
            .write(to: session.appendingPathComponent("events.jsonl"), atomically: true, encoding: .utf8)
        let firstLine = "CompactionProcessor session=legacy-session context_tokens=100"
        let older = fixture.logs.appendingPathComponent("process-1.log")
        let newer = fixture.logs.appendingPathComponent("process-2.log")
        try (firstLine + "\n").write(to: older, atomically: true, encoding: .utf8)
        try (firstLine + "\nCompactionProcessor session=legacy-session context_tokens=160\n")
            .write(to: newer, atomically: true, encoding: .utf8)
        try fixture.setModificationDate(Date(timeIntervalSince1970: 100), for: older)
        try fixture.setModificationDate(Date(timeIntervalSince1970: 200), for: newer)

        let result = try await fixture.parser().parse()
        let usage = try XCTUnwrap(result.usages.first)

        XCTAssertEqual(usage.inputTokens, 100)
        XCTAssertEqual(usage.outputTokens, 60)
        XCTAssertEqual(usage.provenanceConfidence, .exact)
    }

    func testShutdownSummaryIsUsedWhenTurnUsageIsAbsent() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = try fixture.session("shutdown-only")
        try #"{"id":"shutdown","type":"session.shutdown","model":"gpt-5","usage":{"input_tokens":70,"output_tokens":8,"cache_read_input_tokens":4},"timestamp":"2026-07-20T10:00:03Z"}"#
            .write(to: session.appendingPathComponent("events.jsonl"), atomically: true, encoding: .utf8)

        let result = try await fixture.parser().parse()
        let usage = try XCTUnwrap(result.usages.first)

        XCTAssertEqual(usage.inputTokens, 70)
        XCTAssertEqual(usage.outputTokens, 8)
        XCTAssertEqual(usage.cacheReadTokens, 4)
    }

    func testMissingRootIsEmptyButInvalidRootSurfacesDiscoveryError() async throws {
        let fixture = try Fixture(createSessionRoot: false)
        defer { fixture.remove() }
        let missing = fixture.root.appendingPathComponent("missing")
        let empty = try await CopilotParser(
            sessionStateURL: missing,
            logsURL: fixture.logs
        ).parse()
        XCTAssertTrue(empty.usages.isEmpty)

        try Data("not a directory".utf8).write(to: missing)
        do {
            _ = try await CopilotParser(sessionStateURL: missing, logsURL: fixture.logs).parse()
            XCTFail("Expected invalid session root to surface a discovery error")
        } catch {
            XCTAssertFalse(String(describing: error).isEmpty)
        }
    }
}

private final class Fixture {
    let root: URL
    let sessions: URL
    let logs: URL

    init(createSessionRoot: Bool = true) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("copilot-parser-tests-\(UUID().uuidString)", isDirectory: true)
        sessions = root.appendingPathComponent("session-state", isDirectory: true)
        logs = root.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if createSessionRoot {
            try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    }

    func session(_ id: String) throws -> URL {
        let url = sessions.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func parser() -> CopilotParser {
        CopilotParser(sessionStateURL: sessions, logsURL: logs)
    }

    func setModificationDate(_ date: Date, for url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
