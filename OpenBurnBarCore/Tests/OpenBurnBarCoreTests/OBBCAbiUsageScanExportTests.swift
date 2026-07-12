import Foundation
import XCTest
@testable import OpenBurnBarCore

final class OBBCAbiUsageScanExportTests: XCTestCase {
    func test_scanReadsClaudeAndCursorFixturesWithStableRuntimeRows() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("obb-cabi-usage-scan-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let home = root.appendingPathComponent("home", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let claude = home.appendingPathComponent(
            ".claude/projects/-Users-test-Documents-ParserContract",
            isDirectory: true
        )
        let cursor = home.appendingPathComponent(".cursor-agent/sessions", isDirectory: true)
        try fileManager.createDirectory(at: claude, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: cursor, withIntermediateDirectories: true)

        try fileManager.copyItem(
            at: fixture("pc-claude-basic-session.jsonl"),
            to: claude.appendingPathComponent("claude-basic-session.jsonl")
        )
        let cursorFixture = """
        {"role":"user","content":"Inspect the Windows usage runtime","timestamp":"2026-07-10T12:00:00Z"}
        {"role":"assistant","content":"I found the parser boundary.","thinking":"Check the native bridge.","timestamp":"2026-07-10T12:00:01Z"}
        {"role":"tool","content":"File Path: `file:///C:/src/OpenBurnBar/App.xaml.cs`","timestamp":"2026-07-10T12:00:02Z"}
        """
        try Data(cursorFixture.utf8).write(
            to: cursor.appendingPathComponent("cursor-basic.jsonl"),
            options: .atomic
        )

        let codexRoot = home.appendingPathComponent(".codex", isDirectory: true)
        try fileManager.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        let rolloutURL = codexRoot.appendingPathComponent("rollout-basic.jsonl", isDirectory: false)
        let rolloutFixture = """
        {"type":"turn_context","timestamp":"2025-12-24T12:00:00.000Z","payload":{"model":"openai/gpt-5.2-codex"}}
        {"type":"event_msg","timestamp":"2025-12-24T12:00:01.000Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":160,"cached_input_tokens":40,"output_tokens":16},"model":"openai/gpt-5.2-codex"}}}
        {"item":{"role":"user","content":"Codex privacy probe: summarize the mirror handshake."}}
        {"item":{"role":"assistant","content":"Codex privacy probe reply: the handshake pairs peers."}}
        """
        try Data(rolloutFixture.utf8).write(to: rolloutURL, options: .atomic)
        try createCodexThreadDatabase(at: codexRoot, rolloutPath: rolloutURL.path)

        let request = OBBCAbiUsageScanRequest(
            supportDirectory: support.path,
            homeDirectory: home.path,
            claudeProjectsDirectory: home.appendingPathComponent(".claude/projects").path,
            codexHomeDirectory: home.path,
            cursorSessionsDirectory: cursor.path,
            factorySessionsDirectory: home.appendingPathComponent(".factory/sessions").path,
            hermesHomeDirectory: home.appendingPathComponent(".hermes").path,
            includeConversationBodies: true
        )
        let requestData = try JSONEncoder().encode(request)

        let first = try OBBCAbiUsageScanExport.run(requestData: requestData)
        let second = try OBBCAbiUsageScanExport.run(requestData: requestData)

        XCTAssertTrue(first.ok)
        XCTAssertNil(first.error)
        XCTAssertEqual(
            first.providers.first(where: { $0.provider == AgentProvider.claudeCode.rawValue })?.status,
            .succeeded
        )
        XCTAssertEqual(
            first.providers.first(where: { $0.provider == AgentProvider.cursorAgent.rawValue })?.status,
            .succeeded
        )
        XCTAssertEqual(
            first.providers.first(where: { $0.provider == AgentProvider.codex.rawValue })?.status,
            .succeeded
        )
        XCTAssertTrue(first.usages.contains(where: { $0.provider == AgentProvider.claudeCode.rawValue }))
        XCTAssertTrue(first.usages.contains(where: { $0.provider == AgentProvider.cursorAgent.rawValue }))
        XCTAssertTrue(first.usages.contains(where: { $0.provider == AgentProvider.codex.rawValue }))
        XCTAssertFalse(first.conversations.isEmpty)
        XCTAssertTrue(first.conversations.contains(where: { $0.provider == AgentProvider.codex.rawValue }))
        XCTAssertFalse(second.conversations.isEmpty)
        XCTAssertTrue(second.conversations.contains(where: { $0.provider == AgentProvider.codex.rawValue }))
        XCTAssertEqual(first.usages.map(\.id), second.usages.map(\.id))

        // Parser caches live under `<applicationSupportRoot>/OpenBurnBar/*parser_cache.json`
        // (`OpenBurnBarAppPaths.supportDirectory`), not directly under the root
        // handed to the scan request.
        let cacheDirectory = support.appendingPathComponent("OpenBurnBar", isDirectory: true)

        // A legacy cache produced before the privacy fix may still carry a
        // persisted conversation body; a fresh scan must strip it in place.
        try injectLegacyCodexConversation(
            cacheURL: cacheDirectory.appendingPathComponent("codex_parser_cache.json")
        )
        // A cache entry without usage must be re-warmed (and re-persisted)
        // without ever writing the conversation body back to disk.
        try removeCachedUsage(
            fromCacheAt: cacheDirectory.appendingPathComponent("claude_code_parser_cache.json")
        )

        let third = try OBBCAbiUsageScanExport.run(requestData: requestData)
        XCTAssertTrue(third.ok)
        XCTAssertEqual(third.usages.count, first.usages.count)
        XCTAssertTrue(third.conversations.contains(where: { $0.provider == AgentProvider.codex.rawValue }))
        XCTAssertTrue(third.conversations.contains(where: { $0.provider == AgentProvider.claudeCode.rawValue }))

        let cacheFiles = try fileManager.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains("parser_cache") }
        XCTAssertTrue(cacheFiles.contains(where: { $0.lastPathComponent == "claude_code_parser_cache.json" }))
        XCTAssertTrue(cacheFiles.contains(where: { $0.lastPathComponent == "codex_parser_cache.json" }))
        for cacheFile in cacheFiles {
            let cacheData = try Data(contentsOf: cacheFile)
            XCTAssertFalse(cacheData.contains(Data("Hello, help me write a function that adds two numbers.".utf8)))
            XCTAssertFalse(cacheData.contains(Data("Here's a simple Swift function:".utf8)))
            XCTAssertFalse(cacheData.contains(Data("Inspect the Windows usage runtime".utf8)))
            XCTAssertFalse(cacheData.contains(Data("I found the parser boundary.".utf8)))
            XCTAssertFalse(cacheData.contains(Data("Codex privacy probe".utf8)))
            XCTAssertFalse(cacheData.contains(Data("LEGACY-CODEX-CONVERSATION-BODY".utf8)))
        }
    }

    func test_scanRejectsIncompleteRequest() throws {
        let invalid = Data(#"{"supportDirectory":""}"#.utf8)
        XCTAssertThrowsError(try OBBCAbiUsageScanExport.run(requestData: invalid)) { error in
            XCTAssertEqual(error as? OBBCAbiUsageScanError, .invalidRequest)
        }
    }

    func test_scanReadsFactoryAndHermesFixtures() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("obb-cabi-provider-scan-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let home = root.appendingPathComponent("home", isDirectory: true)
        let factory = home.appendingPathComponent(".factory/sessions", isDirectory: true)
        let factoryProject = factory.appendingPathComponent("-Users-test-OpenBurnBar", isDirectory: true)
        let hermes = home.appendingPathComponent(".hermes", isDirectory: true)
        let hermesSessions = hermes
            .appendingPathComponent("profiles/default/sessions", isDirectory: true)
        try fileManager.createDirectory(at: factoryProject, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: hermesSessions, withIntermediateDirectories: true)
        try fileManager.copyItem(
            at: fixture("pc-factory-with-settings.jsonl"),
            to: factoryProject.appendingPathComponent("factory-with-settings.jsonl")
        )
        try fileManager.copyItem(
            at: fixture("pc-factory-with-settings-settings.json"),
            to: factoryProject.appendingPathComponent("factory-with-settings.settings.json")
        )
        try fileManager.copyItem(
            at: fixture("pc-factory-with-settings-metadata.json"),
            to: factoryProject.appendingPathComponent("factory-with-settings.metadata.json")
        )
        try fileManager.copyItem(
            at: fixture("pc-hermes-session-snapshot.json"),
            to: hermesSessions.appendingPathComponent("session_cron_test_001.json")
        )

        let requestData = try JSONEncoder().encode(
            request(root: root, home: home, factory: factory, hermes: hermes)
        )
        let response = try OBBCAbiUsageScanExport.run(requestData: requestData)

        XCTAssertTrue(response.ok)
        XCTAssertEqual(provider(.factory, in: response)?.status, .succeeded)
        XCTAssertEqual(provider(.hermes, in: response)?.status, .succeeded)
        XCTAssertTrue(response.usages.contains(where: { $0.provider == AgentProvider.factory.rawValue }))
        XCTAssertTrue(response.conversations.contains(where: { $0.provider == AgentProvider.factory.rawValue }))
        XCTAssertTrue(response.conversations.contains(where: { $0.provider == AgentProvider.hermes.rawValue }))

        // Second scan hits the warmed cache; conversation bodies must still be
        // served (reparsed transiently) without being persisted.
        let second = try OBBCAbiUsageScanExport.run(requestData: requestData)
        XCTAssertTrue(second.conversations.contains(where: { $0.provider == AgentProvider.factory.rawValue }))
        XCTAssertEqual(response.usages.map(\.id), second.usages.map(\.id))

        // A cache entry without usage must be re-warmed and re-persisted
        // without writing the conversation body back to disk.
        let factoryCacheURL = root
            .appendingPathComponent("support", isDirectory: true)
            .appendingPathComponent("OpenBurnBar", isDirectory: true)
            .appendingPathComponent("factory_droid_parser_cache.json", isDirectory: false)
        try removeCachedUsage(fromCacheAt: factoryCacheURL)

        let third = try OBBCAbiUsageScanExport.run(requestData: requestData)
        XCTAssertTrue(third.conversations.contains(where: { $0.provider == AgentProvider.factory.rawValue }))
        XCTAssertEqual(response.usages.map(\.id), third.usages.map(\.id))

        let cacheData = try Data(contentsOf: factoryCacheURL)
        XCTAssertFalse(cacheData.contains(Data("Hi there".utf8)))
    }

    func test_scanIsolatesProviderFailure() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("obb-cabi-provider-failure-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let home = root.appendingPathComponent("home", isDirectory: true)
        let factoryFile = home.appendingPathComponent("factory-sessions-is-a-file", isDirectory: false)
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: factoryFile)

        let response = try OBBCAbiUsageScanExport.run(requestData: JSONEncoder().encode(
            request(root: root, home: home, factory: factoryFile)
        ))

        XCTAssertTrue(response.ok)
        XCTAssertEqual(provider(.factory, in: response)?.status, .failed)
        XCTAssertNotNil(provider(.factory, in: response)?.error)
        XCTAssertTrue(response.usages.isEmpty)
    }

    func test_scanCEntryPointReturnsFailureJSONForMissingRequest() throws {
        let pointer = try XCTUnwrap(obb_scan_usage(requestJSON: nil))
        defer { obb_string_free(pointer) }

        let response = try JSONDecoder().decode(
            OBBCAbiUsageScanResponse.self,
            from: Data(String(cString: pointer).utf8)
        )
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error, OBBCAbiUsageScanError.missingRequest.description)
        XCTAssertTrue(response.providers.isEmpty)
    }

    func test_parseCEntryPointUsesSynchronousClaudeParser() throws {
        let stdout = try String(contentsOf: fixture("pc-claude-basic-session.jsonl"), encoding: .utf8)
        let provider = AgentProvider.claudeCode.rawValue
        let pointer = stdout.withCString { stdoutPointer in
            provider.withCString { providerPointer in
                obb_parse_cli_stdout(stdout: stdoutPointer, provider: providerPointer)
            }
        }
        let resultPointer = try XCTUnwrap(pointer)
        defer { obb_string_free(resultPointer) }

        let response = try JSONDecoder().decode(
            OBBCAbiParseCliStdoutResponse.self,
            from: Data(String(cString: resultPointer).utf8)
        )
        XCTAssertTrue(response.ok)
        XCTAssertNil(response.error)
        XCTAssertFalse(response.usages.isEmpty)
        XCTAssertTrue(response.usages.allSatisfy { $0.provider == provider })
    }

    private func request(
        root: URL,
        home: URL,
        factory: URL? = nil,
        hermes: URL? = nil
    ) -> OBBCAbiUsageScanRequest {
        OBBCAbiUsageScanRequest(
            supportDirectory: root.appendingPathComponent("support", isDirectory: true).path,
            homeDirectory: home.path,
            claudeProjectsDirectory: home.appendingPathComponent(".claude/projects", isDirectory: true).path,
            codexHomeDirectory: home.path,
            cursorSessionsDirectory: home.appendingPathComponent(".cursor-agent/sessions", isDirectory: true).path,
            factorySessionsDirectory: (factory ?? home.appendingPathComponent(".factory/sessions", isDirectory: true)).path,
            hermesHomeDirectory: (hermes ?? home.appendingPathComponent(".hermes", isDirectory: true)).path,
            includeConversationBodies: true
        )
    }

    private func provider(
        _ provider: AgentProvider,
        in response: OBBCAbiUsageScanResponse
    ) -> OBBCAbiProviderScanResult? {
        response.providers.first(where: { $0.provider == provider.rawValue })
    }

    private func createCodexThreadDatabase(at codexRoot: URL, rolloutPath: String) throws {
        let connection = try SQLiteConnection.openForWriting(
            creatingAt: codexRoot.appendingPathComponent("state_5.sqlite", isDirectory: false).path
        )
        defer { connection.close() }
        try connection.execute("""
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
        try connection.execute(
            """
                INSERT INTO threads (
                    id, title, model, model_provider, tokens_used,
                    created_at, updated_at, cwd, rollout_path, archived
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
            """,
            arguments: [
                .text("codex-thread-1"),
                .text("Codex privacy probe thread"),
                .text("openai/gpt-5.2-codex"),
                .text("openai"),
                .int(176),
                .int(1_766_577_600),
                .int(1_766_577_700),
                .text("~"),
                .text(rolloutPath)
            ]
        )
    }

    /// Simulates a legacy (pre-privacy-fix) codex cache that still carries a
    /// persisted conversation body, so a scan must strip it in place.
    private func injectLegacyCodexConversation(cacheURL: URL) throws {
        let store = ParserDiskCacheStore<CodexCacheEntry>(
            cacheURL: cacheURL,
            schemaVersion: 1,
            logLabel: "OBBCAbiUsageScanExportTests"
        )
        var cache = store.load()
        XCTAssertFalse(cache.fileEntries.isEmpty, "expected a warmed codex parser cache to seed")
        for (key, entry) in cache.fileEntries {
            cache.fileEntries[key] = CodexCacheEntry(
                signature: entry.signature,
                tokenUsage: entry.tokenUsage,
                conversation: CodexConversationCacheEntry(
                    title: "legacy",
                    markdown: "LEGACY-CODEX-CONVERSATION-BODY",
                    messageCount: 1,
                    userWordCount: 1,
                    assistantWordCount: 1,
                    keyFiles: [],
                    keyCommands: [],
                    keyTools: [],
                    lastAssistantMessage: "LEGACY-CODEX-CONVERSATION-BODY"
                )
            )
        }
        store.persist(cache)
    }

    /// Drops the persisted `usage` payload from every entry of a parser cache
    /// (schema-agnostic plist surgery, entry types are parser-private).
    private func removeCachedUsage(fromCacheAt url: URL) throws {
        let data = try Data(contentsOf: url)
        var root = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        )
        var entries = try XCTUnwrap(root["fileEntries"] as? [String: Any])
        XCTAssertFalse(entries.isEmpty, "expected a warmed parser cache at \(url.lastPathComponent)")
        for (key, value) in entries {
            var entry = try XCTUnwrap(value as? [String: Any])
            entry.removeValue(forKey: "usage")
            entries[key] = entry
        }
        root["fileEntries"] = entries
        let rewritten = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        try rewritten.write(to: url, options: .atomic)
    }

    private func fixture(_ name: String) -> URL {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return repositoryRoot
            .appendingPathComponent("AgentLensTests/Fixtures/ParserContract", isDirectory: true)
            .appendingPathComponent(name, isDirectory: false)
    }
}
