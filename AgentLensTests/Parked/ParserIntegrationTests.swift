import Foundation
import XCTest
import GRDB
@testable import OpenBurnBar

// MARK: - Parser Integration Test Fixtures

/// Fixture log file builders for parser integration tests
enum ParserTestFixtures {

    // MARK: - Claude Code JSONL Fixtures

    /// Creates a minimal Claude Code session JSONL file content
    static func claudeCodeSession(
        sessionId: String = "test-session-001",
        model: String = "claude-sonnet-4-20250514",
        inputTokens: Int = 1000,
        outputTokens: Int = 500,
        cacheCreationTokens: Int = 0,
        cacheReadTokens: Int = 0
    ) -> String {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        return """
        {"type":"user","timestamp":"\(timestamp)","message":{"role":"user","content":[{"type":"text","text":"Hello, help me write a function that adds two numbers."}]}}
        {"type":"assistant","timestamp":"\(timestamp)","message":{"role":"assistant","content":[{"type":"text","text":"Here's a simple Swift function:"},{"type":"text","text":"func add(_ a: Int, _ b: Int) -> Int { a + b }"}],"usage":{"input_tokens":\(inputTokens),"output_tokens":\(outputTokens),"cache_creation_input_tokens":\(cacheCreationTokens),"cache_read_input_tokens":\(cacheReadTokens)},"model":"\(model)"}}
        """
    }

    /// Creates a Claude Code session with multiple turns
    static func claudeCodeMultiTurnSession() -> String {
        let baseTime = Date(timeIntervalSince1970: 1742000000)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        return """
        {"type":"user","timestamp":"\(formatter.string(from: baseTime))","message":{"role":"user","content":[{"type":"text","text":"Create a new Swift file for authentication."}]}}
        {"type":"assistant","timestamp":"\(formatter.string(from: baseTime.addingTimeInterval(1)))","message":{"role":"assistant","content":[{"type":"tool_use","name":"Write","input":{"file_path":"/test/Auth.swift","content":"import Foundation\\n\\nstruct Auth {}\\n"}}],"model":"claude-sonnet-4-20250514","usage":{"input_tokens":50,"output_tokens":100}}}
        {"type":"user","timestamp":"\(formatter.string(from: baseTime.addingTimeInterval(2)))","message":{"role":"user","content":[{"type":"text","text":"Now add a login method."}]}}
        {"type":"assistant","timestamp":"\(formatter.string(from: baseTime.addingTimeInterval(3)))","message":{"role":"assistant","content":[{"type":"text","text":"I'll add the login method."}],"model":"claude-sonnet-4-20250514","usage":{"input_tokens":150,"output_tokens":200}}}
        """
    }

    /// Creates a Claude Code session with subagent
    static func claudeCodeWithSubagent() -> String {
        let baseTime = Date(timeIntervalSince1970: 1742000100)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        return """
        {"type":"user","timestamp":"\(formatter.string(from: baseTime))","message":{"role":"user","content":[{"type":"text","text":"Research async/await patterns."}]}}
        {"type":"assistant","timestamp":"\(formatter.string(from: baseTime.addingTimeInterval(1)))","message":{"role":"assistant","content":[{"type":"text","text":"I'll research this using a subagent."},{"type":"text","text":"[Spawning subagent for research]"}],"model":"claude-sonnet-4-20250514","usage":{"input_tokens":200,"output_tokens":150}}}
        """
    }

    // MARK: - Factory Droid JSONL Fixtures

    /// Creates a Factory Droid session JSONL file content
    static func factoryDroidSession(
        sessionId: String = "factory-test-001",
        model: String = "glm-4",
        inputTokens: Int = 800,
        outputTokens: Int = 400
    ) -> String {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        return """
        {"type":"user","timestamp":"\(timestamp)","message":{"role":"user","content":"Write a test function"}}
        {"type":"assistant","timestamp":"\(timestamp)","message":{"role":"assistant","content":"Here's the test: func test() {}","usage":{"input_tokens":\(inputTokens),"output_tokens":\(outputTokens)},"model":"\(model)"}}
        """
    }

    // MARK: - Codex Fixtures

    static func codexRolloutSession(
        model: String = "openai/gpt-5.2-codex",
        totalInputTokens: Int = 160,
        cachedInputTokens: Int = 40,
        outputTokens: Int = 16
    ) -> String {
        let baseTime = Date(timeIntervalSince1970: 1766577600)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        return """
        {"type":"turn_context","timestamp":"\(formatter.string(from: baseTime))","payload":{"model":"\(model)"}}
        {"type":"event_msg","timestamp":"\(formatter.string(from: baseTime.addingTimeInterval(1)))","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\(totalInputTokens),"cached_input_tokens":\(cachedInputTokens),"output_tokens":\(outputTokens)},"model":"\(model)"}}}
        """
    }

    static func codexRolloutSessionWithLastUsageOnly(
        model: String = "openai/gpt-5.2-codex"
    ) -> String {
        let baseTime = Date(timeIntervalSince1970: 1766577600)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        return """
        {"type":"turn_context","timestamp":"\(formatter.string(from: baseTime))","payload":{"model":"\(model)"}}
        {"type":"event_msg","timestamp":"\(formatter.string(from: baseTime.addingTimeInterval(1)))","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10},"model":"\(model)"}}}
        {"type":"event_msg","timestamp":"\(formatter.string(from: baseTime.addingTimeInterval(2)))","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":60,"cached_input_tokens":20,"output_tokens":6},"model":"\(model)"}}}
        """
    }

    /// Creates a Codex session with a partial/placeholder token_count map followed by delta events.
    /// VAL-TOKEN-010: The partial token_count (missing input_tokens/output_tokens) must NOT
    /// suppress valid delta accumulation from last_token_usage events.
    static func codexRolloutSessionWithPartialTokenCountAndDeltas(
        model: String = "openai/gpt-5.2-codex"
    ) -> String {
        let baseTime = Date(timeIntervalSince1970: 1766577600)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        // This partial token_count has cached_input_tokens but NO input_tokens/output_tokens.
        // It should be treated as NOT cumulative (return nil), allowing delta processing.
        return """
        {"type":"turn_context","timestamp":"\(formatter.string(from: baseTime))","payload":{"model":"\(model)"}}
        {"type":"event_msg","timestamp":"\(formatter.string(from: baseTime.addingTimeInterval(1)))","payload":{"type":"token_count","info":{"token_count":{"cached_input_tokens":100},"model":"\(model)"}}}
        {"type":"event_msg","timestamp":"\(formatter.string(from: baseTime.addingTimeInterval(2)))","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10},"model":"\(model)"}}}
        {"type":"event_msg","timestamp":"\(formatter.string(from: baseTime.addingTimeInterval(3)))","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":60,"cached_input_tokens":20,"output_tokens":6},"model":"\(model)"}}}
        """
    }

    /// Creates a Factory Droid session with settings.json structure
    static func factoryDroidSessionWithSettings(
        sessionId: String,
        model: String,
        inputTokens: Int,
        outputTokens: Int
    ) -> (jsonl: String, settings: String, metadata: String?) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let jsonl = """
        {"type":"user","timestamp":"\(timestamp)","message":{"role":"user","content":"Hello"}}
        {"type":"assistant","timestamp":"\(timestamp)","message":{"role":"assistant","content":"Hi there","model":"\(model)","usage":{"input_tokens":\(inputTokens),"output_tokens":\(outputTokens)}}}
        """

        let settings = """
        {
          "model": "\(model)",
          "tokenUsage": {
            "input_tokens": \(inputTokens),
            "output_tokens": \(outputTokens),
            "total_tokens": \(inputTokens + outputTokens)
          }
        }
        """

        let metadata = """
        {
          "model": "\(model)",
          "usage": {
            "input_tokens": \(inputTokens),
            "output_tokens": \(outputTokens)
          },
          "created_at": "\(timestamp)"
        }
        """

        return (jsonl, settings, metadata)
    }

    // MARK: - Hermes Fixtures

    static func hermesSessionSnapshot(
        sessionId: String = "cron_test_001",
        model: String = "MiniMax-M2.7-highspeed",
        platform: String = "cron",
        userText: String = "Build a beautiful district core with parks and mixed-use frontage.",
        assistantText: String = "Reviewed the build area, planned a coherent block, and applied a bounded set of upgrades."
    ) -> String {
        let baseTime = Date(timeIntervalSince1970: 1_775_061_000)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        return """
        {
          "session_id": "\(sessionId)",
          "model": "\(model)",
          "platform": "\(platform)",
          "session_start": "\(formatter.string(from: baseTime))",
          "last_updated": "\(formatter.string(from: baseTime.addingTimeInterval(12)))",
          "messages": [
            {
              "role": "user",
              "timestamp": "\(formatter.string(from: baseTime))",
              "content": "\(userText)"
            },
            {
              "role": "assistant",
              "timestamp": "\(formatter.string(from: baseTime.addingTimeInterval(12)))",
              "content": "\(assistantText)"
            }
          ]
        }
        """
    }

    static func hermesToolHeavySessionSnapshot(
        sessionId: String = "cron_tool_heavy_001",
        model: String = "MiniMax-M2.7-highspeed",
        platform: String = "cron"
    ) -> String {
        let baseTime = Date(timeIntervalSince1970: 1_775_061_500)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let systemPrompt = String(repeating: "World builder operating policy. ", count: 160)
        let toolOutput = String(repeating: "Chunk analysis output with placement candidates and terrain checks. ", count: 220)
        let assistantText = String(repeating: "Reviewed the candidate batch and refined the district plan. ", count: 40)

        return """
        {
          "session_id": "\(sessionId)",
          "model": "\(model)",
          "platform": "\(platform)",
          "session_start": "\(formatter.string(from: baseTime))",
          "last_updated": "\(formatter.string(from: baseTime.addingTimeInterval(18)))",
          "system_prompt": "\(systemPrompt)",
          "messages": [
            {
              "role": "user",
              "timestamp": "\(formatter.string(from: baseTime))",
              "content": "Run the next bounded world-building cycle."
            },
            {
              "role": "tool",
              "timestamp": "\(formatter.string(from: baseTime.addingTimeInterval(6)))",
              "content": "{\\"output\\": \\"\(toolOutput)\\"}"
            },
            {
              "role": "assistant",
              "timestamp": "\(formatter.string(from: baseTime.addingTimeInterval(18)))",
              "content": "\(assistantText)"
            }
          ]
        }
        """
    }

    // MARK: - Edge Case Fixtures

    /// Creates a session with malformed JSON lines
    static func sessionWithMalformedLines() -> String {
        return """
        {"type":"user","message":{"role":"user","content":"Valid line"}}
        INVALID_JSON_LINE
        {"type":"assistant","message":{"role":"assistant","content":"Another valid line","usage":{"input_tokens":10,"output_tokens":20}}}
        {"incomplete": "json"
        """
    }

    /// Creates a session with missing usage data
    static func sessionWithMissingUsage() -> String {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        return """
        {"type":"user","timestamp":"\(timestamp)","message":{"role":"user","content":"Hello"}}
        {"type":"assistant","timestamp":"\(timestamp)","message":{"role":"assistant","content":"Hi"}}
        """
    }

    /// Creates a session with cache tokens only
    static func sessionWithCacheTokens() -> String {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        return """
        {"type":"assistant","timestamp":"\(timestamp)","message":{"role":"assistant","content":[{"type":"text","text":"Using cached context"}],"model":"claude-sonnet-4-20250514","usage":{"input_tokens":0,"output_tokens":50,"cache_creation_input_tokens":1000,"cache_read_input_tokens":5000}}}
        """
    }

    static func claudeStreamingSessionWithDuplicateUsage() -> String {
        let baseTime = Date(timeIntervalSince1970: 1742000200)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        return """
        {"type":"assistant","requestId":"req_123","timestamp":"\(formatter.string(from: baseTime))","message":{"id":"msg_123","role":"assistant","content":[{"type":"text","text":"chunk 1"}],"model":"claude-sonnet-4-20250514","usage":{"input_tokens":100,"output_tokens":40}}}
        {"type":"assistant","requestId":"req_123","timestamp":"\(formatter.string(from: baseTime.addingTimeInterval(1)))","message":{"id":"msg_123","role":"assistant","content":[{"type":"text","text":"chunk 2"}],"model":"claude-sonnet-4-20250514","usage":{"input_tokens":100,"output_tokens":40}}}
        {"type":"assistant","requestId":"req_123","timestamp":"\(formatter.string(from: baseTime.addingTimeInterval(2)))","message":{"id":"msg_123","role":"assistant","content":[{"type":"text","text":"chunk 3"}],"model":"claude-sonnet-4-20250514","usage":{"input_tokens":100,"output_tokens":40}}}
        """
    }

    /// Creates an empty session (no valid usage)
    static func emptySession() -> String {
        return """
        {"type":"system","message":{"role":"system","content":"System prompt"}}
        """
    }
}

// MARK: - Parser Integration Test Harness

@MainActor
final class ParserIntegrationTestHarness {
    let rootURL: URL
    let databaseQueue: DatabaseQueue
    let dataStore: DataStore
    let fileManager: FileManager

    init(name: String = "parser-integration") throws {
        self.fileManager = .default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("BurnBarParserTest-\(name)-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        rootURL = root

        let dbDirectory = root.appendingPathComponent("db", isDirectory: true)
        try fileManager.createDirectory(at: dbDirectory, withIntermediateDirectories: true)
        let dbPath = dbDirectory.appendingPathComponent("test.sqlite")

        databaseQueue = try DatabaseQueue(path: dbPath.path)
        dataStore = try DataStore(
            databaseQueue: databaseQueue,
            runMigrations: true,
            refreshOnInit: false
        )
    }

    func cleanup() {
        try? databaseQueue.close()
        try? fileManager.removeItem(at: rootURL)
    }

    // MARK: - Fixture File Creation

    func createClaudeCodeProject(
        projectName: String,
        sessions: [(sessionId: String, content: String)]
    ) throws -> URL {
        // Claude Code format: ~/.claude/projects/{encoded-project-path}/{session-id}.jsonl
        let encodedProject = projectName
            .replacingOccurrences(of: "~", with: "")
            .replacingOccurrences(of: "/", with: "-")

        let projectsRoot = rootURL.appendingPathComponent(".claude/projects", isDirectory: true)
        let projectDir = projectsRoot.appendingPathComponent(encodedProject, isDirectory: true)
        try fileManager.createDirectory(at: projectDir, withIntermediateDirectories: true)

        for session in sessions {
            let sessionFile = projectDir.appendingPathComponent("\(session.sessionId).jsonl")
            try session.content.write(to: sessionFile, atomically: true, encoding: .utf8)
        }

        return projectDir
    }

    func createFactoryDroidProject(
        projectName: String,
        sessions: [(sessionId: String, content: String, settings: String?, metadata: String?)]
    ) throws -> URL {
        // Factory Droid format: ~/.factory/sessions/{project-name}/{session-id}.jsonl
        let sessionsRoot = rootURL.appendingPathComponent(".factory/sessions", isDirectory: true)
        let projectDir = sessionsRoot.appendingPathComponent(projectName, isDirectory: true)
        try fileManager.createDirectory(at: projectDir, withIntermediateDirectories: true)

        for session in sessions {
            let sessionFile = projectDir.appendingPathComponent("\(session.sessionId).jsonl")
            try session.content.write(to: sessionFile, atomically: true, encoding: .utf8)

            if let settings = session.settings {
                let settingsFile = projectDir.appendingPathComponent("\(session.sessionId).settings.json")
                try settings.write(to: settingsFile, atomically: true, encoding: .utf8)
            }

            if let metadata = session.metadata {
                let metadataFile = projectDir.appendingPathComponent("\(session.sessionId).metadata.json")
                try metadata.write(to: metadataFile, atomically: true, encoding: .utf8)
            }
        }

        return projectDir
    }

    func createCodexThreadDatabase(
        threads: [(id: String, model: String, tokensUsed: Int, rolloutPath: String, createdAt: Int64, updatedAt: Int64, cwd: String)]
    ) throws -> URL {
        let codexRoot = rootURL.appendingPathComponent(".codex", isDirectory: true)
        try fileManager.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        let dbURL = codexRoot.appendingPathComponent("state_5.sqlite")
        let dbQueue = try DatabaseQueue(path: dbURL.path)

        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE threads (
                    id TEXT PRIMARY KEY,
                    title TEXT,
                    model TEXT,
                    model_provider TEXT,
                    tokens_used INTEGER,
                    created_at INTEGER,
                    updated_at INTEGER,
                    cwd TEXT,
                    rollout_path TEXT,
                    archived INTEGER DEFAULT 0
                )
            """)

            for thread in threads {
                try db.execute(
                    sql: """
                        INSERT INTO threads (
                            id, title, model, model_provider, tokens_used,
                            created_at, updated_at, cwd, rollout_path, archived
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
                    """,
                    arguments: [
                        thread.id,
                        thread.id,
                        thread.model,
                        "openai",
                        thread.tokensUsed,
                        thread.createdAt,
                        thread.updatedAt,
                        thread.cwd,
                        thread.rolloutPath,
                    ]
                )
            }
        }

        try dbQueue.close()
        return dbURL
    }

    @discardableResult
    func createHermesSessionSnapshot(
        profileName: String? = nil,
        sessionId: String,
        content: String
    ) throws -> URL {
        let hermesRoot = rootURL.appendingPathComponent(".hermes", isDirectory: true)
        let homeURL: URL
        if let profileName {
            homeURL = hermesRoot
                .appendingPathComponent("profiles", isDirectory: true)
                .appendingPathComponent(profileName, isDirectory: true)
        } else {
            homeURL = hermesRoot
        }

        let sessionsDir = homeURL.appendingPathComponent("sessions", isDirectory: true)
        try fileManager.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        let snapshotURL = sessionsDir.appendingPathComponent("session_\(sessionId).json")
        try content.write(to: snapshotURL, atomically: true, encoding: .utf8)
        return hermesRoot
    }
}

// MARK: - Parser Integration Tests

@MainActor
final class ParserIntegrationTests: XCTestCase {

    var harness: ParserIntegrationTestHarness!

    override func setUp() async throws {
        try await super.setUp()
        harness = try ParserIntegrationTestHarness(name: "\(name ?? "unknown")-\(UUID().uuidString.prefix(8))")
    }

    override func tearDown() async throws {
        harness.cleanup()
        harness = nil
        try await super.tearDown()
    }

    // MARK: - Claude Code Parser Tests

    func test_claudeCodeParser_extractsBasicUsage() async throws {
        // Arrange
        let sessionContent = ParserTestFixtures.claudeCodeSession(
            inputTokens: 1000,
            outputTokens: 500
        )
        _ = try harness.createClaudeCodeProject(
            projectName: "TestProject",
            sessions: [("session-001", sessionContent)]
        )

        // Create parser pointing to our test directory
        let parser = TestableClaudeCodeParser(
            fileManager: harness.fileManager,
            testProjectsPath: harness.rootURL.appendingPathComponent(".claude/projects")
        )

        // Act
        let result = try await parser.parse()

        // Assert
        XCTAssertFalse(result.usages.isEmpty, "Should extract at least one usage record")
        let usage = result.usages[0]
        XCTAssertEqual(usage.provider, .claudeCode)
        XCTAssertEqual(usage.sessionId, "session-001")
        XCTAssertEqual(usage.inputTokens, 1000)
        XCTAssertEqual(usage.outputTokens, 500)
        XCTAssertGreaterThan(usage.costUSD, 0)
    }

    func test_claudeCodeParser_extractsConversation() async throws {
        // Arrange
        let sessionContent = ParserTestFixtures.claudeCodeSession()
        _ = try harness.createClaudeCodeProject(
            projectName: "-Users-test-Documents-TestProject",
            sessions: [("session-001", sessionContent)]
        )

        let parser = TestableClaudeCodeParser(
            fileManager: harness.fileManager,
            testProjectsPath: harness.rootURL.appendingPathComponent(".claude/projects")
        )

        // Act
        let result = try await parser.parse()

        // Assert
        XCTAssertFalse(result.conversations.isEmpty, "Should extract conversation record")
        let conversation = result.conversations[0]
        XCTAssertEqual(conversation.provider, .claudeCode)
        XCTAssertEqual(conversation.sessionId, "session-001")
        XCTAssertEqual(conversation.projectName, "~/Documents/TestProject")
    }

    func test_claudeCodeParser_decodesProjectPath() async throws {
        // Arrange
        let sessionContent = ParserTestFixtures.claudeCodeSession()
        _ = try harness.createClaudeCodeProject(
            projectName: "~-Users-test-Documents-MyProject",
            sessions: [("session-001", sessionContent)]
        )

        let parser = TestableClaudeCodeParser(
            fileManager: harness.fileManager,
            testProjectsPath: harness.rootURL.appendingPathComponent(".claude/projects")
        )

        // Act
        let result = try await parser.parse()

        // Assert
        XCTAssertFalse(result.conversations.isEmpty)
        let conversation = result.conversations[0]
        XCTAssertEqual(conversation.projectName, "~/Documents/MyProject")
    }

    func test_claudeCodeParser_handlesMultiTurnSession() async throws {
        // Arrange
        let sessionContent = ParserTestFixtures.claudeCodeMultiTurnSession()
        _ = try harness.createClaudeCodeProject(
            projectName: "MultiTurn",
            sessions: [("session-001", sessionContent)]
        )

        let parser = TestableClaudeCodeParser(
            fileManager: harness.fileManager,
            testProjectsPath: harness.rootURL.appendingPathComponent(".claude/projects")
        )

        // Act
        let result = try await parser.parse()

        // Assert
        XCTAssertFalse(result.usages.isEmpty)
        let usage = result.usages[0]
        // Multi-turn should aggregate tokens across all assistant messages
        XCTAssertGreaterThanOrEqual(usage.inputTokens, 50)
        XCTAssertGreaterThanOrEqual(usage.outputTokens, 100)
    }

    func test_claudeCodeParser_handlesMalformedLines() async throws {
        // Arrange
        let sessionContent = ParserTestFixtures.sessionWithMalformedLines()
        _ = try harness.createClaudeCodeProject(
            projectName: "Malformed",
            sessions: [("session-001", sessionContent)]
        )

        let parser = TestableClaudeCodeParser(
            fileManager: harness.fileManager,
            testProjectsPath: harness.rootURL.appendingPathComponent(".claude/projects")
        )

        // Act - Should not throw
        let result = try await parser.parse()

        // Assert - Should still extract valid usage
        XCTAssertFalse(result.usages.isEmpty)
    }

    func test_claudeCodeParser_handlesMissingUsage() async throws {
        // Arrange
        let sessionContent = ParserTestFixtures.sessionWithMissingUsage()
        _ = try harness.createClaudeCodeProject(
            projectName: "MissingUsage",
            sessions: [("session-001", sessionContent)]
        )

        let parser = TestableClaudeCodeParser(
            fileManager: harness.fileManager,
            testProjectsPath: harness.rootURL.appendingPathComponent(".claude/projects")
        )

        // Act
        let result = try await parser.parse()

        // Assert - Should skip messages without usage
        XCTAssertTrue(result.usages.isEmpty, "Should not create usage for messages without token data")
    }

    func test_claudeCodeParser_extractsCacheTokens() async throws {
        // Arrange
        let sessionContent = ParserTestFixtures.sessionWithCacheTokens()
        _ = try harness.createClaudeCodeProject(
            projectName: "CacheTest",
            sessions: [("session-001", sessionContent)]
        )

        let parser = TestableClaudeCodeParser(
            fileManager: harness.fileManager,
            testProjectsPath: harness.rootURL.appendingPathComponent(".claude/projects")
        )

        // Act
        let result = try await parser.parse()

        // Assert
        XCTAssertFalse(result.usages.isEmpty)
        let usage = result.usages[0]
        XCTAssertEqual(usage.cacheCreationTokens, 1000)
        XCTAssertEqual(usage.cacheReadTokens, 5000)
    }

    func test_claudeCodeParser_handlesEmptySession() async throws {
        // Arrange
        let sessionContent = ParserTestFixtures.emptySession()
        _ = try harness.createClaudeCodeProject(
            projectName: "Empty",
            sessions: [("session-001", sessionContent)]
        )

        let parser = TestableClaudeCodeParser(
            fileManager: harness.fileManager,
            testProjectsPath: harness.rootURL.appendingPathComponent(".claude/projects")
        )

        // Act
        let result = try await parser.parse()

        // Assert - Empty session should produce no usage
        XCTAssertTrue(result.usages.isEmpty, "Should not produce usage for session with only system messages")
    }

    func test_claudeCodeParser_deduplicatesStreamingUsageChunks() async throws {
        let sessionContent = ParserTestFixtures.claudeStreamingSessionWithDuplicateUsage()
        _ = try harness.createClaudeCodeProject(
            projectName: "Streaming",
            sessions: [("session-001", sessionContent)]
        )

        let parser = TestableClaudeCodeParser(
            fileManager: harness.fileManager,
            testProjectsPath: harness.rootURL.appendingPathComponent(".claude/projects")
        )

        let result = try await parser.parse()

        XCTAssertEqual(result.usages.count, 1)
        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertEqual(usage.inputTokens, 100)
        XCTAssertEqual(usage.outputTokens, 40)
    }

    // MARK: - Factory Droid Parser Tests

    func test_factoryDroidParser_extractsBasicUsage() async throws {
        // Arrange
        let (jsonl, settings, _) = ParserTestFixtures.factoryDroidSessionWithSettings(
            sessionId: "factory-001",
            model: "glm-4",
            inputTokens: 800,
            outputTokens: 400
        )
        _ = try harness.createFactoryDroidProject(
            projectName: "TestFactory",
            sessions: [(sessionId: "factory-001", content: jsonl, settings: settings, metadata: nil)]
        )

        let parser = TestableFactoryDroidParser(
            fileManager: harness.fileManager,
            testSessionsPath: harness.rootURL.appendingPathComponent(".factory/sessions")
        )

        // Act
        let result = try await parser.parse()

        // Assert
        XCTAssertFalse(result.usages.isEmpty, "Should extract at least one usage record")
        let usage = result.usages[0]
        XCTAssertEqual(usage.provider, .factory)
        XCTAssertEqual(usage.sessionId, "factory-001")
        XCTAssertEqual(usage.inputTokens, 800)
        XCTAssertEqual(usage.outputTokens, 400)
    }

    func test_factoryDroidParser_extractsFromMetadata() async throws {
        // Arrange
        let (jsonl, _, metadata) = ParserTestFixtures.factoryDroidSessionWithSettings(
            sessionId: "factory-metadata-001",
            model: "glm-5",
            inputTokens: 1200,
            outputTokens: 600
        )
        _ = try harness.createFactoryDroidProject(
            projectName: "MetadataTest",
            sessions: [(sessionId: "factory-metadata-001", content: jsonl, settings: nil, metadata: metadata)]
        )

        let parser = TestableFactoryDroidParser(
            fileManager: harness.fileManager,
            testSessionsPath: harness.rootURL.appendingPathComponent(".factory/sessions")
        )

        // Act
        let result = try await parser.parse()

        // Assert
        XCTAssertFalse(result.usages.isEmpty)
        let usage = result.usages[0]
        XCTAssertEqual(usage.model, "glm-5")
        XCTAssertEqual(usage.inputTokens, 1200)
    }

    func test_hermesParser_extractsProfileLocalSessionSnapshot() async throws {
        let sessionId = "cron_world_build_001"
        let hermesRoot = try harness.createHermesSessionSnapshot(
            profileName: "world-director",
            sessionId: sessionId,
            content: ParserTestFixtures.hermesSessionSnapshot(sessionId: sessionId)
        )

        let parser = HermesParser(
            fileManager: harness.fileManager,
            hermesRootURL: hermesRoot
        )

        let result = try await parser.parse()

        XCTAssertEqual(result.usages.count, 1)
        XCTAssertEqual(result.conversations.count, 1)

        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertEqual(usage.provider, .hermes)
        XCTAssertEqual(usage.sessionId, "world-director::\(sessionId)")
        XCTAssertEqual(usage.projectName, "world-director")
        XCTAssertEqual(usage.model, "MiniMax-M2.7-highspeed")
        XCTAssertGreaterThan(usage.totalTokens, 0)

        let conversation = try XCTUnwrap(result.conversations.first)
        XCTAssertEqual(conversation.sessionId, "world-director::\(sessionId)")
        XCTAssertEqual(conversation.projectName, "world-director")
    }

    func test_hermesParser_namespacesDuplicateRawSessionIDsAcrossProfiles() async throws {
        let sharedSessionId = "cron_shared_001"
        let hermesRoot = try harness.createHermesSessionSnapshot(
            profileName: "world-director",
            sessionId: sharedSessionId,
            content: ParserTestFixtures.hermesSessionSnapshot(
                sessionId: sharedSessionId,
                assistantText: "Director planned and dispatched the next bounded world cycle."
            )
        )
        _ = try harness.createHermesSessionSnapshot(
            profileName: "world-critic",
            sessionId: sharedSessionId,
            content: ParserTestFixtures.hermesSessionSnapshot(
                sessionId: sharedSessionId,
                assistantText: "Critic reviewed the proposed batch and approved the aesthetically coherent subset."
            )
        )

        let parser = HermesParser(
            fileManager: harness.fileManager,
            hermesRootURL: hermesRoot
        )

        let result = try await parser.parse()
        let sessionIDs = Set(result.usages.map(\.sessionId))

        XCTAssertEqual(result.usages.count, 2)
        XCTAssertEqual(sessionIDs, Set([
            "world-critic::\(sharedSessionId)",
            "world-director::\(sharedSessionId)",
        ]))
    }

    func test_hermesParser_estimatesInputFromSystemPromptAndToolOutputs() async throws {
        let sessionId = "cron_tool_heavy_001"
        let hermesRoot = try harness.createHermesSessionSnapshot(
            profileName: "world-director",
            sessionId: sessionId,
            content: ParserTestFixtures.hermesToolHeavySessionSnapshot(sessionId: sessionId)
        )

        let parser = HermesParser(
            fileManager: harness.fileManager,
            hermesRootURL: hermesRoot
        )

        let result = try await parser.parse()

        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertGreaterThan(usage.inputTokens, 2_000)
        XCTAssertGreaterThan(usage.totalTokens, usage.outputTokens)
    }

    func test_codexParser_extractsWrappedTokenCountTotalsWithoutDoubleCountingCachedInput() async throws {
        let rolloutDirectory = harness.rootURL.appendingPathComponent(".codex/sessions/2025/12/24", isDirectory: true)
        try harness.fileManager.createDirectory(at: rolloutDirectory, withIntermediateDirectories: true)
        let rolloutURL = rolloutDirectory.appendingPathComponent("rollout-2025-12-24T12-00-00.jsonl")
        let session = ParserTestFixtures.codexRolloutSession()
        try session.write(to: rolloutURL, atomically: true, encoding: .utf8)

        _ = try harness.createCodexThreadDatabase(threads: [(
            id: "codex-thread-001",
            model: "openai/gpt-5.2-codex",
            tokensUsed: 176,
            rolloutPath: rolloutURL.path,
            createdAt: 1_766_577_600,
            updatedAt: 1_766_577_660,
            cwd: "/tmp/OpenBurnBar"
        )])

        let parser = TestableCodexParser(
            fileManager: harness.fileManager,
            codexRoot: harness.rootURL.appendingPathComponent(".codex", isDirectory: true),
            appPaths: OpenBurnBarAppPaths(applicationSupportRoot: harness.rootURL.appendingPathComponent("support", isDirectory: true))
        )

        let result = try await parser.parse()

        XCTAssertEqual(result.usages.count, 1)
        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertEqual(usage.inputTokens, 120)
        XCTAssertEqual(usage.cacheReadTokens, 40)
        XCTAssertEqual(usage.outputTokens, 16)
        XCTAssertEqual(usage.totalTokens, 136)
    }

    func test_codexParser_accumulatesLastTokenUsageWhenTotalsAreUnavailable() async throws {
        let rolloutDirectory = harness.rootURL.appendingPathComponent(".codex/sessions/2025/12/25", isDirectory: true)
        try harness.fileManager.createDirectory(at: rolloutDirectory, withIntermediateDirectories: true)
        let rolloutURL = rolloutDirectory.appendingPathComponent("rollout-2025-12-25T12-00-00.jsonl")
        let session = ParserTestFixtures.codexRolloutSessionWithLastUsageOnly()
        try session.write(to: rolloutURL, atomically: true, encoding: .utf8)

        _ = try harness.createCodexThreadDatabase(threads: [(
            id: "codex-thread-002",
            model: "openai/gpt-5.2-codex",
            tokensUsed: 176,
            rolloutPath: rolloutURL.path,
            createdAt: 1_766_664_000,
            updatedAt: 1_766_664_060,
            cwd: "/tmp/OpenBurnBar"
        )])

        let parser = TestableCodexParser(
            fileManager: harness.fileManager,
            codexRoot: harness.rootURL.appendingPathComponent(".codex", isDirectory: true),
            appPaths: OpenBurnBarAppPaths(applicationSupportRoot: harness.rootURL.appendingPathComponent("support", isDirectory: true))
        )

        let result = try await parser.parse()

        XCTAssertEqual(result.usages.count, 1)
        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertEqual(usage.inputTokens, 120)
        XCTAssertEqual(usage.cacheReadTokens, 40)
        XCTAssertEqual(usage.outputTokens, 16)
        XCTAssertEqual(usage.totalTokens, 136)
    }

    // MARK: - Codex Partial Token Count Tests (VAL-TOKEN-010)

    /// VAL-TOKEN-010: Partial token_count maps (missing input_tokens/output_tokens) must NOT
    /// suppress valid delta accumulation from last_token_usage events.
    /// This was a regression where codexCumulativeTotalsFromTokenCountInfo returned (0,0,0)
    /// for any token_count map, treating partial data as authoritative cumulative.
    func test_codexParser_partialTokenCountDoesNotSuppressDeltaAccumulation() async throws {
        let rolloutDirectory = harness.rootURL.appendingPathComponent(".codex/sessions/2025/12/26", isDirectory: true)
        try harness.fileManager.createDirectory(at: rolloutDirectory, withIntermediateDirectories: true)
        let rolloutURL = rolloutDirectory.appendingPathComponent("rollout-2025-12-26T12-00-00.jsonl")
        let session = ParserTestFixtures.codexRolloutSessionWithPartialTokenCountAndDeltas()
        try session.write(to: rolloutURL, atomically: true, encoding: .utf8)

        _ = try harness.createCodexThreadDatabase(threads: [(
            id: "codex-thread-003",
            model: "openai/gpt-5.2-codex",
            tokensUsed: 176,
            rolloutPath: rolloutURL.path,
            createdAt: 1_766_750_000,
            updatedAt: 1_766_750_060,
            cwd: "/tmp/OpenBurnBar"
        )])

        let parser = TestableCodexParser(
            fileManager: harness.fileManager,
            codexRoot: harness.rootURL.appendingPathComponent(".codex", isDirectory: true),
            appPaths: OpenBurnBarAppPaths(applicationSupportRoot: harness.rootURL.appendingPathComponent("support", isDirectory: true))
        )

        let result = try await parser.parse()

        XCTAssertEqual(result.usages.count, 1)
        let usage = try XCTUnwrap(result.usages.first)
        // Deltas: (100-20) + (60-20) = 80 + 40 = 120 input tokens
        // Deltas: 20 + 20 = 40 cache read tokens
        // Deltas: 10 + 6 = 16 output tokens
        XCTAssertEqual(usage.inputTokens, 120)
        XCTAssertEqual(usage.cacheReadTokens, 40)
        XCTAssertEqual(usage.outputTokens, 16)
        XCTAssertEqual(usage.totalTokens, 136)
    }

    func test_tokenExtractionUtility_extractsCacheCreationTokens() {
        let extracted = TokenExtractionUtility.extractUsageTokens([
            "input_tokens": 120,
            "output_tokens": 80,
            "cache_creation_input_tokens": 40,
            "cache_read_input_tokens": 20
        ])

        XCTAssertEqual(extracted.input, 120)
        XCTAssertEqual(extracted.output, 80)
        XCTAssertEqual(extracted.cacheCreation, 40)
        XCTAssertEqual(extracted.cacheRead, 20)
    }

    // MARK: - Codex Cumulative Totals Extraction (VAL-TOKEN-010)

    /// VAL-TOKEN-010: codexCumulativeTotalsFromTokenCountInfo must return nil for partial
    /// token_count maps (missing input_tokens/output_tokens), so delta parsing proceeds.
    func test_codexCumulativeTotalsFromTokenCountInfo_returnsNilForPartialTokenCountMap() {
        // Partial map with only cached_input_tokens, no input_tokens or output_tokens
        let partialInfo: [String: Any] = [
            "token_count": ["cached_input_tokens": 100] as [String: Any]
        ]
        let result = TokenExtractionUtility.codexCumulativeTotalsFromTokenCountInfo(partialInfo)
        XCTAssertNil(result, "Partial token_count map should return nil, not (0,0,0)")
    }

    /// VAL-TOKEN-010: Full cumulative token_count map should return valid tuple.
    func test_codexCumulativeTotalsFromTokenCountInfo_returnsTupleForFullTokenCountMap() {
        let fullInfo: [String: Any] = [
            "token_count": [
                "input_tokens": 160,
                "output_tokens": 16,
                "cached_input_tokens": 40
            ]
        ]
        let result = TokenExtractionUtility.codexCumulativeTotalsFromTokenCountInfo(fullInfo)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.input, 160)
        XCTAssertEqual(result?.output, 16)
        XCTAssertEqual(result?.cacheRead, 40)
    }

    /// VAL-TOKEN-010: Empty token_count map should return nil.
    func test_codexCumulativeTotalsFromTokenCountInfo_returnsNilForEmptyTokenCountMap() {
        let emptyInfo: [String: Any] = [
            "token_count": [:]
        ]
        let result = TokenExtractionUtility.codexCumulativeTotalsFromTokenCountInfo(emptyInfo)
        XCTAssertNil(result, "Empty token_count map should return nil")
    }

    /// VAL-TOKEN-010: Root-level input/output without token_count wrapper should work.
    func test_codexCumulativeTotalsFromTokenCountInfo_returnsTupleForRootLevelFields() {
        let rootLevelInfo: [String: Any] = [
            "input_tokens": 200,
            "output_tokens": 50
        ]
        let result = TokenExtractionUtility.codexCumulativeTotalsFromTokenCountInfo(rootLevelInfo)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.input, 200)
        XCTAssertEqual(result?.output, 50)
        XCTAssertEqual(result?.cacheRead, 0)
    }

    func test_tokenExtractionUtility_previewMarkersIncreaseVisibleCharacterCount() {
        let previewText = """
        line 1
        line 2
        line 3
        [Showing lines 1-3 of 12 total lines]
        """

        let plain = TokenExtractionUtility.contentMetrics(from: "line 1\nline 2\nline 3")
        let preview = TokenExtractionUtility.contentMetrics(from: previewText)

        XCTAssertGreaterThan(preview.visibleChars, plain.visibleChars)
    }

    // MARK: - Parser → DataStore Integration Tests

    func test_parserResult_storesToDataStore() async throws {
        // Arrange
        let sessionContent = ParserTestFixtures.claudeCodeSession(
            inputTokens: 2000,
            outputTokens: 1000
        )
        _ = try harness.createClaudeCodeProject(
            projectName: "DataStoreTest",
            sessions: [("store-001", sessionContent)]
        )

        let parser = TestableClaudeCodeParser(
            fileManager: harness.fileManager,
            testProjectsPath: harness.rootURL.appendingPathComponent(".claude/projects")
        )

        // Act
        let result = try await parser.parse()

        // Store usages
        harness.dataStore.replaceUsages(result.usages)

        // Also store conversations
        for conversation in result.conversations {
            try harness.dataStore.upsertConversation(conversation)
        }

        // Assert
        let storedUsages = harness.dataStore.usages
        XCTAssertFalse(storedUsages.isEmpty, "Should have stored usages in DataStore")

        let storedConversations = try harness.dataStore.fetchSessionLogSummaries(limit: 1000)
        XCTAssertFalse(storedConversations.isEmpty, "Should have stored conversations in DataStore")
    }

    func test_multipleParsers_produceDistinctRecords() async throws {
        // Arrange - Create sessions for multiple providers
        let claudeSession = ParserTestFixtures.claudeCodeSession(
            sessionId: "claude-multi-001",
            inputTokens: 1000,
            outputTokens: 500
        )
        let (factoryJsonl, factorySettings, _) = ParserTestFixtures.factoryDroidSessionWithSettings(
            sessionId: "factory-multi-001",
            model: "glm-4",
            inputTokens: 800,
            outputTokens: 400
        )

        _ = try harness.createClaudeCodeProject(
            projectName: "MultiProvider",
            sessions: [("claude-multi-001", claudeSession)]
        )
        _ = try harness.createFactoryDroidProject(
            projectName: "MultiProvider",
            sessions: [(sessionId: "factory-multi-001", content: factoryJsonl, settings: factorySettings, metadata: nil)]
        )

        // Act
        let claudeParser = TestableClaudeCodeParser(
            fileManager: harness.fileManager,
            testProjectsPath: harness.rootURL.appendingPathComponent(".claude/projects")
        )
        let factoryParser = TestableFactoryDroidParser(
            fileManager: harness.fileManager,
            testSessionsPath: harness.rootURL.appendingPathComponent(".factory/sessions")
        )

        let claudeResult = try await claudeParser.parse()
        let factoryResult = try await factoryParser.parse()

        // Store all
        harness.dataStore.replaceUsages(claudeResult.usages + factoryResult.usages)

        // Assert
        let allUsages = harness.dataStore.usages
        XCTAssertEqual(allUsages.count, 2, "Should have exactly 2 usage records")

        let providers: Set<AgentProvider> = Set(allUsages.map(\.provider))
        XCTAssertTrue(providers.contains(.claudeCode))
        XCTAssertTrue(providers.contains(.factory))
    }

    // MARK: - Edge Case Tests

    func test_parser_handlesNonExistentDirectory() async throws {
        // Arrange
        let nonExistentPath = harness.rootURL.appendingPathComponent("nonexistent/.claude/projects")

        let parser = TestableClaudeCodeParser(
            fileManager: harness.fileManager,
            testProjectsPath: nonExistentPath
        )

        // Act
        let result = try await parser.parse()

        // Assert - Should return empty, not throw
        XCTAssertTrue(result.usages.isEmpty)
        XCTAssertTrue(result.conversations.isEmpty)
    }

    func test_parser_calculatesCostCorrectly() async throws {
        // Arrange - Known model with known pricing
        let sessionContent = ParserTestFixtures.claudeCodeSession(
            model: "claude-sonnet-4-20250514",
            inputTokens: 1_000_000, // 1M input tokens
            outputTokens: 1_000_000  // 1M output tokens
        )
        _ = try harness.createClaudeCodeProject(
            projectName: "CostTest",
            sessions: [("cost-001", sessionContent)]
        )

        let parser = TestableClaudeCodeParser(
            fileManager: harness.fileManager,
            testProjectsPath: harness.rootURL.appendingPathComponent(".claude/projects")
        )

        // Act
        let result = try await parser.parse()

        // Assert
        XCTAssertFalse(result.usages.isEmpty)
        let usage = result.usages[0]

        // Claude Sonnet 4 pricing: ~$3/1M input, ~$15/1M output
        // So 1M input + 1M output should be approximately $18
        let expectedMin = 15.0  // Lower bound (output)
        let expectedMax = 25.0  // Upper bound (input + output with some variance)
        XCTAssertGreaterThan(usage.costUSD, expectedMin)
        XCTAssertLessThan(usage.costUSD, expectedMax)
    }
}

// MARK: - Testable Parser Wrappers

/// Testable wrapper for ClaudeCodeParser that allows injecting test paths
final class TestableClaudeCodeParser: LogParser, @unchecked Sendable {
    let provider: AgentProvider = .claudeCode
    private let fileManager: FileManager
    private let testProjectsPath: URL
    private let cacheURL: URL

    init(fileManager: FileManager = .default, testProjectsPath: URL) {
        self.fileManager = fileManager
        self.testProjectsPath = testProjectsPath
        self.cacheURL = fileManager.temporaryDirectory
            .appendingPathComponent("claude-parser-test-cache-\(UUID().uuidString).json")
    }

    private func parseTimestamp(_ raw: Any?) -> Date? {
        if let string = raw as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: string) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: string) { return date }
            return nil
        }

        let epoch: Double?
        if let number = raw as? NSNumber {
            epoch = number.doubleValue
        } else if let value = raw as? Double {
            epoch = value
        } else if let value = raw as? Int {
            epoch = Double(value)
        } else {
            epoch = nil
        }

        guard let epoch else { return nil }
        let seconds = epoch > 100_000_000_000 ? epoch / 1000.0 : epoch
        return Date(timeIntervalSince1970: seconds)
    }

    func parse() async throws -> ParseResult {
        guard fileManager.fileExists(atPath: testProjectsPath.path) else {
            return ParseResult(usages: [], conversations: [])
        }

        var usages: [TokenUsage] = []
        var conversations: [ConversationRecord] = []

        guard let projectDirs = try? fileManager.contentsOfDirectory(
            at: testProjectsPath,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return ParseResult(usages: [], conversations: [])
        }

        for projectDir in projectDirs.filter(\.hasDirectoryPath) {
            let projectName = decodeProjectName(projectDir.lastPathComponent)

            guard let files = try? fileManager.contentsOfDirectory(at: projectDir, includingPropertiesForKeys: nil) else {
                continue
            }

            let jsonlFiles = files.filter { $0.pathExtension == "jsonl" }

            for jsonlFile in jsonlFiles {
                let sessionId = jsonlFile.deletingPathExtension().lastPathComponent
                if let parsed = try? parseSession(file: jsonlFile, sessionId: sessionId, projectName: projectName) {
                    if let usage = parsed.usage {
                        usages.append(usage)
                    }
                    if let conversation = parsed.conversation {
                        conversations.append(conversation)
                    }
                }
            }
        }

        return ParseResult(usages: usages, conversations: conversations)
    }

    private func decodeProjectName(_ encoded: String) -> String {
        guard encoded.hasPrefix("-Users-") else {
            return encoded
        }
        let pathAfterPrefix = String(encoded.dropFirst(7))
        var segments: [String] = []
        var currentSegment = ""

        for (index, char) in pathAfterPrefix.enumerated() {
            if char == "-" && index + 1 < pathAfterPrefix.count {
                let nextIndex = pathAfterPrefix.index(pathAfterPrefix.startIndex, offsetBy: index + 1)
                let nextChar = pathAfterPrefix[nextIndex]
                if nextChar.isUppercase {
                    if !currentSegment.isEmpty {
                        segments.append(currentSegment)
                    }
                    currentSegment = ""
                } else {
                    currentSegment.append(char)
                }
            } else {
                currentSegment.append(char)
            }
        }
        if !currentSegment.isEmpty {
            segments.append(currentSegment)
        }

        if segments.count == 1 {
            return "~/" + segments[0]
        } else {
            return "~/" + segments.dropFirst().joined(separator: "/")
        }
    }

    private func parseSession(
        file: URL,
        sessionId: String,
        projectName: String
    ) throws -> (usage: TokenUsage?, conversation: ConversationRecord?)? {
        guard let handle = try? FileHandle(forReadingFrom: file) else {
            return nil
        }
        defer { try? handle.close() }

        let mtime = modificationDate(of: file)
        var totalInput = 0
        var totalOutput = 0
        var cacheCreation = 0
        var cacheRead = 0
        var models: Set<String> = []
        var startTime: Date?
        var endTime: Date?
        var seenUsageKeys = Set<String>()

        for line in handle.readAllUTF8Lines() {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            guard json["type"] as? String == "assistant",
                  let message = json["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else {
                continue
            }

            if let usageKey = self.claudeUsageIdentity(json: json, message: message) {
                guard seenUsageKeys.insert(usageKey).inserted else { continue }
            }

            if let ts = parseTimestamp(json["timestamp"]) {
                if startTime == nil { startTime = ts }
                endTime = ts
            }

            totalInput += (usage["input_tokens"] as? Int) ?? 0
            totalOutput += (usage["output_tokens"] as? Int) ?? 0
            cacheCreation += (usage["cache_creation_input_tokens"] as? Int) ?? 0
            cacheRead += (usage["cache_read_input_tokens"] as? Int) ?? 0

            if let model = message["model"] as? String {
                models.insert(model)
            }
        }

        guard totalInput > 0 || totalOutput > 0 else {
            return nil
        }

        let model = models.first ?? "claude"
        let pricing = ModelPricing.lookup(model: model)
        let cost = pricing.cost(
            inputTokens: totalInput,
            outputTokens: totalOutput,
            cacheCreationTokens: cacheCreation,
            cacheReadTokens: cacheRead
        )

        let usageStart = startTime ?? mtime ?? Date()
        let usageEnd = endTime ?? mtime ?? usageStart

        let usage = TokenUsage(
            provider: .claudeCode,
            sessionId: sessionId,
            projectName: projectName,
            model: model,
            inputTokens: totalInput,
            outputTokens: totalOutput,
            cacheCreationTokens: cacheCreation,
            cacheReadTokens: cacheRead,
            costUSD: cost,
            startTime: usageStart,
            endTime: usageEnd
        )

        let conversation = ConversationRecord(
            id: ConversationRecord.stableId(provider: .claudeCode, sessionId: sessionId),
            provider: .claudeCode,
            sessionId: sessionId,
            projectName: projectName,
            startTime: usageStart,
            endTime: usageEnd,
            messageCount: 0,
            userWordCount: 0,
            assistantWordCount: 0,
            keyFiles: [],
            keyCommands: [],
            keyTools: [],
            inferredTaskTitle: projectName,
            lastAssistantMessage: "",
            fullText: "",
            indexedAt: Date(),
            fileModifiedAt: mtime,
            summary: nil
        )

        return (usage, conversation)
    }

    private func claudeUsageIdentity(json: [String: Any], message: [String: Any]) -> String? {
        guard let messageID = message["id"] as? String,
              let requestID = json["requestId"] as? String,
              !messageID.isEmpty,
              !requestID.isEmpty else {
            return nil
        }
        return "\(messageID):\(requestID)"
    }

    private func modificationDate(of url: URL) -> Date? {
        (try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    private static func parseTimestamp(_ raw: Any?) -> Date? {
        if let string = raw as? String {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let parsed = fractional.date(from: string) { return parsed }

            let basic = ISO8601DateFormatter()
            basic.formatOptions = [.withInternetDateTime]
            if let parsed = basic.date(from: string) { return parsed }
            return nil
        }

        let epoch: Double?
        if let number = raw as? NSNumber {
            epoch = number.doubleValue
        } else if let value = raw as? Double {
            epoch = value
        } else if let value = raw as? Int {
            epoch = Double(value)
        } else {
            epoch = nil
        }

        guard let epoch else { return nil }
        let seconds = epoch > 100_000_000_000 ? epoch / 1000.0 : epoch
        return Date(timeIntervalSince1970: seconds)
    }
}

final class TestableCodexParser: LogParser, @unchecked Sendable {
    let provider: AgentProvider = .codex
    private let fileManager: FileManager
    private let appPaths: OpenBurnBarAppPaths
    private let homeDirectoryURL: URL

    init(fileManager: FileManager = .default, codexRoot: URL, appPaths: OpenBurnBarAppPaths) {
        self.fileManager = fileManager
        self.appPaths = appPaths
        self.homeDirectoryURL = codexRoot.deletingLastPathComponent()
    }

    func parse() async throws -> ParseResult {
        let parser = CodexParser(
            fileManager: fileManager,
            appPaths: appPaths,
            homeDirectoryURL: homeDirectoryURL
        )
        return try await parser.parse()
    }
}

/// Testable wrapper for FactoryDroidParser
final class TestableFactoryDroidParser: LogParser, @unchecked Sendable {
    let provider: AgentProvider = .factory
    private let fileManager: FileManager
    private let testSessionsPath: URL

    init(fileManager: FileManager = .default, testSessionsPath: URL) {
        self.fileManager = fileManager
        self.testSessionsPath = testSessionsPath
    }

    func parse() async throws -> ParseResult {
        guard fileManager.fileExists(atPath: testSessionsPath.path) else {
            return ParseResult(usages: [], conversations: [])
        }

        var usages: [TokenUsage] = []
        var conversations: [ConversationRecord] = []

        guard let projectDirs = try? fileManager.contentsOfDirectory(
            at: testSessionsPath,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return ParseResult(usages: [], conversations: [])
        }

        for projectDir in projectDirs.filter(\.hasDirectoryPath) {
            let projectName = decodeProjectName(projectDir.lastPathComponent)

            guard let files = try? fileManager.contentsOfDirectory(at: projectDir, includingPropertiesForKeys: nil) else {
                continue
            }

            let jsonlFiles = files.filter { $0.pathExtension == "jsonl" }

            for jsonlFile in jsonlFiles {
                let baseName = jsonlFile.deletingPathExtension().lastPathComponent
                let settingsFile = projectDir.appendingPathComponent("\(baseName).settings.json")
                let metadataFile = projectDir.appendingPathComponent("\(baseName).metadata.json")

                if let parsed = try? parseSession(
                    jsonlFile: jsonlFile,
                    settingsFile: settingsFile,
                    metadataFile: metadataFile,
                    sessionId: baseName,
                    projectName: projectName
                ) {
                    if let usage = parsed.usage {
                        usages.append(usage)
                    }
                    if let conversation = parsed.conversation {
                        conversations.append(conversation)
                    }
                }
            }
        }

        return ParseResult(usages: usages, conversations: conversations)
    }

    private func decodeProjectName(_ encoded: String) -> String {
        encoded
            .replacingOccurrences(of: "-Users-", with: "~/")
            .replacingOccurrences(of: "-", with: "/")
    }

    private func parseSession(
        jsonlFile: URL,
        settingsFile: URL,
        metadataFile: URL,
        sessionId: String,
        projectName: String
    ) throws -> (usage: TokenUsage?, conversation: ConversationRecord?)? {
        var totalInput = 0
        var totalOutput = 0
        var cacheCreation = 0
        var cacheRead = 0
        var model = "unknown"
        var startTime: Date?
        var endTime: Date?

        // Check settings.json
        if let data = try? Data(contentsOf: settingsFile),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let m = json["model"] as? String {
                model = m
            }
            if let tokenUsage = json["tokenUsage"] as? [String: Any] {
                totalInput = tokenUsage["input_tokens"] as? Int ?? 0
                totalOutput = tokenUsage["output_tokens"] as? Int ?? 0
            }
        }

        // Check metadata.json if settings didn't have tokens
        if totalInput == 0 && totalOutput == 0 {
            if let data = try? Data(contentsOf: metadataFile),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if model == "unknown", let m = json["model"] as? String {
                    model = m
                }
                if let usage = json["usage"] as? [String: Any] ?? json["tokenUsage"] as? [String: Any] {
                    totalInput = usage["input_tokens"] as? Int ?? 0
                    totalOutput = usage["output_tokens"] as? Int ?? 0
                }
            }
        }

        // Parse JSONL for timestamps and additional tokens
        if let handle = try? FileHandle(forReadingFrom: jsonlFile) {
            defer { try? handle.close() }

            for line in handle.readAllUTF8Lines() {
                guard let data = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }

                if let ts = parseTimestamp(json["timestamp"] as? String) {
                    if startTime == nil { startTime = ts }
                    endTime = ts
                }

                if let message = json["message"] as? [String: Any],
                   let usage = message["usage"] as? [String: Any] {
                    if totalInput == 0 {
                        totalInput = usage["input_tokens"] as? Int ?? 0
                    }
                    if totalOutput == 0 {
                        totalOutput = usage["output_tokens"] as? Int ?? 0
                    }
                }
            }
        }

        guard totalInput > 0 || totalOutput > 0 else {
            return nil
        }

        let mtime = (try? fileManager.attributesOfItem(atPath: jsonlFile.path)[.modificationDate]) as? Date
        let pricing = ModelPricing.lookup(model: model)
        let cost = pricing.cost(
            inputTokens: totalInput,
            outputTokens: totalOutput,
            cacheCreationTokens: cacheCreation,
            cacheReadTokens: cacheRead
        )

        let usageStart = startTime ?? mtime ?? Date()
        let usageEnd = endTime ?? mtime ?? usageStart

        let usage = TokenUsage(
            provider: .factory,
            sessionId: sessionId,
            projectName: projectName,
            model: model,
            inputTokens: totalInput,
            outputTokens: totalOutput,
            cacheCreationTokens: cacheCreation,
            cacheReadTokens: cacheRead,
            costUSD: cost,
            startTime: usageStart,
            endTime: usageEnd
        )

        let conversation = ConversationRecord(
            id: ConversationRecord.stableId(provider: .factory, sessionId: sessionId),
            provider: .factory,
            sessionId: sessionId,
            projectName: projectName,
            startTime: usageStart,
            endTime: usageEnd,
            messageCount: 0,
            userWordCount: 0,
            assistantWordCount: 0,
            keyFiles: [],
            keyCommands: [],
            keyTools: [],
            inferredTaskTitle: projectName,
            lastAssistantMessage: "",
            fullText: "",
            indexedAt: Date(),
            fileModifiedAt: mtime,
            summary: nil
        )

        return (usage, conversation)
    }

    private func parseTimestamp(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: raw)
    }
}
