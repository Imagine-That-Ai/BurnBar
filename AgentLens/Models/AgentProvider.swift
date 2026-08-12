import BurnBarCore
import Foundation
import SwiftUI

// MARK: - Provider Support Level

enum ProviderSupportLevel {
    /// Full token data parsed from logs (exact counts)
    case supported
    /// Token data is estimated or derived from heuristics
    case partial
    /// Parser exists but returns empty — no real implementation yet
    case unsupported

    /// Canonical user-facing label. Provider-list/detail surfaces derive their
    /// copy from this (VAL-PROV-010) — never a fabricated exact-cost claim.
    var label: String {
        switch self {
        case .supported: return "Supported"
        case .partial: return "Partial support"
        case .unsupported: return "Not yet supported"
        }
    }
}

// MARK: - Data Confidence

enum DataConfidence {
    /// Token counts come directly from API/log data
    case exact
    /// Token counts are derived from heuristics (e.g. character count)
    case estimated
    /// No data available
    case unavailable

    /// Canonical user-facing label for confidence badges.
    var label: String {
        switch self {
        case .exact: return "Exact"
        case .estimated: return "Estimated"
        case .unavailable: return "Unsupported"
        }
    }
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
    case grokBot = "Grok Bot"
    case grokCLI = "Grok CLI"
    case pi = "Pi"
    case geminiCLI = "Gemini CLI"
    case goose = "Goose"
    
    var id: String { rawValue }
    
    /// Colorful logo URLs from lobehub (https://lobehub.com/icons)
    var logoURL: URL? {
        switch self {
        case .factory:
            return Bundle.main.url(forResource: "66e1b25cc9185ef537421b18_Factory.ai", withExtension: "webp")
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
        case .kiloCode, .rooCode, .forgeDev, .hermes, .goose:
            return nil
        case .grokBot:
            return URL(string: "https://raw.githubusercontent.com/lobehub/lobe-icons/refs/heads/master/packages/static-png/light/grok.png")
        case .grokCLI:
            return URL(string: "https://raw.githubusercontent.com/lobehub/lobe-icons/refs/heads/master/packages/static-png/light/grok.png")
        case .pi:
            return URL(string: "https://raw.githubusercontent.com/lobehub/lobe-icons/refs/heads/master/packages/static-png/light/pi.png")
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
        case .grokBot: return "circle.hexagongrid.fill"
        case .grokCLI: return "chevron.left.forwardslash.chevron.right"
        case .pi: return "pi"
        case .geminiCLI: return "diamond.fill"
        case .goose: return "bird.fill"
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
        case .grokBot: return "~/.grokbot"
        case .grokCLI: return "~/.grok/sessions"
        case .pi: return "~/.pi/agent/sessions"
        case .geminiCLI: return "~/.gemini/tmp"
        case .goose: return "~/.local/share/goose/sessions"
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
        case .grokBot: return "*.json"
        case .grokCLI: return "*.jsonl"
        case .pi: return "*.jsonl"
        case .augment: return "*.jsonl"
        case .geminiCLI: return "*.json"
        case .goose: return "sessions.db"
        }
    }

    var supportLevel: ProviderSupportLevel {
        switch self {
        case .factory, .claudeCode, .codex, .aider, .cline, .kiloCode, .rooCode, .forgeDev, .hermes, .geminiCLI, .goose:
            return .supported
        case .copilot, .kimi, .zai, .minimax, .cursor, .grokCLI, .pi:
            return .partial
        case .grokBot, .augment:
            return .unsupported
        }
    }

    var dataConfidence: DataConfidence {
        switch self {
        case .factory, .claudeCode, .codex, .kimi, .aider, .cline, .kiloCode,
             .rooCode, .forgeDev, .hermes, .geminiCLI, .goose:
            return .exact
        case .zai, .minimax, .copilot, .cursor, .grokCLI, .pi:
            return .estimated
        case .grokBot, .augment:
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
    let totalTokens: Int
    let cost: Double
    let startTime: Date
    let endTime: Date
    let createdAt: Date
    
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
        costUSD: Double = 0,
        startTime: Date,
        endTime: Date
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
        self.totalTokens = inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens
        self.cost = costUSD
        self.startTime = startTime
        self.endTime = endTime
        self.createdAt = Date()
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

// MARK: - Fleet Identity Mapping

extension AgentProvider {
    /// Maps a fleet wire id to the app-side provider used for display and theming.
    /// Every declared roster id resolves to a known provider — never a fallback
    /// (VAL-CROSS-003). Unknown/forward-compatible ids return nil.
    init?(fleetAgentID: BurnBarFleetAgentID) {
        switch fleetAgentID {
        case .claudeCode: self = .claudeCode
        case .factoryDroid: self = .factory
        case .codex: self = .codex
        case .hermes: self = .hermes
        case .grokBot: self = .grokBot
        case .grokCLI: self = .grokCLI
        case .pi: self = .pi
        case .cursor: self = .cursor
        case .kimi: self = .kimi
        case .geminiCLI: self = .geminiCLI
        case .unknown: return nil
        }
    }
}
