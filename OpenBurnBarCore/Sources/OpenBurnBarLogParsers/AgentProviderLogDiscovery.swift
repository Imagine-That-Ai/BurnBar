import Foundation
import OpenBurnBarKernel

/// Canonical provider log directory and file-pattern discovery for Linux and cross-platform ingestion.
///
/// macOS-specific VS Code globalStorage paths are mapped to `~/.config/Code/User/globalStorage/...` on Linux.
/// Session identity is derived from resolved absolute paths so symlink/rotation cases do not rewrite IDs silently.
public enum AgentProviderLogDiscovery {
    public struct ResolvedLogSource: Equatable, Sendable {
        public var provider: AgentProvider
        public var logicalPath: String
        public var resolvedPath: String
        public var filePattern: String
        public var sessionIdentityKey: String

        public init(
            provider: AgentProvider,
            logicalPath: String,
            resolvedPath: String,
            filePattern: String,
            sessionIdentityKey: String
        ) {
            self.provider = provider
            self.logicalPath = logicalPath
            self.resolvedPath = resolvedPath
            self.filePattern = filePattern
            self.sessionIdentityKey = sessionIdentityKey
        }
    }

    public static func logicalLogDirectory(for provider: AgentProvider) -> String {
        switch provider {
        case .factory:
            return "~/.factory/sessions"
        case .claudeCode:
            return "~/.claude/projects"
        case .copilot:
            return "~/.copilot/session-state"
        case .aider:
            return "~/.aider"
        case .cursor:
            return "~/.cursor/ai-tracking"
        case .openAI, .deepSeek, .mimo, .openBurnBar:
            return "~/.codex"
        case .codex:
            return "~/.codex/sessions"
        case .openCode:
            return "~/.local/share/opencode"
        case .zai, .minimax:
            return "~/.factory/sessions"
        case .kimi:
            return "~/.kimi/sessions"
        case .cline:
            #if os(Linux)
            return "~/.config/Code/User/globalStorage/saoudrizwan.claude-dev/tasks"
            #else
            return "~/Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/tasks"
            #endif
        case .kiloCode:
            #if os(Linux)
            return "~/.config/Code/User/globalStorage/kilocode.kilo-code/tasks"
            #else
            return "~/Library/Application Support/Code/User/globalStorage/kilocode.kilo-code/tasks"
            #endif
        case .rooCode:
            #if os(Linux)
            return "~/.config/Code/User/globalStorage/rooveterinaryinc.roo-cline/tasks"
            #else
            return "~/Library/Application Support/Code/User/globalStorage/rooveterinaryinc.roo-cline/tasks"
            #endif
        case .forgeDev:
            return "~/.forge/sessions"
        case .augment:
            #if os(Linux)
            return "~/.config/Code/User/globalStorage/augment.vscode-augment"
            #else
            return "~/Library/Application Support/Code/User/globalStorage/augment.vscode-augment"
            #endif
        case .hermes:
            return "~/.hermes/sessions"
        case .piAgent:
            return "~/.pi/sessions"
        case .geminiCLI:
            return "~/.gemini/tmp"
        case .antigravity:
            return "~/.gemini/antigravity-cli"
        case .cursorAgent:
            return "~/.cursor-agent/sessions"
        case .goose:
            return "~/.local/share/goose/sessions"
        case .openClaw:
            return "~/.openclaw/sessions"
        case .openClaude:
            return "~/.openclaude/sessions"
        case .omp:
            return "~/.omp/agent/sessions"
        case .junie:
            return "~/.junie/sessions"
        case .ollama:
            return "~/.ollama/logs"
        case .windsurf:
            #if os(Linux)
            return "~/.config/Windsurf - Next/User/globalStorage"
            #else
            return "~/Library/Application Support/Windsurf - Next/User/globalStorage"
            #endif
        case .warp:
            #if os(Linux)
            return "~/.config/Warp"
            #else
            return "~/Library/Application Support/dev.warp.Warp-Stable"
            #endif
        case .xAI:
            return "~/.grok/sessions"
        }
    }

    public static func filePattern(for provider: AgentProvider) -> String {
        switch provider {
        case .factory, .claudeCode, .copilot, .aider, .zai, .minimax, .forgeDev, .hermes, .piAgent, .cursorAgent, .openClaw, .openClaude, .omp, .junie:
            return "*.jsonl"
        case .cursor:
            return "*.db"
        case .openAI:
            return "openai-no-local-logs"
        case .deepSeek:
            return "deepseek-no-local-logs"
        case .codex:
            return "*.jsonl"
        case .openCode:
            return "opencode.db"
        case .kimi:
            return "*.jsonl"
        case .cline, .kiloCode, .rooCode:
            return "*.json"
        case .augment:
            return "*.jsonl"
        case .geminiCLI:
            return "*.json"
        case .antigravity:
            return "history.jsonl"
        case .goose:
            return "sessions.db"
        case .ollama:
            return "server*.log"
        case .windsurf:
            return "state.vscdb"
        case .warp:
            return "warp_network*.log"
        case .xAI:
            return "summary.json"
        case .mimo:
            return "mimo-no-local-logs"
        case .openBurnBar:
            return "openburnbar-no-local-logs"
        }
    }

    public static func resolveLogSource(
        for provider: AgentProvider,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ResolvedLogSource {
        let logical = logicalLogDirectory(for: provider)
        let homeDirectory = environment["HOME"]
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        let resolved = OpenBurnBarLinuxPaths.expandPath(
            logical,
            homeDirectory: homeDirectory,
            environment: environment
        )
        let pattern = filePattern(for: provider)
        let identity = sessionIdentityKey(provider: provider, resolvedPath: resolved)
        return ResolvedLogSource(
            provider: provider,
            logicalPath: logical,
            resolvedPath: resolved,
            filePattern: pattern,
            sessionIdentityKey: identity
        )
    }

    public static func sessionIdentityKey(provider: AgentProvider, resolvedPath: String) -> String {
        "\(provider.rawValue)|\(resolvedPath)"
    }
}
