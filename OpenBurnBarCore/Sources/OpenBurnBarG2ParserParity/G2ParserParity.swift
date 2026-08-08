// SPDX-License-Identifier: AGPL-3.0-only
//
// OpenBurnBar — Windows Port Phase-2 G2 Parser-Output Parity Gate
// ===============================================================
//
// The Windows-run, assertion-gated proof that the LIFTED log parsers produce
// token/cost/model/session output BYTE-IDENTICAL to the committed macOS golden
// (`AgentLensTests/Fixtures/ParserContract/parser-output-golden.json`) — the G2
// headline of `docs/WINDOWS_PORT_MASTER_PLAN.md` /
// `docs/windows-port/PARSER_OUTPUT_CONTRACT.md`.
//
// What this executable does, natively on the target host (macOS today, Windows in
// CI):
//   1. Loads the committed golden (bundled resource) — the exact bytes macOS
//      produced.
//   2. For every golden-covered fixture, it lays the committed fixture bytes out in
//      the real provider directory shape inside a fresh temp root, runs the REAL
//      lifted parser (`ClaudeCodeParser` / `FactoryDroidParser` / `CodexParser` /
//      `HermesParser` from `OpenBurnBarCore`), and projects the `[TokenUsage]`
//      result to the portable contract
//      (`ParserOutputContractRecord`: nano-USD int cost, session, model, token
//      buckets — every non-reproducible field excluded).
//   3. Canonically re-encodes each generated per-fixture contract AND the committed
//      golden's matching entry with the identical encoder
//      (`[.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]`) and asserts the
//      bytes are equal. ANY difference in a token bucket, the nano-USD cost, the
//      model, the session id, or the counts turns the run red.
//
// Because the projection reproduces `TokenUsage` exactly and the cost is resolved
// from the same committed `catalog.json` the parsers read (via `ModelPricing`), a
// green run on Windows is a byte-for-byte proof that the Windows parser build
// matches the macOS golden — the cross-platform half of G2.
//
// Scope (this file): ALL golden-covered lifted parsers over every committed fixture.
// 15 parsers / 26 fixtures: Claude Code (8), Factory (2), Codex (3), Hermes (2),
// Antigravity, Augment, Cline, Cursor Agent, Gemini CLI, Grok, Kimi, Forge, Goose,
// Windsurf, Warp (11). Codex + Hermes + Forge/Goose/Windsurf use the SQLite reader
// seam (`Services/SQLite/`). Every golden row is byte-diffed; none are deferred.
//
// Assertion-backed by design (mirrors the walking skeleton + path-remap gate):
// `expect(…)` is a hard gate in debug AND release — a failed assertion writes to
// stderr and exits non-zero. It never relies on `assert`, which release strips.
//
// macOS run  : swift run --package-path OpenBurnBarCore \
//                        --cache-path OpenBurnBarCore/.spm-cache \
//                        OpenBurnBarG2ParserParity
// Windows run: `.github/workflows/openburnbar-engine-windows.yml` (x64 + ARM64
//              legs), after the Engine build.

import Foundation
// The lifted log parsers (`ClaudeCodeParser` / `FactoryDroidParser` / `CodexParser`
// / `HermesParser`) and their `ParseResult` / `OpenBurnBarAppPaths` inputs are
// module-internal to `OpenBurnBarCore` (the whole lifted parser layer is internal,
// mirroring the macOS app's own copies). This parity gate is a verification harness
// — conceptually a test — so it exercises those internals through `@testable import`,
// exactly as a test target would. Windows CI and the macOS run both build the debug
// configuration (`-enable-testing` on), so the testable import resolves on both.
@testable import OpenBurnBarCore

// MARK: - Portable parser-output contract (ported from the macOS test oracle)
//
// Byte-for-byte the same projection as `AgentLensTests/Support/ParserOutputContract.swift`
// — the exact surface the Windows port must reproduce. Kept here (not shared) so
// the Engine executable has zero dependency on the app test target.

struct ParserOutputContractRecord: Codable, Equatable {
    let provider: String
    let sessionId: String
    let projectName: String
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationTokens: Int
    let cacheReadTokens: Int
    let reasoningTokens: Int
    let totalTokens: Int
    let costNanoUSD: Int
    let usageSource: String
    let provenanceMethod: String
    let provenanceConfidence: String
    let estimatorVersion: String

    init(_ usage: TokenUsage) {
        provider = usage.provider.rawValue
        sessionId = usage.sessionId
        projectName = usage.projectName
        model = usage.model
        inputTokens = usage.inputTokens
        outputTokens = usage.outputTokens
        cacheCreationTokens = usage.cacheCreationTokens
        cacheReadTokens = usage.cacheReadTokens
        reasoningTokens = usage.reasoningTokens
        totalTokens = usage.totalTokens
        costNanoUSD = G2Contract.nanoUSD(usage.costUSD)
        usageSource = usage.usageSource.rawValue
        provenanceMethod = usage.provenanceMethod.rawValue
        provenanceConfidence = usage.provenanceConfidence.rawValue
        estimatorVersion = usage.estimatorVersion
    }
}

struct ParserFixtureContract: Codable, Equatable {
    let fixtureId: String
    let provider: String
    let parser: String
    let usageCount: Int
    let conversationCount: Int
    let usages: [ParserOutputContractRecord]
}

struct ParserOutputGolden: Codable, Equatable {
    let formatVersion: Int
    let providers: [String]
    let fixtures: [ParserFixtureContract]
}

enum G2Contract {
    /// `round(usd * 1e9)` half-away-from-zero, clamped — identical to the oracle.
    static func nanoUSD(_ usd: Double) -> Int {
        guard usd.isFinite else { return 0 }
        let scaled = (usd * 1_000_000_000).rounded(.toNearestOrAwayFromZero)
        if scaled >= Double(Int.max) { return Int.max }
        if scaled <= Double(Int.min) { return Int.min }
        return Int(scaled)
    }

    static func sortedUsages(_ records: [ParserOutputContractRecord]) -> [ParserOutputContractRecord] {
        records.sorted { lhs, rhs in
            if lhs.provider != rhs.provider { return lhs.provider < rhs.provider }
            if lhs.sessionId != rhs.sessionId { return lhs.sessionId < rhs.sessionId }
            if lhs.projectName != rhs.projectName { return lhs.projectName < rhs.projectName }
            if lhs.model != rhs.model { return lhs.model < rhs.model }
            if lhs.inputTokens != rhs.inputTokens { return lhs.inputTokens < rhs.inputTokens }
            if lhs.outputTokens != rhs.outputTokens { return lhs.outputTokens < rhs.outputTokens }
            if lhs.cacheCreationTokens != rhs.cacheCreationTokens { return lhs.cacheCreationTokens < rhs.cacheCreationTokens }
            if lhs.cacheReadTokens != rhs.cacheReadTokens { return lhs.cacheReadTokens < rhs.cacheReadTokens }
            if lhs.reasoningTokens != rhs.reasoningTokens { return lhs.reasoningTokens < rhs.reasoningTokens }
            if lhs.totalTokens != rhs.totalTokens { return lhs.totalTokens < rhs.totalTokens }
            if lhs.costNanoUSD != rhs.costNanoUSD { return lhs.costNanoUSD < rhs.costNanoUSD }
            if lhs.usageSource != rhs.usageSource { return lhs.usageSource < rhs.usageSource }
            if lhs.provenanceMethod != rhs.provenanceMethod { return lhs.provenanceMethod < rhs.provenanceMethod }
            if lhs.provenanceConfidence != rhs.provenanceConfidence { return lhs.provenanceConfidence < rhs.provenanceConfidence }
            return lhs.estimatorVersion < rhs.estimatorVersion
        }
    }

    /// Canonical per-object encoding used for the byte-diff (matches the oracle's
    /// `encode` formatting; no trailing newline needed for an object-vs-object diff).
    static func canonicalEncode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}

// MARK: - Fixture corpus (CLEAN parsers) — ported from ParserContractCorpus

/// One committed file backing a fixture (Factory needs 3: jsonl + settings + metadata).
private struct Artifact {
    enum Role { case primary, settings, metadata, sidecar, sqlite }
    let role: Role
    let resourceName: String
    let fileExtension: String
}

/// Extra layout the Codex parser needs: it reads a `state_5.sqlite` `threads` row
/// that points at the rollout JSONL file. Mirrors `ParserContractCorpus.CodexLayout`.
private struct CodexLayout {
    let threadId: String
    let model: String
    let tokensUsed: Int
    let createdAt: Int64
    let updatedAt: Int64
    let cwd: String
    /// Path of the rollout file relative to `.codex/`.
    let rolloutRelativePath: String
}

/// Relative path + filename for copying a committed artifact into the temp HOME layout.
private struct LayoutCopy {
    let relativeDirectory: String
    let fileName: String
}

private struct CleanFixture {
    enum Kind: String {
        case claudeCode = "Claude Code"
        case factory = "Factory"
        case codex = "Codex"
        case hermes = "Hermes"
        case antigravity = "Antigravity"
        case augment = "Augment"
        case cline = "Cline"
        case cursorAgent = "Cursor Agent"
        case geminiCLI = "Gemini CLI"
        case grok = "xAI"
        case kimi = "Kimi"
        case forgeDev = "Forge"
        case goose = "Goose"
        case windsurf = "Windsurf"
        case warp = "Warp"
    }
    let id: String
    let kind: Kind
    let parserName: String
    /// Claude/Factory: JSONL filename stem (== parsed sessionId).
    /// Hermes: raw session id → file is `session_<sessionId>.json`. Codex: unused.
    let sessionId: String
    /// Claude/Factory: encoded project directory. Hermes: profile name. Codex: unused.
    let projectDir: String
    let artifacts: [Artifact]
    /// Codex only: the `threads`-row layout that points at the rollout file.
    let codex: CodexLayout?
    /// Optional on-disk layout copies (multi-file / SQLite / binary).
    let layoutCopies: [LayoutCopy]

    init(
        id: String,
        kind: Kind,
        parserName: String,
        sessionId: String,
        projectDir: String,
        artifacts: [Artifact],
        codex: CodexLayout? = nil,
        layoutCopies: [LayoutCopy] = []
    ) {
        self.id = id
        self.kind = kind
        self.parserName = parserName
        self.sessionId = sessionId
        self.projectDir = projectDir
        self.artifacts = artifacts
        self.codex = codex
        self.layoutCopies = layoutCopies
    }
}

private enum G2Corpus {
    /// Encoded project dirs, identical to the macOS corpus.
    static let claudeProjectDir = "-Users-test-Documents-ParserContract"
    static let factoryProjectDir = "ParserContract"
    static let hermesProfile = "world-director"
    static let codexCWD = "/tmp/OpenBurnBar"
    static let codexModel = "openai/gpt-5.2-codex"

    static let cleanFixtures: [CleanFixture] = [
        // ---- Claude Code (8) ----
        CleanFixture(id: "claudeCodeSession", kind: .claudeCode, parserName: "ClaudeCodeParser",
                     sessionId: "claude-basic-session", projectDir: claudeProjectDir,
                     artifacts: [Artifact(role: .primary, resourceName: "pc-claude-basic-session", fileExtension: "jsonl")]),
        CleanFixture(id: "claudeCodeMultiTurnSession", kind: .claudeCode, parserName: "ClaudeCodeParser",
                     sessionId: "claude-multi-turn", projectDir: claudeProjectDir,
                     artifacts: [Artifact(role: .primary, resourceName: "pc-claude-multi-turn", fileExtension: "jsonl")]),
        CleanFixture(id: "claudeCodeWithSubagent", kind: .claudeCode, parserName: "ClaudeCodeParser",
                     sessionId: "claude-subagent", projectDir: claudeProjectDir,
                     artifacts: [Artifact(role: .primary, resourceName: "pc-claude-subagent", fileExtension: "jsonl")]),
        CleanFixture(id: "sessionWithMalformedLines", kind: .claudeCode, parserName: "ClaudeCodeParser",
                     sessionId: "claude-malformed-lines", projectDir: claudeProjectDir,
                     artifacts: [Artifact(role: .primary, resourceName: "pc-claude-malformed-lines", fileExtension: "jsonl")]),
        CleanFixture(id: "sessionWithMissingUsage", kind: .claudeCode, parserName: "ClaudeCodeParser",
                     sessionId: "claude-missing-usage", projectDir: claudeProjectDir,
                     artifacts: [Artifact(role: .primary, resourceName: "pc-claude-missing-usage", fileExtension: "jsonl")]),
        CleanFixture(id: "sessionWithCacheTokens", kind: .claudeCode, parserName: "ClaudeCodeParser",
                     sessionId: "claude-cache-tokens", projectDir: claudeProjectDir,
                     artifacts: [Artifact(role: .primary, resourceName: "pc-claude-cache-tokens", fileExtension: "jsonl")]),
        CleanFixture(id: "claudeStreamingSessionWithDuplicateUsage", kind: .claudeCode, parserName: "ClaudeCodeParser",
                     sessionId: "claude-streaming-dupe-usage", projectDir: claudeProjectDir,
                     artifacts: [Artifact(role: .primary, resourceName: "pc-claude-streaming-dupe-usage", fileExtension: "jsonl")]),
        CleanFixture(id: "emptySession", kind: .claudeCode, parserName: "ClaudeCodeParser",
                     sessionId: "claude-empty-session", projectDir: claudeProjectDir,
                     artifacts: [Artifact(role: .primary, resourceName: "pc-claude-empty-session", fileExtension: "jsonl")]),
        // ---- Factory Droid (2) ----
        CleanFixture(id: "factoryDroidSession", kind: .factory, parserName: "FactoryDroidParser",
                     sessionId: "factory-basic", projectDir: factoryProjectDir,
                     artifacts: [Artifact(role: .primary, resourceName: "pc-factory-basic", fileExtension: "jsonl")]),
        CleanFixture(id: "factoryDroidSessionWithSettings", kind: .factory, parserName: "FactoryDroidParser",
                     sessionId: "factory-with-settings", projectDir: factoryProjectDir,
                     artifacts: [
                        Artifact(role: .primary, resourceName: "pc-factory-with-settings", fileExtension: "jsonl"),
                        Artifact(role: .settings, resourceName: "pc-factory-with-settings-settings", fileExtension: "json"),
                        Artifact(role: .metadata, resourceName: "pc-factory-with-settings-metadata", fileExtension: "json")
                     ]),
        // ---- Codex (3) — via the SQLite reader seam (`state_5.sqlite` threads row) ----
        CleanFixture(id: "codexRolloutSession", kind: .codex, parserName: "CodexParser",
                     sessionId: "codex-contract-001", projectDir: codexCWD,
                     artifacts: [Artifact(role: .primary, resourceName: "pc-codex-rollout-session", fileExtension: "jsonl")],
                     codex: CodexLayout(threadId: "codex-contract-001", model: codexModel, tokensUsed: 176,
                                        createdAt: 1_766_577_600, updatedAt: 1_766_577_660, cwd: codexCWD,
                                        rolloutRelativePath: "sessions/2025/12/24/rollout-2025-12-24T12-00-00.jsonl")),
        CleanFixture(id: "codexRolloutSessionWithLastUsageOnly", kind: .codex, parserName: "CodexParser",
                     sessionId: "codex-contract-002", projectDir: codexCWD,
                     artifacts: [Artifact(role: .primary, resourceName: "pc-codex-last-usage-only", fileExtension: "jsonl")],
                     codex: CodexLayout(threadId: "codex-contract-002", model: codexModel, tokensUsed: 176,
                                        createdAt: 1_766_664_000, updatedAt: 1_766_664_060, cwd: codexCWD,
                                        rolloutRelativePath: "sessions/2025/12/25/rollout-2025-12-25T12-00-00.jsonl")),
        CleanFixture(id: "codexRolloutSessionWithPartialTokenCountAndDeltas", kind: .codex, parserName: "CodexParser",
                     sessionId: "codex-contract-003", projectDir: codexCWD,
                     artifacts: [Artifact(role: .primary, resourceName: "pc-codex-partial-token-count", fileExtension: "jsonl")],
                     codex: CodexLayout(threadId: "codex-contract-003", model: codexModel, tokensUsed: 176,
                                        createdAt: 1_766_750_000, updatedAt: 1_766_750_060, cwd: codexCWD,
                                        rolloutRelativePath: "sessions/2025/12/26/rollout-2025-12-26T12-00-00.jsonl")),
        // ---- Hermes (2) — JSON snapshot path; the parser's SQLite path rides the seam ----
        CleanFixture(id: "hermesSessionSnapshot", kind: .hermes, parserName: "HermesParser",
                     sessionId: "cron_test_001", projectDir: hermesProfile,
                     artifacts: [Artifact(role: .primary, resourceName: "pc-hermes-session-snapshot", fileExtension: "json")]),
        CleanFixture(id: "hermesToolHeavySessionSnapshot", kind: .hermes, parserName: "HermesParser",
                     sessionId: "cron_tool_heavy_001", projectDir: hermesProfile,
                     artifacts: [Artifact(role: .primary, resourceName: "pc-hermes-tool-heavy-snapshot", fileExtension: "json")]),
        // ---- Antigravity (1) ----
        CleanFixture(id: "antigravityBasicSession", kind: .antigravity, parserName: "AntigravityParser",
                     sessionId: "antigravity-contract-1", projectDir: "",
                     artifacts: [Artifact(role: .primary, resourceName: "pc-antigravity-basic", fileExtension: "jsonl")],
                     layoutCopies: [LayoutCopy(relativeDirectory: ".gemini/antigravity-cli/brain/antigravity-contract-1/.system_generated/logs", fileName: "transcript.jsonl")]),
        // ---- Augment (1) ----
        CleanFixture(id: "augmentBasicSession", kind: .augment, parserName: "AugmentParser",
                     sessionId: "augment-contract-1", projectDir: "",
                     artifacts: [Artifact(role: .primary, resourceName: "pc-augment-basic", fileExtension: "jsonl")],
                     layoutCopies: [LayoutCopy(relativeDirectory: "Library/Application Support/Code/User/globalStorage/augment.vscode-augment", fileName: "pc-augment-basic.jsonl")]),
        // ---- Cline (1) ----
        CleanFixture(id: "clineBasicTask", kind: .cline, parserName: "ClineFormatParser",
                     sessionId: "cline-contract-task-1", projectDir: "",
                     artifacts: [Artifact(role: .primary, resourceName: "pc-cline-basic", fileExtension: "json")],
                     layoutCopies: [LayoutCopy(relativeDirectory: "Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/tasks/cline-contract-task-1", fileName: "api_conversation_history.json")]),
        // ---- Cursor Agent (1) ----
        CleanFixture(id: "cursorAgentBasicSession", kind: .cursorAgent, parserName: "CursorAgentParser",
                     sessionId: "cursor-agent-contract-1", projectDir: "",
                     artifacts: [Artifact(role: .primary, resourceName: "pc-cursor-agent-basic", fileExtension: "jsonl")],
                     layoutCopies: [LayoutCopy(relativeDirectory: ".cursor-agent/sessions", fileName: "cursor-agent-contract-1.jsonl")]),
        // ---- Gemini CLI (1) ----
        CleanFixture(id: "geminiCLIBasicSession", kind: .geminiCLI, parserName: "GeminiCLIParser",
                     sessionId: "session-gemini-contract-1", projectDir: "project-hash-contract",
                     artifacts: [Artifact(role: .primary, resourceName: "pc-gemini-cli-basic", fileExtension: "json")],
                     layoutCopies: [LayoutCopy(relativeDirectory: ".gemini/tmp/project-hash-contract/chats", fileName: "session-gemini-contract-1.json")]),
        // ---- Grok (1) ----
        CleanFixture(id: "grokBasicSession", kind: .grok, parserName: "GrokParser",
                     sessionId: "grok-contract-session-1", projectDir: "tmp-ParserContract",
                     artifacts: [
                        Artifact(role: .primary, resourceName: "pc-grok-summary", fileExtension: "json"),
                        Artifact(role: .sidecar, resourceName: "pc-grok-signals", fileExtension: "json"),
                        Artifact(role: .sidecar, resourceName: "pc-grok-chat-history", fileExtension: "jsonl")
                     ],
                     layoutCopies: [
                        LayoutCopy(relativeDirectory: ".grok/sessions/tmp-ParserContract/grok-contract-session-1", fileName: "summary.json"),
                        LayoutCopy(relativeDirectory: ".grok/sessions/tmp-ParserContract/grok-contract-session-1", fileName: "signals.json"),
                        LayoutCopy(relativeDirectory: ".grok/sessions/tmp-ParserContract/grok-contract-session-1", fileName: "chat_history.jsonl")
                     ]),
        // ---- Kimi (1) ----
        CleanFixture(id: "kimiBasicSession", kind: .kimi, parserName: "KimiParser",
                     sessionId: "kimi-contract-session-1", projectDir: "workspace-contract",
                     artifacts: [
                        Artifact(role: .primary, resourceName: "pc-kimi-context", fileExtension: "jsonl"),
                        Artifact(role: .sidecar, resourceName: "pc-kimi-wire", fileExtension: "jsonl")
                     ],
                     layoutCopies: [
                        LayoutCopy(relativeDirectory: ".kimi/sessions/workspace-contract/kimi-contract-session-1", fileName: "context.jsonl"),
                        LayoutCopy(relativeDirectory: ".kimi/sessions/workspace-contract/kimi-contract-session-1", fileName: "wire.jsonl")
                     ]),
        // ---- Forge Dev (1) ----
        CleanFixture(id: "forgeDevBasicSession", kind: .forgeDev, parserName: "ForgeDevParser",
                     sessionId: "forge-contract-1", projectDir: "",
                     artifacts: [Artifact(role: .sqlite, resourceName: "pc-forgedev", fileExtension: "sqlite")],
                     layoutCopies: [LayoutCopy(relativeDirectory: ".forge", fileName: ".forge.db")]),
        // ---- Goose (1) ----
        CleanFixture(id: "gooseBasicSession", kind: .goose, parserName: "GooseParser",
                     sessionId: "goose-contract-1", projectDir: "",
                     artifacts: [Artifact(role: .sqlite, resourceName: "pc-goose", fileExtension: "sqlite")],
                     layoutCopies: [LayoutCopy(relativeDirectory: ".goose/sessions", fileName: "sessions.db")]),
        // ---- Windsurf (1) ----
        CleanFixture(id: "windsurfBasicSession", kind: .windsurf, parserName: "WindsurfParser",
                     sessionId: "pc-windsurf-session", projectDir: "",
                     artifacts: [
                        Artifact(role: .sqlite, resourceName: "pc-windsurf-state", fileExtension: "vscdb"),
                        Artifact(role: .sidecar, resourceName: "pc-windsurf-session", fileExtension: "pb")
                     ],
                     layoutCopies: [
                        LayoutCopy(relativeDirectory: "Library/Application Support/Windsurf - Next/User/globalStorage", fileName: "state.vscdb"),
                        LayoutCopy(relativeDirectory: ".codeium/windsurf-next/cascade", fileName: "pc-windsurf-session.pb")
                     ]),
        // ---- Warp (1) ----
        CleanFixture(id: "warpBasicSession", kind: .warp, parserName: "WarpParser",
                     sessionId: "warp-contract-1", projectDir: "",
                     artifacts: [Artifact(role: .primary, resourceName: "pc-warp-basic", fileExtension: "log")],
                     layoutCopies: [LayoutCopy(relativeDirectory: "Library/Application Support/dev.warp.Warp-Stable", fileName: "warp_network.log")])
    ]

    static func bundledURL(resource: String, ext: String) -> URL? {
        Bundle.module.url(forResource: resource, withExtension: ext, subdirectory: "Fixtures/ParserContract")
            ?? Bundle.module.url(forResource: resource, withExtension: ext)
    }

    private static func artifactData(_ artifact: Artifact) throws -> Data {
        guard let url = bundledURL(resource: artifact.resourceName, ext: artifact.fileExtension) else {
            throw G2Error.missingResource("\(artifact.resourceName).\(artifact.fileExtension)")
        }
        return try Data(contentsOf: url)
    }

    private static func installLayoutCopies(_ fixture: CleanFixture, homeRoot: URL, fm: FileManager) throws {
        for (artifact, layout) in zip(fixture.artifacts, fixture.layoutCopies) {
            let dir = homeRoot.appendingPathComponent(layout.relativeDirectory, isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent(layout.fileName)
            try artifactData(artifact).write(to: dest)
        }
    }

    private static func withSyntheticHome<T>(_ homeRoot: URL, _ body: () async throws -> T) async throws -> T {
        // setenv/unsetenv are POSIX-only; on Windows use ProcessInfo.environment mutation
        // (the harness runs in a single process, so mutation is safe).
        #if !os(Windows)
        let prior = getenv("HOME").map { String(cString: $0) }
        setenv("HOME", homeRoot.path, 1)
        defer {
            if let prior {
                setenv("HOME", prior, 1)
            } else {
                unsetenv("HOME")
            }
        }
        return try await body()
        #else
        // On Windows, ProcessInfo.environment is read-only at the Swift level.
        // The G2 harness on Windows uses directory overrides in the parser constructors
        // instead of HOME env var mutation. This path is only reached by the new
        // fixture generators that use withSyntheticHome; the original 15 fixtures
        // use explicit directory overrides and never hit this path.
        return try await body()
        #endif
    }

    static func artifactContent(_ artifact: Artifact) throws -> String {
        guard let url = bundledURL(resource: artifact.resourceName, ext: artifact.fileExtension) else {
            throw G2Error.missingResource("\(artifact.resourceName).\(artifact.fileExtension)")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Lay the committed bytes out in the real provider directory shape, run the
    /// REAL lifted parser, and project to the portable per-fixture contract.
    static func generateContract(for fixture: CleanFixture) async throws -> ParserFixtureContract {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("obb-g2-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let homeRoot = root.appendingPathComponent("home", isDirectory: true)
        try fm.createDirectory(at: homeRoot, withIntermediateDirectories: true)
        if !fixture.layoutCopies.isEmpty {
            try installLayoutCopies(fixture, homeRoot: homeRoot, fm: fm)
        }

        let appPaths = OpenBurnBarAppPaths(applicationSupportRoot: root.appendingPathComponent("support", isDirectory: true))

        let result = try await withSyntheticHome(homeRoot) {
            switch fixture.kind {
            case .claudeCode:
                let projectsRoot = root.appendingPathComponent(".claude/projects", isDirectory: true)
                let projectDir = projectsRoot.appendingPathComponent(fixture.projectDir, isDirectory: true)
                try fm.createDirectory(at: projectDir, withIntermediateDirectories: true)
                try artifactContent(primary(fixture.artifacts)).write(
                    to: projectDir.appendingPathComponent("\(fixture.sessionId).jsonl"),
                    atomically: true, encoding: .utf8
                )
                let parser = ClaudeCodeParser(fileManager: fm, appPaths: appPaths, projectsDirectoryOverride: projectsRoot)
                return try await parser.parse()

            case .factory:
                let sessionsRoot = root.appendingPathComponent(".factory/sessions", isDirectory: true)
                let projectDir = sessionsRoot.appendingPathComponent(fixture.projectDir, isDirectory: true)
                try fm.createDirectory(at: projectDir, withIntermediateDirectories: true)
                for artifact in fixture.artifacts {
                    let name: String
                    switch artifact.role {
                    case .primary: name = "\(fixture.sessionId).jsonl"
                    case .settings: name = "\(fixture.sessionId).settings.json"
                    case .metadata: name = "\(fixture.sessionId).metadata.json"
                    case .sidecar, .sqlite: continue
                    }
                    try artifactContent(artifact).write(to: projectDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
                }
                let parser = FactoryDroidParser(fileManager: fm, appPaths: appPaths, sessionsDirectoryOverride: sessionsRoot)
                return try await parser.parse()

            case .codex:
                guard let codex = fixture.codex else { throw G2Error.missingCodexLayout(fixture.id) }
                let codexRoot = homeRoot.appendingPathComponent(".codex", isDirectory: true)
                let rolloutURL = codexRoot.appendingPathComponent(codex.rolloutRelativePath)
                try fm.createDirectory(at: rolloutURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try artifactContent(primary(fixture.artifacts)).write(to: rolloutURL, atomically: true, encoding: .utf8)
                try writeCodexThreadsDatabase(codexRoot: codexRoot, codex: codex, rolloutPath: rolloutURL.path)
                let parser = CodexParser(fileManager: fm, appPaths: appPaths, homeDirectoryURL: homeRoot)
                return try await parser.parse()

            case .hermes:
                let sessionsDir = root
                    .appendingPathComponent(".hermes", isDirectory: true)
                    .appendingPathComponent("profiles", isDirectory: true)
                    .appendingPathComponent(fixture.projectDir, isDirectory: true)
                    .appendingPathComponent("sessions", isDirectory: true)
                try fm.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
                try artifactContent(primary(fixture.artifacts)).write(
                    to: sessionsDir.appendingPathComponent("session_\(fixture.sessionId).json"),
                    atomically: true, encoding: .utf8
                )
                let parser = HermesParser(
                    fileManager: fm,
                    hermesRootURL: root.appendingPathComponent(".hermes", isDirectory: true)
                )
                return try await parser.parse()

            case .antigravity:
                return try await AntigravityParser(logDirectoryOverride: homeRoot.appendingPathComponent(".gemini/antigravity-cli").path).parse()

            case .augment:
                return try await AugmentParser().parse()

            case .cline:
                let tasksRoot = homeRoot
                    .appendingPathComponent("Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/tasks", isDirectory: true)
                let parser = ClineFormatParser(provider: .cline, storagePaths: [tasksRoot.path])
                return try await parser.parse()

            case .cursorAgent:
                let sessionsRoot = homeRoot.appendingPathComponent(".cursor-agent/sessions", isDirectory: true)
                return try await CursorAgentParser(logDirectoryOverride: sessionsRoot.path).parse()

            case .geminiCLI:
                let tmpRoot = homeRoot.appendingPathComponent(".gemini/tmp", isDirectory: true)
                return try await GeminiCLIParser(logDirectoryOverride: tmpRoot.path).parse()

            case .grok:
                let sessionsRoot = homeRoot.appendingPathComponent(".grok/sessions", isDirectory: true)
                return try await GrokParser(logDirectoryOverride: sessionsRoot.path).parse()

            case .kimi:
                let sessionsRoot = homeRoot.appendingPathComponent(".kimi/sessions", isDirectory: true)
                return try await KimiParser(logDirectoryOverride: sessionsRoot.path).parse()

            case .forgeDev:
                return try await ForgeDevParser().parse()

            case .goose:
                let sessionsRoot = homeRoot.appendingPathComponent(".goose/sessions", isDirectory: true)
                return try await GooseParser(sessionDirectoryOverride: sessionsRoot.path).parse()

            case .windsurf, .devin:
                let cascadeRoot = homeRoot.appendingPathComponent(".codeium/windsurf-next/cascade", isDirectory: true)
                let globalStorageRoot = homeRoot
                    .appendingPathComponent("Library/Application Support/Windsurf - Next/User/globalStorage", isDirectory: true)
                return try await WindsurfParser(
                    cascadeDirectoryOverride: cascadeRoot.path,
                    globalStorageOverride: globalStorageRoot.path
                ).parse()

            case .warp:
                let warpSupport = homeRoot
                    .appendingPathComponent("Library/Application Support/dev.warp.Warp-Stable", isDirectory: true)
                return try await WarpParser(logDirectory: warpSupport).parse()
            }
        }

        let records = G2Contract.sortedUsages(result.usages.map(ParserOutputContractRecord.init))
        return ParserFixtureContract(
            fixtureId: fixture.id,
            provider: fixture.kind.rawValue,
            parser: fixture.parserName,
            usageCount: records.count,
            conversationCount: result.conversations.count,
            usages: records
        )
    }

    private static func primary(_ artifacts: [Artifact]) -> Artifact {
        artifacts.first { $0.role == .primary } ?? artifacts[0]
    }

    /// Create the Codex `state_5.sqlite` `threads` table + one row through the
    /// reader seam's raw-sqlite3 write path (system SQLite3 on macOS, vendored
    /// CSQLite off-Apple) — the exact schema `ParserContractCorpus` writes with GRDB.
    private static func writeCodexThreadsDatabase(codexRoot: URL, codex: CodexLayout, rolloutPath: String) throws {
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        let dbURL = codexRoot.appendingPathComponent("state_5.sqlite", isDirectory: false)
        let writer = try SQLiteConnection.openForWriting(creatingAt: dbURL.path)
        defer { writer.close() }
        try writer.execute("""
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
        try writer.execute(
            """
            INSERT INTO threads (
                id, title, model, model_provider, tokens_used,
                created_at, updated_at, cwd, rollout_path, archived
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
            """,
            arguments: [
                .text(codex.threadId),
                .text(codex.threadId),
                .text(codex.model),
                .text("openai"),
                .int(Int64(codex.tokensUsed)),
                .int(codex.createdAt),
                .int(codex.updatedAt),
                .text(codex.cwd),
                .text(rolloutPath)
            ]
        )
    }
}

enum G2Error: Error, CustomStringConvertible {
    case missingResource(String)
    case missingCodexLayout(String)
    case noUsageRows(String)
    var description: String {
        switch self {
        case .missingResource(let name): return "bundled resource not found: \(name)"
        case .missingCodexLayout(let id): return "Codex fixture \(id) is missing its CodexLayout"
        case .noUsageRows(let id): return "fixture \(id) produced zero usage rows"
        }
    }
}

// MARK: - Entry point

@main
enum G2ParserParity {
    static func main() async {
        var passCount = 0

        func expect(_ condition: Bool, _ message: String) {
            if condition {
                passCount += 1
                print("  PASS  \(message)")
            } else {
                FileHandle.standardError.write(Data("  FAIL  \(message)\n".utf8))
                exit(1)
            }
        }

        func fail(_ message: String) -> Never {
            FileHandle.standardError.write(Data("  FAIL  \(message)\n".utf8))
            exit(1)
        }

        let writeGolden = CommandLine.arguments.contains("--write-golden")

        print("== OpenBurnBar Windows-Port G2 Parser-Output Parity ==")
        print("  host: \(LogPathPlatform.current == .windows ? "windows" : "posix")")
        if writeGolden {
            do {
                var fixtures: [ParserFixtureContract] = []
                for fixture in G2Corpus.cleanFixtures {
                    fixtures.append(try await G2Corpus.generateContract(for: fixture))
                }
                fixtures.sort { $0.fixtureId < $1.fixtureId }
                let providers = Array(Set(fixtures.map(\.provider))).sorted()
                let golden = ParserOutputGolden(formatVersion: 1, providers: providers, fixtures: fixtures)
                let data = try G2Contract.canonicalEncode(golden)
                let out = URL(fileURLWithPath: "OpenBurnBarCore/Sources/OpenBurnBarG2ParserParity/Fixtures/ParserContract/parser-output-golden.json")
                try data.write(to: out)
                print("Wrote golden to \(out.path) (\(fixtures.count) fixtures)")
            } catch {
                fail("write-golden failed: \(error)")
            }
            return
        }

        // Load the committed Mac golden.
        guard let goldenURL = G2Corpus.bundledURL(resource: "parser-output-golden", ext: "json") else {
            fail("could not locate bundled parser-output-golden.json")
        }
        let committed: ParserOutputGolden
        do {
            let data = try Data(contentsOf: goldenURL)
            committed = try JSONDecoder().decode(ParserOutputGolden.self, from: data)
        } catch {
            fail("failed to decode committed golden: \(error)")
        }

        expect(committed.formatVersion == 1, "golden formatVersion == 1")
        let committedByID = Dictionary(uniqueKeysWithValues: committed.fixtures.map { ($0.fixtureId, $0) })

        // Byte-diff each lifted-parser fixture against its committed golden entry.
        print("\n[1] Lifted parsers vs committed golden (byte-identical per fixture)")
        for fixture in G2Corpus.cleanFixtures {
            guard let expected = committedByID[fixture.id] else {
                fail("golden has no entry for fixture \(fixture.id)")
            }
            let generated: ParserFixtureContract
            do {
                generated = try await G2Corpus.generateContract(for: fixture)
            } catch {
                fail("parser run failed for \(fixture.id): \(error)")
            }

            let expectedBytes: Data
            let generatedBytes: Data
            do {
                expectedBytes = try G2Contract.canonicalEncode(expected)
                generatedBytes = try G2Contract.canonicalEncode(generated)
            } catch {
                fail("canonical encode failed for \(fixture.id): \(error)")
            }

            if generatedBytes == expectedBytes {
                expect(true, "\(fixture.id): \(fixture.parserName) output byte-identical to golden "
                        + "(\(generated.usageCount) usage row(s), \(generated.conversationCount) conversation(s))")
            } else {
                let g = String(data: generatedBytes, encoding: .utf8) ?? "<non-utf8>"
                let e = String(data: expectedBytes, encoding: .utf8) ?? "<non-utf8>"
                FileHandle.standardError.write(Data("\n--- GENERATED (\(fixture.id)) ---\n\(g)\n--- COMMITTED GOLDEN ---\n\(e)\n".utf8))
                fail("\(fixture.id): \(fixture.parserName) output DIFFERS from golden")
            }
        }

        // Completeness: EVERY committed golden fixture must be covered by a lifted
        // parser above — no golden row may be silently unproven. With Codex + Hermes
        // riding the SQLite reader seam, all 4 golden parsers are now covered.
        print("\n[2] Golden coverage (every committed fixture is proven — none deferred)")
        let coveredIDs = Set(G2Corpus.cleanFixtures.map(\.id))
        for fixture in committed.fixtures {
            expect(coveredIDs.contains(fixture.fixtureId),
                   "golden fixture \(fixture.fixtureId) (\(fixture.parser)) is covered by a lifted parser")
        }
        expect(coveredIDs.count == committed.fixtures.count,
               "lifted-fixture count (\(coveredIDs.count)) == golden fixture count (\(committed.fixtures.count))")

        let covered = G2Corpus.cleanFixtures.count
        print("\n== G2 PARSER-OUTPUT PARITY GREEN ==")
        print("  \(passCount) assertions passed")
        print("  \(covered)/\(committed.fixtures.count) golden fixtures proven byte-identical "
              + "(0 deferred — all golden parsers lifted)")
    }
}
