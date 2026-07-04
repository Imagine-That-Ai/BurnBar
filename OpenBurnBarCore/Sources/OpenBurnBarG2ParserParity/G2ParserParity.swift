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
//   2. For every golden-covered fixture whose parser has been lifted into the
//      Foundation-only Engine, it lays the committed fixture bytes out in the real
//      provider directory shape inside a fresh temp root, runs the REAL lifted
//      parser (`ClaudeCodeParser` / `FactoryDroidParser` from `OpenBurnBarCore`),
//      and projects the `[TokenUsage]` result to the portable contract
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
// Scope (this file): the CLEAN, Foundation-only parsers — ClaudeCode (8 fixtures)
// + FactoryDroid (2 fixtures) = 10 golden rows. The two SQLite-backed parsers
// (Codex + Hermes) ride the SQLite reader seam (a separately-scoped follow-up —
// see the `pendingSeamFixtures` note below); their fixtures are already bundled so
// the corpus is complete.
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
import OpenBurnBarCore

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
    enum Role { case primary, settings, metadata }
    let role: Role
    let resourceName: String
    let fileExtension: String
}

private struct CleanFixture {
    enum Kind: String { case claudeCode = "Claude Code"; case factory = "Factory" }
    let id: String
    let kind: Kind
    let parserName: String
    let sessionId: String
    let projectDir: String
    let artifacts: [Artifact]
}

private enum G2Corpus {
    /// Encoded project dirs, identical to the macOS corpus.
    static let claudeProjectDir = "-Users-test-Documents-ParserContract"
    static let factoryProjectDir = "ParserContract"

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
                     ])
    ]

    /// Golden fixtures still awaiting the SQLite reader seam (Codex + Hermes). Their
    /// bytes are bundled; the harness reports them as pending rather than skipping
    /// silently, so the deferred coverage is visible in the CI log.
    static let pendingSeamFixtures = [
        "codexRolloutSession", "codexRolloutSessionWithLastUsageOnly",
        "codexRolloutSessionWithPartialTokenCountAndDeltas",
        "hermesSessionSnapshot", "hermesToolHeavySessionSnapshot"
    ]

    static func bundledURL(resource: String, ext: String) -> URL? {
        Bundle.module.url(forResource: resource, withExtension: ext, subdirectory: "Fixtures/ParserContract")
            ?? Bundle.module.url(forResource: resource, withExtension: ext)
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

        let appPaths = OpenBurnBarAppPaths(applicationSupportRoot: root.appendingPathComponent("support", isDirectory: true))
        let result: ParseResult

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
            result = try await parser.parse()

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
                }
                try artifactContent(artifact).write(to: projectDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
            let parser = FactoryDroidParser(fileManager: fm, appPaths: appPaths, sessionsDirectoryOverride: sessionsRoot)
            result = try await parser.parse()
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
}

enum G2Error: Error, CustomStringConvertible {
    case missingResource(String)
    var description: String {
        switch self {
        case .missingResource(let name): return "bundled resource not found: \(name)"
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

        print("== OpenBurnBar Windows-Port G2 Parser-Output Parity ==")
        print("  host: \(LogPathPlatform.current == .windows ? "windows" : "posix")")

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

        // Report the SQLite-seam fixtures still to be lifted (visible, not silent).
        print("\n[2] Deferred (SQLite reader seam — Codex + Hermes)")
        for id in G2Corpus.pendingSeamFixtures {
            let present = committedByID[id] != nil
            expect(present, "golden entry present for deferred fixture \(id) (bundled; awaiting seam)")
        }

        let covered = G2Corpus.cleanFixtures.count
        print("\n== G2 PARSER-OUTPUT PARITY GREEN ==")
        print("  \(passCount) assertions passed")
        print("  \(covered)/\(committed.fixtures.count) golden fixtures proven byte-identical "
              + "(\(G2Corpus.pendingSeamFixtures.count) deferred to the SQLite reader seam)")
    }
}
