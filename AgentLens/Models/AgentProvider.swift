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
    /// Filesystem directory where the provider writes session logs the
    /// macOS file watcher can scrape. Some providers (e.g. `.openAI`) have
    /// no local logs at all — they reuse another path so the file watcher's
    /// exhaustive switch never crashes; the `filePattern` for those entries
    /// pins a non-matching glob so no files are ever read.
    var logDirectory: String {
        switch self {
        case .factory: return "~/.factory/sessions"
        case .claudeCode: return "~/.claude/projects"
        case .copilot: return "~/.copilot/session-state"
        case .aider: return "~/.aider"
        case .cursor: return "~/.cursor/ai-tracking"
        // OpenAI is an org-billing identity (refreshed via API), not a local
        // log source. Reuse the Codex log dir so the file watcher's switch
        // doesn't crash when an OpenAI account row is iterated; the parser
        // never matches files under it because the OpenAI adapter pulls
        // remotely instead of parsing local logs.
        case .openAI: return "~/.codex"
        case .codex: return "~/.codex"
        case .zai: return "~/.factory/sessions"
        case .minimax: return "~/.factory/sessions"
        case .kimi: return "~/.kimi/sessions"
        case .cline: return "~/Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/tasks"
        case .kiloCode: return "~/Library/Application Support/Code/User/globalStorage/kilocode.kilo-code/tasks"
        case .rooCode: return "~/Library/Application Support/Code/User/globalStorage/rooveterinaryinc.roo-cline/tasks"
        case .forgeDev: return "~/.forge/sessions"
        case .augment: return "~/Library/Application Support/Code/User/globalStorage/augment.vscode-augment"
        case .hermes: return "~/.hermes/sessions"
        case .geminiCLI: return "~/.gemini/tmp"
        case .goose: return "~/.local/share/goose/sessions"
        case .openClaw: return "~/.openclaw/sessions"
        case .ollama: return "~/.ollama/logs"
        case .windsurf: return "~/Library/Application Support/Windsurf - Next/User/globalStorage"
        case .warp: return "~/Library/Application Support/dev.warp.Warp-Stable"
        }
    }

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
        case .codex: return "state_5.sqlite"
        case .zai: return "*.jsonl"
        case .minimax: return "*.jsonl"
        case .kimi: return "*.jsonl"
        case .cline, .kiloCode, .rooCode: return "*.json"
        case .forgeDev, .hermes: return "*.jsonl"
        case .augment: return "*.jsonl"
        case .geminiCLI: return "*.json"
        case .goose: return "sessions.db"
        case .openClaw: return "*.jsonl"
        case .ollama: return "server*.log"
        case .windsurf: return "state.vscdb"
        case .warp: return "warp_network*.log"
        }
    }

    /// How well the macOS app supports this provider's local data.
    var supportLevel: ProviderSupportLevel {
        switch self {
        case .factory, .claudeCode, .codex, .aider, .cline, .kiloCode, .rooCode, .forgeDev, .hermes, .geminiCLI, .goose:
            return .supported
        // OpenAI is supported via the official org usage endpoint — no log
        // parsing, but exact aggregate counts.
        case .openAI:
            return .supported
        case .openClaw, .copilot, .kimi, .zai, .minimax, .cursor, .windsurf, .warp, .ollama:
            return .partial
        case .augment:
            return .unsupported
        }
    }

    /// Confidence the macOS app assigns to token counts derived from this
    /// provider's local artifacts.
    var dataConfidence: DataConfidence {
        switch self {
        case .factory, .claudeCode, .codex, .kimi, .aider, .cline, .kiloCode, .rooCode, .forgeDev, .hermes, .geminiCLI, .goose, .openClaw:
            return .exact
        // OpenAI exposes exact tokens-used per org via the usage API.
        case .openAI:
            return .exact
        case .zai, .minimax, .copilot, .cursor, .windsurf, .warp, .ollama:
            return .estimated
        case .augment:
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
    /// Aggregate cache hit rate signal across all rows in this model summary.
    let cacheEfficiency: OpenBurnBarCore.CacheEfficiency

    var formattedCost: String {
        totalCost.formatAsCost()
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
