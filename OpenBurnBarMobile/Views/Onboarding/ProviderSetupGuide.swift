import Foundation
import OpenBurnBarCore

/// Single source of truth for "how do I connect this provider?" copy and metadata.
///
/// Used by:
///   - The first-run onboarding wizard (`OnboardingWizardView`)
///   - The post-onboarding manual sheet (`AddProviderConnectionView`)
///   - The "Available providers" list one-line hint (`ProviderConnectionsView`)
///
/// This avoids duplicating the same instructions across three surfaces.
struct ProviderSetupGuide: Hashable, Sendable {
    let provider: AgentProvider
    let kinds: [CredentialKind]
    let defaultKind: CredentialKind
    let labelSuggestion: String
    let dashboardURL: URL?
    let dashboardCTA: String
    let oneLineHint: String
    let instructions: [GuideStep]
    let credentialPlaceholder: String
    let credentialFooterMarkdown: String
    let supportsHosted: Bool
    let supportsSelfHosted: Bool

    /// Quick boolean — if true the manual sheet's hosted/self-hosted picker is
    /// shown. Mirrors the gating in `AddProviderConnectionView`.
    var supportsRemoteRunner: Bool { supportsHosted || supportsSelfHosted }
}

struct GuideStep: Hashable, Sendable, Identifiable {
    let number: Int
    let title: String
    let detail: String?
    /// Optional monospace snippet (a path, a CLI command, a JSON key).
    let codeSnippet: String?

    var id: Int { number }

    init(_ number: Int, _ title: String, detail: String? = nil, codeSnippet: String? = nil) {
        self.number = number
        self.title = title
        self.detail = detail
        self.codeSnippet = codeSnippet
    }
}

extension ProviderSetupGuide {

    /// Returns the curated guide for the provider, or a sensible generic
    /// fallback so we never crash on a provider we haven't documented yet.
    static func guide(for provider: AgentProvider) -> ProviderSetupGuide {
        switch provider {
        case .factory:
            return ProviderSetupGuide(
                provider: provider,
                kinds: [.token, .bearer],
                defaultKind: .token,
                labelSuggestion: "Factory",
                dashboardURL: URL(string: "https://app.factory.ai/settings/api-keys"),
                dashboardCTA: "Open Factory dashboard",
                oneLineHint: "API key from Factory's developer settings.",
                instructions: [
                    GuideStep(1, "Open Factory's dashboard", detail: "Sign in and navigate to Settings → API Keys."),
                    GuideStep(2, "Create a new key", detail: "Name it something memorable — \"OpenBurnBar\" works."),
                    GuideStep(3, "Copy the key here", detail: "Paste it below; it stays encrypted in your sync vault.")
                ],
                credentialPlaceholder: "fk_...",
                credentialFooterMarkdown: "Factory keys never leave your encrypted sync vault. Refresh runs from any signed-in device.",
                supportsHosted: false,
                supportsSelfHosted: false
            )

        case .claudeCode:
            return ProviderSetupGuide(
                provider: provider,
                kinds: [.session],
                defaultKind: .session,
                labelSuggestion: "Claude",
                dashboardURL: URL(string: "https://claude.ai/account"),
                dashboardCTA: "Open Claude account",
                oneLineHint: "Self-hosted runner only — keep credentials on your Mac.",
                instructions: [
                    GuideStep(1, "Run a Claude Code runner", detail: "Use the OpenBurnBar Mac app or the standalone runner image."),
                    GuideStep(2, "Copy the runner URL", detail: "Use HTTPS for deployed runners, or http://localhost for testing.", codeSnippet: "https://your-runner.run.app"),
                    GuideStep(3, "Add an optional secret", detail: "If your runner requires an access secret, paste it on the next step.")
                ],
                credentialPlaceholder: "https://your-runner.run.app",
                credentialFooterMarkdown: "Claude Code credentials stay on your runner. This device only stores the runner URL.",
                supportsHosted: false,
                supportsSelfHosted: true
            )

        case .copilot:
            return ProviderSetupGuide(
                provider: provider,
                kinds: [.token, .bearer],
                defaultKind: .token,
                labelSuggestion: "Copilot",
                dashboardURL: URL(string: "https://github.com/settings/copilot"),
                dashboardCTA: "Open GitHub Copilot settings",
                oneLineHint: "Personal access token with the Copilot scope.",
                instructions: [
                    GuideStep(1, "Open GitHub Copilot settings", detail: "Confirm your subscription is active."),
                    GuideStep(2, "Create a fine-grained PAT", detail: "Scope: Copilot. We only read usage."),
                    GuideStep(3, "Paste the token below", detail: "OpenBurnBar reads quota and request counts only.")
                ],
                credentialPlaceholder: "ghp_...",
                credentialFooterMarkdown: "Copilot token is encrypted in your sync vault and refreshed only when you tap refresh.",
                supportsHosted: false,
                supportsSelfHosted: false
            )

        case .aider:
            return ProviderSetupGuide(
                provider: provider,
                kinds: [.token, .bearer],
                defaultKind: .token,
                labelSuggestion: "Aider",
                dashboardURL: nil,
                dashboardCTA: "Aider docs",
                oneLineHint: "Bring your own provider key (OpenAI, Anthropic, etc.).",
                instructions: [
                    GuideStep(1, "Open Aider's config", detail: "Aider routes through your provider of choice."),
                    GuideStep(2, "Find the active key", detail: "Usually in ~/.aider.conf.yml or your shell env."),
                    GuideStep(3, "Paste it below", detail: "We track usage against the underlying provider quota.")
                ],
                credentialPlaceholder: "sk-...",
                credentialFooterMarkdown: "OpenBurnBar tracks the provider Aider is configured to use.",
                supportsHosted: false,
                supportsSelfHosted: false
            )

        case .cursor:
            return ProviderSetupGuide(
                provider: provider,
                kinds: [.cookie, .session],
                defaultKind: .cookie,
                labelSuggestion: "Cursor",
                dashboardURL: URL(string: "https://cursor.com/dashboard"),
                dashboardCTA: "Open Cursor dashboard",
                oneLineHint: "Sign in once and we capture the session cookie.",
                instructions: [
                    GuideStep(1, "Open the Cursor dashboard", detail: "Sign in with the same account you use in the editor."),
                    GuideStep(2, "Copy your session cookie", detail: "DevTools → Application → Cookies → cursor.com → WorkosCursorSessionToken.", codeSnippet: "WorkosCursorSessionToken=..."),
                    GuideStep(3, "Paste the cookie below", detail: "We reuse Cursor's own auth — no separate key required.")
                ],
                credentialPlaceholder: "WorkosCursorSessionToken=...",
                credentialFooterMarkdown: "Cookies expire eventually. If quota refresh stops, sign in again and reconnect.",
                supportsHosted: false,
                supportsSelfHosted: false
            )

        case .openAI:
            return ProviderSetupGuide(
                provider: provider,
                kinds: [.token, .bearer],
                defaultKind: .token,
                labelSuggestion: "OpenAI",
                dashboardURL: URL(string: "https://platform.openai.com/api-keys"),
                dashboardCTA: "Open OpenAI keys page",
                oneLineHint: "Project API key — read access is enough.",
                instructions: [
                    GuideStep(1, "Open the OpenAI API keys page", detail: "Sign in to platform.openai.com."),
                    GuideStep(2, "Create a new secret key", detail: "Restrict to read access if you want."),
                    GuideStep(3, "Paste it below", detail: "Starts with `sk-proj-` for project keys.")
                ],
                credentialPlaceholder: "sk-proj-...",
                credentialFooterMarkdown: "OpenAI keys are encrypted at rest and refresh runs from any signed-in device.",
                supportsHosted: false,
                supportsSelfHosted: false
            )

        case .codex:
            return ProviderSetupGuide(
                provider: provider,
                kinds: [.session],
                defaultKind: .session,
                labelSuggestion: "Codex",
                dashboardURL: URL(string: "https://chat.openai.com"),
                dashboardCTA: "Open ChatGPT",
                oneLineHint: "Hosted sync available, or self-host on your Mac.",
                instructions: [
                    GuideStep(1, "Sign in to ChatGPT once", detail: "On any device — we just need the auth bundle."),
                    GuideStep(2, "Copy ~/.codex/auth.json", detail: "If you've used the codex CLI on this device, this file exists.", codeSnippet: "~/.codex/auth.json"),
                    GuideStep(3, "Paste the JSON contents below", detail: "Hosted: stored encrypted server-side. Self-hosted: stays on your runner.")
                ],
                credentialPlaceholder: "{\"OPENAI_API_KEY\": \"...\"}",
                credentialFooterMarkdown: "Hosted sync requires the OpenBurnBar **Hosted Quota Sync** subscription. Self-hosted needs a runner URL.",
                supportsHosted: true,
                supportsSelfHosted: true
            )

        case .zai:
            return ProviderSetupGuide(
                provider: provider,
                kinds: [.token, .bearer],
                defaultKind: .bearer,
                labelSuggestion: "Zai",
                dashboardURL: URL(string: "https://z.ai"),
                dashboardCTA: "Open Zai",
                oneLineHint: "API token from your Zai workspace settings.",
                instructions: [
                    GuideStep(1, "Open your Zai workspace", detail: "Sign in to z.ai."),
                    GuideStep(2, "Create an API token", detail: "Settings → API Tokens → New."),
                    GuideStep(3, "Paste it below", detail: "Read scope is enough for quota tracking.")
                ],
                credentialPlaceholder: "zai-...",
                credentialFooterMarkdown: "Zai tokens are encrypted at rest.",
                supportsHosted: false,
                supportsSelfHosted: false
            )

        case .minimax:
            return ProviderSetupGuide(
                provider: provider,
                kinds: [.token, .bearer],
                defaultKind: .bearer,
                labelSuggestion: "MiniMax",
                dashboardURL: URL(string: "https://platform.minimaxi.com/user-center/basic-information/interface-key"),
                dashboardCTA: "Open MiniMax keys",
                oneLineHint: "Group ID + API key from the platform console.",
                instructions: [
                    GuideStep(1, "Open the MiniMax console", detail: "Sign in and go to Interface Key."),
                    GuideStep(2, "Copy your API key", detail: "Bearer token — keep your group ID handy too."),
                    GuideStep(3, "Paste the key below", detail: "OpenBurnBar reads usage and remaining tokens.")
                ],
                credentialPlaceholder: "Bearer ...",
                credentialFooterMarkdown: "MiniMax keys are encrypted at rest.",
                supportsHosted: false,
                supportsSelfHosted: false
            )

        case .kimi:
            return ProviderSetupGuide(
                provider: provider,
                kinds: [.token, .bearer],
                defaultKind: .bearer,
                labelSuggestion: "Kimi",
                dashboardURL: URL(string: "https://platform.moonshot.cn/console/api-keys"),
                dashboardCTA: "Open Moonshot keys",
                oneLineHint: "Bearer token from Moonshot AI's console.",
                instructions: [
                    GuideStep(1, "Open the Moonshot console", detail: "Sign in to platform.moonshot.cn."),
                    GuideStep(2, "Create an API key", detail: "Console → API Keys → Create."),
                    GuideStep(3, "Paste it below", detail: "Starts with `sk-`.")
                ],
                credentialPlaceholder: "sk-...",
                credentialFooterMarkdown: "Kimi keys are encrypted at rest.",
                supportsHosted: false,
                supportsSelfHosted: false
            )

        case .cline:
            return ProviderSetupGuide(
                provider: provider,
                kinds: [.token, .bearer],
                defaultKind: .token,
                labelSuggestion: "Cline",
                dashboardURL: nil,
                dashboardCTA: "Cline docs",
                oneLineHint: "Bring your own provider key (Cline routes through it).",
                instructions: [
                    GuideStep(1, "Open Cline in VS Code", detail: "Settings → Cline."),
                    GuideStep(2, "Find your active provider key", detail: "Usually OpenAI, Anthropic, or OpenRouter."),
                    GuideStep(3, "Paste that key below", detail: "We track usage against the underlying provider.")
                ],
                credentialPlaceholder: "sk-...",
                credentialFooterMarkdown: "Cline routes through whichever provider you've configured. We track the underlying spend.",
                supportsHosted: false,
                supportsSelfHosted: false
            )

        case .kiloCode:
            return ProviderSetupGuide(
                provider: provider,
                kinds: [.token, .bearer],
                defaultKind: .token,
                labelSuggestion: "Kilo Code",
                dashboardURL: URL(string: "https://kilocode.ai"),
                dashboardCTA: "Open Kilo Code",
                oneLineHint: "Personal API key from Kilo Code's settings.",
                instructions: [
                    GuideStep(1, "Open Kilo Code's web dashboard", detail: "Sign in with your account."),
                    GuideStep(2, "Generate an API key", detail: "Settings → API."),
                    GuideStep(3, "Paste it below", detail: "OpenBurnBar reads usage and quota.")
                ],
                credentialPlaceholder: "kc-...",
                credentialFooterMarkdown: "Kilo Code keys are encrypted at rest.",
                supportsHosted: false,
                supportsSelfHosted: false
            )

        case .rooCode:
            return ProviderSetupGuide(
                provider: provider,
                kinds: [.token, .bearer],
                defaultKind: .token,
                labelSuggestion: "Roo Code",
                dashboardURL: nil,
                dashboardCTA: "Roo Code docs",
                oneLineHint: "Bring your own provider key.",
                instructions: [
                    GuideStep(1, "Open Roo Code in VS Code", detail: "Settings → Roo Code."),
                    GuideStep(2, "Find your active provider key", detail: "Usually OpenAI, Anthropic, or OpenRouter."),
                    GuideStep(3, "Paste that key below", detail: "We track usage against the underlying provider.")
                ],
                credentialPlaceholder: "sk-...",
                credentialFooterMarkdown: "Roo Code routes through whichever provider you've configured.",
                supportsHosted: false,
                supportsSelfHosted: false
            )

        case .forgeDev:
            return ProviderSetupGuide(
                provider: provider,
                kinds: [.token, .bearer],
                defaultKind: .token,
                labelSuggestion: "Forge",
                dashboardURL: URL(string: "https://forgecode.dev"),
                dashboardCTA: "Open Forge",
                oneLineHint: "API key from Forge's developer settings.",
                instructions: [
                    GuideStep(1, "Open the Forge dashboard", detail: "Sign in with your account."),
                    GuideStep(2, "Create an API key", detail: "Settings → API Keys."),
                    GuideStep(3, "Paste it below", detail: "OpenBurnBar reads usage.")
                ],
                credentialPlaceholder: "forge_...",
                credentialFooterMarkdown: "Forge keys are encrypted at rest.",
                supportsHosted: false,
                supportsSelfHosted: false
            )

        case .augment:
            return ProviderSetupGuide(
                provider: provider,
                kinds: [.token, .bearer, .session],
                defaultKind: .session,
                labelSuggestion: "Augment",
                dashboardURL: URL(string: "https://augmentcode.com"),
                dashboardCTA: "Open Augment",
                oneLineHint: "Session token from Augment's web app.",
                instructions: [
                    GuideStep(1, "Open Augment's web app", detail: "Sign in with the same account you use in your editor."),
                    GuideStep(2, "Copy the session cookie", detail: "DevTools → Application → Cookies → augmentcode.com → session."),
                    GuideStep(3, "Paste it below", detail: "We reuse Augment's own auth.")
                ],
                credentialPlaceholder: "Augment session token",
                credentialFooterMarkdown: "Sessions can expire. Reconnect if quota refresh stops.",
                supportsHosted: false,
                supportsSelfHosted: false
            )

        case .hermes:
            return ProviderSetupGuide(
                provider: provider,
                kinds: [.token, .bearer],
                defaultKind: .bearer,
                labelSuggestion: "Hermes",
                dashboardURL: URL(string: "https://hermes.ai"),
                dashboardCTA: "Open Hermes",
                oneLineHint: "API token from your Hermes workspace.",
                instructions: [
                    GuideStep(1, "Open your Hermes workspace", detail: "Sign in with your account."),
                    GuideStep(2, "Create an API token", detail: "Settings → Tokens → New."),
                    GuideStep(3, "Paste it below", detail: "OpenBurnBar reads usage and quota.")
                ],
                credentialPlaceholder: "hermes_...",
                credentialFooterMarkdown: "Hermes tokens are encrypted at rest.",
                supportsHosted: false,
                supportsSelfHosted: false
            )

        case .geminiCLI:
            return ProviderSetupGuide(
                provider: provider,
                kinds: [.token, .bearer],
                defaultKind: .token,
                labelSuggestion: "Gemini",
                dashboardURL: URL(string: "https://aistudio.google.com/apikey"),
                dashboardCTA: "Open Google AI Studio",
                oneLineHint: "Google AI Studio API key.",
                instructions: [
                    GuideStep(1, "Open Google AI Studio", detail: "Sign in with your Google account."),
                    GuideStep(2, "Create an API key", detail: "Get API Key → Create API Key."),
                    GuideStep(3, "Paste it below", detail: "OpenBurnBar reads usage.")
                ],
                credentialPlaceholder: "AIza...",
                credentialFooterMarkdown: "Gemini keys are encrypted at rest.",
                supportsHosted: false,
                supportsSelfHosted: false
            )

        case .goose:
            return ProviderSetupGuide(
                provider: provider,
                kinds: [.token, .bearer],
                defaultKind: .token,
                labelSuggestion: "Goose",
                dashboardURL: URL(string: "https://block.github.io/goose/"),
                dashboardCTA: "Open Goose docs",
                oneLineHint: "Bring your own provider key (Goose routes through it).",
                instructions: [
                    GuideStep(1, "Open Goose's config", detail: "~/.config/goose/config.yaml"),
                    GuideStep(2, "Find the active provider key", detail: "Usually OpenAI, Anthropic, or Databricks."),
                    GuideStep(3, "Paste that key below", detail: "We track usage against the underlying provider.")
                ],
                credentialPlaceholder: "sk-...",
                credentialFooterMarkdown: "Goose routes through whichever provider you've configured.",
                supportsHosted: false,
                supportsSelfHosted: false
            )

        case .openClaw:
            return ProviderSetupGuide(
                provider: provider,
                kinds: [.token, .bearer],
                defaultKind: .token,
                labelSuggestion: "OpenClaw",
                dashboardURL: nil,
                dashboardCTA: "OpenClaw docs",
                oneLineHint: "API token from your OpenClaw workspace.",
                instructions: [
                    GuideStep(1, "Open your OpenClaw workspace", detail: "Sign in with your account."),
                    GuideStep(2, "Create an API token", detail: "Settings → Tokens."),
                    GuideStep(3, "Paste it below", detail: "OpenBurnBar reads usage.")
                ],
                credentialPlaceholder: "claw_...",
                credentialFooterMarkdown: "OpenClaw tokens are encrypted at rest.",
                supportsHosted: false,
                supportsSelfHosted: false
            )

        case .ollama:
            return ProviderSetupGuide(
                provider: provider,
                kinds: [.token],
                defaultKind: .token,
                labelSuggestion: "Ollama",
                dashboardURL: URL(string: "https://ollama.com"),
                dashboardCTA: "Open Ollama",
                oneLineHint: "Local-first — point us at your Ollama host.",
                instructions: [
                    GuideStep(1, "Run Ollama locally or on a server", detail: "Default port is 11434."),
                    GuideStep(2, "Note your host URL", detail: "e.g. http://localhost:11434", codeSnippet: "http://localhost:11434"),
                    GuideStep(3, "Paste it below", detail: "OpenBurnBar tracks model usage and request counts.")
                ],
                credentialPlaceholder: "http://localhost:11434",
                credentialFooterMarkdown: "Ollama runs locally — we only read usage stats from its API.",
                supportsHosted: false,
                supportsSelfHosted: false
            )

        case .windsurf:
            return ProviderSetupGuide(
                provider: provider,
                kinds: [.token, .bearer, .session],
                defaultKind: .session,
                labelSuggestion: "Windsurf",
                dashboardURL: URL(string: "https://codeium.com/windsurf"),
                dashboardCTA: "Open Windsurf",
                oneLineHint: "Codeium session token from the Windsurf web app.",
                instructions: [
                    GuideStep(1, "Open the Windsurf web app", detail: "Sign in with the same account you use in the editor."),
                    GuideStep(2, "Copy the session token", detail: "Settings → API or DevTools → Application → Cookies."),
                    GuideStep(3, "Paste it below", detail: "We reuse Codeium's auth.")
                ],
                credentialPlaceholder: "Windsurf session token",
                credentialFooterMarkdown: "Sessions can expire. Reconnect if quota refresh stops.",
                supportsHosted: false,
                supportsSelfHosted: false
            )

        case .warp:
            return ProviderSetupGuide(
                provider: provider,
                kinds: [.token, .bearer, .session],
                defaultKind: .session,
                labelSuggestion: "Warp",
                dashboardURL: URL(string: "https://app.warp.dev"),
                dashboardCTA: "Open Warp",
                oneLineHint: "Warp session token from the web app.",
                instructions: [
                    GuideStep(1, "Open the Warp web app", detail: "Sign in with the same account you use in the terminal."),
                    GuideStep(2, "Copy the session token", detail: "DevTools → Application → Cookies → warp.dev."),
                    GuideStep(3, "Paste it below", detail: "We reuse Warp's auth.")
                ],
                credentialPlaceholder: "Warp session token",
                credentialFooterMarkdown: "Sessions can expire. Reconnect if quota refresh stops.",
                supportsHosted: false,
                supportsSelfHosted: false
            )
        }
    }

    /// Friendly per-kind label for the credential picker (e.g. "Bearer token" instead of "bearer").
    static func credentialKindLabel(_ kind: CredentialKind) -> String {
        switch kind {
        case .token:   return "Token"
        case .bearer:  return "Bearer"
        case .session: return "Session"
        case .cookie:  return "Cookie"
        case .plan:    return "Plan code"
        }
    }
}

// MARK: - Recommended ordering

extension ProviderSetupGuide {
    /// "Top picks" the wizard surfaces first — the providers most users connect.
    static let recommended: [AgentProvider] = [
        .claudeCode,
        .factory,
        .codex,
        .openAI,
        .cursor,
        .copilot,
        .geminiCLI
    ]

    static func sortedProvidersForOnboarding() -> [AgentProvider] {
        let recommendedSet = Set(recommended)
        let recommendedOrdered = recommended.filter { AgentProvider.allCases.contains($0) }
        let rest = AgentProvider.allCases
            .filter { !recommendedSet.contains($0) }
            .sorted { $0.displayName < $1.displayName }
        return recommendedOrdered + rest
    }
}
