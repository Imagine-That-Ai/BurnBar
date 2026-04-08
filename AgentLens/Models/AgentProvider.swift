import SwiftUI
import Foundation

// MARK: - Provider Support Level

enum ProviderSupportLevel {
    /// Full token data parsed from logs (exact counts)
    case supported
    /// Token data is estimated or derived from heuristics
    case partial
    /// Parser exists but returns empty — no real implementation yet
    case unsupported
}

// MARK: - Data Confidence

enum DataConfidence {
    /// Token counts come directly from API/log data
    case exact
    /// Token counts are derived from heuristics (e.g. character count)
    case estimated
    /// No data available
    case unavailable
}

// MARK: - Usage Provenance Method

/// Describes how token usage values were obtained for a given row.
/// Used alongside `UsageProvenanceConfidence` to audit exact vs estimated origin.
enum UsageProvenanceMethod: String, Codable, Hashable, CaseIterable, Sendable {
    /// Token counts parsed directly from provider logs or API responses.
    case providerLog = "provider_log"
    /// Token counts from a connector bridge (e.g. Cursor connector).
    case connectorBridge = "connector_bridge"
    /// Token counts from the daemon (e.g. OpenBurnBar daemon events).
    case daemonBridge = "daemon_bridge"
    /// Token counts from in-app chat session tracking.
    case inAppChat = "in_app_chat"
    /// Token counts from a billing/provider usage API.
    case billingAPI = "billing_api"
    /// Token counts derived from character/content heuristics when exact data is unavailable.
    case heuristicEstimate = "heuristic_estimate"
    /// Token counts from cloud sync (remote device), preserving original provenance.
    case cloudSync = "cloud_sync"
    /// Provenance is unknown (legacy rows or data with unclear origin).
    case unknown = "unknown"
}

// MARK: - Usage Provenance Confidence

/// Confidence level for the provenance of a token usage row.
/// Ordered from most to least authoritative. Used to prevent downgrades.
enum UsageProvenanceConfidence: String, Codable, Hashable, CaseIterable, Comparable, Sendable {
    /// Token counts are exact and authoritative (from provider logs, APIs, or bridges).
    case exact = "exact"
    /// Token counts are derived from exact totals via normalization (e.g. splitting total_tokens into input/output).
    case derivedExact = "derived_exact"
    /// Token counts are high-confidence estimates (e.g. language-aware heuristic).
    case highConfidenceEstimate = "high_confidence_estimate"
    /// Token counts are lower-confidence estimates (e.g. coarse heuristic without language context).
    case lowConfidenceEstimate = "low_confidence_estimate"
    /// Confidence is unknown (legacy rows).
    case unknown = "unknown"

    /// Numeric precedence for comparison. Higher value = more authoritative.
    var precedence: Int {
        switch self {
        case .exact: return 4
        case .derivedExact: return 3
        case .highConfidenceEstimate: return 2
        case .lowConfidenceEstimate: return 1
        case .unknown: return 0
        }
    }

    static func < (lhs: UsageProvenanceConfidence, rhs: UsageProvenanceConfidence) -> Bool {
        lhs.precedence < rhs.precedence
    }
}

// MARK: - Usage Source

/// Where a `TokenUsage` row was produced (analytics / deduplication).
enum UsageSource: String, Codable, Hashable, CaseIterable {
    case providerLog = "provider_log"
    case inAppChat = "in_app_chat"
    case cursorBridge = "cursor_bridge"
    case billingAPI = "billing_api"
    case daemon = "daemon"
    /// Legacy rows or cloud documents without this field.
    case unknown = "unknown"
}

// MARK: - Agent Provider Enum

enum AgentProvider: String, Codable, CaseIterable, Identifiable {
    case factory = "Factory"
    case claudeCode = "Claude Code"
    case copilot = "Copilot"
    case aider = "Aider"
    case cursor = "Cursor"
    case codex = "Codex"
    case zai = "Zai"
    case minimax = "MiniMax"
    case kimi = "Kimi"
    case cline = "Cline"
    case kiloCode = "Kilo Code"
    case rooCode = "Roo Code"
    case forgeDev = "Forge"
    case augment = "Augment"
    case hermes = "Hermes"
    case geminiCLI = "Gemini CLI"
    case goose = "Goose"
    case openClaw = "OpenClaw"

    var id: String { rawValue }
    
    /// Colorful logo URLs from lobehub (https://lobehub.com/icons)
    var logoURL: URL? {
        switch self {
        case .factory:
            return nil
        case .claudeCode:
            return URL(string: "https://raw.githubusercontent.com/lobehub/lobe-icons/refs/heads/master/packages/static-png/light/claudecode-color.png")
        case .copilot:
            return URL(string: "https://raw.githubusercontent.com/lobehub/lobe-icons/refs/heads/master/packages/static-png/light/copilot-color.png")
        case .aider:
            return nil
        case .cursor:
            return URL(string: "https://raw.githubusercontent.com/lobehub/lobe-icons/refs/heads/master/packages/static-png/light/cursor.png")
        case .codex:
            return URL(string: "https://raw.githubusercontent.com/lobehub/lobe-icons/refs/heads/master/packages/static-png/light/codex-color.png")
        case .zai:
            return URL(string: "https://raw.githubusercontent.com/lobehub/lobe-icons/refs/heads/master/packages/static-png/light/zai.png")
        case .minimax:
            return URL(string: "https://raw.githubusercontent.com/lobehub/lobe-icons/refs/heads/master/packages/static-png/light/minimax-color.png")
        case .kimi:
            return URL(string: "https://raw.githubusercontent.com/lobehub/lobe-icons/refs/heads/master/packages/static-png/light/kimi-color.png")
        case .cline:
            return URL(string: "https://raw.githubusercontent.com/lobehub/lobe-icons/refs/heads/master/packages/static-png/light/cline-color.png")
        case .kiloCode, .rooCode, .forgeDev, .hermes, .goose, .openClaw:
            return nil
        case .geminiCLI:
            return URL(string: "https://raw.githubusercontent.com/lobehub/lobe-icons/refs/heads/master/packages/static-png/light/gemini-color.png")
        case .augment:
            return URL(string: "https://raw.githubusercontent.com/lobehub/lobe-icons/refs/heads/master/packages/static-png/light/augment-color.png")
        }
    }

    var iconName: String {
        switch self {
        case .factory: return "cpu.fill"
        case .claudeCode: return "bubble.left.and.bubble.right.fill"
        case .copilot: return "sparkles"
        case .aider: return "terminal.fill"
        case .cursor: return "cursor.rays"
        case .codex: return "hammer.fill"
        case .zai: return "bolt.fill"
        case .minimax: return "star.fill"
        case .kimi: return "moon.fill"
        case .cline: return "brain.head.profile"
        case .kiloCode: return "k.circle.fill"
        case .rooCode: return "hare.fill"
        case .forgeDev: return "flame.fill"
        case .augment: return "arrow.trianglehead.2.counterclockwise.rotate.90"
        case .hermes: return "wind"
        case .geminiCLI: return "diamond.fill"
        case .goose: return "bird.fill"
        case .openClaw: return "point.3.connected.trianglepath.dotted"
        }
    }
    
    var displayName: String { rawValue }
    
    var logDirectory: String {
        switch self {
        case .factory: return "~/.factory/sessions"
        case .claudeCode: return "~/.claude/projects"
        case .copilot: return "~/.copilot/session-state"
        case .aider: return "~/.aider"
        case .cursor: return "~/.cursor/ai-tracking"
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
        }
    }

    var filePattern: String {
        switch self {
        case .factory: return "*.jsonl"
        case .claudeCode: return "*.jsonl"
        case .copilot: return "*.jsonl"
        case .aider: return "*.jsonl"
        case .cursor: return "*.db"
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
        }
    }

    var supportLevel: ProviderSupportLevel {
        switch self {
        case .factory, .claudeCode, .codex, .aider, .cline, .kiloCode, .rooCode, .forgeDev, .hermes, .geminiCLI, .goose:
            return .supported
        case .openClaw, .copilot, .kimi, .zai, .minimax, .cursor:
            return .partial
        case .augment:
            return .unsupported
        }
    }

    var dataConfidence: DataConfidence {
        switch self {
        case .factory, .claudeCode, .codex, .kimi, .aider, .cline, .kiloCode, .rooCode, .forgeDev, .hermes, .geminiCLI, .goose, .openClaw:
            return .exact
        case .zai, .minimax, .copilot, .cursor:
            return .estimated
        case .augment:
            return .unavailable
        }
    }
}

// MARK: - Token Usage Record

struct TokenUsage: Codable, Identifiable, Hashable {
    let id: UUID
    let provider: AgentProvider
    let sessionId: String
    let projectName: String
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationTokens: Int
    let cacheReadTokens: Int
    /// Output-class tokens reported separately (e.g. OpenAI `reasoning_tokens`); billed at output rates.
    let reasoningTokens: Int
    let totalTokens: Int
    let cost: Double
    let startTime: Date
    let endTime: Date
    let createdAt: Date
    /// Origin of this row (log parser, in-app chat, connector, API, daemon).
    let usageSource: UsageSource
    /// Non-nil for rows downloaded from another device via cloud sync.
    let sourceDeviceId: String?
    /// Human-readable name of the source device (e.g. "MacBook Pro (Work)").
    let sourceDeviceName: String?
    /// True for rows downloaded from Firestore; excluded from upload sync.
    let isRemote: Bool
    /// How the token counts were obtained (log parser, API, heuristic, etc.).
    let provenanceMethod: UsageProvenanceMethod
    /// Confidence level for the token counts (exact, derived, estimated, unknown).
    let provenanceConfidence: UsageProvenanceConfidence
    /// Version identifier of the estimator/normalizer that produced these counts.
    /// Empty string when counts are from exact provider data.
    let estimatorVersion: String

    // Alias for backwards compatibility
    var costUSD: Double { cost }

    init(
        id: UUID = UUID(),
        provider: AgentProvider,
        sessionId: String,
        projectName: String,
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int = 0,
        cacheReadTokens: Int = 0,
        reasoningTokens: Int = 0,
        costUSD: Double = 0,
        startTime: Date,
        endTime: Date,
        createdAt: Date = Date(),
        usageSource: UsageSource = .providerLog,
        sourceDeviceId: String? = nil,
        sourceDeviceName: String? = nil,
        isRemote: Bool = false,
        provenanceMethod: UsageProvenanceMethod = .unknown,
        provenanceConfidence: UsageProvenanceConfidence = .unknown,
        estimatorVersion: String = ""
    ) {
        self.id = id
        self.provider = provider
        self.sessionId = sessionId
        self.projectName = projectName
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.reasoningTokens = reasoningTokens
        self.totalTokens = Self.billedTotalTokens(
            input: inputTokens,
            output: outputTokens,
            cacheCreation: cacheCreationTokens,
            cacheRead: cacheReadTokens,
            reasoning: reasoningTokens
        )
        self.cost = costUSD
        self.startTime = startTime
        self.endTime = endTime
        self.createdAt = createdAt
        self.usageSource = usageSource
        self.sourceDeviceId = sourceDeviceId
        self.sourceDeviceName = sourceDeviceName
        self.isRemote = isRemote
        self.provenanceMethod = provenanceMethod
        self.provenanceConfidence = provenanceConfidence
        self.estimatorVersion = estimatorVersion
    }

    /// Sum of billable token buckets (matches provider invoices when all fields are populated).
    static func billedTotalTokens(
        input: Int,
        output: Int,
        cacheCreation: Int,
        cacheRead: Int,
        reasoning: Int
    ) -> Int {
        max(0, input) + max(0, output) + max(0, cacheCreation) + max(0, cacheRead) + max(0, reasoning)
    }

    private enum CodingKeys: String, CodingKey {
        case id, provider, sessionId, projectName, model
        case inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens, reasoningTokens
        case totalTokens, cost, startTime, endTime, createdAt, usageSource
        case sourceDeviceId, sourceDeviceName, isRemote
        case provenanceMethod, provenanceConfidence, estimatorVersion
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        provider = try c.decode(AgentProvider.self, forKey: .provider)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        projectName = try c.decode(String.self, forKey: .projectName)
        model = try c.decode(String.self, forKey: .model)
        inputTokens = try c.decode(Int.self, forKey: .inputTokens)
        outputTokens = try c.decode(Int.self, forKey: .outputTokens)
        cacheCreationTokens = try c.decodeIfPresent(Int.self, forKey: .cacheCreationTokens) ?? 0
        cacheReadTokens = try c.decodeIfPresent(Int.self, forKey: .cacheReadTokens) ?? 0
        reasoningTokens = try c.decodeIfPresent(Int.self, forKey: .reasoningTokens) ?? 0
        totalTokens = try c.decodeIfPresent(Int.self, forKey: .totalTokens)
            ?? Self.billedTotalTokens(
                input: inputTokens,
                output: outputTokens,
                cacheCreation: cacheCreationTokens,
                cacheRead: cacheReadTokens,
                reasoning: reasoningTokens
            )
        cost = try c.decode(Double.self, forKey: .cost)
        startTime = try c.decode(Date.self, forKey: .startTime)
        endTime = try c.decode(Date.self, forKey: .endTime)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        usageSource = try c.decodeIfPresent(UsageSource.self, forKey: .usageSource) ?? .unknown
        sourceDeviceId = try c.decodeIfPresent(String.self, forKey: .sourceDeviceId)
        sourceDeviceName = try c.decodeIfPresent(String.self, forKey: .sourceDeviceName)
        isRemote = try c.decodeIfPresent(Bool.self, forKey: .isRemote) ?? false
        provenanceMethod = try c.decodeIfPresent(UsageProvenanceMethod.self, forKey: .provenanceMethod) ?? .unknown
        provenanceConfidence = try c.decodeIfPresent(UsageProvenanceConfidence.self, forKey: .provenanceConfidence) ?? .unknown
        estimatorVersion = try c.decodeIfPresent(String.self, forKey: .estimatorVersion) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(provider, forKey: .provider)
        try c.encode(sessionId, forKey: .sessionId)
        try c.encode(projectName, forKey: .projectName)
        try c.encode(model, forKey: .model)
        try c.encode(inputTokens, forKey: .inputTokens)
        try c.encode(outputTokens, forKey: .outputTokens)
        try c.encode(cacheCreationTokens, forKey: .cacheCreationTokens)
        try c.encode(cacheReadTokens, forKey: .cacheReadTokens)
        try c.encode(reasoningTokens, forKey: .reasoningTokens)
        try c.encode(totalTokens, forKey: .totalTokens)
        try c.encode(cost, forKey: .cost)
        try c.encode(startTime, forKey: .startTime)
        try c.encode(endTime, forKey: .endTime)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(usageSource, forKey: .usageSource)
        try c.encodeIfPresent(sourceDeviceId, forKey: .sourceDeviceId)
        try c.encodeIfPresent(sourceDeviceName, forKey: .sourceDeviceName)
        try c.encode(isRemote, forKey: .isRemote)
        try c.encode(provenanceMethod, forKey: .provenanceMethod)
        try c.encode(provenanceConfidence, forKey: .provenanceConfidence)
        try c.encode(estimatorVersion, forKey: .estimatorVersion)
    }
    
    // Computed properties
    var duration: TimeInterval {
        endTime.timeIntervalSince(startTime)
    }
    
    var formattedDuration: String {
        let interval = Int(duration)
        let hours = interval / 3600
        let minutes = (interval % 3600) / 60
        let seconds = interval % 60
        
        if hours > 0 {
            return String(format: "%dh %dm", hours, minutes)
        } else if minutes > 0 {
            return String(format: "%dm %ds", minutes, seconds)
        } else {
            return String(format: "%ds", seconds)
        }
    }

    /// Whether this session's time span overlaps `dateRange` (inclusive `ClosedRange` semantics).
    /// Using interval overlap instead of `range.contains(startTime)` includes sessions that
    /// started before the window but ended inside it (or span it), matching user expectations
    /// for "Today" / "Last 7 days" etc.
    func intersects(dateRange: ClosedRange<Date>) -> Bool {
        let s = min(startTime, endTime)
        let e = max(startTime, endTime)
        return s <= dateRange.upperBound && e >= dateRange.lowerBound
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

struct ProviderSummary: Identifiable, Hashable {
    let id = UUID()
    let provider: AgentProvider
    let totalCost: Double
    let totalTokens: Int
    let totalInputTokens: Int
    let totalOutputTokens: Int
    let sessionCount: Int
    let modelBreakdown: [ModelUsage]
    
    var formattedCost: String {
        totalCost.formatAsCost()
    }
}

// MARK: - Model Usage

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
}
