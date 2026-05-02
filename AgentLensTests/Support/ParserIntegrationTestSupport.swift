import Foundation
import GRDB
import XCTest
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
