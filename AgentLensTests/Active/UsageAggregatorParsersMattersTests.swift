import OpenBurnBarCore
import XCTest
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
        let paths = OpenBurnBar.OpenBurnBarAppPaths(applicationSupportRoot: root)

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
        let paths = OpenBurnBar.OpenBurnBarAppPaths(applicationSupportRoot: fileRoot)

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
        let paths = OpenBurnBar.OpenBurnBarAppPaths(applicationSupportRoot: fileRoot)

        // Home directory with no `.codex/state_5.sqlite` -> parse returns empty.
        let home = uniqueTempURL(suffix: "-home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        let parser = OpenBurnBar.CodexParser(
            fileManager: .default,
            appPaths: paths,
            homeDirectoryURL: home
        )

        let result = try await parser.parse()
        XCTAssertTrue(result.usages.isEmpty)
        XCTAssertTrue(result.conversations.isEmpty)
    }

    /// 2026-07-16 resource/privacy fix: Codex conversation bodies are now
    /// privacy-transient — a body-enabled parse returns them in memory but
    /// they are NEVER written to the on-disk parser cache (previously they
    /// were persisted and scrubbed by the next usage-only pass).
    @MainActor
    func testCodexParserNeverCachesConversationBodies() async throws {
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
        let appPaths = OpenBurnBar.OpenBurnBarAppPaths(applicationSupportRoot: supportRoot)
        let parser = TestableCodexParser(
            fileManager: harness.fileManager,
            codexRoot: harness.rootURL.appendingPathComponent(".codex", isDirectory: true),
            appPaths: appPaths
        )
        let cacheURL = appPaths.supportDirectory.appendingPathComponent("codex_parser_cache.json")

        let redacted = try await parser.parse(options: LogParseOptions(includeConversationBodies: false))
        XCTAssertEqual(redacted.usages.count, 1)
        XCTAssertTrue(redacted.conversations.isEmpty)
        let redactedCache = try Data(contentsOf: cacheURL)
        XCTAssertFalse(redactedCache.containsRawString(privatePrompt))
        XCTAssertFalse(redactedCache.containsRawString(privateAnswer))

        // Body-enabled parsing is transient: the conversation is returned in
        // memory, but the cache written by the same pass must not carry it.
        let indexed = try await parser.parse(options: LogParseOptions(includeConversationBodies: true))
        XCTAssertEqual(indexed.conversations.count, 1)
        XCTAssertEqual(indexed.conversations.first?.fullText.contains(privatePrompt), true)
        let warmedCache = try Data(contentsOf: cacheURL)
        XCTAssertFalse(warmedCache.containsRawString(privatePrompt),
                       "body-enabled parse must never persist prompt text to the parser cache")
        XCTAssertFalse(warmedCache.containsRawString(privateAnswer),
                       "body-enabled parse must never persist assistant text to the parser cache")

        // A vanished rollout file drops its cache entry but keeps the
        // heuristic usage row; the cache still carries no private text.
        try harness.fileManager.removeItem(at: rolloutURL)
        let missingFile = try await parser.parse(options: LogParseOptions(includeConversationBodies: false))
        XCTAssertEqual(missingFile.usages.count, 1)
        XCTAssertTrue(missingFile.conversations.isEmpty)
        let missingFileCache = try Data(contentsOf: cacheURL)
        XCTAssertFalse(missingFileCache.containsRawString(privatePrompt))
        XCTAssertFalse(missingFileCache.containsRawString(privateAnswer))

        // Re-created file + another body-enabled pass followed by a
        // usage-only pass: no phase of the cycle ever puts bodies on disk.
        try session.write(to: rolloutURL, atomically: true, encoding: .utf8)
        _ = try await parser.parse(options: LogParseOptions(includeConversationBodies: true))
        let usageOnly = try await parser.parse(options: LogParseOptions(includeConversationBodies: false))
        XCTAssertTrue(usageOnly.conversations.isEmpty)
        let finalCache = try Data(contentsOf: cacheURL)
        XCTAssertFalse(finalCache.containsRawString(privatePrompt))
        XCTAssertFalse(finalCache.containsRawString(privateAnswer))
    }

    @MainActor
    func testCodexParserMinimumDateLimitsHistoricalThreadScan() async throws {
        let harness = try ParserIntegrationTestHarness(name: "codex-minimum-date-\(UUID().uuidString.prefix(8))")
        defer { harness.cleanup() }

        let oldRollout = harness.rootURL.appendingPathComponent(".codex/sessions/2026/06/22/old.jsonl")
        let recentRollout = harness.rootURL.appendingPathComponent(".codex/sessions/2026/07/12/recent.jsonl")
        try harness.fileManager.createDirectory(
            at: oldRollout.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try harness.fileManager.createDirectory(
            at: recentRollout.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let session = """
        {"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":10}}}}
        """
        try session.write(to: oldRollout, atomically: true, encoding: .utf8)
        try session.write(to: recentRollout, atomically: true, encoding: .utf8)

        // 2026-07-16 fix: `minimumFileModificationDate` now defers by file
        // modification date (the LogParseOptions contract) instead of by the
        // thread's SQL created_at, so the fixture must stamp real mtimes on
        // either side of the boundary.
        try harness.fileManager.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_782_156_360)],
            ofItemAtPath: oldRollout.path
        )
        try harness.fileManager.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_783_915_260)],
            ofItemAtPath: recentRollout.path
        )

        _ = try harness.createCodexThreadDatabase(threads: [
            (
                id: "codex-old-thread",
                model: "openai/gpt-5.2-codex",
                tokensUsed: 110,
                rolloutPath: oldRollout.path,
                createdAt: 1_782_156_300,
                updatedAt: 1_782_156_360,
                cwd: "/tmp/OpenBurnBar"
            ),
            (
                id: "codex-recent-thread",
                model: "openai/gpt-5.2-codex",
                tokensUsed: 110,
                rolloutPath: recentRollout.path,
                createdAt: 1_783_915_200,
                updatedAt: 1_783_915_260,
                cwd: "/tmp/OpenBurnBar"
            )
        ])

        let parser = TestableCodexParser(
            fileManager: harness.fileManager,
            codexRoot: harness.rootURL.appendingPathComponent(".codex", isDirectory: true),
            appPaths: OpenBurnBar.OpenBurnBarAppPaths(
                applicationSupportRoot: harness.rootURL.appendingPathComponent("support", isDirectory: true)
            )
        )

        let result = try await parser.parse(options: LogParseOptions(
            includeConversationBodies: false,
            minimumFileModificationDate: Date(timeIntervalSince1970: 1_783_915_200)
        ))

        XCTAssertEqual(result.usages.map(\.sessionId), ["codex-recent-thread"])
        XCTAssertTrue(result.conversations.isEmpty)
    }

    func testParserConversationCacheScrubberRedactsKnownParserCaches() throws {
        let supportRoot = uniqueTempURL()
        let appPaths = OpenBurnBar.OpenBurnBarAppPaths(applicationSupportRoot: supportRoot)
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
            XCTAssertNil(entry["conversation"])
        }
    }

    func testParserConversationCacheScrubberRedactsBinaryPlistCaches() throws {
        let supportRoot = uniqueTempURL()
        let appPaths = OpenBurnBar.OpenBurnBarAppPaths(applicationSupportRoot: supportRoot)
        try FileManager.default.createDirectory(at: appPaths.supportDirectory, withIntermediateDirectories: true)

        let privateMarker = "private binary parser cache body \(UUID().uuidString)"
        let cacheURL = appPaths.claudeCodeParserCacheURL
        try seedBinaryParserCache(at: cacheURL, marker: privateMarker)

        ParserConversationCacheScrubber(
            fileManager: .default,
            appPaths: appPaths
        ).scrubKnownParserCaches()

        let scrubbed = try Data(contentsOf: cacheURL)
        XCTAssertFalse(scrubbed.containsRawString(privateMarker))

        let root = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: scrubbed, options: [], format: nil) as? [String: Any]
        )
        let entries = try XCTUnwrap(root["fileEntries"] as? [String: Any])
        let entry = try XCTUnwrap(entries["session"] as? [String: Any])
        XCTAssertNil(entry["conversation"])
    }

    /// `ModelFilterParser` (used for Zai / MiniMax) must likewise stay constructible
    /// and degrade gracefully when the support directory cannot be prepared.
    func testModelFilterParserConstructsWhenSupportDirUnavailable() throws {
        let fileRoot = uniqueTempURL()
        try Data("not a directory".utf8).write(to: fileRoot, options: .atomic)
        let paths = OpenBurnBar.OpenBurnBarAppPaths(applicationSupportRoot: fileRoot)

        // Construction triggers the warm-up; it must not throw / crash.
        let parser = ModelFilterParser(
            modelPattern: "zai",
            provider: .zai,
            fileManager: .default,
            appPaths: paths
        )
        XCTAssertEqual(parser.provider, .zai)
    }

    func testModelFilterParserSkipsSessionsOlderThanIncrementalCutoff() async throws {
        let root = uniqueTempURL()
        let sessionsURL = root.appendingPathComponent("sessions", isDirectory: true)
        let projectURL = sessionsURL.appendingPathComponent("-Users-alberto-project", isDirectory: true)
        let supportURL = root.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)

        let oldSessionURL = projectURL.appendingPathComponent("old-session.jsonl")
        let recentSessionURL = projectURL.appendingPathComponent("recent-session.jsonl")
        let settings = Data(#"{"model":"zai/glm-4.5","tokenUsage":{"input_tokens":100,"output_tokens":10}}"#.utf8)

        for sessionURL in [oldSessionURL, recentSessionURL] {
            try Data().write(to: sessionURL)
            try settings.write(to: sessionURL.deletingPathExtension().appendingPathExtension("settings.json"))
        }

        let cutoff = Date(timeIntervalSince1970: 1_800_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: cutoff.addingTimeInterval(-60)],
            ofItemAtPath: oldSessionURL.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: cutoff.addingTimeInterval(60)],
            ofItemAtPath: recentSessionURL.path
        )

        let parser = ModelFilterParser(
            modelPattern: "zai",
            provider: .zai,
            fileManager: .default,
            appPaths: OpenBurnBar.OpenBurnBarAppPaths(applicationSupportRoot: supportURL),
            sessionsDirectoryOverride: sessionsURL
        )
        let result = try await parser.parse(options: LogParseOptions(
            includeConversationBodies: false,
            minimumFileModificationDate: cutoff
        ))

        XCTAssertEqual(result.usages.map(\.sessionId), ["recent-session"])
        XCTAssertTrue(result.conversations.isEmpty)
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

    func testParserRegistryEveryEntryHonorsGovernedFutureBoundaryWithoutFallback() async {
        let expectedProviders: Set<AgentProvider> = [
            .factory, .claudeCode, .copilot, .aider, .cursor, .cursorAgent,
            .codex, .openCode, .piAgent, .zai, .minimax, .kimi, .xAI,
            .cline, .kiloCode, .rooCode, .forgeDev, .augment, .hermes,
            .geminiCLI, .antigravity, .goose, .openClaw, .windsurf, .warp,
            .ollama, .junie
        ]
        let parsers = ParserRegistry.defaultParsers()
        let registeredProviders = Set(parsers.keys)

        XCTAssertEqual(registeredProviders, expectedProviders)

        for provider in registeredProviders.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let parser = parsers[provider] else {
                XCTFail("missing parser for \(provider.rawValue)")
                continue
            }
            XCTAssertEqual(parser.provider, provider)
            let governor = ParserResourceGovernor(
                limits: ParserResourceLimits(memoryCeilingBytes: 1),
                footprintProvider: { 2 }
            )

            do {
                _ = try await parser.parse(options: LogParseOptions(
                    includeConversationBodies: false,
                    minimumFileModificationDate: .distantFuture,
                    resourceGovernor: governor
                ))
            } catch is ParserResourceExceeded {
                // A locally present candidate reached the governed checkpoint
                // before any content admission. An empty fixture root returns
                // normally; both paths prove options dispatch for that entry.
            } catch is ParserOptionsUnsupported {
                XCTFail("\(provider.rawValue) reached an obsolete ungoverned fallback")
            } catch {
                XCTFail("\(provider.rawValue) returned unexpected governed-parse error: \(error)")
            }
            XCTAssertEqual(
                governor.consumedBytes,
                0,
                "the stable future-boundary fixture must not admit content for \(provider.rawValue)"
            )
        }
    }

    private func seedParserCache(at cacheURL: URL, marker: String) throws {
        let data = try JSONSerialization.data(withJSONObject: parserCacheRoot(marker: marker), options: [.prettyPrinted, .sortedKeys])
        try data.write(to: cacheURL, options: .atomic)
    }

    private func seedBinaryParserCache(at cacheURL: URL, marker: String) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: parserCacheRoot(marker: marker, includeNullUsage: false),
            format: .binary,
            options: 0
        )
        try data.write(to: cacheURL, options: .atomic)
    }

    private func parserCacheRoot(marker: String, includeNullUsage: Bool = true) -> [String: Any] {
        var entry: [String: Any] = [
            "signature": ["size": 1, "modifiedAt": 1],
            "conversation": [
                "id": "session",
                "fullText": marker
            ]
        ]
        if includeNullUsage {
            entry["usage"] = NSNull()
        }

        return [
            "schemaVersion": 2,
            "fileEntries": [
                "session": entry
            ]
        ]
    }
}

private extension Data {
    func containsRawString(_ string: String) -> Bool {
        range(of: Data(string.utf8)) != nil
    }
}
