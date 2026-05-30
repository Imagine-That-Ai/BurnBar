import XCTest
@testable import OpenBurnBar

final class CursorAgentParserTests: XCTestCase {

    func testProviderReturnsCursorAgent() {
        let parser = CursorAgentParser()
        XCTAssertEqual(parser.provider, .cursorAgent)
    }

    func testParseEmptyDirectory() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-cursor-agent-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let result = try await CursorAgentParser(logDirectoryOverride: tempDir.path).parse()
        XCTAssertTrue(result.usages.isEmpty)
        XCTAssertTrue(result.conversations.isEmpty)
    }

    func testParsesFixtureSessionFromFlatJSONL() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-cursor-agent-flat-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sessionId = "019e3403-e9bc-7131-872d-ae2728fb330a"
        let sessionFile = tempDir.appendingPathComponent("\(sessionId).jsonl")
        
        let sampleLogLines = """
        {"role":"system","content":"System instructions here.","timestamp":"2026-05-30T01:00:00Z"}
        {"role":"user","content":"Please check the codebase rules.","timestamp":"2026-05-30T01:00:05Z"}
        {"role":"assistant","content":"Sure! Let's do a grep search.","thinking":"Grep is faster here.","tool_calls":[{"name":"grep_search","args":{"Query":"GrokParser"}}],"timestamp":"2026-05-30T01:00:10Z"}
        {"role":"tool","type":"TOOL_OUTPUT","content":"File Path: `file:///path/to/GrokParser.swift`\\nLine Content: final class GrokParser","timestamp":"2026-05-30T01:00:15Z"}
        {"role":"assistant","content":"Found the parser definition. It uses .xAI.","timestamp":"2026-05-30T01:00:20Z"}
        """
        
        try sampleLogLines.write(to: sessionFile, atomically: true, encoding: .utf8)

        let result = try await CursorAgentParser(logDirectoryOverride: tempDir.path).parse()
        
        XCTAssertEqual(result.usages.count, 1)
        XCTAssertEqual(result.conversations.count, 1)
        
        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertEqual(usage.sessionId, sessionId)
        XCTAssertEqual(usage.provider, .cursorAgent)
        XCTAssertEqual(usage.model, "cursor-agent-pro")
        XCTAssertTrue(usage.inputTokens > 0)
        XCTAssertTrue(usage.outputTokens > 0)
        XCTAssertEqual(usage.provenanceConfidence, .exact)

        let conv = try XCTUnwrap(result.conversations.first)
        XCTAssertEqual(conv.sessionId, sessionId)
        XCTAssertEqual(conv.messageCount, 2)
        XCTAssertEqual(conv.projectName, "Cursor Agent")
        XCTAssertTrue(conv.fullText.contains("codebase rules"))
        XCTAssertTrue(conv.fullText.contains("Found the parser"))
        XCTAssertTrue(conv.keyTools.contains("grep_search"))
        XCTAssertTrue(conv.keyFiles.contains("GrokParser.swift"))
    }

    func testParsesFixtureSessionFromNestedDir() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-cursor-agent-nested-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sessionId = "session-nested-id"
        let sessionDir = tempDir.appendingPathComponent(sessionId, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let summaryURL = sessionDir.appendingPathComponent("summary.json")
        let summaryContent = """
        {
            "model": "claude-3-5-sonnet",
            "title": "Nested Session Test",
            "projectName": "BurnBar",
            "info": {
                "cwd": "/Users/albertonunez/Documents/Windsurf/BurnBar"
            }
        }
        """
        try summaryContent.write(to: summaryURL, atomically: true, encoding: .utf8)

        let transcriptURL = sessionDir.appendingPathComponent("transcript.jsonl")
        let sampleLogLines = """
        {"source":"SYSTEM","type":"SYSTEM_MESSAGE","content":"System details.","created_at":"2026-05-30T02:00:00Z"}
        {"source":"USER_EXPLICIT","type":"USER_INPUT","content":"Let's implement a feature.","created_at":"2026-05-30T02:00:05Z"}
        {"source":"MODEL","type":"PLANNER_RESPONSE","content":"Absolutely, here is the code.","thinking":"Coding is fun.","tool_calls":[],"created_at":"2026-05-30T02:00:10Z"}
        """
        try sampleLogLines.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let result = try await CursorAgentParser(logDirectoryOverride: tempDir.path).parse()
        
        XCTAssertEqual(result.usages.count, 1)
        XCTAssertEqual(result.conversations.count, 1)
        
        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertEqual(usage.sessionId, sessionId)
        XCTAssertEqual(usage.provider, .cursorAgent)
        XCTAssertEqual(usage.model, "claude-3-5-sonnet")
        XCTAssertEqual(usage.projectName, "BurnBar")

        let conv = try XCTUnwrap(result.conversations.first)
        XCTAssertEqual(conv.sessionId, sessionId)
        XCTAssertEqual(conv.inferredTaskTitle, "Nested Session Test")
        XCTAssertEqual(conv.projectName, "BurnBar")
        XCTAssertEqual(conv.messageCount, 1)
        XCTAssertTrue(conv.fullText.contains("Coding is fun") == false) // Thinking is omitted from readable transcript text
        XCTAssertTrue(conv.fullText.contains("implement a feature"))
    }
}
