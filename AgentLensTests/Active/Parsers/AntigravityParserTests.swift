import XCTest
@testable import OpenBurnBar

final class AntigravityParserTests: XCTestCase {

    // MARK: - Helpers

    private func tempDir(_ name: String = "antigravity-parser-tests") -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    }

    /// Creates a fake conversation directory with a transcript_full.jsonl file.
    /// Returns (conversationDir, transcriptFile) URLs.
    private func createConversation(
        in brainDir: URL,
        sessionId: String = UUID().uuidString,
        lines: [String],
        useFullTranscript: Bool = true
    ) throws -> (dir: URL, transcript: URL) {
        let convDir = brainDir.appendingPathComponent(sessionId)
        let logsDir = convDir
            .appendingPathComponent(".system_generated")
            .appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

        let filename = useFullTranscript ? "transcript_full.jsonl" : "transcript.jsonl"
        let transcriptFile = logsDir.appendingPathComponent(filename)
        let content = lines.joined(separator: "\n") + "\n"
        try content.write(to: transcriptFile, atomically: true, encoding: .utf8)

        return (convDir, transcriptFile)
    }

    /// Builds a single JSONL line from parts.
    private func jsonLine(
        stepIndex: Int = 0,
        source: String,
        type: String,
        content: String = "",
        thinking: String? = nil,
        toolCalls: [[String: Any]]? = nil,
        createdAt: String = "2026-05-27T06:00:00Z"
    ) throws -> String {
        var dict: [String: Any] = [
            "step_index": stepIndex,
            "source": source,
            "type": type,
            "status": "DONE",
            "created_at": createdAt
        ]
        if !content.isEmpty { dict["content"] = content }
        if let thinking, !thinking.isEmpty { dict["thinking"] = thinking }
        if let toolCalls { dict["tool_calls"] = toolCalls }
        let data = try JSONSerialization.data(withJSONObject: dict)
        guard let line = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "AntigravityParserTests", code: 1)
        }
        return line
    }

    // MARK: - Provider Identity

    func testProviderReturnsAntigravity() {
        let parser = AntigravityParser()
        XCTAssertEqual(parser.provider, .antigravity)
    }

    // MARK: - Content Categorization

    func testUserContentCountedAsInput() throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let userContent = String(repeating: "Hello world ", count: 100) // ~1200 chars
        let lines = [
            try jsonLine(stepIndex: 0, source: "USER_EXPLICIT", type: "USER_INPUT", content: userContent)
        ]
        let (_, transcript) = try createConversation(in: root, lines: lines)
        let parser = AntigravityParser()

        let result = parser.parseSession(
            transcriptFile: transcript,
            sessionId: "test-user",
            fallbackModel: "test-model"
        )

        let usage = try XCTUnwrap(result?.usage)
        // Input tokens should be > 0 since user content contributes to input
        XCTAssertGreaterThan(usage.inputTokens, 0)
        // Output should be 0 — no assistant response
        XCTAssertEqual(usage.outputTokens, 0)
    }

    func testThinkingContentCountedAsOutput() throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let userContent = "What is 2+2?"
        let assistantContent = "The answer is 4."
        // Substantial thinking — this is the key content the old parser was missing
        let thinkingContent = String(repeating: "Let me analyze this step by step. ", count: 100)

        let lines = [
            try jsonLine(stepIndex: 0, source: "USER_EXPLICIT", type: "USER_INPUT", content: userContent),
            try jsonLine(stepIndex: 1, source: "MODEL", type: "PLANNER_RESPONSE",
                     content: assistantContent, thinking: thinkingContent)
        ]
        let (_, transcript) = try createConversation(in: root, lines: lines)
        let parser = AntigravityParser()

        let result = parser.parseSession(
            transcriptFile: transcript,
            sessionId: "test-thinking",
            fallbackModel: "test-model"
        )

        let usage = try XCTUnwrap(result?.usage)
        // Output tokens should be significantly more than just the visible assistant text
        // The thinking is ~3400 chars at 2.45 chars/token ≈ 1388 tokens
        // The visible is ~16 chars at 3.35 chars/token ≈ 5 tokens
        // Without thinking, output would be ~5 tokens; with thinking it should be ~1400+
        XCTAssertGreaterThan(usage.outputTokens, 100,
            "Output tokens should include thinking content, not just visible text")
    }

    func testToolOutputCountedAsInput() throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let userContent = "Show me the file."
        // Simulate a large VIEW_FILE result
        let toolOutput = String(repeating: "func example() { return true }\n", count: 200) // ~6200 chars

        let lines = [
            try jsonLine(stepIndex: 0, source: "USER_EXPLICIT", type: "USER_INPUT", content: userContent),
            try jsonLine(stepIndex: 1, source: "MODEL", type: "PLANNER_RESPONSE", content: "Let me look at that file.",
                     toolCalls: [["name": "view_file", "args": ["AbsolutePath": "/path/to/file.swift"]]]),
            try jsonLine(stepIndex: 2, source: "MODEL", type: "VIEW_FILE",
                     content: "File Path: `file:///path/to/file.swift`\n" + toolOutput)
        ]
        let (_, transcript) = try createConversation(in: root, lines: lines)
        let parser = AntigravityParser()

        let result = parser.parseSession(
            transcriptFile: transcript,
            sessionId: "test-tool-output",
            fallbackModel: "test-model"
        )

        let usage = try XCTUnwrap(result?.usage)
        // Input should be much larger than just user content because tool output feeds back as context
        // User: ~18 chars. Tool output: ~6200 chars. So input should reflect the total.
        let userOnlyEstimate = TokenExtractionUtility.estimatedTokenCount(for: 18, charsPerToken: 3.35)
        XCTAssertGreaterThan(usage.inputTokens, userOnlyEstimate * 10,
            "Input tokens should include tool output content, not just user text")
    }

    func testSystemMessagesCountedAsInput() throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let systemContent = String(repeating: "You are a helpful assistant. ", count: 200) // ~5600 chars
        let userContent = "Hi"

        let lines = [
            try jsonLine(stepIndex: 0, source: "USER_EXPLICIT", type: "USER_INPUT", content: userContent),
            try jsonLine(stepIndex: 1, source: "SYSTEM", type: "CONVERSATION_HISTORY", content: systemContent),
            try jsonLine(stepIndex: 2, source: "MODEL", type: "PLANNER_RESPONSE", content: "Hello!")
        ]
        let (_, transcript) = try createConversation(in: root, lines: lines)
        let parser = AntigravityParser()

        let result = parser.parseSession(
            transcriptFile: transcript,
            sessionId: "test-system",
            fallbackModel: "test-model"
        )

        let usage = try XCTUnwrap(result?.usage)
        // Input should include system content, not just user content
        let userOnlyEstimate = TokenExtractionUtility.estimatedTokenCount(for: 2, charsPerToken: 3.35)
        XCTAssertGreaterThan(usage.inputTokens, userOnlyEstimate * 10,
            "Input tokens should include system messages")
    }

    func testToolCallArgsCountedAsOutput() throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let userContent = "Search the codebase for token usage."
        // Tool call with substantial argument content
        let longQuery = String(repeating: "search term ", count: 100) // ~1200 chars

        let lines = [
            try jsonLine(stepIndex: 0, source: "USER_EXPLICIT", type: "USER_INPUT", content: userContent),
            try jsonLine(stepIndex: 1, source: "MODEL", type: "PLANNER_RESPONSE",
                     content: "Let me search for that.",
                     toolCalls: [
                        ["name": "grep_search", "args": [
                            "Query": longQuery,
                            "SearchPath": "/path/to/project",
                            "CaseInsensitive": "true",
                            "MatchPerLine": "true"
                        ]]
                     ])
        ]
        let (_, transcript) = try createConversation(in: root, lines: lines)
        let parser = AntigravityParser()

        let result = parser.parseSession(
            transcriptFile: transcript,
            sessionId: "test-tool-args",
            fallbackModel: "test-model"
        )

        let usage = try XCTUnwrap(result?.usage)
        // Output should include tool call arguments (model-generated content)
        let visibleOnlyEstimate = TokenExtractionUtility.estimatedTokenCount(
            for: "Let me search for that.".count, charsPerToken: 3.35)
        XCTAssertGreaterThan(usage.outputTokens, visibleOnlyEstimate * 2,
            "Output tokens should include tool call arguments")
    }

    func testSystemMessageTypeCountedAsInput() throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let userContent = "Fix this bug."
        let systemMessage = String(repeating: "Subagent report data. ", count: 200)

        let lines = [
            try jsonLine(stepIndex: 0, source: "USER_EXPLICIT", type: "USER_INPUT", content: userContent),
            try jsonLine(stepIndex: 1, source: "SYSTEM", type: "SYSTEM_MESSAGE", content: systemMessage),
            try jsonLine(stepIndex: 2, source: "MODEL", type: "PLANNER_RESPONSE", content: "Fixed.")
        ]
        let (_, transcript) = try createConversation(in: root, lines: lines)
        let parser = AntigravityParser()

        let result = parser.parseSession(
            transcriptFile: transcript,
            sessionId: "test-sysmsg",
            fallbackModel: "test-model"
        )

        let usage = try XCTUnwrap(result?.usage)
        // Verify system messages contribute to input
        XCTAssertGreaterThan(usage.inputTokens, 100,
            "SYSTEM_MESSAGE type should contribute to input tokens")
    }

    // MARK: - Model Extraction

    func testModelExtractedFromUserSettingsChange() throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let userContent = """
        Fix the bug.
        <USER_SETTINGS_CHANGE>
        The user changed setting `Model Selection` from None to Claude Opus 4.6 (Thinking). No need to comment on this change.
        </USER_SETTINGS_CHANGE>
        """

        let lines = [
            try jsonLine(stepIndex: 0, source: "USER_EXPLICIT", type: "USER_INPUT", content: userContent),
            try jsonLine(stepIndex: 1, source: "MODEL", type: "PLANNER_RESPONSE", content: "Done.")
        ]
        let (_, transcript) = try createConversation(in: root, lines: lines)
        let parser = AntigravityParser()

        let result = parser.parseSession(
            transcriptFile: transcript,
            sessionId: "test-model",
            fallbackModel: "some-fallback-model"
        )

        let usage = try XCTUnwrap(result?.usage)
        XCTAssertEqual(usage.model, "Claude Opus 4.6 (Thinking)",
            "Should extract model from USER_SETTINGS_CHANGE, not use fallback")
    }

    func testFallbackModelUsedWhenNoSettingsChange() throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let lines = [
            try jsonLine(stepIndex: 0, source: "USER_EXPLICIT", type: "USER_INPUT", content: "Hello"),
            try jsonLine(stepIndex: 1, source: "MODEL", type: "PLANNER_RESPONSE", content: "Hi there!")
        ]
        let (_, transcript) = try createConversation(in: root, lines: lines)
        let parser = AntigravityParser()

        let result = parser.parseSession(
            transcriptFile: transcript,
            sessionId: "test-fallback",
            fallbackModel: "my-fallback-model"
        )

        let usage = try XCTUnwrap(result?.usage)
        XCTAssertEqual(usage.model, "my-fallback-model",
            "Should use fallback model when no USER_SETTINGS_CHANGE present")
    }

    func testModelExtractionHandlesGeminiFlash() throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let userContent = """
        Hello
        <USER_SETTINGS_CHANGE>
        The user changed setting `Model Selection` from None to Gemini 3.5 Flash (High). No need to comment.
        </USER_SETTINGS_CHANGE>
        """

        let lines = [
            try jsonLine(stepIndex: 0, source: "USER_EXPLICIT", type: "USER_INPUT", content: userContent),
            try jsonLine(stepIndex: 1, source: "MODEL", type: "PLANNER_RESPONSE", content: "Hi!")
        ]
        let (_, transcript) = try createConversation(in: root, lines: lines)
        let parser = AntigravityParser()

        let result = parser.parseSession(
            transcriptFile: transcript,
            sessionId: "test-gemini",
            fallbackModel: "fallback"
        )

        let usage = try XCTUnwrap(result?.usage)
        XCTAssertEqual(usage.model, "Gemini 3.5 Flash (High)")
    }

    // MARK: - Transcript File Preference

    func testPrefersFullTranscriptOverTruncated() throws {
        let root = tempDir()
        let sessionId = "test-full-pref"
        let convDir = root.appendingPathComponent(sessionId)
        let logsDir = convDir.appendingPathComponent(".system_generated").appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // The full transcript has much more content
        let bigContent = String(repeating: "Full transcript content. ", count: 500) // ~12500 chars
        let smallContent = "Truncated."

        let fullLines = [
            try jsonLine(stepIndex: 0, source: "USER_EXPLICIT", type: "USER_INPUT", content: bigContent),
            try jsonLine(stepIndex: 1, source: "MODEL", type: "PLANNER_RESPONSE", content: "Response.")
        ]
        let truncatedLines = [
            try jsonLine(stepIndex: 0, source: "USER_EXPLICIT", type: "USER_INPUT", content: smallContent),
            try jsonLine(stepIndex: 1, source: "MODEL", type: "PLANNER_RESPONSE", content: "Response.")
        ]

        try (fullLines.joined(separator: "\n") + "\n").write(
            to: logsDir.appendingPathComponent("transcript_full.jsonl"),
            atomically: true, encoding: .utf8)
        try (truncatedLines.joined(separator: "\n") + "\n").write(
            to: logsDir.appendingPathComponent("transcript.jsonl"),
            atomically: true, encoding: .utf8)

        let parser = AntigravityParser()
        let fullFile = logsDir.appendingPathComponent("transcript_full.jsonl")
        let result = parser.parseSession(
            transcriptFile: fullFile,
            sessionId: sessionId,
            fallbackModel: "test-model"
        )

        let usage = try XCTUnwrap(result?.usage)
        // Should have large input token count from the full transcript's big content
        XCTAssertGreaterThan(usage.inputTokens, 1000,
            "Should use full transcript content, not truncated version")
    }

    func testFallsBackToTruncatedTranscript() throws {
        let root = tempDir()
        let sessionId = "test-truncated"
        let convDir = root.appendingPathComponent(sessionId)
        let logsDir = convDir.appendingPathComponent(".system_generated").appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Only truncated transcript exists
        let lines = [
            try jsonLine(stepIndex: 0, source: "USER_EXPLICIT", type: "USER_INPUT", content: "Hello world"),
            try jsonLine(stepIndex: 1, source: "MODEL", type: "PLANNER_RESPONSE", content: "Hi!")
        ]
        try (lines.joined(separator: "\n") + "\n").write(
            to: logsDir.appendingPathComponent("transcript.jsonl"),
            atomically: true, encoding: .utf8)

        let parser = AntigravityParser()
        let result = parser.parseSession(
            transcriptFile: logsDir.appendingPathComponent("transcript.jsonl"),
            sessionId: sessionId,
            fallbackModel: "test-model"
        )

        XCTAssertNotNil(result?.usage, "Should parse successfully from truncated transcript")
    }

    // MARK: - Edge Cases

    func testEmptyTranscriptReturnsNil() throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let (_, transcript) = try createConversation(in: root, lines: [])
        let parser = AntigravityParser()

        let result = parser.parseSession(
            transcriptFile: transcript,
            sessionId: "empty",
            fallbackModel: "test-model"
        )

        XCTAssertNil(result?.usage, "Empty transcript should return nil usage")
    }

    func testOnlySystemMessagesReturnsValidResult() throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let systemContent = String(repeating: "System prompt context. ", count: 100)
        let lines = [
            try jsonLine(stepIndex: 0, source: "SYSTEM", type: "CONVERSATION_HISTORY", content: systemContent)
        ]
        let (_, transcript) = try createConversation(in: root, lines: lines)
        let parser = AntigravityParser()

        let result = parser.parseSession(
            transcriptFile: transcript,
            sessionId: "system-only",
            fallbackModel: "test-model"
        )

        // System-only content should still produce a result since it's input tokens
        let usage = try XCTUnwrap(result?.usage)
        XCTAssertGreaterThan(usage.inputTokens, 0)
    }

    // MARK: - Provenance

    func testProvenanceIsHighConfidenceEstimate() throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let lines = [
            try jsonLine(stepIndex: 0, source: "USER_EXPLICIT", type: "USER_INPUT", content: "Hello"),
            try jsonLine(stepIndex: 1, source: "MODEL", type: "PLANNER_RESPONSE", content: "Hi!")
        ]
        let (_, transcript) = try createConversation(in: root, lines: lines)
        let parser = AntigravityParser()

        let result = parser.parseSession(
            transcriptFile: transcript,
            sessionId: "test-provenance",
            fallbackModel: "test-model"
        )

        let usage = try XCTUnwrap(result?.usage)
        XCTAssertEqual(usage.provenanceMethod, .heuristicEstimate,
            "Should be heuristicEstimate since transcript has no API-level usage data")
        XCTAssertEqual(usage.provenanceConfidence, .highConfidenceEstimate,
            "Should be highConfidenceEstimate since all content categories are now counted")
    }

    // MARK: - Conversation Record

    func testConversationRecordExtractsToolNames() throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let lines = [
            try jsonLine(stepIndex: 0, source: "USER_EXPLICIT", type: "USER_INPUT", content: "Search the code."),
            try jsonLine(stepIndex: 1, source: "MODEL", type: "PLANNER_RESPONSE",
                     content: "Let me search.",
                     toolCalls: [
                        ["name": "grep_search", "args": ["Query": "hello"]],
                        ["name": "view_file", "args": ["AbsolutePath": "/file.swift"]],
                        ["name": "grep_search", "args": ["Query": "world"]]
                     ]),
            try jsonLine(stepIndex: 2, source: "MODEL", type: "GREP_SEARCH", content: "Results..."),
            try jsonLine(stepIndex: 3, source: "MODEL", type: "VIEW_FILE",
                     content: "File Path: `file:///path/to/test.swift`\ncode here")
        ]
        let (_, transcript) = try createConversation(in: root, lines: lines)
        let parser = AntigravityParser()

        let result = parser.parseSession(
            transcriptFile: transcript,
            sessionId: "test-tools",
            fallbackModel: "test-model"
        )

        let conv = try XCTUnwrap(result?.conversation)
        XCTAssertTrue(conv.keyTools.contains("grep_search"))
        XCTAssertTrue(conv.keyTools.contains("view_file"))
        XCTAssertTrue(conv.keyFiles.contains("test.swift"))
    }

    func testConversationRecordStripsTitleMetadata() throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let userContent = """
        <user_information>lots of metadata here</user_information>
        <USER_SETTINGS_CHANGE>model changed</USER_SETTINGS_CHANGE>
        Fix the token counting bug
        <ADDITIONAL_METADATA>timestamp info</ADDITIONAL_METADATA>
        """

        let lines = [
            try jsonLine(stepIndex: 0, source: "USER_EXPLICIT", type: "USER_INPUT", content: userContent),
            try jsonLine(stepIndex: 1, source: "MODEL", type: "PLANNER_RESPONSE", content: "Done.")
        ]
        let (_, transcript) = try createConversation(in: root, lines: lines)
        let parser = AntigravityParser()

        let result = parser.parseSession(
            transcriptFile: transcript,
            sessionId: "test-title",
            fallbackModel: "test-model"
        )

        let conv = try XCTUnwrap(result?.conversation)
        // The inferred task title should be the actual user prompt, not metadata
        XCTAssertTrue(conv.inferredTaskTitle.contains("Fix the token counting bug"),
            "Title should be cleaned user prompt, got: \(conv.inferredTaskTitle)")
        XCTAssertFalse(conv.inferredTaskTitle.contains("user_information"),
            "Title should not contain metadata tags")
    }

    // MARK: - Project Name Extraction

    func testProjectNameExtractedFromCorpusMapping() throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let userContent = """
        <user_information>
        The USER's OS version is mac.
        The user has 1 active workspaces:
        /Users/albert/Documents/BurnBar -> Imagine-That-Ai/BurnBar
        </user_information>
        <USER_REQUEST>Fix the bug</USER_REQUEST>
        """

        let lines = [
            try jsonLine(stepIndex: 0, source: "USER_EXPLICIT", type: "USER_INPUT", content: userContent),
            try jsonLine(stepIndex: 1, source: "MODEL", type: "PLANNER_RESPONSE", content: "Fixed.")
        ]
        let (_, transcript) = try createConversation(in: root, lines: lines)
        let parser = AntigravityParser()

        let result = parser.parseSession(
            transcriptFile: transcript,
            sessionId: "test-project",
            fallbackModel: "test-model"
        )

        let usage = try XCTUnwrap(result?.usage)
        XCTAssertEqual(usage.projectName, "Imagine-That-Ai/BurnBar",
            "Should extract project name from corpus mapping")
    }

    func testProjectNameFallsBackToAntigravity() throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let lines = [
            try jsonLine(stepIndex: 0, source: "USER_EXPLICIT", type: "USER_INPUT", content: "Hello"),
            try jsonLine(stepIndex: 1, source: "MODEL", type: "PLANNER_RESPONSE", content: "Hi!")
        ]
        let (_, transcript) = try createConversation(in: root, lines: lines)
        let parser = AntigravityParser()

        let result = parser.parseSession(
            transcriptFile: transcript,
            sessionId: "test-default-project",
            fallbackModel: "test-model"
        )

        let usage = try XCTUnwrap(result?.usage)
        XCTAssertEqual(usage.projectName, "Antigravity",
            "Should default to 'Antigravity' when no workspace info found")
    }

    // MARK: - Comprehensive Multi-Turn Session

    func testRealisticMultiTurnSession() throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let systemPrompt = String(repeating: "System instruction. ", count: 300)      // ~6000 chars
        let userPrompt = "Fix the token counting for Antigravity."                     // ~40 chars
        let thinkingBlock = String(repeating: "I need to analyze the parser. ", count: 200)  // ~6000 chars
        let assistantResponse = "Let me investigate the parser implementation."        // ~44 chars
        let fileContent = String(repeating: "import Foundation\nfunc test() {}\n", count: 100) // ~3300 chars
        let searchResults = String(repeating: "file.swift:42: match found\n", count: 50) // ~1350 chars

        let settingsChangeMeta = """
        <USER_SETTINGS_CHANGE>
        The user changed setting `Model Selection` from None to Claude Opus 4.6 (Thinking). No need to comment.
        </USER_SETTINGS_CHANGE>
        """

        let lines = [
            // System context
            try jsonLine(stepIndex: 0, source: "SYSTEM", type: "CONVERSATION_HISTORY", content: systemPrompt,
                     createdAt: "2026-05-27T06:00:00Z"),
            // User request with metadata
            try jsonLine(stepIndex: 1, source: "USER_EXPLICIT", type: "USER_INPUT",
                     content: userPrompt + "\n" + settingsChangeMeta,
                     createdAt: "2026-05-27T06:00:01Z"),
            // Model response with thinking and tool calls
            try jsonLine(stepIndex: 2, source: "MODEL", type: "PLANNER_RESPONSE",
                     content: assistantResponse, thinking: thinkingBlock,
                     toolCalls: [
                        ["name": "view_file", "args": ["AbsolutePath": "/path/to/AntigravityParser.swift"]],
                        ["name": "grep_search", "args": [
                            "Query": "tokenCount",
                            "SearchPath": "/path/to/project",
                            "MatchPerLine": "true"
                        ]]
                     ],
                     createdAt: "2026-05-27T06:00:05Z"),
            // Tool results
            try jsonLine(stepIndex: 3, source: "MODEL", type: "VIEW_FILE",
                     content: "File Path: `file:///path/to/AntigravityParser.swift`\n" + fileContent,
                     createdAt: "2026-05-27T06:00:06Z"),
            try jsonLine(stepIndex: 4, source: "MODEL", type: "GREP_SEARCH",
                     content: searchResults,
                     createdAt: "2026-05-27T06:00:07Z"),
            // Follow-up subagent message
            try jsonLine(stepIndex: 5, source: "SYSTEM", type: "SYSTEM_MESSAGE",
                     content: "Subagent completed research: found 5 issues.",
                     createdAt: "2026-05-27T06:00:10Z"),
            // Second model response
            try jsonLine(stepIndex: 6, source: "MODEL", type: "PLANNER_RESPONSE",
                     content: "Based on my analysis, I'll now rewrite the parser.",
                     thinking: "The key issues are clear now.",
                     createdAt: "2026-05-27T06:00:15Z")
        ]

        let (_, transcript) = try createConversation(in: root, lines: lines)
        let parser = AntigravityParser()

        let result = parser.parseSession(
            transcriptFile: transcript,
            sessionId: "test-realistic",
            fallbackModel: "fallback"
        )

        let usage = try XCTUnwrap(result?.usage)
        let conv = try XCTUnwrap(result?.conversation)

        // Verify model extracted from settings change
        XCTAssertEqual(usage.model, "Claude Opus 4.6 (Thinking)")

        // Verify input includes system + user + tool outputs
        // System: ~6000 + User: ~40+meta + VIEW_FILE: ~3300 + GREP_SEARCH: ~1350 + SYSTEM_MESSAGE: ~50
        // ≈ 10740+ chars → should be well over 2000 tokens
        XCTAssertGreaterThan(usage.inputTokens, 2000,
            "Input should include system+user+tool outputs, got \(usage.inputTokens)")

        // Verify output includes assistant + thinking + tool args
        // Assistant: ~44+~50 = ~94 + Thinking: ~6000+~30 ≈ 6030 + Tool args: ~100
        // ≈ 6224 chars → should be well over 500 tokens
        XCTAssertGreaterThan(usage.outputTokens, 500,
            "Output should include assistant+thinking+tool args, got \(usage.outputTokens)")

        // Verify conversation metadata
        XCTAssertEqual(conv.provider, .antigravity)
        XCTAssertTrue(conv.keyTools.contains("view_file"))
        XCTAssertTrue(conv.keyTools.contains("grep_search"))
        XCTAssertTrue(conv.keyFiles.contains("AntigravityParser.swift"))
        XCTAssertEqual(usage.provenanceConfidence, .highConfidenceEstimate)
    }

    // MARK: - String Length Utility

    func testStringLengthOfNestedValues() {
        // String
        XCTAssertEqual(AntigravityParser.stringLength(of: "hello"), 5)

        // Array
        XCTAssertEqual(AntigravityParser.stringLength(of: ["ab", "cd"] as [Any]), 4)

        // Dict
        let dict: [String: Any] = ["key": "val"]
        XCTAssertEqual(AntigravityParser.stringLength(of: dict), 6) // "key" + "val"

        // Number
        XCTAssertEqual(AntigravityParser.stringLength(of: NSNumber(value: 42)), 2) // "42"
    }

    // MARK: - Timestamp Extraction

    func testTimestampsExtractedFromTranscript() throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let lines = [
            try jsonLine(stepIndex: 0, source: "USER_EXPLICIT", type: "USER_INPUT",
                     content: "Start", createdAt: "2026-05-27T06:00:00Z"),
            try jsonLine(stepIndex: 1, source: "MODEL", type: "PLANNER_RESPONSE",
                     content: "End.", createdAt: "2026-05-27T06:30:00Z")
        ]
        let (_, transcript) = try createConversation(in: root, lines: lines)
        let parser = AntigravityParser()

        let result = parser.parseSession(
            transcriptFile: transcript,
            sessionId: "test-timestamps",
            fallbackModel: "test-model"
        )

        let usage = try XCTUnwrap(result?.usage)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        XCTAssertEqual(formatter.string(from: usage.startTime), "2026-05-27T06:00:00Z")
        XCTAssertEqual(formatter.string(from: usage.endTime), "2026-05-27T06:30:00Z")
    }

    func testFractionalSecondTimestampsParsed() throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let lines = [
            try jsonLine(stepIndex: 0, source: "USER_EXPLICIT", type: "USER_INPUT",
                     content: "Hi", createdAt: "2026-05-27T06:00:00.123Z"),
            try jsonLine(stepIndex: 1, source: "MODEL", type: "PLANNER_RESPONSE",
                     content: "Hello!", createdAt: "2026-05-27T06:00:05.456Z")
        ]
        let (_, transcript) = try createConversation(in: root, lines: lines)
        let parser = AntigravityParser()

        let result = parser.parseSession(
            transcriptFile: transcript,
            sessionId: "test-frac-ts",
            fallbackModel: "test-model"
        )

        XCTAssertNotNil(result?.usage, "Should parse fractional-second timestamps successfully")
        let usage = try XCTUnwrap(result?.usage)
        // Verify the timestamps are distinct (start < end)
        XCTAssertLessThan(usage.startTime, usage.endTime)
    }
}
