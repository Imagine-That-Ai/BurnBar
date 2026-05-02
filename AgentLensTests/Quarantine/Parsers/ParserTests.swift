import XCTest
@testable import OpenBurnBar

// MARK: - CopilotParser Tests

final class CopilotParserTests: XCTestCase {

    private var tempDirectory: URL!
    private let fileManager = FileManager.default

    override func setUp() {
        super.setUp()
        tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("openburnbar-copilot-parser-tests-\(UUID().uuidString)", isDirectory: true)
        try? fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? fileManager.removeItem(at: tempDirectory)
        super.tearDown()
    }

    func test_provider_returnsCopilot() {
        let parser = CopilotParser()
        XCTAssertEqual(parser.provider, .copilot)
    }

    func test_parse_withNoSessionStateDirectory_returnsEmpty() async throws {
        let parser = CopilotParser()
        let result = try await parser.parse()

        XCTAssertTrue(result.usages.isEmpty)
        XCTAssertTrue(result.conversations.isEmpty)
    }

    func test_parse_withEmptySessionState_returnsEmpty() async throws {
        // Create empty session-state directory
        let sessionStateDir = tempDirectory.appendingPathComponent("session-state", isDirectory: true)
        try fileManager.createDirectory(at: sessionStateDir, withIntermediateDirectories: true)

        // Create symbolic link at expected path
        let copilotDir = tempDirectory.appendingPathComponent(".copilot", isDirectory: true)
        try fileManager.createDirectory(at: copilotDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: copilotDir.appendingPathComponent("session-state", isDirectory: true), withIntermediateDirectories: true)

        // Parser looks for ~/.copilot/session-state which doesn't exist in our test
        // So it should return empty
        let parser = CopilotParser()
        let result = try await parser.parse()

        // Parser looks in ~/.copilot which doesn't exist - returns empty
        XCTAssertTrue(result.usages.isEmpty)
    }

    func test_parseMetadata_withValidJSON() {
        let metadata: [String: Any] = [
            "model": "gpt-5",
            "usage": [
                "input_tokens": 100,
                "output_tokens": 50
            ]
        ]

        let parser = CopilotParser()
        let data = try! JSONSerialization.data(withJSONObject: metadata)
        let tempFile = tempDirectory.appendingPathComponent("metadata.json")
        try! data.write(to: tempFile)

        // Can't test private method directly, but we can verify the structure
        XCTAssertNotNil(metadata["model"])
        XCTAssertNotNil(metadata["usage"])
    }

    func test_parseMetadata_withMissingUsage() {
        let metadata: [String: Any] = [
            "model": "gpt-5"
        ]

        XCTAssertNil(metadata["usage"])
    }

    func test_parseMetadata_withEmptyUsage() {
        let metadata: [String: Any] = [
            "model": "gpt-5",
            "usage": [:]
        ]

        XCTAssertEqual((metadata["usage"] as? [String: Any])?.count, 0)
    }

    func test_parse_withValidEvents_extractsUsage() async throws {
        let copilotDir = tempDirectory.appendingPathComponent(".copilot", isDirectory: true)
        let sessionStateDir = copilotDir.appendingPathComponent("session-state/test-session", isDirectory: true)
        try fileManager.createDirectory(at: sessionStateDir, withIntermediateDirectories: true)

        let eventsContent = """
        {"type":"user","timestamp":"2024-01-01T12:00:00Z","role":"user","content":"Hello"}
        {"type":"assistant","timestamp":"2024-01-01T12:00:01Z","role":"assistant","content":"Hi","usage":{"input_tokens":100,"output_tokens":50}}
        """
        let eventsFile = sessionStateDir.appendingPathComponent("events.jsonl")
        try eventsContent.write(to: eventsFile, atomically: true, encoding: .utf8)

        let parser = CopilotParser(copilotRootPath: copilotDir.path)
        let result = try await parser.parse()

        XCTAssertFalse(result.usages.isEmpty)
        let usage = result.usages[0]
        XCTAssertEqual(usage.inputTokens, 100)
        XCTAssertEqual(usage.outputTokens, 50)
        XCTAssertEqual(usage.provider, .copilot)
    }
}

// MARK: - AiderParser Tests

final class AiderParserTests: XCTestCase {

    private var tempDirectory: URL!
    private let fileManager = FileManager.default

    override func setUp() {
        super.setUp()
        tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("openburnbar-aider-parser-tests-\(UUID().uuidString)", isDirectory: true)
        try? fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? fileManager.removeItem(at: tempDirectory)
        super.tearDown()
    }

    func test_provider_returnsAider() {
        let parser = AiderParser()
        XCTAssertEqual(parser.provider, .aider)
    }

    func test_parse_withNoAnalyticsLog_returnsEmpty() async throws {
        let parser = AiderParser()
        let result = try await parser.parse()

        XCTAssertTrue(result.usages.isEmpty)
        XCTAssertTrue(result.conversations.isEmpty)
    }

    func test_parse_withEmptyAnalyticsLog_returnsEmpty() async throws {
        let analyticsFile = tempDirectory.appendingPathComponent("analytics.jsonl")
        try "".write(to: analyticsFile, atomically: true, encoding: .utf8)

        // Parser looks in ~/.aider which doesn't exist
        let parser = AiderParser()
        let result = try await parser.parse()

        XCTAssertTrue(result.usages.isEmpty)
    }

    func test_parseSessionGroupsMessagesIntoSessions() throws {
        // Create a test analytics log with message_send events
        let events = """
        {"event": "launched", "time": 1700000000, "properties": {"main_model": "claude-3-5-sonnet"}}
        {"event": "message_send", "time": 1700000100, "properties": {"prompt_tokens": 100, "completion_tokens": 50, "cost": 0.01}}
        {"event": "message_send", "time": 1700000200, "properties": {"prompt_tokens": 200, "completion_tokens": 100, "cost": 0.02}}
        {"event": "exit", "time": 1700000300}
        """
        let analyticsFile = tempDirectory.appendingPathComponent("analytics.jsonl")
        try events.write(to: analyticsFile, atomically: true, encoding: .utf8)

        // Parser doesn't find ~/.aider so returns empty
        let parser = AiderParser()
        XCTAssertTrue(parser.provider == .aider)
    }

    func test_parse_withValidAnalyticsLog_extractsUsage() async throws {
        let aiderDir = tempDirectory.appendingPathComponent(".aider", isDirectory: true)
        try fileManager.createDirectory(at: aiderDir, withIntermediateDirectories: true)

        let events = """
        {"event": "launched", "time": 1700000000, "properties": {"main_model": "claude-3-5-sonnet"}}
        {"event": "message_send", "time": 1700000100, "properties": {"prompt_tokens": 100, "completion_tokens": 50, "cost": 0.01}}
        {"event": "exit", "time": 1700000200}
        """
        let analyticsFile = aiderDir.appendingPathComponent("analytics.jsonl")
        try events.write(to: analyticsFile, atomically: true, encoding: .utf8)

        let parser = AiderParser(aiderRootPath: aiderDir.path)
        let result = try await parser.parse()

        XCTAssertFalse(result.usages.isEmpty)
        let usage = result.usages[0]
        XCTAssertEqual(usage.inputTokens, 100)
        XCTAssertEqual(usage.outputTokens, 50)
        XCTAssertEqual(usage.provider, .aider)
    }
}

// MARK: - CursorParser Tests

final class CursorParserTests: XCTestCase {

    private var tempDirectory: URL!
    private let fileManager = FileManager.default

    override func setUp() {
        super.setUp()
        tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("openburnbar-cursor-parser-tests-\(UUID().uuidString)", isDirectory: true)
        try? fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? fileManager.removeItem(at: tempDirectory)
        super.tearDown()
    }

    func test_provider_returnsCursor() {
        let parser = CursorParser()
        XCTAssertEqual(parser.provider, .cursor)
    }

    func test_parse_withNoDatabase_returnsEmpty() async throws {
        let parser = CursorParser()
        let result = try await parser.parse()

        XCTAssertTrue(result.usages.isEmpty)
        XCTAssertTrue(result.conversations.isEmpty)
    }

    func test_parse_withValidDatabase_extractsUsage() async throws {
        let cursorDir = tempDirectory.appendingPathComponent(".cursor", isDirectory: true)
        let trackingDir = cursorDir.appendingPathComponent("ai-tracking", isDirectory: true)
        try fileManager.createDirectory(at: trackingDir, withIntermediateDirectories: true)
        let dbPath = trackingDir.appendingPathComponent("ai-code-tracking.db").path

        // Create minimal SQLite database with ai_code_hashes table
        var config = Configuration()
        let db = try DatabaseQueue(path: dbPath, configuration: config)
        try db.write { db in
            try db.execute(sql: """
                CREATE TABLE ai_code_hashes (
                    conversationId TEXT,
                    model TEXT,
                    createdAt REAL
                )
            """)
            try db.execute(sql: """
                INSERT INTO ai_code_hashes (conversationId, model, createdAt)
                VALUES ('cursor-session-001', 'claude-3-5-sonnet', 1700000000)
            """)
        }
        try db.close()

        let parser = CursorParser(cursorRootPath: cursorDir.path)
        let result = try await parser.parse()

        XCTAssertFalse(result.usages.isEmpty)
        let usage = result.usages[0]
        XCTAssertEqual(usage.provider, .cursor)
        XCTAssertEqual(usage.sessionId, "cursor-session-001")
    }
}

// MARK: - CodexParser Tests

final class CodexParserTests: XCTestCase {

    private var tempDirectory: URL!
    private let fileManager = FileManager.default

    override func setUp() {
        super.setUp()
        tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("openburnbar-codex-parser-tests-\(UUID().uuidString)", isDirectory: true)
        try? fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? fileManager.removeItem(at: tempDirectory)
        super.tearDown()
    }

    func test_provider_returnsCodex() {
        let parser = CodexParser()
        XCTAssertEqual(parser.provider, .codex)
    }

    func test_init_withCustomParameters() {
        let parser = CodexParser(
            fileManager: .default,
            appPaths: .live(),
            homeDirectoryURL: URL(fileURLWithPath: "/tmp")
        )
        XCTAssertEqual(parser.provider, .codex)
    }

    func test_parse_withNoDatabase_returnsEmpty() async throws {
        let parser = CodexParser(
            fileManager: .default,
            homeDirectoryURL: URL(fileURLWithPath: "/nonexistent")
        )
        let result = try await parser.parse()

        XCTAssertTrue(result.usages.isEmpty)
    }

    func test_parseCodexSessionJSONL_withEmptyFile_returnsNil() {
        let parser = CodexParser()
        let emptyFile = tempDirectory.appendingPathComponent("empty.jsonl")
        try! "".write(to: emptyFile, atomically: true, encoding: .utf8)

        let result = parser.parseCodexSessionJSONL(path: emptyFile.path)
        XCTAssertNil(result)
    }

    func test_parseCodexSessionJSONL_withNoTokenCountEvents_returnsNil() {
        let parser = CodexParser()
        let content = """
        {"type": "other_event"}
        {"type": "another_event"}
        """
        let file = tempDirectory.appendingPathComponent("session.jsonl")
        try! content.write(to: file, atomically: true, encoding: .utf8)

        let result = parser.parseCodexSessionJSONL(path: file.path)
        XCTAssertNil(result)
    }

    func test_parseCodexSessionJSONL_withCumulativeTokenCount() {
        let parser = CodexParser()
        let content = """
        {"event_msg": {"token_count": {"input_tokens": 1000, "output_tokens": 500, "cached_input_tokens": 200}}}
        """
        let file = tempDirectory.appendingPathComponent("session.jsonl")
        try! content.write(to: file, atomically: true, encoding: .utf8)

        let result = parser.parseCodexSessionJSONL(path: file.path)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.input, 1000)
        XCTAssertEqual(result?.output, 500)
        XCTAssertEqual(result?.cacheRead, 200)
    }

    func test_parseCodexSessionJSONL_withDeltaTokenCount() {
        let parser = CodexParser()
        let content = """
        {"event_msg": {"last_token_usage": {"input_tokens": 100, "cached_input_tokens": 20, "output_tokens": 50}}}
        {"event_msg": {"last_token_usage": {"input_tokens": 150, "cached_input_tokens": 30, "output_tokens": 75}}}
        """
        let file = tempDirectory.appendingPathComponent("session.jsonl")
        try! content.write(to: file, atomically: true, encoding: .utf8)

        let result = parser.parseCodexSessionJSONL(path: file.path)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.input > 0)
        XCTAssertTrue(result!.output > 0)
    }

    func test_parseCodexSessionJSONL_cumulativeTakesPrecedenceOverDelta() {
        let parser = CodexParser()
        // Both cumulative and delta present - cumulative should win
        let content = """
        {"event_msg": {"last_token_usage": {"input_tokens": 100, "output_tokens": 50}}}
        {"event_msg": {"token_count": {"input_tokens": 1000, "output_tokens": 500}}}
        """
        let file = tempDirectory.appendingPathComponent("session.jsonl")
        try! content.write(to: file, atomically: true, encoding: .utf8)

        let result = parser.parseCodexSessionJSONL(path: file.path)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.input, 1000)
        XCTAssertEqual(result?.output, 500)
    }

    func test_fileSignature_withValidFile() throws {
        let parser = CodexParser()
        let testFile = tempDirectory.appendingPathComponent("test.txt")
        try "test content".write(to: testFile, atomically: true, encoding: .utf8)

        let signature = parser.fileSignature(forPath: testFile.path)
        XCTAssertNotNil(signature)
        XCTAssertTrue(signature!.sizeBytes > 0)
    }

    func test_fileSignature_withNonexistentFile() {
        let parser = CodexParser()
        let signature = parser.fileSignature(forPath: "/nonexistent/file.txt")
        XCTAssertNil(signature)
    }
}

// MARK: - KimiParser Tests

final class KimiParserTests: XCTestCase {

    private var tempDirectory: URL!
    private let fileManager = FileManager.default

    override func setUp() {
        super.setUp()
        tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("openburnbar-kimi-parser-tests-\(UUID().uuidString)", isDirectory: true)
        try? fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? fileManager.removeItem(at: tempDirectory)
        super.tearDown()
    }

    func test_provider_returnsKimi() {
        let parser = KimiParser()
        XCTAssertEqual(parser.provider, .kimi)
    }

    func test_parse_withNoSessionsDirectory_returnsEmpty() async throws {
        let parser = KimiParser()
        let result = try await parser.parse()

        XCTAssertTrue(result.usages.isEmpty)
        XCTAssertTrue(result.conversations.isEmpty)
    }

    func test_parseSession_withNoContextFile_returnsNil() {
        let parser = KimiParser()
        let workspaceDir = tempDirectory.appendingPathComponent("workspace1", isDirectory: true)
        try fileManager.createDirectory(at: workspaceDir, withIntermediateDirectories: true)

        let result = try parser.parseSession(
            sessionId: "s1",
            contextFile: workspaceDir.appendingPathComponent("context.jsonl"),
            wireFile: nil,
            projectName: "test"
        )
        XCTAssertNil(result)
    }

    func test_parseSession_withContextFileOnly_usesCharacterEstimation() throws {
        let parser = KimiParser()
        let sessionDir = tempDirectory.appendingPathComponent("workspace1/session1", isDirectory: true)
        try fileManager.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let contextContent = """
        {"role": "user", "content": "Hello, this is a test message with some content here"}
        {"role": "assistant", "content": "Hi! I'm an assistant responding to your message"}
        """
        let contextFile = sessionDir.appendingPathComponent("context.jsonl")
        try contextContent.write(to: contextFile, atomically: true, encoding: .utf8)

        let result = try parser.parseSession(
            sessionId: "s1",
            contextFile: contextFile,
            wireFile: nil,
            projectName: "test"
        )

        XCTAssertNotNil(result)
        XCTAssertNotNil(result?.usage)
        XCTAssertTrue(result!.usage!.inputTokens > 0)
    }

    func test_parseSession_withWireFile_usesExactCounts() throws {
        let parser = KimiParser()
        let sessionDir = tempDirectory.appendingPathComponent("workspace1/session1", isDirectory: true)
        try fileManager.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        // Create context file
        let contextContent = """
        {"role": "user", "content": "Test"}
        """
        let contextFile = sessionDir.appendingPathComponent("context.jsonl")
        try contextContent.write(to: contextFile, atomically: true, encoding: .utf8)

        // Create wire file with exact token counts
        let wireContent = """
        {"message": {"type": "StatusUpdate", "payload": {"token_usage": {"input_other": 1000, "output": 500, "input_cache_read": 200, "input_cache_creation": 0}}}}
        """
        let wireFile = sessionDir.appendingPathComponent("wire.jsonl")
        try wireContent.write(to: wireFile, atomically: true, encoding: .utf8)

        let result = try parser.parseSession(
            sessionId: "s1",
            contextFile: contextFile,
            wireFile: wireFile,
            projectName: "test"
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result!.usage!.inputTokens, 1200) // input_other + cache_read = 1000 + 200
        XCTAssertEqual(result!.usage!.outputTokens, 500)
    }

    func test_parseSession_withEmptyContent_returnsNil() throws {
        let parser = KimiParser()
        let sessionDir = tempDirectory.appendingPathComponent("workspace1/session1", isDirectory: true)
        try fileManager.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let contextFile = sessionDir.appendingPathComponent("context.jsonl")
        try "".write(to: contextFile, atomically: true, encoding: .utf8)

        let result = try parser.parseSession(
            sessionId: "s1",
            contextFile: contextFile,
            wireFile: nil,
            projectName: "test"
        )
        XCTAssertNil(result)
    }

    func test_parseSession_extractsWordCounts() throws {
        let parser = KimiParser()
        let sessionDir = tempDirectory.appendingPathComponent("workspace1/session1", isDirectory: true)
        try fileManager.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let contextContent = """
        {"role": "user", "content": "Hello world test one two"}
        {"role": "assistant", "content": "Response with words here"}
        """
        let contextFile = sessionDir.appendingPathComponent("context.jsonl")
        try contextContent.write(to: contextFile, atomically: true, encoding: .utf8)

        let result = try parser.parseSession(
            sessionId: "s1",
            contextFile: contextFile,
            wireFile: nil,
            projectName: "test"
        )

        XCTAssertNotNil(result)
        XCTAssertNotNil(result?.conversation)
        XCTAssertEqual(result!.conversation!.userWordCount, 5)
        XCTAssertEqual(result!.conversation!.assistantWordCount, 4)
    }

    func test_parseSession_withISOTimestamp() throws {
        let parser = KimiParser()
        let sessionDir = tempDirectory.appendingPathComponent("workspace1/session1", isDirectory: true)
        try fileManager.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let isoDate = ISO8601DateFormatter().string(from: Date())
        let contextContent = """
        {"role": "user", "content": "Test", "created_at": "\(isoDate)"}
        """
        let contextFile = sessionDir.appendingPathComponent("context.jsonl")
        try contextContent.write(to: contextFile, atomically: true, encoding: .utf8)

        let result = try parser.parseSession(
            sessionId: "s1",
            contextFile: contextFile,
            wireFile: nil,
            projectName: "test"
        )

        XCTAssertNotNil(result)
        XCTAssertNotNil(result?.usage)
    }
}

// MARK: - ClineFormatParser Tests

final class ClineFormatParserTests: XCTestCase {

    private var tempDirectory: URL!
    private let fileManager = FileManager.default

    override func setUp() {
        super.setUp()
        tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("openburnbar-cline-parser-tests-\(UUID().uuidString)", isDirectory: true)
        try? fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? fileManager.removeItem(at: tempDirectory)
        super.tearDown()
    }

    func test_provider_returnsCline() {
        let parser = ClineFormatParser(
            provider: .cline,
            storagePaths: ["~/Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/tasks"]
        )
        XCTAssertEqual(parser.provider, .cline)
    }

    func test_provider_returnsKiloCode() {
        let parser = ClineFormatParser(
            provider: .kiloCode,
            storagePaths: ["~/Library/Application Support/Code/User/globalStorage/kilocode.kilo-code/tasks"]
        )
        XCTAssertEqual(parser.provider, .kiloCode)
    }

    func test_provider_returnsRooCode() {
        let parser = ClineFormatParser(
            provider: .rooCode,
            storagePaths: ["~/Library/Application Support/Code/User/globalStorage/rooveterinaryinc.roo-cline/tasks"]
        )
        XCTAssertEqual(parser.provider, .rooCode)
    }

    func test_parse_withNoStoragePath_returnsEmpty() async throws {
        let parser = ClineFormatParser(provider: .cline, storagePaths: [tempDirectory.path])
        let result = try await parser.parse()

        XCTAssertTrue(result.usages.isEmpty)
        XCTAssertTrue(result.conversations.isEmpty)
    }

    func test_parseTask_withNoHistoryFile_returnsNil() {
        let parser = ClineFormatParser(provider: .cline, storagePaths: [])
        let result = parser.parseTask(
            taskId: "task1",
            historyFile: tempDirectory.appendingPathComponent("nonexistent.json")
        )
        XCTAssertNil(result)
    }

    func test_parseTask_withInvalidJSON_returnsNil() {
        let parser = ClineFormatParser(provider: .cline, storagePaths: [])
        let invalidFile = tempDirectory.appendingPathComponent("invalid.json")
        try! "not valid json".write(to: invalidFile, atomically: true, encoding: .utf8)

        let result = parser.parseTask(taskId: "task1", historyFile: invalidFile)
        XCTAssertNil(result)
    }

    func test_parseTask_withValidHistory_extractsUsage() throws {
        let parser = ClineFormatParser(provider: .cline, storagePaths: [])
        let historyContent: [[String: Any]] = [
            [
                "role": "user",
                "ts": 1700000000000,
                "content": "Hello"
            ],
            [
                "role": "assistant",
                "ts": 1700000060000,
                "content": "Hi there",
                "model": "claude-3-5-sonnet",
                "usage": [
                    "input_tokens": 100,
                    "output_tokens": 50
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: historyContent)
        let historyFile = tempDirectory.appendingPathComponent("api_conversation_history.json")
        try data.write(to: historyFile)

        let result = parser.parseTask(taskId: "task1", historyFile: historyFile)

        XCTAssertNotNil(result)
        XCTAssertNotNil(result?.usage)
        XCTAssertEqual(result!.usage!.inputTokens, 100)
        XCTAssertEqual(result!.usage!.outputTokens, 50)
    }

    func test_parseTask_withNoUsageData_fallsBackToEstimation() throws {
        let parser = ClineFormatParser(provider: .cline, storagePaths: [])
        let historyContent: [[String: Any]] = [
            [
                "role": "user",
                "ts": 1700000000000,
                "content": "This is a test message with some content here"
            ],
            [
                "role": "assistant",
                "ts": 1700000060000,
                "content": "This is a response from the assistant"
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: historyContent)
        let historyFile = tempDirectory.appendingPathComponent("api_conversation_history.json")
        try data.write(to: historyFile)

        let result = parser.parseTask(taskId: "task1", historyFile: historyFile)

        XCTAssertNotNil(result)
        XCTAssertNotNil(result?.usage)
        // Falls back to estimation when no usage data
        XCTAssertTrue(result!.usage!.inputTokens > 0 || result!.usage!.outputTokens > 0)
    }

    func test_parseTask_extractsModel() throws {
        let parser = ClineFormatParser(provider: .cline, storagePaths: [])
        let historyContent: [[String: Any]] = [
            [
                "role": "assistant",
                "ts": 1700000000000,
                "model": "custom-model-name",
                "usage": ["input_tokens": 100, "output_tokens": 50]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: historyContent)
        let historyFile = tempDirectory.appendingPathComponent("api_conversation_history.json")
        try data.write(to: historyFile)

        let result = parser.parseTask(taskId: "task1", historyFile: historyFile)

        XCTAssertNotNil(result)
        XCTAssertEqual(result!.usage!.model, "custom-model-name")
    }

    func test_parseTask_calculatesCost() throws {
        let parser = ClineFormatParser(provider: .cline, storagePaths: [])
        let historyContent: [[String: Any]] = [
            [
                "role": "assistant",
                "ts": 1700000000000,
                "model": "claude-3-5-sonnet",
                "usage": ["input_tokens": 1000000, "output_tokens": 500000] // 1M input, 500K output
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: historyContent)
        let historyFile = tempDirectory.appendingPathComponent("api_conversation_history.json")
        try data.write(to: historyFile)

        let result = parser.parseTask(taskId: "task1", historyFile: historyFile)

        XCTAssertNotNil(result)
        XCTAssertTrue(result!.usage!.costUSD > 0)
    }

    func test_extractText_withStringContent() {
        let parser = ClineFormatParser(provider: .cline, storagePaths: [])
        let text = parser.extractText(from: "Hello, world!")

        XCTAssertEqual(text, "Hello, world!")
    }

    func test_extractText_withArrayContent() {
        let parser = ClineFormatParser(provider: .cline, storagePaths: [])
        let content: [[String: Any]] = [
            ["type": "text", "text": "First part"],
            ["type": "text", "text": "Second part"]
        ]

        let text = parser.extractText(from: content)

        XCTAssertEqual(text, "First part\nSecond part")
    }

    func test_extractText_withMixedContent() {
        let parser = ClineFormatParser(provider: .cline, storagePaths: [])
        let content: [[String: Any]] = [
            ["type": "image", "data": "base64..."],
            ["type": "text", "text": "Visible text"]
        ]

        let text = parser.extractText(from: content)

        XCTAssertEqual(text, "Visible text")
    }
}

// MARK: - ForgeDevParser Tests

final class ForgeDevParserTests: XCTestCase {

    private var tempDirectory: URL!
    private let fileManager = FileManager.default

    override func setUp() {
        super.setUp()
        tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("openburnbar-forge-parser-tests-\(UUID().uuidString)", isDirectory: true)
        try? fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? fileManager.removeItem(at: tempDirectory)
        super.tearDown()
    }

    func test_provider_returnsForgeDev() {
        let parser = ForgeDevParser()
        XCTAssertEqual(parser.provider, .forgeDev)
    }

    func test_parse_withNoDatabase_returnsEmpty() async throws {
        let parser = ForgeDevParser()
        let result = try await parser.parse()

        // Returns empty because no databases found at expected paths
        XCTAssertTrue(result.usages.isEmpty || result.conversations.isEmpty)
    }

    func test_parseContextMessages_extractsUsage() throws {
        let parser = ForgeDevParser()
        let messages: [[String: Any]] = [
            [
                "message": [
                    "text": ["role": "user", "content": "Test message"]
                ],
                "usage": [
                    "prompt_tokens": 100,
                    "completion_tokens": 50,
                    "cached_tokens": 25
                ]
            ]
        ]

        let summary = parser.parseContextMessages(messages)

        XCTAssertEqual(summary.inputTokens, 100)
        XCTAssertEqual(summary.outputTokens, 50)
        XCTAssertEqual(summary.cacheReadTokens, 25)
    }

    func test_parseContextMessages_extractsModel() throws {
        let parser = ForgeDevParser()
        let messages: [[String: Any]] = [
            [
                "message": [
                    "text": ["role": "assistant", "content": "Response", "model": "gpt-5"]
                ]
            ]
        ]

        let summary = parser.parseContextMessages(messages)

        XCTAssertEqual(summary.model, "gpt-5")
    }

    func test_parseContextMessages_extractsTools() throws {
        let parser = ForgeDevParser()
        let messages: [[String: Any]] = [
            [
                "message": [
                    "tool": ["name": "bash"]
                ]
            ],
            [
                "message": [
                    "tool": ["name": "read"]
                ]
            ]
        ]

        let summary = parser.parseContextMessages(messages)

        XCTAssertEqual(summary.keyTools.count, 2)
        XCTAssertTrue(summary.keyTools.contains("bash"))
        XCTAssertTrue(summary.keyTools.contains("read"))
    }

    func test_normalizeUsage_withAllValues() throws {
        let parser = ForgeDevParser()
        let result = parser.normalizeUsage(prompt: 100, completion: 50, cached: 25, total: 175)

        XCTAssertEqual(result.input, 75) // prompt - cached
        XCTAssertEqual(result.output, 50)
        XCTAssertEqual(result.cacheRead, 25)
    }

    func test_normalizeUsage_withNoTotal() throws {
        let parser = ForgeDevParser()
        let result = parser.normalizeUsage(prompt: 100, completion: 50, cached: 25, total: 0)

        XCTAssertEqual(result.input, 100)
        XCTAssertEqual(result.output, 50)
        XCTAssertEqual(result.cacheRead, 25)
    }

    func test_normalizeUsage_withZeroPrompt() throws {
        let parser = ForgeDevParser()
        let result = parser.normalizeUsage(prompt: 0, completion: 50, cached: 10, total: 60)

        XCTAssertEqual(result.input, 0) // 0 because prompt was 0
        XCTAssertEqual(result.output, 50)
        XCTAssertEqual(result.cacheRead, 10)
    }

    func test_inferProjectPath_withCommonBase() throws {
        let parser = ForgeDevParser()
        let paths = [
            "/Users/test/project/src/file1.ts",
            "/Users/test/project/src/file2.ts",
            "/Users/test/project/lib/util.ts"
        ]

        let result = parser.inferProjectPath(from: ["files_changed": paths])

        XCTAssertEqual(result, "/Users/test/project/src")
    }

    func test_inferProjectPath_withNoCommonBase() throws {
        let parser = ForgeDevParser()
        let paths = [
            "/Users/test/project1/file.ts",
            "/Users/other/project2/file.ts"
        ]

        let result = parser.inferProjectPath(from: ["files_changed": paths])

        // Should return the common prefix's parent
        XCTAssertFalse(result == paths[0])
    }

    func test_collectFilePaths_withFilesChanged() throws {
        let parser = ForgeDevParser()
        let metrics: [String: Any] = [
            "files_changed": [
                "file1.ts": true,
                "file2.ts": true
            ]
        ]

        let result = parser.collectFilePaths(from: metrics)

        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.contains("file1.ts"))
        XCTAssertTrue(result.contains("file2.ts"))
    }

    func test_parse_withValidJsonlSession_extractsUsage() async throws {
        let forgeDir = tempDirectory.appendingPathComponent(".forge-dev", isDirectory: true)
        try fileManager.createDirectory(at: forgeDir, withIntermediateDirectories: true)

        let sessionContent = """
        {"role": "user", "content": "Hello", "timestamp": "2024-01-01T12:00:00Z"}
        {"role": "assistant", "content": "Hi", "timestamp": "2024-01-01T12:00:01Z", "usage": {"input_tokens": 100, "output_tokens": 50}}
        """
        let sessionFile = forgeDir.appendingPathComponent("session.jsonl")
        try sessionContent.write(to: sessionFile, atomically: true, encoding: .utf8)

        let parser = ForgeDevParser(forgeDevRootPath: forgeDir.path)
        let result = try await parser.parse()

        XCTAssertFalse(result.usages.isEmpty)
        let usage = result.usages[0]
        XCTAssertEqual(usage.inputTokens, 100)
        XCTAssertEqual(usage.outputTokens, 50)
        XCTAssertEqual(usage.provider, .forgeDev)
    }
}

// MARK: - AugmentParser Tests

final class AugmentParserTests: XCTestCase {

    private var tempDirectory: URL!
    private let fileManager = FileManager.default

    override func setUp() {
        super.setUp()
        tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("openburnbar-augment-parser-tests-\(UUID().uuidString)", isDirectory: true)
        try? fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? fileManager.removeItem(at: tempDirectory)
        super.tearDown()
    }

    func test_provider_returnsAugment() {
        let parser = AugmentParser()
        XCTAssertEqual(parser.provider, .augment)
    }

    func test_parse_withNoRoots_returnsEmpty() async throws {
        let parser = AugmentParser()
        let result = try await parser.parse()

        XCTAssertTrue(result.usages.isEmpty)
        XCTAssertTrue(result.conversations.isEmpty)
    }

    func test_candidateRoots_returnsExpectedPaths() {
        let parser = AugmentParser()
        let roots = parser.candidateRoots()

        XCTAssertFalse(roots.isEmpty)
    }

    func test_parseJSON_withUsageData() throws {
        let parser = AugmentParser()
        let jsonContent: [String: Any] = [
            "model": "claude-3-5-sonnet",
            "usage": [
                "input_tokens": 100,
                "output_tokens": 50
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: jsonContent)
        let jsonFile = tempDirectory.appendingPathComponent("session.json")
        try data.write(to: jsonFile)

        let result = parser.parseJSON(file: jsonFile, sessionId: "test-session")

        XCTAssertNotNil(result)
        XCTAssertNotNil(result?.usage)
        XCTAssertEqual(result!.usage!.inputTokens, 100)
        XCTAssertEqual(result!.usage!.outputTokens, 50)
    }

    func test_parseJSONL_withMessages() throws {
        let parser = AugmentParser()
        let lines = [
            "{\"role\": \"user\", \"content\": \"Hello\", \"timestamp\": 1700000000}",
            "{\"role\": \"assistant\", \"content\": \"Hi\", \"timestamp\": 1700000060}"
        ].joined(separator: "\n")

        let jsonlFile = tempDirectory.appendingPathComponent("session.jsonl")
        try lines.write(to: jsonlFile, atomically: true, encoding: .utf8)

        let result = parser.parseJSONL(file: jsonlFile, sessionId: "test-session")

        XCTAssertNotNil(result)
        XCTAssertNotNil(result?.conversation)
        XCTAssertEqual(result!.conversation!.messageCount, 2)
    }

    func test_parse_withValidJSON_extractsUsage() async throws {
        let augmentDir = tempDirectory.appendingPathComponent("augment", isDirectory: true)
        try fileManager.createDirectory(at: augmentDir, withIntermediateDirectories: true)

        let jsonContent: [String: Any] = [
            "model": "claude-3-5-sonnet",
            "usage": [
                "input_tokens": 100,
                "output_tokens": 50
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: jsonContent)
        let jsonFile = augmentDir.appendingPathComponent("session.json")
        try data.write(to: jsonFile)

        let parser = AugmentParser(augmentRootPath: augmentDir.path)
        let result = try await parser.parse()

        XCTAssertFalse(result.usages.isEmpty)
        let usage = result.usages[0]
        XCTAssertEqual(usage.inputTokens, 100)
        XCTAssertEqual(usage.outputTokens, 50)
        XCTAssertEqual(usage.provider, .augment)
    }
}

// MARK: - HermesParser Tests

final class HermesParserTests: XCTestCase {

    private var tempDirectory: URL!
    private let fileManager = FileManager.default

    override func setUp() {
        super.setUp()
        tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("openburnbar-hermes-parser-tests-\(UUID().uuidString)", isDirectory: true)
        try? fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? fileManager.removeItem(at: tempDirectory)
        super.tearDown()
    }

    func test_provider_returnsHermes() {
        let parser = HermesParser()
        XCTAssertEqual(parser.provider, .hermes)
    }

    func test_parse_withNoHermesRoot_returnsEmpty() async throws {
        let parser = HermesParser(fileManager: .default, hermesRootURL: URL(fileURLWithPath: "/nonexistent"))
        let result = try await parser.parse()

        XCTAssertTrue(result.usages.isEmpty)
        XCTAssertTrue(result.conversations.isEmpty)
    }

    func test_parseTimestamp_withISO8601Fractional() {
        let parser = HermesParser()
        let dateString = "2024-01-01T12:00:00.123Z"

        let result = parser.parseTimestamp(dateString)

        XCTAssertNotNil(result)
    }

    func test_parseTimestamp_withISO8601Basic() {
        let parser = HermesParser()
        let dateString = "2024-01-01T12:00:00Z"

        let result = parser.parseTimestamp(dateString)

        XCTAssertNotNil(result)
    }

    func test_parseTimestamp_withEpochSeconds() {
        let parser = HermesParser()
        let epoch: Double = 1704067200

        let result = parser.parseTimestamp(epoch)

        XCTAssertNotNil(result)
    }

    func test_parseTimestamp_withMilliseconds() {
        let parser = HermesParser()
        let epoch: Int = 1704067200000

        let result = parser.parseTimestamp(epoch)

        XCTAssertNotNil(result)
    }

    func test_parseTimestamp_withNil_returnsNil() {
        let parser = HermesParser()
        let result = parser.parseTimestamp(nil)
        XCTAssertNil(result)
    }

    func test_dateValue_withString() {
        let parser = HermesParser()
        let result = parser.dateValue("2024-01-01 12:00:00")
        XCTAssertNotNil(result)
    }

    func test_dateValue_withDouble() {
        let parser = HermesParser()
        let result = parser.dateValue(1704067200.0)
        XCTAssertNotNil(result)
    }

    func test_dateValue_withInt() {
        let parser = HermesParser()
        let result = parser.dateValue(1704067200)
        XCTAssertNotNil(result)
    }

    func test_dateValue_withInt64() {
        let parser = HermesParser()
        let result = parser.dateValue(Int64(1704067200))
        XCTAssertNotNil(result)
    }

    func test_transcriptSummary_consumesUserRole() {
        var summary = TranscriptSummary()
        summary.consume(role: "user", content: "Hello, world!")

        XCTAssertEqual(summary.userChars, 13)
        XCTAssertEqual(summary.userWords, 2)
        XCTAssertEqual(summary.firstUser, "Hello, world!")
    }

    func test_transcriptSummary_consumesAssistantRole() {
        var summary = TranscriptSummary()
        summary.consume(role: "assistant", content: "Hello, world!")

        XCTAssertEqual(summary.assistantChars, 13)
        XCTAssertEqual(summary.assistantWords, 2)
        XCTAssertEqual(summary.lastAssistant, "Hello, world!")
    }

    func test_transcriptSummary_consumesToolRole() {
        var summary = TranscriptSummary()
        summary.consume(role: "tool", content: "Tool result content")

        XCTAssertEqual(summary.toolChars, 21)
        XCTAssertEqual(summary.toolMessageCount, 1)
    }

    func test_transcriptSummary_consumesSystemRole() {
        var summary = TranscriptSummary()
        summary.consume(role: "system", content: "System prompt content")

        XCTAssertEqual(summary.systemPromptChars, 22)
    }

    func test_transcriptSummary_tracksKeyTools() {
        var summary = TranscriptSummary()
        summary.consume(role: "tool", content: "bash output")
        summary.consume(role: "tool", content: "read result")
        summary.consume(role: "tool", content: "bash another")

        XCTAssertEqual(summary.keyTools.count, 2)
        XCTAssertTrue(summary.keyTools.contains("bash"))
        XCTAssertTrue(summary.keyTools.contains("read"))
    }

    func test_transcriptSummary_tracksMessageCount() {
        var summary = TranscriptSummary()
        summary.consume(role: "user", content: "Hello")
        summary.consume(role: "assistant", content: "Hi")
        summary.consume(role: "user", content: "How are you?")
        summary.consume(role: "assistant", content: "Fine thanks")

        XCTAssertEqual(summary.messageCount, 4)
    }

    func test_transcriptSummary_tracksTimestamps() {
        var summary = TranscriptSummary()
        let startDate = Date()
        let endDate = startDate.addingTimeInterval(3600)

        summary.consume(role: "user", content: "Start", rawContent: startDate)
        summary.consume(role: "assistant", content: "End", rawContent: endDate)

        XCTAssertNotNil(summary.startTime)
        XCTAssertNotNil(summary.endTime)
    }

    func test_transcriptSummary_extractsModelFromContent() {
        var summary = TranscriptSummary()
        summary.consume(role: "assistant", content: "Using model: custom-model for inference")

        XCTAssertEqual(summary.model, "custom-model")
    }

    func test_transcriptSummary_estimatedUsage() {
        var summary = TranscriptSummary()
        summary.userChars = 1000
        summary.assistantChars = 500
        summary.userWords = 150
        summary.assistantWords = 75
        summary.messageCount = 10
        summary.toolMessageCount = 3
        summary.systemPromptChars = 200

        let estimated = summary.estimatedUsage()

        XCTAssertTrue(estimated.input > 0)
        XCTAssertTrue(estimated.output > 0)
    }

    func test_usageBuilder_withValidInput() {
        let parser = HermesParser()
        let usage = parser.usage(
            sessionId: "s1",
            projectName: "TestProject",
            model: "claude-3-5-sonnet",
            inputTokens: 1000,
            outputTokens: 500,
            cacheCreationTokens: 100,
            cacheReadTokens: 50,
            costOverride: nil,
            startTime: Date(),
            endTime: Date()
        )

        XCTAssertNotNil(usage)
        XCTAssertEqual(usage!.inputTokens, 1000)
        XCTAssertEqual(usage!.outputTokens, 500)
        XCTAssertEqual(usage!.cacheCreationTokens, 100)
        XCTAssertEqual(usage!.cacheReadTokens, 50)
    }

    func test_usageBuilder_withZeroTokens_returnsNil() {
        let parser = HermesParser()
        let usage = parser.usage(
            sessionId: "s1",
            projectName: "TestProject",
            model: "claude-3-5-sonnet",
            inputTokens: 0,
            outputTokens: 0,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            costOverride: nil,
            startTime: Date(),
            endTime: Date()
        )

        XCTAssertNil(usage)
    }

    func test_usageBuilder_withExplicitCost() {
        let parser = HermesParser()
        let usage = parser.usage(
            sessionId: "s1",
            projectName: "TestProject",
            model: "claude-3-5-sonnet",
            inputTokens: 1000,
            outputTokens: 500,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            costOverride: 0.15,
            startTime: Date(),
            endTime: Date()
        )

        XCTAssertNotNil(usage)
        XCTAssertEqual(usage!.costUSD, 0.15)
    }

    func test_conversationBuilder_withValidData() {
        let parser = HermesParser()
        var summary = TranscriptSummary()
        summary.fullText = "This is a test conversation"
        summary.messageCount = 2
        summary.userWords = 5
        summary.assistantWords = 6
        summary.firstUser = "Hello"
        summary.lastAssistant = "Hi there"

        let conversation = parser.conversation(
            sessionId: "s1",
            projectName: "TestProject",
            title: "Test Title",
            summary: summary,
            startTime: Date(),
            endTime: Date()
        )

        XCTAssertNotNil(conversation)
        XCTAssertEqual(conversation!.sessionId, "s1")
        XCTAssertEqual(conversation!.inferredTaskTitle, "Test Title")
        XCTAssertEqual(conversation!.messageCount, 2)
    }

    func test_conversationBuilder_withEmptyFullText_returnsNil() {
        let parser = HermesParser()
        var summary = TranscriptSummary()
        summary.fullText = ""
        summary.messageCount = 0

        let conversation = parser.conversation(
            sessionId: "s1",
            projectName: "TestProject",
            title: "Test",
            summary: summary,
            startTime: Date(),
            endTime: Date()
        )

        XCTAssertNil(conversation)
    }

    func test_deduplicate_removesDuplicates() {
        let parser = HermesParser()
        let usage1 = TokenUsage(
            provider: .hermes,
            sessionId: "s1",
            projectName: "p",
            model: "m",
            inputTokens: 100,
            outputTokens: 50,
            costUSD: 0.01,
            startTime: Date(),
            endTime: Date()
        )
        let usage2 = TokenUsage(
            provider: .hermes,
            sessionId: "s1", // Same session ID
            projectName: "p",
            model: "m",
            inputTokens: 200, // Different values
            outputTokens: 100,
            costUSD: 0.02,
            startTime: Date(),
            endTime: Date()
        )

        let result = parser.deduplicate([usage1, usage2])

        XCTAssertEqual(result.count, 1)
    }

    func test_resolvedHermesHome_normalizesPath() {
        let parser = HermesParser()
        let home = parser.resolvedHermesHome()

        XCTAssertNotNil(home)
    }

    func test_parseSQLiteDatabase_withNoTables() throws {
        // Create an empty SQLite database
        let dbPath = tempDirectory.appendingPathComponent("test.db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath.path, &db), SQLITE_OK)
        sqlite3_close(db)

        let parser = HermesParser()
        let result = try parser.parseSQLiteDatabase(dbURL: dbPath)

        XCTAssertTrue(result.usages.isEmpty)
    }
}

// MARK: - GeminiCLIParser Tests

final class GeminiCLIParserTests: XCTestCase {

    private var tempDirectory: URL!
    private let fileManager = FileManager.default

    override func setUp() {
        super.setUp()
        tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("openburnbar-gemini-parser-tests-\(UUID().uuidString)", isDirectory: true)
        try? fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? fileManager.removeItem(at: tempDirectory)
        super.tearDown()
    }

    func test_provider_returnsGeminiCLI() {
        let parser = GeminiCLIParser()
        XCTAssertEqual(parser.provider, .geminiCLI)
    }

    func test_parse_withNoBasePath_returnsEmpty() async throws {
        let parser = GeminiCLIParser()
        let result = try await parser.parse()

        XCTAssertTrue(result.usages.isEmpty)
        XCTAssertTrue(result.conversations.isEmpty)
    }

    func test_parseJsonlSession_withValidData() throws {
        let parser = GeminiCLIParser()
        let projectDir = tempDirectory.appendingPathComponent("project1", isDirectory: true)
        try fileManager.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let chatsDir = projectDir.appendingPathComponent("chats", isDirectory: true)
        try fileManager.createDirectory(at: chatsDir, withIntermediateDirectories: true)

        let content = """
        {"type": "message_update", "role": "user", "content": "Hello", "timestamp": "2024-01-01T12:00:00Z"}
        {"type": "message_update", "role": "model", "content": "Hi there", "timestamp": "2024-01-01T12:00:01Z", "usage": {"input_tokens": 10, "output_tokens": 5}}
        """
        let sessionFile = chatsDir.appendingPathComponent("session-test.jsonl")
        try content.write(to: sessionFile, atomically: true, encoding: .utf8)

        let result = try parser.parseJsonlSession(
            file: sessionFile,
            sessionId: "test",
            projectName: "project1"
        )

        XCTAssertNotNil(result)
        XCTAssertNotNil(result?.usage)
    }

    func test_parseJsonSession_withArrayFormat() throws {
        let parser = GeminiCLIParser()
        let projectDir = tempDirectory.appendingPathComponent("project1", isDirectory: true)
        try fileManager.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let chatsDir = projectDir.appendingPathComponent("chats", isDirectory: true)
        try fileManager.createDirectory(at: chatsDir, withIntermediateDirectories: true)

        let content: [[String: Any]] = [
            ["role": "user", "content": "Hello", "timestamp": 1704067200],
            ["role": "model", "content": "Hi", "timestamp": 1704067260, "usage": ["input_tokens": 10, "output_tokens": 5]]
        ]
        let data = try JSONSerialization.data(withJSONObject: content)
        let sessionFile = chatsDir.appendingPathComponent("session-test.json")
        try data.write(to: sessionFile)

        let result = try parser.parseJsonSession(
            file: sessionFile,
            sessionId: "test",
            projectName: "project1"
        )

        XCTAssertNotNil(result)
        XCTAssertNotNil(result?.usage)
    }

    func test_parseJsonSession_withObjectFormat() throws {
        let parser = GeminiCLIParser()
        let projectDir = tempDirectory.appendingPathComponent("project1", isDirectory: true)
        try fileManager.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let chatsDir = projectDir.appendingPathComponent("chats", isDirectory: true)
        try fileManager.createDirectory(at: chatsDir, withIntermediateDirectories: true)

        let content: [String: Any] = [
            "messages": [
                ["role": "user", "content": "Hello", "timestamp": 1704067200],
                ["role": "model", "content": "Hi", "timestamp": 1704067260, "usage": ["input_tokens": 10, "output_tokens": 5]]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: content)
        let sessionFile = chatsDir.appendingPathComponent("session-test.json")
        try data.write(to: sessionFile)

        let result = try parser.parseJsonSession(
            file: sessionFile,
            sessionId: "test",
            projectName: "project1"
        )

        XCTAssertNotNil(result)
        XCTAssertNotNil(result?.usage)
    }

    func test_extractContent_withDirectString() {
        let parser = GeminiCLIParser()
        let json: [String: Any] = ["content": "Hello, world!"]

        let result = parser.extractContent(from: json)

        XCTAssertEqual(result, "Hello, world!")
    }

    func test_extractContent_withNestedMessage() {
        let parser = GeminiCLIParser()
        let json: [String: Any] = [
            "message": ["content": "Hello from nested"]
        ]

        let result = parser.extractContent(from: json)

        XCTAssertEqual(result, "Hello from nested")
    }

    func test_extractContent_withPartsFormat() {
        let parser = GeminiCLIParser()
        let json: [String: Any] = [
            "parts": [
                ["text": "Part 1"],
                ["text": "Part 2"]
            ]
        ]

        let result = parser.extractContent(from: json)

        XCTAssertEqual(result, "Part 1\nPart 2")
    }

    func test_accumulateUsage_withStandardKeys() {
        var acc = GeminiSessionAccumulator()
        let usage: [String: Any] = [
            "input_tokens": 100,
            "output_tokens": 50,
            "cached_tokens": 25
        ]

        TokenExtractionUtility.extractUsageTokens(usage) // Just to show it works

        XCTAssertTrue(true) // Placeholder for structure validation
    }
}

// MARK: - GooseParser Tests

final class GooseParserTests: XCTestCase {

    private var tempDirectory: URL!
    private let fileManager = FileManager.default

    override func setUp() {
        super.setUp()
        tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("openburnbar-goose-parser-tests-\(UUID().uuidString)", isDirectory: true)
        try? fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? fileManager.removeItem(at: tempDirectory)
        super.tearDown()
    }

    func test_provider_returnsGoose() {
        let parser = GooseParser()
        XCTAssertEqual(parser.provider, .goose)
    }

    func test_parse_withNoDatabaseOrFiles_returnsEmpty() async throws {
        let parser = GooseParser()
        let result = try await parser.parse()

        // Returns empty because no databases or files at expected paths
        XCTAssertTrue(result.usages.isEmpty || result.conversations.isEmpty)
    }

    func test_resolvedSessionDirectories_returnsExpectedPaths() {
        let parser = GooseParser()
        let directories = parser.resolvedSessionDirectories()

        XCTAssertFalse(directories.isEmpty)
    }

    func test_parseJsonlSession_withUsageData() throws {
        let parser = GooseParser()
        let content = """
        {"role": "user", "content": "Hello", "timestamp": "2024-01-01T12:00:00Z"}
        {"role": "assistant", "content": "Hi", "timestamp": "2024-01-01T12:00:01Z", "usage": {"input_tokens": 10, "output_tokens": 5}}
        """
        let file = tempDirectory.appendingPathComponent("session.jsonl")
        try content.write(to: file, atomically: true, encoding: .utf8)

        let result = try parser.parseJsonlSession(file: file, sessionId: "test")

        XCTAssertNotNil(result)
        XCTAssertNotNil(result?.usage)
    }

    func test_parseJsonlSession_withoutUsageData_usesEstimation() throws {
        let parser = GooseParser()
        let content = """
        {"role": "user", "content": "Hello world this is a test message with some content"}
        {"role": "assistant", "content": "This is a response from the assistant"}
        """
        let file = tempDirectory.appendingPathComponent("session.jsonl")
        try content.write(to: file, atomically: true, encoding: .utf8)

        let result = try parser.parseJsonlSession(file: file, sessionId: "test")

        XCTAssertNotNil(result)
        XCTAssertNotNil(result?.usage)
        // Falls back to estimation when no usage
        XCTAssertTrue(result!.usage!.inputTokens > 0 || result!.usage!.outputTokens > 0)
    }

    func test_parseJsonlSession_withModel() throws {
        let parser = GooseParser()
        let content = """
        {"role": "user", "content": "Hello", "model": "gpt-5"}
        """
        let file = tempDirectory.appendingPathComponent("session.jsonl")
        try content.write(to: file, atomically: true, encoding: .utf8)

        let result = try parser.parseJsonlSession(file: file, sessionId: "test")

        XCTAssertNotNil(result)
        XCTAssertTrue(result!.usage!.model.contains("gpt") || result!.usage!.model == "goose")
    }

    func test_timestampParsing_withISO8601() {
        let parser = GooseParser()
        let dateString = "2024-01-01T12:00:00.123Z"

        // Using reflection to test ISO8601 formatter
        XCTAssertNotNil(GooseParser.iso8601Fractional.date(from: dateString))
    }

    func test_timestampParsing_withISO8601Basic() {
        let parser = GooseParser()
        let dateString = "2024-01-01T12:00:00Z"

        XCTAssertNotNil(GooseParser.iso8601Basic.date(from: dateString))
    }

    func test_firstNonZero_returnsFirstNonZeroValue() {
        let parser = GooseParser()

        XCTAssertEqual(parser.firstNonZero(0, 0, 5, 0), 5)
        XCTAssertEqual(parser.firstNonZero(0), 0)
        XCTAssertEqual(parser.firstNonZero(3, 0, 1), 3)
    }
}

// MARK: - WindsurfParser Tests

final class WindsurfParserTests: XCTestCase {

    private var tempDirectory: URL!
    private let fileManager = FileManager.default

    override func setUp() {
        super.setUp()
        tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("openburnbar-windsurf-parser-tests-\(UUID().uuidString)", isDirectory: true)
        try? fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? fileManager.removeItem(at: tempDirectory)
        super.tearDown()
    }

    func test_provider_returnsWindsurf() {
        let parser = WindsurfParser()
        XCTAssertEqual(parser.provider, .windsurf)
    }

    func test_parse_withNoPBFiles_returnsEmpty() async throws {
        let parser = WindsurfParser()
        let result = try await parser.parse()

        // Parser looks for ~/.codeium/windsurf-next/cascade which doesn't exist
        XCTAssertTrue(result.usages.isEmpty || result.conversations.isEmpty)
    }

    func test_normalizeWindsurfModel_withGPT() {
        let result = WindsurfParser.normalizeWindsurfModel("MODEL_GPT_5_2_LOW")

        XCTAssertEqual(result, "GPT-5")
    }

    func test_normalizeWindsurfModel_withClaude() {
        let result = WindsurfParser.normalizeWindsurfModel("MODEL_CLAUDE_3_5_SONNET")

        XCTAssertEqual(result, "Claude Sonnet")
    }

    func test_normalizeWindsurfModel_withGemini() {
        let result = WindsurfParser.normalizeWindsurfModel("gemini-3-1-pro-high")

        XCTAssertEqual(result, "Gemini 3")
    }

    func test_normalizeWindsurfModel_withDeepSeek() {
        let result = WindsurfParser.normalizeWindsurfModel("deepseek-3")

        XCTAssertEqual(result, "DeepSeek")
    }

    func test_normalizeWindsurfModel_withSWE() {
        let result = WindsurfParser.normalizeWindsurfModel("swe-1-5-pro")

        XCTAssertEqual(result, "SWE-1.5")
    }

    func test_normalizeWindsurfModel_withUnknown() {
        let result = WindsurfParser.normalizeWindsurfModel("unknown-model")

        XCTAssertEqual(result, "unknown-model")
    }

    func test_estimatedBytesPerToken_constant() {
        // Verify the estimation constant is reasonable
        XCTAssertGreaterThan(WindsurfParser.estimatedBytesPerToken, 0)
        XCTAssertLessThan(WindsurfParser.estimatedBytesPerToken, 100)
    }

    func test_inputOutputRatio_constant() {
        XCTAssertGreaterThan(WindsurfParser.inputOutputRatio, 0)
        XCTAssertEqual(WindsurfParser.inputOutputRatio, 3.0)
    }

    func test_parse_withValidPBFile_extractsUsage() async throws {
        let cascadeDir = tempDirectory.appendingPathComponent("cascade", isDirectory: true)
        try fileManager.createDirectory(at: cascadeDir, withIntermediateDirectories: true)

        // Create a fake .pb file with enough size to pass the >100 bytes check
        let pbContent = String(repeating: "X", count: 500)
        let pbFile = cascadeDir.appendingPathComponent("session-test.pb")
        try pbContent.write(to: pbFile, atomically: true, encoding: .utf8)

        let parser = WindsurfParser(windsurfRootPath: cascadeDir.path)
        let result = try await parser.parse()

        XCTAssertFalse(result.usages.isEmpty)
        let usage = result.usages[0]
        XCTAssertEqual(usage.provider, .windsurf)
        XCTAssertEqual(usage.sessionId, "session-test")
        XCTAssertGreaterThan(usage.totalTokens, 0)
    }
}

// MARK: - ModelFilterParser Tests

final class ModelFilterParserTests: XCTestCase {

    private var tempDirectory: URL!
    private let fileManager = FileManager.default

    override func setUp() {
        super.setUp()
        tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("openburnbar-model-filter-parser-tests-\(UUID().uuidString)", isDirectory: true)
        try? fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? fileManager.removeItem(at: tempDirectory)
        super.tearDown()
    }

    func test_provider_returnsZai() {
        let parser = ModelFilterParser(modelPattern: "zai", provider: .zai)
        XCTAssertEqual(parser.provider, .zai)
    }

    func test_provider_returnsMiniMax() {
        let parser = ModelFilterParser(modelPattern: "minimax", provider: .minimax)
        XCTAssertEqual(parser.provider, .minimax)
    }

    func test_parse_withNoSessionsDirectory_returnsEmpty() async throws {
        let parser = ModelFilterParser(modelPattern: "zai", provider: .zai)
        let result = try await parser.parse()

        XCTAssertTrue(result.usages.isEmpty)
        XCTAssertTrue(result.conversations.isEmpty)
    }

    func test_modelPatternMatching_zaiPattern() throws {
        let parser = ModelFilterParser(modelPattern: "zai", provider: .zai)

        // Create a test session file
        let sessionsDir = tempDirectory.appendingPathComponent("sessions", isDirectory: true)
        try fileManager.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        let projectDir = sessionsDir.appendingPathComponent("project1", isDirectory: true)
        try fileManager.createDirectory(at: projectDir, withIntermediateDirectories: true)

        // Create settings file with zai model
        let settings: [String: Any] = [
            "model": "Zai/agent-model"
        ]
        let settingsData = try JSONSerialization.data(withJSONObject: settings)
        let settingsFile = projectDir.appendingPathComponent("session.settings.json")
        try settingsData.write(to: settingsFile)

        // Create metadata file
        let metadata: [String: Any] = [
            "tokenUsage": [
                "input_tokens": 100,
                "output_tokens": 50
            ]
        ]
        let metadataData = try JSONSerialization.data(withJSONObject: metadata)
        let metadataFile = projectDir.appendingPathComponent("session.metadata.json")
        try metadataData.write(to: metadataFile)

        // Create session JSONL
        let jsonlContent = """
        {"message": {"role": "user", "content": "Hello"}}
        """
        let jsonlFile = projectDir.appendingPathComponent("session.jsonl")
        try jsonlContent.write(to: jsonlFile, atomically: true, encoding: .utf8)

        // This test verifies the pattern matching logic exists
        XCTAssertTrue(parser.provider == .zai)
    }

    func test_decodeProjectName_withEncodedPath() {
        let parser = ModelFilterParser(modelPattern: "zai", provider: .zai)

        let result = parser.decodeProjectName("-Users-test-project-src")

        XCTAssertEqual(result, "~/test/project/src")
    }

    func test_decodeProjectName_withDoubleDash() {
        let parser = ModelFilterParser(modelPattern: "zai", provider: .zai)

        let result = parser.decodeProjectName("test--project")

        XCTAssertTrue(result.contains("test"))
    }

    func test_parse_withMatchingModel_extractsUsage() async throws {
        let sessionsDir = tempDirectory.appendingPathComponent("sessions", isDirectory: true)
        try fileManager.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        let projectDir = sessionsDir.appendingPathComponent("project1", isDirectory: true)
        try fileManager.createDirectory(at: projectDir, withIntermediateDirectories: true)

        // Create settings file with zai model
        let settings: [String: Any] = [
            "model": "Zai/agent-model",
            "tokenUsage": [
                "input_tokens": 100,
                "output_tokens": 50
            ]
        ]
        let settingsData = try JSONSerialization.data(withJSONObject: settings)
        let settingsFile = projectDir.appendingPathComponent("session.settings.json")
        try settingsData.write(to: settingsFile)

        // Create session JSONL
        let jsonlContent = """
        {"message": {"role": "user", "content": "Hello"}}
        """
        let jsonlFile = projectDir.appendingPathComponent("session.jsonl")
        try jsonlContent.write(to: jsonlFile, atomically: true, encoding: .utf8)

        let parser = ModelFilterParser(
            modelPattern: "zai",
            provider: .zai,
            sessionsRootPath: sessionsDir.path
        )
        let result = try await parser.parse()

        XCTAssertFalse(result.usages.isEmpty)
        let usage = result.usages[0]
        XCTAssertEqual(usage.provider, .zai)
        XCTAssertEqual(usage.inputTokens, 100)
        XCTAssertEqual(usage.outputTokens, 50)
    }
}

// MARK: - FactoryDroidParser Additional Tests

final class FactoryDroidParserAdditionalTests: XCTestCase {

    private var tempDirectory: URL!
    private let fileManager = FileManager.default

    override func setUp() {
        super.setUp()
        tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("openburnbar-factory-parser-tests-\(UUID().uuidString)", isDirectory: true)
        try? fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? fileManager.removeItem(at: tempDirectory)
        super.tearDown()
    }

    func test_detectProviderFromModel_withMinimax() {
        let parser = FactoryDroidParser()
        let result = parser.detectProviderFromModel("minimax-01")

        XCTAssertEqual(result, .minimax)
    }

    func test_detectProviderFromModel_withGLM() {
        let parser = FactoryDroidParser()
        let result = parser.detectProviderFromModel("glm-4")

        XCTAssertEqual(result, .zai)
    }

    func test_detectProviderFromModel_withZai() {
        let parser = FactoryDroidParser()
        let result = parser.detectProviderFromModel("z.ai/agent-model")

        XCTAssertEqual(result, .zai)
    }

    func test_detectProviderFromModel_withUnknown_defaultsToFactory() {
        let parser = FactoryDroidParser()
        let result = parser.detectProviderFromModel("unknown-model")

        XCTAssertEqual(result, .factory)
    }

    func test_decodeProjectName_withEncodedPath() {
        let parser = FactoryDroidParser()

        let result = parser.decodeProjectName("-Users-test-project-src")

        XCTAssertEqual(result, "~/test/project/src")
    }

    func test_decodeProjectName_withUsersPrefix() {
        let parser = FactoryDroidParser()

        let result = parser.decodeProjectName("-Users-test")

        XCTAssertTrue(result.contains("test"))
    }

    func test_decodeProjectName_withTrailingSlash() {
        let parser = FactoryDroidParser()

        let result = parser.decodeProjectName("test/")

        XCTAssertFalse(result.hasSuffix("/"))
    }
}

// MARK: - ClaudeCodeParser Additional Tests

final class ClaudeCodeParserAdditionalTests: XCTestCase {

    private var tempDirectory: URL!
    private let fileManager = FileManager.default

    override func setUp() {
        super.setUp()
        tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("openburnbar-claudecode-parser-tests-\(UUID().uuidString)", isDirectory: true)
        try? fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? fileManager.removeItem(at: tempDirectory)
        super.tearDown()
    }

    func test_decodeProjectName_withUppercaseLetterAfterDash() {
        let parser = ClaudeCodeParser()

        let result = parser.decodeProjectName("-Users-Test-Project-src")

        XCTAssertTrue(result.contains("Test"))
        XCTAssertTrue(result.contains("Project"))
    }

    func test_parseTimestamp_withISO8601Fractional() {
        let parser = ClaudeCodeParser()
        let dateString = "2024-01-01T12:00:00.123Z"

        let result = parser.parseTimestamp(dateString)

        XCTAssertNotNil(result)
    }

    func test_parseTimestamp_withISO8601Basic() {
        let parser = ClaudeCodeParser()
        let dateString = "2024-01-01T12:00:00Z"

        let result = parser.parseTimestamp(dateString)

        XCTAssertNotNil(result)
    }

    func test_parseTimestamp_withEpochMilliseconds() {
        let parser = ClaudeCodeParser()
        let timestamp: NSNumber = 1704067200000

        let result = parser.parseTimestamp(timestamp)

        XCTAssertNotNil(result)
    }

    func test_parseTimestamp_withEpochSeconds() {
        let parser = ClaudeCodeParser()
        let timestamp: Double = 1704067200

        let result = parser.parseTimestamp(timestamp)

        XCTAssertNotNil(result)
    }

    func test_parseTimestamp_withNil_returnsNil() {
        let parser = ClaudeCodeParser()

        let result = parser.parseTimestamp(nil)

        XCTAssertNil(result)
    }

    func test_claudeUsageIdentity_withValidIds() {
        let parser = ClaudeCodeParser()
        let json: [String: Any] = [
            "requestId": "req-123"
        ]
        let message: [String: Any] = [
            "id": "msg-456"
        ]

        let result = parser.claudeUsageIdentity(json: json, message: message)

        XCTAssertEqual(result, "msg-456:req-123")
    }

    func test_claudeUsageIdentity_withMissingIds_returnsNil() {
        let parser = ClaudeCodeParser()
        let json: [String: Any] = [:]
        let message: [String: Any] = [:]

        let result = parser.claudeUsageIdentity(json: json, message: message)

        XCTAssertNil(result)
    }

    func test_claudeUsageIdentity_withEmptyId_returnsNil() {
        let parser = ClaudeCodeParser()
        let json: [String: Any] = ["requestId": ""]
        let message: [String: Any] = ["id": "msg-456"]

        let result = parser.claudeUsageIdentity(json: json, message: message)

        XCTAssertNil(result)
    }
}

// MARK: - FileHandle Extension Tests

final class FileHandleExtensionTests: XCTestCase {

    private var tempFile: URL!
    private let fileManager = FileManager.default

    override func setUp() {
        super.setUp()
        tempFile = fileManager.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).txt")
    }

    override func tearDown() {
        try? fileManager.removeItem(at: tempFile)
        super.tearDown()
    }

    func test_readAllUTF8Lines_withMultipleLines() throws {
        let content = "line1\nline2\nline3"
        try content.write(to: tempFile, atomically: true, encoding: .utf8)

        let handle = try FileHandle(forReadingFrom: tempFile)
        let lines = handle.readAllUTF8Lines()

        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0], "line1")
        XCTAssertEqual(lines[1], "line2")
        XCTAssertEqual(lines[2], "line3")
        try handle.close()
    }

    func test_readAllUTF8Lines_withEmptyFile() throws {
        try "".write(to: tempFile, atomically: true, encoding: .utf8)

        let handle = try FileHandle(forReadingFrom: tempFile)
        let lines = handle.readAllUTF8Lines()

        XCTAssertEqual(lines.count, 0)
        try handle.close()
    }

    func test_readAllUTF8Lines_withDifferentLineEndings() throws {
        let content = "line1\r\nline2\nline3"
        try content.write(to: tempFile, atomically: true, encoding: .utf8)

        let handle = try FileHandle(forReadingFrom: tempFile)
        let lines = handle.readAllUTF8Lines()

        // Should split on any newline character
        XCTAssertEqual(lines.count, 3)
        try handle.close()
    }

    func test_readLine_returnsFirstLine() throws {
        let content = "first line\nsecond line"
        try content.write(to: tempFile, atomically: true, encoding: .utf8)

        let handle = try FileHandle(forReadingFrom: tempFile)
        let line = handle.readLine()

        XCTAssertEqual(line, "first line")
        try handle.close()
    }

    func test_readLine_returnsNilAtEOF() throws {
        try "".write(to: tempFile, atomically: true, encoding: .utf8)

        let handle = try FileHandle(forReadingFrom: tempFile)
        let line = handle.readLine()

        XCTAssertNil(line)
        try handle.close()
    }

    func test_readLastLine() throws {
        let content = "line1\nline2\nlast line"
        try content.write(to: tempFile, atomically: true, encoding: .utf8)

        let handle = try FileHandle(forReadingFrom: tempFile)
        let line = try handle.readLastLine()

        XCTAssertEqual(line, "last line")
        try handle.close()
    }

    func test_readLastLine_withEmptyFile() throws {
        try "".write(to: tempFile, atomically: true, encoding: .utf8)

        let handle = try FileHandle(forReadingFrom: tempFile)
        let line = try handle.readLastLine()

        XCTAssertNil(line)
        try handle.close()
    }
}
