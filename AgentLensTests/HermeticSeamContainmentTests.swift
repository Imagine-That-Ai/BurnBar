@testable import BurnBar
import Darwin
import Foundation
import GRDB
import XCTest

// MARK: - Hermetic Seam Containment Tests

/// Round-2 scrutiny (aggregator-refreshall-proof.json) hermetic-boundary
/// escapes, fixed and proven:
///
/// 1. `GooseParser.resolvedSessionDirectories` must read `GOOSE_PATH_ROOT`
///    from the INJECTED environment dict when one is provided — the live
///    process environment is never consulted in that case. An explicit empty
///    value in the injected dict disables the variable. With no injected
///    environment the live variable is honored (real-root behavior preserved).
///
/// 2. `CodexParser` must only follow `rollout_path` values that resolve
///    INSIDE the (possibly overridden) Codex root. Out-of-root paths are
///    skipped typed (`lastSkippedOutOfRootRolloutPaths`) and NEVER opened —
///    proven with a canary file whose access time must stay backdated and
///    whose distinctive token content must never appear in the parsed row.
@MainActor
final class HermeticSeamContainmentTests: XCTestCase {

    private var tempRoot: URL!
    private var rootsDir: URL!

    private var originalConversationIndexingEnabled: Bool?
    private var originalAutoSessionSummariesEnabled: Bool?
    private var originalArtifactDiscoveryEnabled: Bool?

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermetic-seam-containment-\(UUID().uuidString)", isDirectory: true)
        rootsDir = tempRoot.appendingPathComponent("roots", isDirectory: true)
        try FileManager.default.createDirectory(at: rootsDir, withIntermediateDirectories: true)

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
        rootsDir = nil
    }

    // MARK: Goose — injected GOOSE_PATH_ROOT wins over the live environment

    func test_gooseParser_honorsInjectedGOOSEPathRoot_ignoresLiveEnv() async throws {
        // Live-env decoy: a GOOSE_PATH_ROOT pointing at a database with a
        // session that must NEVER be seen when an environment is injected.
        let decoyRoot = tempRoot.appendingPathComponent("decoy", isDirectory: true)
        try makeGooseDatabase(
            at: decoyRoot.appendingPathComponent("data/sessions/sessions.db"),
            sessionId: "decoy-session",
            inputTokens: 200,
            outputTokens: 100
        )
        setenv("GOOSE_PATH_ROOT", decoyRoot.path, 1)
        defer { unsetenv("GOOSE_PATH_ROOT") }

        // Injected root: a different database under the injected GOOSE_PATH_ROOT.
        let injectedRoot = tempRoot.appendingPathComponent("injected", isDirectory: true)
        try makeGooseDatabase(
            at: injectedRoot.appendingPathComponent("data/sessions/sessions.db"),
            sessionId: "injected-session",
            inputTokens: 100,
            outputTokens: 50
        )

        let parser = GooseParser(environment: [
            "GOOSE_PATH_ROOT": injectedRoot.path,
            "BURNBAR_FLEET_ROOTS_DIR": rootsDir.path
        ])
        let result = try await parser.parse()

        let sessionIds = result.usages.map(\.sessionId)
        XCTAssertTrue(
            sessionIds.contains("injected-session"),
            "The injected GOOSE_PATH_ROOT must be honored"
        )
        XCTAssertFalse(
            sessionIds.contains("decoy-session"),
            "The live GOOSE_PATH_ROOT must be ignored when an injected environment is provided"
        )
    }

    func test_gooseParser_injectedEmptyValueDisablesLiveVariable() async throws {
        let decoyRoot = tempRoot.appendingPathComponent("decoy", isDirectory: true)
        try makeGooseDatabase(
            at: decoyRoot.appendingPathComponent("data/sessions/sessions.db"),
            sessionId: "decoy-session",
            inputTokens: 200,
            outputTokens: 100
        )
        setenv("GOOSE_PATH_ROOT", decoyRoot.path, 1)
        defer { unsetenv("GOOSE_PATH_ROOT") }

        // An explicit empty value in the injected dict disables the variable.
        let parser = GooseParser(environment: [
            "GOOSE_PATH_ROOT": "",
            "BURNBAR_FLEET_ROOTS_DIR": rootsDir.path
        ])
        let result = try await parser.parse()

        XCTAssertTrue(
            result.usages.allSatisfy { $0.sessionId != "decoy-session" },
            "An explicit empty GOOSE_PATH_ROOT must disable the live variable"
        )
        XCTAssertTrue(result.usages.isEmpty, "No fixture content exists under the injected roots")
    }

    func test_gooseParser_withoutInjectedEnvironment_honorsLiveVariable() async throws {
        // Real-root behavior must be preserved: with no injected environment
        // the live GOOSE_PATH_ROOT is still honored.
        let decoyRoot = tempRoot.appendingPathComponent("decoy", isDirectory: true)
        try makeGooseDatabase(
            at: decoyRoot.appendingPathComponent("data/sessions/sessions.db"),
            sessionId: "decoy-session",
            inputTokens: 200,
            outputTokens: 100
        )
        setenv("GOOSE_PATH_ROOT", decoyRoot.path, 1)
        defer { unsetenv("GOOSE_PATH_ROOT") }

        let parser = GooseParser(environment: nil)
        let result = try await parser.parse()

        XCTAssertTrue(
            result.usages.contains { $0.sessionId == "decoy-session" },
            "Without an injected environment the live GOOSE_PATH_ROOT must be honored"
        )
    }

    // MARK: Codex — rollout_path containment

    func test_codexParser_skipsRolloutPathOutsideInjectedRoot_neverOpensCanary() async throws {
        // Canary OUTSIDE the injected codex root: distinctive token content
        // and a backdated access time. If the parser ever opened it, the
        // access time would advance and the exact tokens would leak into the row.
        let canary = tempRoot.appendingPathComponent("canary-rollout.jsonl")
        try writeTokenCountEvent(to: canary, input: 99_999, output: 1)
        let backdated = Date(timeIntervalSince1970: 1_600_000_000)
        backdateAccessTime(canary, to: backdated)
        XCTAssertEqual(accessTime(canary), backdated, "canary atime must be backdated before parsing")

        let codexRoot = rootsDir.appendingPathComponent("codex", isDirectory: true)
        try makeCodexDatabase(
            at: codexRoot.appendingPathComponent("state_5.sqlite"),
            rolloutPath: canary.path,
            tokensUsed: 1_000
        )

        let parser = CodexParser(
            appPaths: BurnBarAppPaths(
                applicationSupportRoot: tempRoot.appendingPathComponent("app-support", isDirectory: true)
            ),
            environment: ["BURNBAR_FLEET_ROOTS_DIR": rootsDir.path]
        )
        let result = try await parser.parse()

        XCTAssertEqual(
            parser.lastSkippedOutOfRootRolloutPaths, 1,
            "The escaping rollout_path must be skipped typed"
        )
        XCTAssertEqual(
            accessTime(canary), backdated,
            "The canary file must never be opened by the parser"
        )
        let usage = try XCTUnwrap(result.usages.first, "The thread row must still parse via tokens_used")
        XCTAssertEqual(usage.inputTokens, 950, "Fallback tokens_used split must apply (1000 × 0.95)")
        XCTAssertEqual(usage.outputTokens, 50, "Fallback tokens_used split must apply (1000 − 950)")
        XCTAssertFalse(
            usage.inputTokens == 99_999,
            "The canary's exact token content must never be ingested"
        )
    }

    func test_codexParser_followsRolloutPathInsideInjectedRoot() async throws {
        // In-root rollout paths keep working: exact token breakdown wins.
        let codexRoot = rootsDir.appendingPathComponent("codex", isDirectory: true)
        let rollout = codexRoot.appendingPathComponent("archived_sessions/rollout-1.jsonl")
        try writeTokenCountEvent(to: rollout, input: 1_234, output: 56)
        try makeCodexDatabase(
            at: codexRoot.appendingPathComponent("state_5.sqlite"),
            rolloutPath: rollout.path,
            tokensUsed: 1_000
        )

        let parser = CodexParser(
            appPaths: BurnBarAppPaths(
                applicationSupportRoot: tempRoot.appendingPathComponent("app-support", isDirectory: true)
            ),
            environment: ["BURNBAR_FLEET_ROOTS_DIR": rootsDir.path]
        )
        let result = try await parser.parse()

        XCTAssertEqual(parser.lastSkippedOutOfRootRolloutPaths, 0, "In-root rollout paths are not skipped")
        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertEqual(usage.inputTokens, 1_234, "Exact tokens from the in-root rollout must win")
        XCTAssertEqual(usage.outputTokens, 56, "Exact tokens from the in-root rollout must win")
    }

    // MARK: refreshAll — hermetic boundary proof end to end

    /// A FULL `refreshAll()` over a minimal fixture tree with both traps
    /// armed: a live-env `GOOSE_PATH_ROOT` decoy and a Codex `rollout_path`
    /// escaping the injected root. The canary file outside the fixture root
    /// must stay unread (backdated atime unchanged) and the decoy goose
    /// database must never be scanned.
    func test_refreshAll_neverReadsOutsideInjectedRoots() async throws {
        // Canary OUTSIDE the injected roots, referenced by the codex fixture.
        let canary = tempRoot.appendingPathComponent("canary-rollout.jsonl")
        try writeTokenCountEvent(to: canary, input: 99_999, output: 1)
        let backdated = Date(timeIntervalSince1970: 1_600_000_000)
        backdateAccessTime(canary, to: backdated)
        XCTAssertEqual(accessTime(canary), backdated, "canary atime must be backdated before refreshAll")

        // Codex fixture: state_5.sqlite whose thread row points at the canary.
        let codexRoot = rootsDir.appendingPathComponent("codex", isDirectory: true)
        try makeCodexDatabase(
            at: codexRoot.appendingPathComponent("state_5.sqlite"),
            rolloutPath: canary.path,
            tokensUsed: 1_000
        )

        // Goose: live-env decoy root vs injected root.
        let decoyRoot = tempRoot.appendingPathComponent("decoy", isDirectory: true)
        try makeGooseDatabase(
            at: decoyRoot.appendingPathComponent("data/sessions/sessions.db"),
            sessionId: "decoy-session",
            inputTokens: 200,
            outputTokens: 100
        )
        let injectedGooseRoot = tempRoot.appendingPathComponent("injected-goose", isDirectory: true)
        try makeGooseDatabase(
            at: injectedGooseRoot.appendingPathComponent("data/sessions/sessions.db"),
            sessionId: "injected-session",
            inputTokens: 100,
            outputTokens: 50
        )
        setenv("GOOSE_PATH_ROOT", decoyRoot.path, 1)
        defer { unsetenv("GOOSE_PATH_ROOT") }

        let store = try makeInMemoryStore()
        let aggregator = makeAggregator(
            dataStore: store,
            environment: [
                "BURNBAR_FLEET_ROOTS_DIR": rootsDir.path,
                "GOOSE_PATH_ROOT": injectedGooseRoot.path
            ]
        )

        await aggregator.refreshAll()

        assertCanaryUnread(canary, backdated: backdated)
        assertCodexFallbackRow(in: store)
        assertGooseInjectedRow(in: store)
    }

    private func assertCanaryUnread(_ canary: URL, backdated: Date) {
        XCTAssertEqual(
            accessTime(canary), backdated,
            "refreshAll must never open a rollout_path escaping the injected root"
        )
    }

    private func assertCodexFallbackRow(in store: DataStore) {
        // The codex row still parses via the tokens_used fallback — never the
        // canary's exact token content.
        let codexUsage = store.usages.first { $0.provider == .codex }
        XCTAssertEqual(codexUsage?.inputTokens, 950, "Codex fallback split must apply (1000 × 0.95)")
        XCTAssertEqual(codexUsage?.outputTokens, 50, "Codex fallback split must apply (1000 − 950)")
    }

    private func assertGooseInjectedRow(in store: DataStore) {
        // The injected GOOSE_PATH_ROOT is honored; the live-env decoy is not.
        XCTAssertTrue(
            store.usages.contains { $0.provider == .goose && $0.sessionId == "injected-session" },
            "refreshAll must honor the injected GOOSE_PATH_ROOT"
        )
        XCTAssertFalse(
            store.usages.contains { $0.provider == .goose && $0.sessionId == "decoy-session" },
            "refreshAll must ignore the live GOOSE_PATH_ROOT when an environment is injected"
        )
    }

    // MARK: helpers

    private func makeInMemoryStore() throws -> DataStore {
        let queue = try DatabaseQueue(path: ":memory:")
        return try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
    }

    private func makeAggregator(dataStore: DataStore, environment: [String: String]) -> UsageAggregator {
        let settings = SettingsManager.shared
        let appPaths = BurnBarAppPaths(
            applicationSupportRoot: tempRoot.appendingPathComponent("app-support", isDirectory: true)
        )
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
            homeDirectoryURL: tempRoot.appendingPathComponent("home", isDirectory: true),
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
                leaseOwner: "hermetic-seam-containment-tests",
                chunker: ProjectionChunker(),
                chunkEmbedder: DeterministicFakeEmbeddingProvider()
            ),
            appPaths: appPaths,
            environment: environment
        )
    }

    private func failingSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FailingURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeGooseDatabase(at url: URL, sessionId: String, inputTokens: Int, outputTokens: Int) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let db = try DatabaseQueue(path: url.path)
        try db.write { db in
            try db.execute(sql: """
                CREATE TABLE sessions (
                    id TEXT, model TEXT, input_tokens INTEGER, output_tokens INTEGER,
                    created_at INTEGER, updated_at INTEGER
                )
                """)
            try db.execute(
                sql: """
                    INSERT INTO sessions (id, model, input_tokens, output_tokens, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [sessionId, "goose-model", inputTokens, outputTokens, 1_750_000_000, 1_750_000_060]
            )
        }
    }

    private func makeCodexDatabase(at url: URL, rolloutPath: String, tokensUsed: Int) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let db = try DatabaseQueue(path: url.path)
        try db.write { db in
            try db.execute(sql: """
                CREATE TABLE threads (
                    id TEXT, title TEXT, model TEXT, model_provider TEXT, tokens_used INTEGER,
                    created_at INTEGER, updated_at INTEGER, cwd TEXT, archived INTEGER, rollout_path TEXT
                )
                """)
            try db.execute(
                sql: """
                    INSERT INTO threads
                        (id, title, model, model_provider, tokens_used, created_at,
                         updated_at, cwd, archived, rollout_path)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    "codex-sess-1", "Codex session", "codex-model", "openai",
                    tokensUsed, 1_750_000_000, 1_750_000_060, "/Users/test/proj", 0, rolloutPath
                ]
            )
        }
    }

    private func writeTokenCountEvent(to url: URL, input: Int, output: Int) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let event: [String: Any] = [
            "type": "token_count",
            "info": [
                "total_token_usage": [
                    "input_tokens": input,
                    "output_tokens": output,
                    "cached_input_tokens": 0
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: event)
        try data.write(to: url)
    }

    /// Backdates a file's access time (and modification time) so a later
    /// open-and-read is detectable: macOS updates atime on read.
    private func backdateAccessTime(_ url: URL, to date: Date) {
        var times = [timeval(), timeval()]
        let seconds = time_t(date.timeIntervalSince1970)
        times[0].tv_sec = seconds
        times[1].tv_sec = seconds
        _ = url.path.withCString { utimes($0, &times) }
    }

    private func accessTime(_ url: URL) -> Date? {
        var st = stat()
        guard url.path.withCString({ stat($0, &st) }) == 0 else { return nil }
        return Date(timeIntervalSince1970: Double(st.st_atimespec.tv_sec))
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
