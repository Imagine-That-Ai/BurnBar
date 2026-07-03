import Foundation
@testable import OpenBurnBar

// MARK: - Parser-output contract format (VAL-P0-HARNESS-024)
//
// A portable, deterministic projection of parser output. This is the exact
// surface a future Windows parser port must reproduce BYTE-IDENTICALLY (the G2
// headline of the Windows-port master plan): given the same on-disk fixture
// corpus, a Windows parser must emit the same `TokenUsage` accounting, session
// identity, model, and cost as macOS does today.
//
// Design rules that make the projection byte-stable across languages/platforms:
//   • Exclude every non-reproducible field: the random `TokenUsage.id` (UUID),
//     wall-clock `startTime`/`endTime`/`createdAt`, and the runtime device ids.
//   • Represent cost as an INTEGER count of nano-USD (`round(costUSD * 1e9)`,
//     half-away-from-zero). Integers have no float text-formatting drift, so the
//     same number renders identically in Swift, C#, Kotlin, and TS.
//   • Serialize with sorted keys + stable pretty-printing so the committed golden
//     is a stable text diff.
//
// The spec lives at `docs/windows-port/PARSER_OUTPUT_CONTRACT.md`.

/// One parsed `TokenUsage` row projected to the portable, byte-stable contract.
struct ParserOutputContractRecord: Codable, Equatable, Hashable {
    /// `AgentProvider.rawValue` (e.g. `"Claude Code"`, `"Codex"`).
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
    /// Cost as an integer count of nano-USD: `round(costUSD * 1_000_000_000)`,
    /// rounding half away from zero. Divide by 1e9 to recover USD. Integer form
    /// is byte-identical across platforms (no `%f` formatting drift).
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
        costNanoUSD = ParserOutputContract.nanoUSD(usage.costUSD)
        usageSource = usage.usageSource.rawValue
        provenanceMethod = usage.provenanceMethod.rawValue
        provenanceConfidence = usage.provenanceConfidence.rawValue
        estimatorVersion = usage.estimatorVersion
    }
}

/// The contract for a single fixture: the parser it targets and every usage row
/// (deterministically ordered) that parser produced over the fixture.
struct ParserFixtureContract: Codable, Equatable {
    let fixtureId: String
    let provider: String
    let parser: String
    let usageCount: Int
    let conversationCount: Int
    let usages: [ParserOutputContractRecord]
}

/// The committed Mac golden: every fixture's contract, ordered by `fixtureId`.
struct ParserOutputGolden: Codable, Equatable {
    /// Bumped when the contract *shape* changes (not when parser output drifts).
    let formatVersion: Int
    /// `AgentProvider` raw values contributing rows, sorted — a cheap human index.
    let providers: [String]
    let fixtures: [ParserFixtureContract]
}

// MARK: - Serialization + numeric rules

enum ParserOutputContract {
    /// Current on-disk contract shape.
    static let formatVersion = 1

    /// `round(usd * 1e9)` half-away-from-zero, clamped to a sane range so a NaN
    /// or absurd value can never poison the golden.
    static func nanoUSD(_ usd: Double) -> Int {
        guard usd.isFinite else { return 0 }
        let scaled = (usd * 1_000_000_000).rounded(.toNearestOrAwayFromZero)
        if scaled >= Double(Int.max) { return Int.max }
        if scaled <= Double(Int.min) { return Int.min }
        return Int(scaled)
    }

    /// Deterministic total ordering of usage rows within a fixture so parser
    /// directory-iteration order can never perturb the golden.
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

    /// Canonical text encoding of the golden (sorted keys + stable pretty-print),
    /// terminated by a trailing newline so the committed file is a clean diff.
    static func encode(_ golden: ParserOutputGolden) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(golden)
        data.append(0x0A)
        return data
    }

    static func decode(_ data: Data) throws -> ParserOutputGolden {
        try JSONDecoder().decode(ParserOutputGolden.self, from: data)
    }

    /// Assemble the golden from already-computed per-fixture contracts.
    static func golden(from fixtures: [ParserFixtureContract]) -> ParserOutputGolden {
        let ordered = fixtures.sorted { $0.fixtureId < $1.fixtureId }
        let providers = Set(ordered.map(\.provider)).sorted()
        return ParserOutputGolden(
            formatVersion: formatVersion,
            providers: providers,
            fixtures: ordered
        )
    }
}
