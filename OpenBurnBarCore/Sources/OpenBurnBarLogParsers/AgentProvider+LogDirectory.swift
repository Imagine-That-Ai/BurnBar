import Foundation
import OpenBurnBarKernel

// MARK: - Provider log-directory resolution (Windows-buildable Engine seam)
//
// Windows-port Phase-2 (G2 parser lift, `docs/WINDOWS_PORT_MASTER_PLAN.md`).
//
// `logDirectory` / `logDirectoryMacForm` were a macOS-app extension on the Engine's
// `AgentProvider`. The lifted log parsers read `provider.logDirectory` to locate a
// provider's session logs, so the accessor is lifted into the Engine alongside the
// parsers. It depends only on Foundation and the Engine's own `LogPathPlatform`
// remap, so it compiles unchanged on macOS/iOS and on Windows/Linux.
//
// macOS/Linux invariant: `logDirectory` returns the historical `~/…` logical form
// (`logDirectoryMacForm`) **unchanged** (the `LogPathPlatform` POSIX branch is a
// pass-through), so every existing caller — which applies `expandingTildeInPath`
// itself — is byte-for-byte identical to before the lift. On Windows the tilde root
// is remapped to `%USERPROFILE%`/`%APPDATA%`/`%LOCALAPPDATA%`.
public extension AgentProvider {
    /// Filesystem directory where the provider writes session logs the file
    /// watcher can scrape, resolved for the current host.
    var logDirectory: String {
        LogPathPlatform.resolveLogDirectory(logDirectoryMacForm)
    }

    /// The historical macOS/Linux `~/…` logical log directory per provider — the
    /// ground-truth table. `logDirectory` layers the Windows path remap on top; on
    /// POSIX hosts the remap is a pass-through so this value flows out unchanged.
    private var logDirectoryMacForm: String {
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
        case .openAI, .deepSeek: return "~/.codex"
        case .codex: return "~/.codex"
        case .openCode: return "~/.local/share/opencode"
        case .zai: return "~/.factory/sessions"
        case .minimax: return "~/.factory/sessions"
        case .kimi: return "~/.kimi/sessions"
        case .cline: return "~/Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/tasks"
        case .kiloCode: return "~/Library/Application Support/Code/User/globalStorage/kilocode.kilo-code/tasks"
        case .rooCode: return "~/Library/Application Support/Code/User/globalStorage/rooveterinaryinc.roo-cline/tasks"
        case .forgeDev: return "~/.forge/sessions"
        case .augment: return "~/Library/Application Support/Code/User/globalStorage/augment.vscode-augment"
        case .hermes: return "~/.hermes/sessions"
        case .piAgent: return "~/.pi/sessions"
        case .geminiCLI: return "~/.gemini/tmp"
        case .antigravity: return "~/.gemini/antigravity-cli"
        case .cursorAgent: return "~/.cursor-agent/sessions"
        case .goose: return "~/.local/share/goose/sessions"
        case .openClaw: return "~/.openclaw/sessions"
        case .openClaude: return "~/.openclaude/sessions"
        case .omp: return "~/.omp/agent/sessions"
        case .junie: return "~/.junie/sessions"
        case .ollama: return "~/.ollama/logs"
        case .windsurf: return "~/Library/Application Support/Windsurf - Next/User/globalStorage"
        case .warp: return "~/Library/Application Support/dev.warp.Warp-Stable"
        case .xAI: return "~/.grok/sessions"
        // MiMo quota is refreshed via Token Plan API; no local log directory.
        case .mimo: return "~/.codex"
        case .openBurnBar: return "~/.codex"
        }
    }
}
