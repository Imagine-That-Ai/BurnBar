import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

/// Behavioral coverage for the formerly-silent `try?` error-swallows in
/// `UsageAggregatorParsers.swift`.
///
/// The disk-cache-backed parsers (`CodexParser`, `ModelFilterParser`) warm up the
/// OpenBurnBar support directory in their initializers. That call used to be
/// `_ = try? OpenBurnBarMigration.prepareSupportDirectory(...)`, which discarded
/// every failure totally silently. It is now routed through
/// `ParserSupportDirectoryWarmUp.prepare(...)`, which:
///   * succeeds and returns `true` when the directory can be created,
///   * logs (`AppLogger.parser.error`) and returns `false` when preparation fails,
///   * never throws / crashes — a parser stays constructible even when its scratch
///     directory is unavailable, degrading gracefully by re-parsing.
///
/// These tests assert the observable success/failure outcome (so the catch path is
/// proven to run, not skipped) and that both parsers remain constructible and
/// runnable when the support directory cannot be prepared.
final class UsageAggregatorParsersMattersTests: XCTestCase {

    private var scratchRoots: [URL] = []

    override func tearDownWithError() throws {
        let fm = FileManager.default
        for root in scratchRoots where fm.fileExists(atPath: root.path) {
            try? fm.removeItem(at: root)
        }
        scratchRoots.removeAll()
        try super.tearDownWithError()
    }

    /// A unique temp URL registered for cleanup. Not created on disk.
    private func uniqueTempURL(suffix: String = "") -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-parsers-matters-\(UUID().uuidString)\(suffix)", isDirectory: true)
        scratchRoots.append(url)
        return url
    }

    // MARK: - ParserSupportDirectoryWarmUp.prepare

    func testWarmUpSucceedsForWritableSupportRoot() throws {
        let root = uniqueTempURL()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = OpenBurnBarAppPaths(applicationSupportRoot: root)

        let prepared = ParserSupportDirectoryWarmUp.prepare(
            fileManager: .default,
            appPaths: paths
        )

        XCTAssertTrue(prepared, "Warm-up must report success for a writable support root.")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: paths.supportDirectory.path),
            "Warm-up must actually create the support directory on success."
        )
    }

    /// Drives the catch path: when the support root is occupied by a *regular file*,
    /// creating the `OpenBurnBar` subdirectory under it throws. The previous `try?`
    /// form swallowed this silently; the fix surfaces it as `false` (and logs).
    func testWarmUpFailsClosedToFalseAndDoesNotThrowWhenRootIsAFile() throws {
        // Place a regular file exactly where the support *root* directory is expected.
        let fileRoot = uniqueTempURL()
        try Data("not a directory".utf8).write(to: fileRoot, options: .atomic)
        let paths = OpenBurnBarAppPaths(applicationSupportRoot: fileRoot)

        // Must not throw / crash even though preparation fails.
        let prepared = ParserSupportDirectoryWarmUp.prepare(
            fileManager: .default,
            appPaths: paths
        )

        XCTAssertFalse(
            prepared,
            "Warm-up must observably report failure (formerly swallowed by try?) when the support directory cannot be created."
        )
        // The root stays a file — we never silently converted it into a directory.
        var isDirectory = ObjCBool(false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileRoot.path, isDirectory: &isDirectory))
        XCTAssertFalse(isDirectory.boolValue, "Warm-up must not clobber a pre-existing regular file at the root path.")
    }

    // MARK: - Graceful degradation of the parsers themselves

    /// `CodexParser` must remain constructible and runnable even when its support
    /// directory cannot be prepared. Pointing at a missing Codex DB keeps the run
    /// hermetic; the assertion is that construction + `parse()` do not crash and
    /// return an empty (degraded) result rather than failing closed.
    func testCodexParserConstructsAndDegradesWhenSupportDirUnavailable() async throws {
        let fileRoot = uniqueTempURL()
        try Data("not a directory".utf8).write(to: fileRoot, options: .atomic)
        let paths = OpenBurnBarAppPaths(applicationSupportRoot: fileRoot)

        // Home directory with no `.codex/state_5.sqlite` -> parse returns empty.
        let home = uniqueTempURL(suffix: "-home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        let parser = CodexParser(
            fileManager: .default,
            appPaths: paths,
            homeDirectoryURL: home
        )

        let result = try await parser.parse()
        XCTAssertTrue(result.usages.isEmpty)
        XCTAssertTrue(result.conversations.isEmpty)
    }

    @MainActor
    func testCodexParserDoesNotCacheConversationBodiesWhenIndexingDisabled() async throws {
        let harness = try ParserIntegrationTestHarness(name: "codex-cache-privacy-\(UUID().uuidString.prefix(8))")
        defer { harness.cleanup() }

        let rolloutDirectory = harness.rootURL.appendingPathComponent(".codex/sessions/2026/06/22", isDirectory: true)
        try harness.fileManager.createDirectory(at: rolloutDirectory, withIntermediateDirectories: true)
        let rolloutURL = rolloutDirectory.appendingPathComponent("rollout-2026-06-22T19-45-00.jsonl")
        let privatePrompt = "private codex prompt \(UUID().uuidString)"
        let privateAnswer = "private codex answer \(UUID().uuidString)"
        let session = """
        {"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":140,"cached_input_tokens":20,"output_tokens":12},"model":"openai/gpt-5.2-codex"}}}
        {"item":{"role":"user","content":[{"text":"\(privatePrompt)"}]}}
        {"item":{"role":"assistant","content":[{"text":"\(privateAnswer)"}]}}
        """
        try session.write(to: rolloutURL, atomically: true, encoding: .utf8)

        _ = try harness.createCodexThreadDatabase(threads: [(
            id: "codex-cache-privacy-thread",
            model: "openai/gpt-5.2-codex",
            tokensUsed: 152,
            rolloutPath: rolloutURL.path,
            createdAt: 1_782_156_300,
            updatedAt: 1_782_156_360,
            cwd: "/tmp/OpenBurnBar"
        )])

        let supportRoot = harness.rootURL.appendingPathComponent("support", isDirectory: true)
        let appPaths = OpenBurnBarAppPaths(applicationSupportRoot: supportRoot)
        let parser = TestableCodexParser(
            fileManager: harness.fileManager,
            codexRoot: harness.rootURL.appendingPathComponent(".codex", isDirectory: true),
            appPaths: appPaths
        )
        let cacheURL = appPaths.supportDirectory.appendingPathComponent("codex_parser_cache.json")

        let redacted = try await parser.parse(options: LogParseOptions(includeConversationBodies: false))
        XCTAssertEqual(redacted.usages.count, 1)
        XCTAssertTrue(redacted.conversations.isEmpty)
        let redactedCache = try String(contentsOf: cacheURL, encoding: .utf8)
        XCTAssertFalse(redactedCache.contains(privatePrompt))
        XCTAssertFalse(redactedCache.contains(privateAnswer))

        let indexed = try await parser.parse(options: LogParseOptions(includeConversationBodies: true))
        XCTAssertEqual(indexed.conversations.count, 1)
        XCTAssertEqual(indexed.conversations.first?.fullText.contains(privatePrompt), true)
        let warmedCache = try String(contentsOf: cacheURL, encoding: .utf8)
        XCTAssertTrue(warmedCache.contains(privatePrompt))
        XCTAssertTrue(warmedCache.contains(privateAnswer))

        try harness.fileManager.removeItem(at: rolloutURL)
        let missingFileScrubbed = try await parser.parse(options: LogParseOptions(includeConversationBodies: false))
        XCTAssertEqual(missingFileScrubbed.usages.count, 1)
        XCTAssertTrue(missingFileScrubbed.conversations.isEmpty)
        let missingFileScrubbedCache = try String(contentsOf: cacheURL, encoding: .utf8)
        XCTAssertFalse(missingFileScrubbedCache.contains(privatePrompt))
        XCTAssertFalse(missingFileScrubbedCache.contains(privateAnswer))

        try session.write(to: rolloutURL, atomically: true, encoding: .utf8)
        _ = try await parser.parse(options: LogParseOptions(includeConversationBodies: true))
        let scrubbed = try await parser.parse(options: LogParseOptions(includeConversationBodies: false))
        XCTAssertTrue(scrubbed.conversations.isEmpty)
        let scrubbedCache = try String(contentsOf: cacheURL, encoding: .utf8)
        XCTAssertFalse(scrubbedCache.contains(privatePrompt))
        XCTAssertFalse(scrubbedCache.contains(privateAnswer))
    }

    func testParserConversationCacheScrubberRedactsKnownParserCaches() throws {
        let supportRoot = uniqueTempURL()
        let appPaths = OpenBurnBarAppPaths(applicationSupportRoot: supportRoot)
        try FileManager.default.createDirectory(at: appPaths.supportDirectory, withIntermediateDirectories: true)

        let privateMarker = "private parser cache body \(UUID().uuidString)"
        let cacheURLs = [
            appPaths.supportDirectory.appendingPathComponent("codex_parser_cache.json"),
            appPaths.claudeCodeParserCacheURL,
            appPaths.factoryDroidParserCacheURL,
            appPaths.supportDirectory.appendingPathComponent("model_filter_parser_zai.json")
        ]

        for cacheURL in cacheURLs {
            try seedParserCache(at: cacheURL, marker: privateMarker)
        }

        ParserConversationCacheScrubber(
            fileManager: .default,
            appPaths: appPaths
        ).scrubKnownParserCaches()

        for cacheURL in cacheURLs {
            let raw = try String(contentsOf: cacheURL, encoding: .utf8)
            XCTAssertFalse(raw.contains(privateMarker), "\(cacheURL.lastPathComponent) still contains private text")

            let root = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
            )
            let entries = try XCTUnwrap(root["fileEntries"] as? [String: Any])
            let entry = try XCTUnwrap(entries["session"] as? [String: Any])
            XCTAssertTrue(entry["conversation"] is NSNull)
        }
    }

    /// `ModelFilterParser` (used for Zai / MiniMax) must likewise stay constructible
    /// and degrade gracefully when the support directory cannot be prepared.
    func testModelFilterParserConstructsWhenSupportDirUnavailable() throws {
        let fileRoot = uniqueTempURL()
        try Data("not a directory".utf8).write(to: fileRoot, options: .atomic)
        let paths = OpenBurnBarAppPaths(applicationSupportRoot: fileRoot)

        // Construction triggers the warm-up; it must not throw / crash.
        let parser = ModelFilterParser(
            modelPattern: "zai",
            provider: .zai,
            fileManager: .default,
            appPaths: paths
        )
        XCTAssertEqual(parser.provider, .zai)
    }

    func testParserRegistryKeepsMimoQuotaApiOnly() {
        let parsers = ParserRegistry.defaultParsers()

        XCTAssertNotNil(parsers[.factory], "Factory sessions must remain parsed by the Factory parser.")
        XCTAssertNotNil(parsers[.zai], "Z.ai model-filter sessions must remain locally parsed.")
        XCTAssertNotNil(parsers[.minimax], "MiniMax model-filter sessions must remain locally parsed.")
        XCTAssertNil(
            parsers[.mimo],
            "MiMo quota is refreshed via Token Plan API, not the shared Factory sessions tree."
        )
    }

    private func seedParserCache(at cacheURL: URL, marker: String) throws {
        let json: [String: Any] = [
            "schemaVersion": 2,
            "fileEntries": [
                "session": [
                    "signature": ["size": 1, "modifiedAt": 1],
                    "usage": NSNull(),
                    "conversation": [
                        "id": "session",
                        "fullText": marker
                    ]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: cacheURL, options: .atomic)
    }
}
