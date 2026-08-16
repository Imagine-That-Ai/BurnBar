@testable import BurnBar
import Foundation
import GRDB
import XCTest

// MARK: - Usage Aggregator Hermetic refreshAll Tests

/// VAL-PROV-009/018 hermetic full-refresh proof (aggregator-refreshall-proof):
/// a FULL `UsageAggregator.refreshAll()` runs twice over injected fixture roots
/// with an injected temp app-support dir — per-provider exact row counts,
/// zero duplicate sessionIds on the second refresh, and no writes outside the
/// injected temp app-support dir.
///
/// Hermeticity (per library/environment.md "UsageAggregator hermetic refreshAll"):
/// - `BURNBAR_FLEET_ROOTS_DIR` in the injected environment dict redirects every
///   parser root under the temp fixture tree (ParserRootResolver seam).
/// - `BurnBarAppPaths(applicationSupportRoot:)` redirects every parser cache
///   (claude/factory/codex/model-filter) and the quota snapshots into the temp
///   app-support dir.
/// - The quota service gets a `TestKeychainBackend` (the real keychain holds a
///   minimax key), an empty `environment` (the live env has `ZAI_API_KEY`), a
///   failing URL session (no network), `.payAsYouGo` minimax mode, and a temp
///   home (no real `~/.claude` reads).
/// - The summary sweep is gated off (`conversationIndexingEnabled` /
///   `autoSessionSummariesEnabled` false) so no Ollama/cloud summarization runs;
///   `artifactDiscoveryEnabled` stays false; the projection pipeline is injected
///   with `DeterministicFakeEmbeddingProvider` (no OpenAI key lookup).
@MainActor
final class UsageAggregatorRefreshAllTests: XCTestCase {

    private static var cachedRealSupportManifest: [String: RecursiveFileManifestEntry]?
    private var tempRoot: URL!
    private var rootsDir: URL!
    private var appSupportRoot: URL!
    private var homeDir: URL!
    private var realSupportSnapshot: [String: RecursiveFileManifestEntry] = [:]

    private var originalConversationIndexingEnabled: Bool?
    private var originalAutoSessionSummariesEnabled: Bool?
    private var originalArtifactDiscoveryEnabled: Bool?

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-aggregator-refreshall-\(UUID().uuidString)", isDirectory: true)
        rootsDir = tempRoot.appendingPathComponent("roots", isDirectory: true)
        appSupportRoot = tempRoot.appendingPathComponent("app-support", isDirectory: true)
        homeDir = tempRoot.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: rootsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: appSupportRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: homeDir, withIntermediateDirectories: true)
        try makeFixtureTree()

        if let cached = Self.cachedRealSupportManifest {
            realSupportSnapshot = cached
        } else {
            let manifest = RecursiveSupportManifest.make(for: BurnBarAppPaths.live().supportDirectory)
            Self.cachedRealSupportManifest = manifest
            realSupportSnapshot = manifest
        }

        // Gate the summary sweep and artifact discovery (real defaults enable
        // both; the sweep would hit Ollama/cloud endpoints). Restored in tearDown.
        let settings = SettingsManager.shared
        originalConversationIndexingEnabled = settings.conversationIndexingEnabled
        originalAutoSessionSummariesEnabled = settings.autoSessionSummariesEnabled
        originalArtifactDiscoveryEnabled = settings.artifactDiscoveryEnabled
        settings.conversationIndexingEnabled = false
        settings.autoSessionSummariesEnabled = false
        settings.artifactDiscoveryEnabled = false
    }

    override func tearDownWithError() throws {
        let settings = SettingsManager.shared
        if let value = originalConversationIndexingEnabled {
            settings.conversationIndexingEnabled = value
        }
        if let value = originalAutoSessionSummariesEnabled {
            settings.autoSessionSummariesEnabled = value
        }
        if let value = originalArtifactDiscoveryEnabled {
            settings.artifactDiscoveryEnabled = value
        }
        originalConversationIndexingEnabled = nil
        originalAutoSessionSummariesEnabled = nil
        originalArtifactDiscoveryEnabled = nil

        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
    }

    // MARK: VAL-PROV-009 — full refreshAll ingests every registered provider

    func test_refreshAll_ingestsAllRegisteredProvidersWithExactCounts() async throws {
        let store = try makeInMemoryStore()
        let aggregator = makeAggregator(dataStore: store)

        await aggregator.refreshAll()

        XCTAssertEqual(aggregator.registeredParserProviders.count, 20,
                       "All AgentProvider cases must be registered")
        let counts = perProviderCounts(store.usages)
        let expected: [AgentProvider: Int] = [
            .factory: 1, .claudeCode: 1, .copilot: 1, .aider: 1, .cursor: 1,
            .codex: 1, .zai: 1, .minimax: 1, .kimi: 1, .cline: 1,
            .kiloCode: 1, .rooCode: 1, .forgeDev: 1, .augment: 1, .hermes: 1,
            .grokCLI: 1, .pi: 1, .geminiCLI: 1, .goose: 1, .grokBot: 0
        ]
        for (provider, expectedCount) in expected {
            XCTAssertEqual(counts[provider] ?? 0, expectedCount,
                           "\(provider) row count must match the fixture baseline")
        }
        XCTAssertEqual(store.usages.count, 19,
                       "Total row count must match the fixture baseline (19 providers × 1 session)")
    }

    // MARK: M2 scrutiny — parser-specific health reaches the aggregator

    func test_refreshAllPropagatesTranscriptHealthToParserHealth() async throws {
        let store = try makeInMemoryStore()
        let aggregator = makeAggregator(dataStore: store)

        await aggregator.refreshAll()

        guard case let .degraded(piCount, piError) = aggregator.parserHealth[.pi] else {
            return XCTFail("Pi malformed-line health must surface as aggregator degradation")
        }
        XCTAssertEqual(piCount, 1)
        XCTAssertTrue(piError.contains("malformedLines="), "Pi error should retain transcript health summary")

        guard case let .degraded(grokCount, grokError) = aggregator.parserHealth[.grokCLI] else {
            return XCTFail("Grok CLI malformed-line health must surface as aggregator degradation")
        }
        XCTAssertEqual(grokCount, 1)
        XCTAssertTrue(grokError.contains("malformedLines="), "Grok error should retain transcript health summary")
    }

    // MARK: VAL-PROV-018 — second refresh is idempotent

    func test_secondRefresh_isIdempotent_noDuplicateSessionIds() async throws {
        let store = try makeInMemoryStore()
        let aggregator = makeAggregator(dataStore: store)

        await aggregator.refreshAll()
        let firstCounts = perProviderCounts(store.usages)
        let firstTotal = store.usages.count
        XCTAssertEqual(firstTotal, 19, "Sanity: first refresh must ingest the full fixture baseline")

        await aggregator.refreshAll()

        XCTAssertEqual(store.usages.count, firstTotal,
                       "Total row count must be identical after the second refresh")
        XCTAssertEqual(perProviderCounts(store.usages), firstCounts,
                       "Per-provider counts must be identical after the second refresh")

        // No duplicate (provider, sessionId) pairs after the second refresh.
        let pairs = store.usages.map { "\($0.provider.rawValue)|\($0.sessionId)" }
        XCTAssertEqual(Set(pairs).count, pairs.count,
                       "No duplicate sessionIds across the second refresh")
        for provider in Set(store.usages.map(\.provider)) {
            let ids = store.usages.filter { $0.provider == provider }.map(\.sessionId)
            XCTAssertEqual(Set(ids).count, ids.count,
                           "No duplicate sessionIds for \(provider)")
        }

        // The SQLite store must not accumulate duplicate rows either.
        let dbRows = try store.fetchUnsynced()
        XCTAssertEqual(dbRows.count, firstTotal,
                       "SQLite must not accumulate duplicate rows across refreshes")
    }

    // MARK: hermeticity — no writes outside the injected temp app-support dir

    func test_refreshAll_writesOnlyInsideInjectedAppSupportDir() async throws {
        let store = try makeInMemoryStore()
        let aggregator = makeAggregator(dataStore: store)

        await aggregator.refreshAll()

        // The real app-support dir must be recursively untouched. The manifest
        // includes nested paths, entry types, sizes, timestamps, and content
        // hashes so content-only writes cannot hide behind stable top-level
        // names or metadata.
        let realSupport = BurnBarAppPaths.live().supportDirectory
        XCTAssertEqual(RecursiveSupportManifest.make(for: realSupport), realSupportSnapshot,
                       "The real app-support dir must not be written by a hermetic refreshAll")

        // The injected temp app-support dir contains exactly the expected
        // parser/quota cache files — nothing else.
        let supportDir = appSupportRoot.appendingPathComponent("BurnBar", isDirectory: true)
        let expectedFiles: Set<String> = [
            "claude_code_parser_cache.json",
            "factory_droid_parser_cache.json",
            "model_filter_parser_zai.json",
            "model_filter_parser_minimax.json",
            "provider_quotas.json"
        ]
        let actualFiles = Set(try FileManager.default.contentsOfDirectory(atPath: supportDir.path))
        XCTAssertEqual(actualFiles, expectedFiles,
                       "Only the expected cache files may be written into the injected app-support dir")
    }

    // MARK: helpers

    private func makeInMemoryStore() throws -> DataStore {
        let queue = try DatabaseQueue(path: ":memory:")
        return try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
    }

    private func makeAggregator(dataStore: DataStore) -> UsageAggregator {
        let settings = SettingsManager.shared
        let appPaths = BurnBarAppPaths(applicationSupportRoot: appSupportRoot)
        let quotaService = ProviderQuotaService(
            keyStore: ProviderAPIKeyStore(
                keychain: KeychainStore(
                    service: "tests.\(UUID().uuidString)",
                    legacyServices: [],
                    backend: TestKeychainBackend()
                )
            ),
            appPaths: appPaths,
            fileManager: .default,
            session: failingSession(),
            environment: [:],
            homeDirectoryURL: homeDir,
            miniMaxModeProvider: { .payAsYouGo },
            factoryPlanProvider: { .unknown }
        )
        return UsageAggregator(
            dataStore: dataStore,
            settingsManager: settings,
            quotaService: quotaService,
            artifactDiscoveryService: ArtifactDiscoveryService(
                dataStore: dataStore,
                settingsProvider: settings
            ),
            projectionPipelineService: ProjectionPipelineService(
                dataStore: dataStore,
                leaseOwner: "usage-aggregator-refreshall-tests",
                chunker: ProjectionChunker(),
                chunkEmbedder: DeterministicFakeEmbeddingProvider()
            ),
            appPaths: appPaths,
            environment: ["BURNBAR_FLEET_ROOTS_DIR": rootsDir.path]
        )
    }

    private func failingSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FailingURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func perProviderCounts(_ usages: [TokenUsage]) -> [AgentProvider: Int] {
        Dictionary(grouping: usages, by: \.provider).mapValues(\.count)
    }

    // MARK: fixture tree (1 session per provider, synthetic content only)

    private func makeFixtureTree() throws {
        try writeClaudeFixture()
        try writeFactoryFixtures()
        try writeCopilotFixture()
        try writeAiderFixture()
        try makeCursorDatabase()
        try makeCodexDatabase()
        try writeKimiFixture()
        try writeClineFamilyFixtures()
        try writeForgeFixture()
        try writeAugmentFixture()
        try writeHermesFixture()
        try writeGrokFixture()
        try writePiFixture()
        try writeGeminiFixture()
        try writeGooseFixture()
    }

    private func writeClaudeFixture() throws {
        try writeJSONL([
            [
                "type": "assistant",
                "timestamp": "2026-08-13T00:00:00Z",
                "message": [
                    "role": "assistant",
                    "content": [["type": "text", "text": "hello"]],
                    "model": "claude-sonnet-4-5",
                    "usage": ["input_tokens": 100, "output_tokens": 50]
                ]
            ]
        ], to: "claude/projects/-Users-test/claude-sess-1.jsonl")
    }

    /// Factory Droid: settings.json carries model + token totals. The model
    /// must NOT contain minimax/glm/zai (FactoryDroidParser would reroute).
    private func writeFactoryFixtures() throws {
        let jsonl = [[
            "type": "assistant",
            "timestamp": "2026-08-13T00:00:00Z",
            "message": [
                "role": "assistant",
                "content": [["type": "text", "text": "hello"]]
            ]
        ]]
        try writeJSONL(jsonl, to: "factory/sessions/-Users-test/factory-sess-1.jsonl")
        try writeJSON(
            ["model": "claude-sonnet-4-5", "tokenUsage": ["input_tokens": 100, "output_tokens": 50]],
            to: "factory/sessions/-Users-test/factory-sess-1.settings.json"
        )

        // Zai (ModelFilterParser, model contains "zai").
        try writeJSONL(jsonl, to: "factory/sessions/-Users-test/zai-sess-1.jsonl")
        try writeJSON(
            ["model": "zai-1-flash", "tokenUsage": ["input_tokens": 100, "output_tokens": 50]],
            to: "factory/sessions/-Users-test/zai-sess-1.settings.json"
        )

        // MiniMax (ModelFilterParser, model contains "minimax").
        try writeJSONL(jsonl, to: "factory/sessions/-Users-test/minimax-sess-1.jsonl")
        try writeJSON(
            ["model": "minimax-01", "tokenUsage": ["input_tokens": 100, "output_tokens": 50]],
            to: "factory/sessions/-Users-test/minimax-sess-1.settings.json"
        )
    }

    private func writeCopilotFixture() throws {
        try writeJSONL([
            [
                "type": "assistant.usage",
                "timestamp": "2026-08-13T00:00:00Z",
                "usage": ["input_tokens": 100, "output_tokens": 50]
            ]
        ], to: "copilot/session-state/copilot-sess-1/events.jsonl")
    }

    private func writeAiderFixture() throws {
        try writeJSONL([
            ["event": "launched", "time": 1750000000, "properties": ["main_model": "aider-model"]],
            [
                "event": "message_send",
                "time": 1750000001,
                "properties": ["prompt_tokens": 100, "completion_tokens": 50, "cost": 0.01]
            ],
            ["event": "exit", "time": 1750000002]
        ], to: "aider/analytics.jsonl")
    }

    private func writeKimiFixture() throws {
        try writeJSONL([
            ["role": "user", "content": "hello world", "created_at": "2026-08-13T00:00:00Z"],
            ["role": "assistant", "content": "hi there", "created_at": "2026-08-13T00:00:01Z"]
        ], to: "kimi/sessions/ws1/kimi-sess-1/context.jsonl")
    }

    private func writeClineFamilyFixtures() throws {
        let history: [[String: Any]] = [
            ["role": "user", "ts": 1750000000000, "content": "hi"],
            [
                "role": "assistant",
                "ts": 1750000001000,
                "model": "claude-sonnet-4-5",
                "usage": ["input_tokens": 100, "output_tokens": 50]
            ]
        ]
        try writeJSONArray(history, to: "cline/tasks/cline-task-1/api_conversation_history.json")
        try writeJSONArray(history, to: "kilocode/tasks/kilocode-task-1/api_conversation_history.json")
        try writeJSONArray(
            history,
            to: "roocode/rooveterinaryinc.roo-cline/tasks/roocode-task-1/api_conversation_history.json"
        )
    }

    private func writeForgeFixture() throws {
        try writeJSONL([
            [
                "message": [
                    "role": "assistant",
                    "model": "forge-model",
                    "usage": ["input_tokens": 100, "output_tokens": 50]
                ],
                "timestamp": "2026-08-13T00:00:00Z"
            ]
        ], to: "forge/sessions/forge-sess-1.jsonl")
    }

    private func writeAugmentFixture() throws {
        try writeJSONL([
            [
                "message": [
                    "role": "assistant",
                    "model": "augment-model",
                    "usage": ["input_tokens": 100, "output_tokens": 50]
                ],
                "timestamp": "2026-08-13T00:00:00Z"
            ]
        ], to: "augment/augment-sess-1.jsonl")
    }

    private func writeHermesFixture() throws {
        try writeJSON([
            "session_id": "hermes-sess-1",
            "model": "hermes-model",
            "session_start": 1750000000,
            "last_updated": 1750000060,
            "messages": [
                ["role": "user", "content": "hi"],
                [
                    "role": "assistant",
                    "content": "hello",
                    "usage": ["input_tokens": 100, "output_tokens": 50]
                ]
            ]
        ], to: "hermes/sessions/session_hermes-sess-1.json")
    }

    private func writeGrokFixture() throws {
        try writeJSON([
            "info": ["id": "grok-sess-1", "cwd": "/Users/test/proj"],
            "current_model_id": "grok-3",
            "created_at": "2026-08-13T00:00:00Z",
            "updated_at": "2026-08-13T00:01:00Z"
        ], to: "grok/sessions/proj/grok-sess-1/summary.json")
        try writeJSONL([
            [
                "params": [
                    "update": [
                        "sessionUpdate": "turn_completed",
                        "prompt_id": "p1",
                        "stop_reason": "completed",
                        "usage": ["inputTokens": 100, "outputTokens": 50, "cachedReadTokens": 10]
                    ]
                ]
            ]
        ], to: "grok/sessions/proj/grok-sess-1/updates.jsonl")
        try write("{\"type\":\"bogus\"}", to: "grok/sessions/proj/grok-sess-1/events.jsonl")
    }

    private func writePiFixture() throws {
        try writeJSONLWithMalformedLine([
            [
                "type": "session",
                "version": 3,
                "id": "pi-sess-1",
                "timestamp": "2026-08-13T00:00:00Z",
                "cwd": "/Users/test/proj"
            ],
            [
                "type": "message",
                "id": "m1",
                "timestamp": "2026-08-13T00:00:01Z",
                "message": [
                    "role": "assistant",
                    "content": [["type": "text", "text": "hi"]],
                    "usage": ["input": 100, "output": 50, "cacheRead": 0, "cacheWrite": 0]
                ]
            ]
        ], to: "pi/agent/sessions/proj/20260813T000000Z_pi-sess-1.jsonl")
    }

    private func writeGeminiFixture() throws {
        try writeJSONL([
            [
                "type": "message_update",
                "timestamp": "2026-08-13T00:00:00Z",
                "usage": ["input_tokens": 100, "output_tokens": 50]
            ]
        ], to: "gemini/tmp/proj/chats/session-gemini-sess-1.jsonl")
    }

    private func writeGooseFixture() throws {
        try writeJSONL([
            ["timestamp": "2026-08-13T00:00:00Z", "role": "user", "content": "hello"],
            [
                "timestamp": "2026-08-13T00:00:01Z",
                "role": "assistant",
                "content": "hi",
                "usage": ["input_tokens": 100, "output_tokens": 50]
            ]
        ], to: "goose/sessions/goose-sess-1.jsonl")
    }

    private func writeJSONL(_ lines: [[String: Any]], to relativePath: String) throws {
        let strings = try lines.map { line -> String in
            let data = try JSONSerialization.data(withJSONObject: line)
            return String(data: data, encoding: .utf8) ?? ""
        }
        try write(strings.joined(separator: "\n"), to: relativePath)
    }

    private func writeJSONLWithMalformedLine(_ lines: [[String: Any]], to relativePath: String) throws {
        let strings = try lines.map { line -> String in
            let data = try JSONSerialization.data(withJSONObject: line)
            return String(data: data, encoding: .utf8) ?? ""
        }
        try write(strings.joined(separator: "\n") + "\n{\"type\":\"malformed\"", to: relativePath)
    }

    private func writeJSON(_ object: [String: Any], to relativePath: String) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try write(String(data: data, encoding: .utf8) ?? "", to: relativePath)
    }

    private func writeJSONArray(_ array: [[String: Any]], to relativePath: String) throws {
        let data = try JSONSerialization.data(withJSONObject: array)
        try write(String(data: data, encoding: .utf8) ?? "", to: relativePath)
    }

    private func write(_ string: String, to relativePath: String) throws {
        let url = rootsDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(string.utf8).write(to: url)
    }

    private func makeCursorDatabase() throws {
        let url = rootsDir.appendingPathComponent("cursor/ai-tracking/ai-code-tracking.db")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let db = try DatabaseQueue(path: url.path)
        try db.write { db in
            try db.execute(sql: """
                CREATE TABLE ai_code_hashes (conversationId TEXT, model TEXT, createdAt REAL)
                """)
            try db.execute(
                sql: "INSERT INTO ai_code_hashes (conversationId, model, createdAt) VALUES (?, ?, ?)",
                arguments: ["cursor-sess-1", "cursor-model", Date().timeIntervalSince1970]
            )
        }
    }

    private func makeCodexDatabase() throws {
        let url = rootsDir.appendingPathComponent("codex/state_5.sqlite")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let db = try DatabaseQueue(path: url.path)
        try db.write { db in
            try db.execute(sql: """
                CREATE TABLE threads (
                    id TEXT, title TEXT, model TEXT, model_provider TEXT, tokens_used INTEGER,
                    created_at INTEGER, updated_at INTEGER, cwd TEXT, archived INTEGER
                )
                """)
            try db.execute(
                sql: """
                    INSERT INTO threads (id, title, model, model_provider, tokens_used, created_at, updated_at, cwd, archived)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    "codex-sess-1", "Codex session", "codex-model", "openai",
                    1000, 1750000000, 1750000060, "/Users/test/proj", 0
                ]
            )
        }
    }
}

// MARK: - Test doubles

private final class TestKeychainBackend: KeychainStoreBackend {
    private var storage: [String: [String: Data]] = [:]
    func set(_ value: Data, service: String, account: String) throws {
        storage[service, default: [:]][account] = value
    }
    func data(for service: String, account: String, allowUserInteraction _: Bool) throws -> Data? {
        storage[service]?[account]
    }
    func delete(service: String, account: String) throws {
        storage[service]?[account] = nil
    }
}

/// Fails every request immediately: any accidental network call in the
/// refresh path surfaces as a fast typed failure instead of hitting the
/// real network (hermetic-first rule).
private final class FailingURLProtocol: URLProtocol {
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}
