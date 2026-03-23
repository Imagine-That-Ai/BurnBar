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
            return nil // Aider doesn't have a logo in lobehub
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
        }
    }
    
    var displayName: String { rawValue }
    
    var logDirectory: String {
        switch self {
        case .factory: return "~/.factory/sessions"
        case .claudeCode: return "~/.claude/projects"
        case .copilot: return "~/Library/Application Support/Copilot"
        case .aider: return "~/.aider"
        case .cursor: return "~/.cursor/ai-tracking"
        case .codex: return "~/.codex"
        case .zai: return "~/.factory/sessions"
        case .minimax: return "~/.factory/sessions"
        case .kimi: return "~/.kimi/sessions"
        }
    }
    
    var filePattern: String {
        switch self {
        case .factory: return "*.jsonl"
        case .claudeCode: return "*.jsonl"
        case .copilot: return "*.json"
        case .aider: return "*.jsonl"
        case .cursor: return "*.db"
        case .codex: return "state_5.sqlite"
        case .zai: return "*.jsonl"
        case .minimax: return "*.jsonl"
        case .kimi: return "*.jsonl"
        }
    }

    var supportLevel: ProviderSupportLevel {
        switch self {
        case .factory, .claudeCode:
            return .supported
        case .codex, .kimi, .zai, .minimax:
            return .partial
        case .copilot, .aider, .cursor:
            return .unsupported
        }
    }

    var dataConfidence: DataConfidence {
        switch self {
        case .factory, .claudeCode:
            return .exact
        case .codex, .kimi, .zai, .minimax:
            return .estimated
        case .copilot, .aider, .cursor:
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
