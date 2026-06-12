import SwiftUI

// MARK: - Monochrome Logo Backdrop
//
// Several bundled provider marks ship as solid dark (or light) glyphs. On the
// Aurora dark surface they disappear without a neutral disc behind them.
// `UnifiedProviderLogoView` and the macOS `ProviderLogoView` share this list.

public extension AgentProvider {
    /// Whether a bundled logo needs a neutral backdrop for contrast in the
    /// current color scheme. Returns `false` when no bundled asset exists —
    /// callers should gate on asset presence first.
    func needsMonochromeLogoBackdrop(colorScheme: ColorScheme) -> Bool {
        if colorScheme == .dark {
            switch self {
            case .openAI, .codex, .cursor, .cursorAgent, .forgeDev, .claudeCode,
                 .factory, .windsurf, .copilot, .aider, .ollama,
                 .openClaw, .geminiCLI, .antigravity, .goose, .augment, .cline,
                 .kiloCode, .rooCode, .hermes, .xAI:
                return true
            default:
                return false
            }
        } else {
            switch self {
            case .kimi, .goose, .augment:
                return true
            default:
                return false
            }
        }
    }
}
