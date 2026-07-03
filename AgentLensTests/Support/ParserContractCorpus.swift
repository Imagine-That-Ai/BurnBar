import Foundation
import GRDB
@testable import OpenBurnBar

// MARK: - Parser contract corpus (VAL-P0-HARNESS-023 / 024)
//
// The single registry that ties the 15 inline `ParserTestFixtures` builders to
// their extracted on-disk vectors and to the parser-output contract.
//
// For each fixture it knows:
//   1. how to render the builder's DEFAULT-argument bytes (`builderArtifacts`),
//   2. the committed on-disk file name(s) that must be byte-identical to (1),
//   3. how to lay the bytes out in the exact directory shape the REAL production
//      parser expects, run that parser, and project the output to the portable
//      contract (`contract(for:artifacts:)`).
//
// (1) + (2) power the byte-identical extraction proof; (3) powers both the
// old-inline-vs-new-file parser-output proof and the Mac golden.

@MainActor
enum ParserContractCorpus {

    // MARK: Types

    /// One committed file backing a fixture (a fixture may need >1, e.g. Factory
    /// Droid: session JSONL + `settings.json` + `metadata.json`).
    struct Artifact: Equatable {
        enum Role: String { case primary, settings, metadata }
        let role: Role
        /// Unique bundle resource base name (no extension); e.g.
        /// `"pc-claude-basic-session"`. Uniqueness keeps flattened-bundle lookup
        /// unambiguous.
        let resourceName: String
        /// File extension without the dot; `"jsonl"` or `"json"`.
        let fileExtension: String
        let content: String

        var fileName: String { "\(resourceName).\(fileExtension)" }
    }

    /// Extra layout data the Codex parser needs (it reads a `state_5.sqlite`
    /// `threads` row that points at the rollout file).
    struct CodexLayout {
        let threadId: String
        let model: String
        let tokensUsed: Int
        let createdAt: Int64
        let updatedAt: Int64
        let cwd: String
        /// Path of the rollout file relative to `.codex/`.
        let rolloutRelativePath: String
    }

    struct Fixture {
        enum Kind: String {
            case claudeCode = "Claude Code"
            case factory = "Factory"
            case codex = "Codex"
            case hermes = "Hermes"
        }
        /// Matches the `ParserTestFixtures` static-func name it was extracted from.
        let id: String
        let kind: Kind
        let parserName: String
        /// Claude/Factory: JSONL filename stem (== parsed `sessionId`).
        /// Codex: unused (see `codex.threadId`).
        /// Hermes: raw session id → file is `session_<sessionId>.json`.
        let sessionId: String
        /// Claude/Factory: encoded project directory name.
        /// Hermes: profile name. Codex: unused (see `codex.cwd`).
        let projectDir: String
        let renderArtifacts: @MainActor () -> [Artifact]
        let codex: CodexLayout?

        init(
            id: String,
            kind: Kind,
            parserName: String,
            sessionId: String,
            projectDir: String,
            codex: CodexLayout? = nil,
            renderArtifacts: @escaping @MainActor () -> [Artifact]
        ) {
            self.id = id
            self.kind = kind
            self.parserName = parserName
            self.sessionId = sessionId
            self.projectDir = projectDir
            self.codex = codex
            self.renderArtifacts = renderArtifacts
        }
    }

    // MARK: Registry — the 15 extracted fixtures

    /// Encoded Claude/Factory project directory shared by the corpus. Claude
    /// decodes `-Users-…` → `~/…`; Factory maps `-Users-`→`~/` and `-`→`/`.
    private static let claudeProjectDir = "-Users-test-Documents-ParserContract"
    private static let factoryProjectDir = "ParserContract"
    private static let hermesProfile = "world-director"
    private static let codexCWD = "/tmp/OpenBurnBar"
    private static let codexModel = "openai/gpt-5.2-codex"

    static let fixtures: [Fixture] = [
        // ---- Claude Code (8) ----
        Fixture(
            id: "claudeCodeSession", kind: .claudeCode, parserName: "ClaudeCodeParser",
            sessionId: "claude-basic-session", projectDir: claudeProjectDir
        ) { [primaryJSONL("pc-claude-basic-session", ParserTestFixtures.claudeCodeSession())] },
        Fixture(
            id: "claudeCodeMultiTurnSession", kind: .claudeCode, parserName: "ClaudeCodeParser",
            sessionId: "claude-multi-turn", projectDir: claudeProjectDir
        ) { [primaryJSONL("pc-claude-multi-turn", ParserTestFixtures.claudeCodeMultiTurnSession())] },
        Fixture(
            id: "claudeCodeWithSubagent", kind: .claudeCode, parserName: "ClaudeCodeParser",
            sessionId: "claude-subagent", projectDir: claudeProjectDir
        ) { [primaryJSONL("pc-claude-subagent", ParserTestFixtures.claudeCodeWithSubagent())] },
        Fixture(
            id: "sessionWithMalformedLines", kind: .claudeCode, parserName: "ClaudeCodeParser",
            sessionId: "claude-malformed-lines", projectDir: claudeProjectDir
        ) { [primaryJSONL("pc-claude-malformed-lines", ParserTestFixtures.sessionWithMalformedLines())] },
        Fixture(
            id: "sessionWithMissingUsage", kind: .claudeCode, parserName: "ClaudeCodeParser",
            sessionId: "claude-missing-usage", projectDir: claudeProjectDir
        ) { [primaryJSONL("pc-claude-missing-usage", ParserTestFixtures.sessionWithMissingUsage())] },
        Fixture(
            id: "sessionWithCacheTokens", kind: .claudeCode, parserName: "ClaudeCodeParser",
            sessionId: "claude-cache-tokens", projectDir: claudeProjectDir
        ) { [primaryJSONL("pc-claude-cache-tokens", ParserTestFixtures.sessionWithCacheTokens())] },
        Fixture(
            id: "claudeStreamingSessionWithDuplicateUsage", kind: .claudeCode, parserName: "ClaudeCodeParser",
            sessionId: "claude-streaming-dupe-usage", projectDir: claudeProjectDir
        ) { [primaryJSONL("pc-claude-streaming-dupe-usage", ParserTestFixtures.claudeStreamingSessionWithDuplicateUsage())] },
        Fixture(
            id: "emptySession", kind: .claudeCode, parserName: "ClaudeCodeParser",
            sessionId: "claude-empty-session", projectDir: claudeProjectDir
        ) { [primaryJSONL("pc-claude-empty-session", ParserTestFixtures.emptySession())] },

        // ---- Factory Droid (2) ----
        Fixture(
            id: "factoryDroidSession", kind: .factory, parserName: "FactoryDroidParser",
            sessionId: "factory-basic", projectDir: factoryProjectDir
        ) { [primaryJSONL("pc-factory-basic", ParserTestFixtures.factoryDroidSession())] },
        Fixture(
            id: "factoryDroidSessionWithSettings", kind: .factory, parserName: "FactoryDroidParser",
            sessionId: "factory-with-settings", projectDir: factoryProjectDir
        ) {
            let bundle = ParserTestFixtures.factoryDroidSessionWithSettings(
                sessionId: "factory-with-settings", model: "glm-4", inputTokens: 800, outputTokens: 400
            )
            var artifacts: [Artifact] = [
                Artifact(role: .primary, resourceName: "pc-factory-with-settings", fileExtension: "jsonl", content: bundle.jsonl),
                Artifact(role: .settings, resourceName: "pc-factory-with-settings-settings", fileExtension: "json", content: bundle.settings)
            ]
            if let metadata = bundle.metadata {
                artifacts.append(Artifact(role: .metadata, resourceName: "pc-factory-with-settings-metadata", fileExtension: "json", content: metadata))
            }
            return artifacts
        },

        // ---- Codex (3) ----
        Fixture(
            id: "codexRolloutSession", kind: .codex, parserName: "CodexParser",
            sessionId: "codex-contract-001", projectDir: codexCWD,
            codex: CodexLayout(
                threadId: "codex-contract-001", model: codexModel, tokensUsed: 176,
                createdAt: 1_766_577_600, updatedAt: 1_766_577_660, cwd: codexCWD,
                rolloutRelativePath: "sessions/2025/12/24/rollout-2025-12-24T12-00-00.jsonl"
            )
        ) { [primaryJSONL("pc-codex-rollout-session", ParserTestFixtures.codexRolloutSession())] },
        Fixture(
            id: "codexRolloutSessionWithLastUsageOnly", kind: .codex, parserName: "CodexParser",
            sessionId: "codex-contract-002", projectDir: codexCWD,
            codex: CodexLayout(
                threadId: "codex-contract-002", model: codexModel, tokensUsed: 176,
                createdAt: 1_766_664_000, updatedAt: 1_766_664_060, cwd: codexCWD,
                rolloutRelativePath: "sessions/2025/12/25/rollout-2025-12-25T12-00-00.jsonl"
            )
        ) { [primaryJSONL("pc-codex-last-usage-only", ParserTestFixtures.codexRolloutSessionWithLastUsageOnly())] },
        Fixture(
            id: "codexRolloutSessionWithPartialTokenCountAndDeltas", kind: .codex, parserName: "CodexParser",
            sessionId: "codex-contract-003", projectDir: codexCWD,
            codex: CodexLayout(
                threadId: "codex-contract-003", model: codexModel, tokensUsed: 176,
                createdAt: 1_766_750_000, updatedAt: 1_766_750_060, cwd: codexCWD,
                rolloutRelativePath: "sessions/2025/12/26/rollout-2025-12-26T12-00-00.jsonl"
            )
        ) { [primaryJSONL("pc-codex-partial-token-count", ParserTestFixtures.codexRolloutSessionWithPartialTokenCountAndDeltas())] },

        // ---- Hermes (2) ----
        Fixture(
            id: "hermesSessionSnapshot", kind: .hermes, parserName: "HermesParser",
            sessionId: "cron_test_001", projectDir: hermesProfile
        ) { [primaryJSON("pc-hermes-session-snapshot", ParserTestFixtures.hermesSessionSnapshot())] },
        Fixture(
            id: "hermesToolHeavySessionSnapshot", kind: .hermes, parserName: "HermesParser",
            sessionId: "cron_tool_heavy_001", projectDir: hermesProfile
        ) { [primaryJSON("pc-hermes-tool-heavy-snapshot", ParserTestFixtures.hermesToolHeavySessionSnapshot())] }
    ]

    private static func primaryJSONL(_ name: String, _ content: String) -> Artifact {
        Artifact(role: .primary, resourceName: name, fileExtension: "jsonl", content: content)
    }

    private static func primaryJSON(_ name: String, _ content: String) -> Artifact {
        Artifact(role: .primary, resourceName: name, fileExtension: "json", content: content)
    }

    // MARK: Public API

    /// The DEFAULT-argument builder render for a fixture — the canonical bytes
    /// the committed on-disk vector must equal.
    static func builderArtifacts(for fixture: Fixture) -> [Artifact] {
        fixture.renderArtifacts()
    }

    /// Load the COMMITTED on-disk vector for a fixture from the test bundle,
    /// preserving each artifact's role/name/extension but replacing content with
    /// the committed bytes. Returns `nil` if the corpus is not bundled yet
    /// (bootstrap run before the files are committed).
    static func committedArtifacts(for fixture: Fixture, bundle: Bundle) throws -> [Artifact]? {
        var loaded: [Artifact] = []
        for spec in fixture.renderArtifacts() {
            guard let url = bundledURL(resource: spec.resourceName, ext: spec.fileExtension, bundle: bundle) else {
                return nil
            }
            let content = try String(contentsOf: url, encoding: .utf8)
            loaded.append(Artifact(role: spec.role, resourceName: spec.resourceName, fileExtension: spec.fileExtension, content: content))
        }
        return loaded
    }

    /// Lay `artifacts` out in the fixture's real directory shape, run the REAL
    /// production parser, and project the result to the portable contract.
    static func contract(for fixture: Fixture, artifacts: [Artifact]) async throws -> ParserFixtureContract {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await runParser(fixture: fixture, artifacts: artifacts, root: root)
        let records = ParserOutputContract.sortedUsages(result.usages.map(ParserOutputContractRecord.init))
        return ParserFixtureContract(
            fixtureId: fixture.id,
            provider: fixture.kind.rawValue,
            parser: fixture.parserName,
            usageCount: records.count,
            conversationCount: result.conversations.count,
            usages: records
        )
    }

    // MARK: Bundle lookup

    static func bundledURL(resource: String, ext: String, bundle: Bundle) -> URL? {
        bundle.url(forResource: resource, withExtension: ext)
            ?? bundle.url(forResource: resource, withExtension: ext, subdirectory: "ParserContract")
            ?? bundle.url(forResource: resource, withExtension: ext, subdirectory: "Fixtures/ParserContract")
    }

    // MARK: Layout + parser invocation (REAL production parsers)

    private static func runParser(fixture: Fixture, artifacts: [Artifact], root: URL) async throws -> ParseResult {
        let fm = FileManager.default
        let appPaths = OpenBurnBarAppPaths(applicationSupportRoot: root.appendingPathComponent("support", isDirectory: true))

        switch fixture.kind {
        case .claudeCode:
            let projectsRoot = root.appendingPathComponent(".claude/projects", isDirectory: true)
            let projectDir = projectsRoot.appendingPathComponent(fixture.projectDir, isDirectory: true)
            try fm.createDirectory(at: projectDir, withIntermediateDirectories: true)
            try primary(artifacts).content.write(
                to: projectDir.appendingPathComponent("\(fixture.sessionId).jsonl"),
                atomically: true, encoding: .utf8
            )
            let parser = ClaudeCodeParser(fileManager: fm, appPaths: appPaths, projectsDirectoryOverride: projectsRoot)
            return try await parser.parse()

        case .factory:
            let sessionsRoot = root.appendingPathComponent(".factory/sessions", isDirectory: true)
            let projectDir = sessionsRoot.appendingPathComponent(fixture.projectDir, isDirectory: true)
            try fm.createDirectory(at: projectDir, withIntermediateDirectories: true)
            for artifact in artifacts {
                let name: String
                switch artifact.role {
                case .primary: name = "\(fixture.sessionId).jsonl"
                case .settings: name = "\(fixture.sessionId).settings.json"
                case .metadata: name = "\(fixture.sessionId).metadata.json"
                }
                try artifact.content.write(to: projectDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
            let parser = FactoryDroidParser(fileManager: fm, appPaths: appPaths, sessionsDirectoryOverride: sessionsRoot)
            return try await parser.parse()

        case .codex:
            guard let codex = fixture.codex else {
                throw CorpusError.missingCodexLayout(fixture.id)
            }
            let codexRoot = root.appendingPathComponent(".codex", isDirectory: true)
            let rolloutURL = codexRoot.appendingPathComponent(codex.rolloutRelativePath)
            try fm.createDirectory(at: rolloutURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try primary(artifacts).content.write(to: rolloutURL, atomically: true, encoding: .utf8)
            try writeCodexThreadsDatabase(codexRoot: codexRoot, codex: codex, rolloutPath: rolloutURL.path)
            let parser = CodexParser(fileManager: fm, appPaths: appPaths, homeDirectoryURL: root)
            return try await parser.parse()

        case .hermes:
            let hermesRoot = root.appendingPathComponent(".hermes", isDirectory: true)
            let sessionsDir = hermesRoot
                .appendingPathComponent("profiles", isDirectory: true)
                .appendingPathComponent(fixture.projectDir, isDirectory: true)
                .appendingPathComponent("sessions", isDirectory: true)
            try fm.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
            try primary(artifacts).content.write(
                to: sessionsDir.appendingPathComponent("session_\(fixture.sessionId).json"),
                atomically: true, encoding: .utf8
            )
            let parser = HermesParser(fileManager: fm, hermesRootURL: hermesRoot)
            return try await parser.parse()
        }
    }

    private static func writeCodexThreadsDatabase(codexRoot: URL, codex: CodexLayout, rolloutPath: String) throws {
        let dbURL = codexRoot.appendingPathComponent("state_5.sqlite", isDirectory: false)
        let queue = try DatabaseQueue(path: dbURL.path)
        try queue.write { db in
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
            try db.execute(
                sql: """
                    INSERT INTO threads (
                        id, title, model, model_provider, tokens_used,
                        created_at, updated_at, cwd, rollout_path, archived
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
                """,
                arguments: [
                    codex.threadId, codex.threadId, codex.model, "openai",
                    codex.tokensUsed, codex.createdAt, codex.updatedAt, codex.cwd, rolloutPath
                ]
            )
        }
        try queue.close()
    }

    private static func primary(_ artifacts: [Artifact]) -> Artifact {
        artifacts.first { $0.role == .primary } ?? artifacts[0]
    }

    private static func makeTempRoot() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-parser-contract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    enum CorpusError: Error, CustomStringConvertible {
        case missingCodexLayout(String)
        var description: String {
            switch self {
            case .missingCodexLayout(let id): return "Codex fixture \(id) is missing its CodexLayout"
            }
        }
    }
}
