import SwiftUI
import Foundation
import OpenBurnBarCore

// MARK: - Module Aliases (Mac side ↔ OpenBurnBarCore canonical)
//
// `AgentProvider`, `TokenUsage`, and the three usage-provenance enums live in
// `OpenBurnBarCore` so the macOS app, iOS/iPad app, and shared core agree on
// rawValues, Codable keys, and accessor names. Re-exporting them here keeps
// the ~100 macOS call sites that reference `AgentProvider` (etc.) without an
// explicit `OpenBurnBarCore.` qualifier — they resolve through these
// typealiases. Mac-only behaviors (log directories, file patterns, support
// levels) live as extensions on the package types further down in this file.

typealias AgentProvider = OpenBurnBarCore.AgentProvider
typealias TokenUsage = OpenBurnBarCore.TokenUsage
typealias UsageProvenanceMethod = OpenBurnBarCore.UsageProvenanceMethod
typealias UsageProvenanceConfidence = OpenBurnBarCore.UsageProvenanceConfidence
typealias UsageSource = OpenBurnBarCore.UsageSource
typealias UsageExecutionSourceKind = OpenBurnBarCore.UsageExecutionSourceKind
typealias EscrowDeviceTrustState = OpenBurnBarCore.EscrowDeviceTrustState

// MARK: - Provider Support Level (Mac-only)

enum ProviderSupportLevel {
    /// Full token data parsed from logs (exact counts)
    case supported
    /// Token data is estimated or derived from heuristics
    case partial
    /// Parser exists but returns empty — no real implementation yet
    case unsupported
}

// MARK: - Data Confidence (Mac-only)

enum DataConfidence {
    /// Token counts come directly from API/log data
    case exact
    /// Token counts are derived from heuristics (e.g. character count)
    case estimated
    /// No data available
    case unavailable
}

// MARK: - Mac-only AgentProvider behaviors

/// Mac-only extensions on the canonical `OpenBurnBarCore.AgentProvider`.
///
/// These describe how the macOS app reads local provider artifacts on disk
/// and how it grades the resulting token data. The mobile target doesn't
/// watch local logs, so these accessors only ship on macOS.
extension AgentProvider {
    // `logDirectory` + `logDirectoryMacForm` moved to OpenBurnBarCore
    // (SharedModels/AgentProvider+LogDirectory.swift) for the Windows-port G2
    // parser lift; consumed here via `import OpenBurnBarCore`.

    /// Glob pattern paired with `logDirectory` that the file watcher uses
    /// to discover session log files for the provider.
    var filePattern: String {
        switch self {
        case .factory: return "*.jsonl"
        case .claudeCode: return "*.jsonl"
        case .copilot: return "*.jsonl"
        case .aider: return "*.jsonl"
        case .cursor: return "*.db"
        // OpenAI usage data flows through the OpenAI organization usage API,
        // not local log files. Pin a non-matching pattern so the file
        // watcher never spuriously reads files for this provider.
        case .openAI: return "openai-no-local-logs"
        case .deepSeek: return "deepseek-no-local-logs"
        case .codex: return "state_5.sqlite"
        case .openCode: return "opencode.db"
        case .zai: return "*.jsonl"
        case .minimax: return "*.jsonl"
        case .kimi: return "*.jsonl"
        case .cline, .kiloCode, .rooCode: return "*.json"
        case .forgeDev, .hermes: return "*.jsonl"
        case .piAgent: return "*.jsonl"
        case .augment: return "*.jsonl"
        case .geminiCLI: return "*.json"
        case .antigravity: return "*.jsonl"
        case .cursorAgent: return "*.jsonl"
        case .goose: return "sessions.db"
        case .openClaw: return "*.jsonl"
        case .openClaude: return "*.jsonl"
        case .omp: return "*.jsonl"
        case .ollama: return "server*.log"
        case .windsurf: return "state.vscdb"
        case .devin: return "state.vscdb"
        case .warp: return "warp_network*.log"
        case .xAI: return "summary.json"
        case .mimo: return "mimo-no-local-logs"
        case .openBurnBar: return "openburnbar-no-local-logs"
        case .junie, .primeAgent, .muse: return "*.jsonl"
        case .fx: return "*.json"
        }
    }

    /// How well the macOS app supports this provider's local data.
    var supportLevel: ProviderSupportLevel {
        switch self {
        case .factory, .claudeCode, .codex, .openCode, .omp, .aider, .cline, .kiloCode, .rooCode, .forgeDev, .hermes, .geminiCLI, .antigravity, .goose, .xAI, .cursorAgent, .openClaude, .junie, .primeAgent, .muse, .fx:
            return .supported
        // OpenAI is supported via the official org usage endpoint — no log
        // parsing, but exact aggregate counts.
        case .openAI, .deepSeek, .openBurnBar:
            return .supported
        case .mimo:
            return .supported
        case .openClaw, .copilot, .kimi, .zai, .minimax, .cursor, .windsurf, .devin, .warp, .ollama, .piAgent:
            return .partial
        case .augment:
            return .unsupported
        }
    }

    /// Confidence the macOS app assigns to token counts derived from this
    /// provider's local artifacts.
    var dataConfidence: DataConfidence {
        switch self {
        case .factory, .claudeCode, .codex, .openCode, .omp, .kimi, .aider, .cline, .kiloCode, .rooCode, .forgeDev, .hermes, .geminiCLI, .antigravity, .goose, .openClaw, .piAgent, .xAI, .cursorAgent, .openClaude, .junie, .primeAgent, .muse, .fx:
            return .exact
        // OpenAI exposes exact tokens-used per org via the usage API.
        case .openAI, .deepSeek, .openBurnBar:
            return .exact
        case .mimo:
            return .exact
        case .zai, .minimax, .copilot, .cursor, .windsurf, .warp, .ollama:
            return .estimated
        // Devin ships `"ingestion": "unavailable"` in
        // contracts/provider-ingestion-catalog.json — no session parser is registered, so
        // there is no local artifact to grade. Claiming `.exact` would paint a green EXACT
        // badge and suppress the aggregate estimated-data warning over no data at all.
        case .augment, .devin:
            return .unavailable
        }
    }
}

// MARK: - Daily Summary

struct DailyUsageSummary: Identifiable, Hashable {
    let id = UUID()
    let date: Date
    let provider: AgentProvider
    let totalInputTokens: Int
    let totalOutputTokens: Int
    let totalCacheCreationTokens: Int
    let totalCacheReadTokens: Int
    let totalTokens: Int
    let totalCost: Double
    let sessionCount: Int
    let models: [String]
    
    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: date)
    }
}

// MARK: - Provider Summary

/// Aggregated usage for a provider, optionally annotated with provenance metadata.
///
/// VAL-CROSS-005: Provenance-aware reporting contracts.
/// Reporting surfaces expose provenance/confidence semantics at the contract-defined
/// granularity (row-level where available; aggregate fallback metadata otherwise).
struct ProviderSummary: Identifiable, Hashable {
    let id = UUID()
    let provider: AgentProvider
    let totalCost: Double
    let totalTokens: Int
    let totalInputTokens: Int
    let totalOutputTokens: Int
    let sessionCount: Int
    let modelBreakdown: [ModelUsage]
    /// The dominant (highest-precedence) provenance confidence across all rows in this summary.
    /// Exposed so reporting consumers can distinguish exact from fallback-derived values.
    let provenanceConfidence: UsageProvenanceConfidence
    /// The dominant provenance method across all rows in this summary.
    let provenanceMethod: UsageProvenanceMethod
    /// Whether any row contributing to this summary has estimated (non-exact/derived-exact) provenance.
    /// This reflects mixed-confidence composition rather than dominant-row confidence.
    let hasEstimatedContributions: Bool
    /// Aggregate cache hit rate signal across all rows feeding this summary.
    /// Drives `UnifiedCacheHitRateBadge` next to provider rows in dashboard surfaces.
    let cacheEfficiency: OpenBurnBarCore.CacheEfficiency

    var formattedCost: String {
        totalCost.formatAsCost()
    }

    /// Whether this summary contains any estimated (non-exact) data.
    var hasEstimatedData: Bool {
        hasEstimatedContributions
    }
}

// MARK: - Credential Summary

/// Aggregated usage for a single provider credential (API key / account slot / OAuth identity).
///
/// `CredentialSummary` slices `token_usage` by `(provider, providerAccountID)` so dashboards
/// and budget logic can answer "where did this specific key spend?" — the dimension the
/// existing `ProviderSummary` collapses. The `accountID` here is the same hashed partition
/// token persisted in `token_usage.providerAccountID` (see `UsageStore.usagePartitionToken`),
/// and `accountLabel` is the human-readable counterpart from `token_usage.providerAccountLabel`.
struct CredentialSummary: Identifiable, Hashable {
    let id = UUID()
    /// Display provider (drives logo, theme, copy). Mirrors `ProviderSummary.provider`.
    let provider: AgentProvider
    /// Stable hashed partition token identifying this credential within the provider scope.
    /// `nil` when usage rows for this provider arrived without an account ID (e.g. legacy logs).
    let accountID: String?
    /// User-facing label for the credential. Falls back to a synthesized name when the row
    /// arrived without a label (e.g. "anthropic · default").
    let accountLabel: String
    /// Where this credential's secret material lives. Drives the storage badge in the UI.
    let accountSource: ProviderAccountStorageScope?
    let totalCost: Double
    let totalTokens: Int
    let totalInputTokens: Int
    let totalOutputTokens: Int
    let sessionCount: Int
    let modelBreakdown: [ModelUsage]
    /// The dominant provenance confidence across rows for this credential.
    let provenanceConfidence: UsageProvenanceConfidence
    /// The dominant provenance method across rows for this credential.
    let provenanceMethod: UsageProvenanceMethod
    /// Whether any row contributing to this credential's spend used estimated provenance.
    let hasEstimatedContributions: Bool
    /// Aggregate cache hit-rate signal — feeds `UnifiedCacheHitRateBadge` in the lane.
    let cacheEfficiency: OpenBurnBarCore.CacheEfficiency

    var formattedCost: String {
        totalCost.formatAsCost()
    }

    /// Whether this summary contains any estimated (non-exact) data.
    var hasEstimatedData: Bool {
        hasEstimatedContributions
    }

    /// Stable identity key for grouping / lookup — `(providerID, accountID ?? "default")`.
    /// Independent of `id` (a per-instance UUID) so the same logical credential keeps
    /// the same key across view refreshes.
    var stableKey: String {
        "\(provider.rawValue)#\(accountID ?? "default")"
    }
}

// MARK: - Project Spend Summary

/// Aggregated usage for a single project (free-text `projectName` populated by log parsers).
///
/// Slices `token_usage` by `projectName` so dashboards and budget logic can answer
/// "where did this project's money go?" — a dimension already in every row but not
/// surfaced as an aggregate in any view today. Provider and model breakdowns mirror
/// the shape of `ProviderSummary.modelBreakdown` and `ModelSummary.providerBreakdown`.
struct ProjectSpendSummary: Identifiable, Hashable {
    let id = UUID()
    /// Display name (the raw `token_usage.projectName` — free text, not normalized).
    let projectName: String
    let totalCost: Double
    let totalTokens: Int
    let totalInputTokens: Int
    let totalOutputTokens: Int
    let sessionCount: Int
    /// Which providers contributed spend to this project (ranked by cost).
    let providerBreakdown: [ProviderUsage]
    /// Which models contributed spend to this project (ranked by cost).
    let modelBreakdown: [ModelUsage]
    /// The dominant provenance confidence across rows for this project.
    let provenanceConfidence: UsageProvenanceConfidence
    /// The dominant provenance method across rows for this project.
    let provenanceMethod: UsageProvenanceMethod
    /// Whether any row contributing to this project's spend used estimated provenance.
    let hasEstimatedContributions: Bool
    /// Aggregate cache hit-rate signal across rows in this project.
    let cacheEfficiency: OpenBurnBarCore.CacheEfficiency

    var formattedCost: String {
        totalCost.formatAsCost()
    }

    /// Whether this summary contains any estimated (non-exact) data.
    var hasEstimatedData: Bool {
        hasEstimatedContributions
    }
}

// MARK: - Model Usage

/// Aggregated usage for a specific model within a provider summary.
///
/// VAL-CROSS-005: Provenance-aware reporting contracts.
/// Model-level breakdown includes provenance metadata so consumers can audit
/// whether values came from exact provider data or fallback estimation.
struct ModelUsage: Identifiable, Hashable {
    let id = UUID()
    let modelName: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationTokens: Int
    let cacheReadTokens: Int
    let reasoningTokens: Int
    let totalTokens: Int
    let cost: Double
    let percentage: Double
    /// The dominant provenance confidence for this model's rows.
    let provenanceConfidence: UsageProvenanceConfidence
    /// The dominant provenance method for this model's rows.
    let provenanceMethod: UsageProvenanceMethod
    /// Whether any row contributing to this model's usage has estimated (non-exact/derived-exact) provenance.
    /// This reflects mixed-confidence composition rather than dominant-row confidence.
    let hasEstimatedContributions: Bool

    /// Whether this model usage contains any estimated (non-exact) data.
    var hasEstimatedData: Bool {
        hasEstimatedContributions
    }

    /// Per-row `CacheEfficiency` projection matching `TokenUsage` contract.
    var cacheEfficiency: OpenBurnBarCore.CacheEfficiency {
        OpenBurnBarCore.CacheEfficiency(
            inputTokens: inputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens
        )
    }
}

// MARK: - Dashboard View Mode

enum DashboardViewMode: String, CaseIterable, Identifiable {
    case agents = "Agents"
    case models = "Models"
    var id: String { rawValue }
    var displayName: String { rawValue }
    var icon: String {
        switch self {
        case .agents: return "cpu"
        case .models: return "cube.transparent"
        }
    }
}

// MARK: - Model Summary

struct ModelSummary: Identifiable, Hashable {
    let id = UUID()
    let modelName: String
    let displayName: String
    let totalCost: Double
    let totalTokens: Int
    let totalInputTokens: Int
    let totalOutputTokens: Int
    let sessionCount: Int
    let providerBreakdown: [ProviderUsage]
    let executionSourceBreakdown: [ExecutionSourceUsage]
    /// Aggregate cache hit rate signal across all rows in this model summary.
    let cacheEfficiency: OpenBurnBarCore.CacheEfficiency

    init(
        modelName: String,
        displayName: String,
        totalCost: Double,
        totalTokens: Int,
        totalInputTokens: Int,
        totalOutputTokens: Int,
        sessionCount: Int,
        providerBreakdown: [ProviderUsage],
        executionSourceBreakdown: [ExecutionSourceUsage] = [],
        cacheEfficiency: OpenBurnBarCore.CacheEfficiency
    ) {
        self.modelName = modelName
        self.displayName = displayName
        self.totalCost = totalCost
        self.totalTokens = totalTokens
        self.totalInputTokens = totalInputTokens
        self.totalOutputTokens = totalOutputTokens
        self.sessionCount = sessionCount
        self.providerBreakdown = providerBreakdown
        self.executionSourceBreakdown = executionSourceBreakdown
        self.cacheEfficiency = cacheEfficiency
    }

    var formattedCost: String {
        totalCost.formatAsCost()
    }
}

// MARK: - Execution Source Usage (for model breakdown)

struct ExecutionSourceUsage: Identifiable, Hashable {
    var id: String { executionSourceID }
    let executionSourceID: String
    let name: String
    let kind: UsageExecutionSourceKind
    let confidence: UsageProvenanceConfidence
    let sessionCount: Int
    let totalTokens: Int
    let cost: Double
    let percentage: Double
    let cacheEfficiency: OpenBurnBarCore.CacheEfficiency

    static func aggregate(_ usages: [TokenUsage], totalCost: Double) -> [ExecutionSourceUsage] {
        Dictionary(grouping: usages, by: \.executionSourceID)
            .map { sourceID, rows in
                let cost = rows.reduce(0) { $0 + $1.cost }
                return ExecutionSourceUsage(
                    executionSourceID: sourceID,
                    name: rows.first(where: { $0.executionSourceName != "Unknown" })?.executionSourceName
                        ?? rows.first?.executionSourceName
                        ?? "Unknown",
                    kind: rows.first(where: { $0.executionSourceKind != .unknown })?.executionSourceKind
                        ?? .unknown,
                    confidence: rows.map(\.executionSourceConfidence).max() ?? .unknown,
                    sessionCount: rows.count,
                    totalTokens: rows.reduce(0) { $0 + $1.totalTokens },
                    cost: cost,
                    percentage: totalCost > 0 ? (cost / totalCost) * 100 : 0,
                    cacheEfficiency: CacheEfficiency.aggregate(rows)
                )
            }
            .sorted { $0.cost > $1.cost }
    }
}

// MARK: - Provider Usage (for model breakdown)

struct ProviderUsage: Identifiable, Hashable {
    let id = UUID()
    let provider: AgentProvider
    let sessionCount: Int
    let totalTokens: Int
    let cost: Double
    let percentage: Double
    /// Aggregate cache hit rate signal across this provider's contribution to a model summary.
    let cacheEfficiency: OpenBurnBarCore.CacheEfficiency
}

// MARK: - Cache Efficiency Aggregation

extension OpenBurnBarCore.CacheEfficiency {
    /// Sums the input/cache-creation/cache-read tokens across `usages` so a
    /// single `CacheEfficiency` value can represent a provider, model, or
    /// session group. Returns `.zero` for an empty input.
    ///
    /// Mirrors the canonical `CacheEfficiency` shape from `OpenBurnBarCore`;
    /// this aggregation extension is Mac-only because it operates on the Mac
    /// `TokenUsage` row type. The mobile target uses an analogous helper on
    /// the package's `TokenUsage`.
    static func aggregate(_ usages: [TokenUsage]) -> OpenBurnBarCore.CacheEfficiency {
        guard !usages.isEmpty else { return .zero }
        var input = 0
        var creation = 0
        var read = 0
        for usage in usages {
            input += max(0, usage.inputTokens)
            creation += max(0, usage.cacheCreationTokens)
            read += max(0, usage.cacheReadTokens)
        }
        return OpenBurnBarCore.CacheEfficiency(
            inputTokens: input,
            cacheCreationTokens: creation,
            cacheReadTokens: read
        )
    }
}

extension TokenUsage {
    /// Per-row `CacheEfficiency` projection that keeps row-level cache hit
    /// rate badges (Session Detail, History) using the same canonical type
    /// as the aggregated provider/model summaries.
    var cacheEfficiency: OpenBurnBarCore.CacheEfficiency {
        OpenBurnBarCore.CacheEfficiency(
            inputTokens: inputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens
        )
    }
}
