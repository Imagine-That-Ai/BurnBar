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
                oneLineHint: "Hosted sync or self-hosted runner — Claude Code quota on any device.",
                instructions: [
                    GuideStep(1, "Choose a sync mode", detail: "Hosted sync stores credentials encrypted server-side. Self-hosted keeps them on your runner."),
                    GuideStep(2, "Paste your credential or runner URL", detail: "For hosted: paste your Claude Code auth JSON. For self-hosted: provide your runner URL."),
                    GuideStep(3, "Quota refreshes automatically", detail: "Your Claude Code usage and remaining limits appear in real time.")
                ],
                credentialPlaceholder: "Paste credentials JSON or use a runner URL",
                credentialFooterMarkdown: "Hosted sync stores your credentials encrypted server-side. Self-hosted keeps credentials on your runner only.",
                supportsHosted: true,
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
                labelSuggestion: "Z.ai",
                dashboardURL: URL(string: "https://z.ai/manage-apikey/apikey-list"),
                dashboardCTA: "Open Z.ai API keys",
                oneLineHint: "API key from Z.ai (or open.bigmodel.cn if you're on the China platform).",
                instructions: [
                    GuideStep(1, "Open Z.ai's API keys page", detail: "International users sign in to z.ai. Mainland China accounts can use open.bigmodel.cn — both keys work."),
                    GuideStep(2, "Create an API key", detail: "Read access is enough; OpenBurnBar only reads quota and balance."),
                    GuideStep(3, "Paste the key below", detail: "We validate via api.z.ai/api/paas/v4/models and read your coding-plan window.")
                ],
                credentialPlaceholder: "Paste your Z.ai API key",
                credentialFooterMarkdown: "Z.ai keys are encrypted at rest. We try `api.z.ai` first and fall back to `open.bigmodel.cn` automatically.",
                supportsHosted: false,
                supportsSelfHosted: false
            )

        case .minimax:
            return ProviderSetupGuide(
                provider: provider,
                kinds: [.token, .bearer],
                defaultKind: .bearer,
                labelSuggestion: "MiniMax",
                dashboardURL: URL(string: "https://platform.minimax.io/user-center/basic-information/interface-key"),
                dashboardCTA: "Open MiniMax keys",
                oneLineHint: "Token Plan API key from platform.minimax.io.",
                instructions: [
                    GuideStep(1, "Open the MiniMax console", detail: "Sign in and navigate to Interface Key."),
                    GuideStep(2, "Copy your API key", detail: "Token Plan keys validate via api.minimax.io. Coding Plan keys (`sk-cp-…`) also work."),
                    GuideStep(3, "Paste the key below", detail: "OpenBurnBar reads remaining tokens and your 5-hour / weekly quota window.")
                ],
                credentialPlaceholder: "Paste your MiniMax API key",
                credentialFooterMarkdown: "MiniMax keys are encrypted at rest. We hit `www.minimax.io/v1/token_plan/remains` to validate.",
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
                oneLineHint: "API key from Moonshot AI — live quota refresh from any device.",
                instructions: [
                    GuideStep(1, "Open the Moonshot console", detail: "Sign in to platform.moonshot.cn."),
                    GuideStep(2, "Create an API key", detail: "Console → API Keys → Create. International users can also use api.kimi.ai keys."),
                    GuideStep(3, "Paste it below", detail: "Starts with `sk-`.")
                ],
                credentialPlaceholder: "sk-...",
                credentialFooterMarkdown: "Kimi API keys are encrypted at rest and refreshed automatically. We validate against /v1/models and try both api.kimi.ai and api.moonshot.cn.",
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
                oneLineHint: "Runtime token for Hermes chat and agent activity.",
                instructions: [
                    GuideStep(1, "Open your Hermes workspace", detail: "Sign in with your account."),
                    GuideStep(2, "Create an API token", detail: "Settings → Tokens → New."),
                    GuideStep(3, "Paste it below", detail: "OpenBurnBar uses Hermes for chat/runtime activity, not provider quota.")
                ],
                credentialPlaceholder: "hermes_...",
                credentialFooterMarkdown: "Hermes has no quota endpoint. Tokens are encrypted at rest.",
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
                oneLineHint: "Ollama Cloud quota is read from signed-in Mac browser sessions.",
                instructions: [
                    GuideStep(1, "Sign in to Ollama Cloud on your Mac", detail: "Open ollama.com in Chrome with the account that owns your cloud plan."),
                    GuideStep(2, "Open the Mac app", detail: "OpenBurnBar reads Ollama Cloud's 5-hour and weekly quota windows when the dashboard exposes them."),
                    GuideStep(3, "Keep local Ollama optional", detail: "Local models have no quota and are not shown under Quota.")
                ],
                credentialPlaceholder: "Optional Ollama Cloud API key",
                credentialFooterMarkdown: "Local model counts are not quota. Only Ollama Cloud quota windows appear in Quota.",
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

        case .piAgent:
            return ProviderSetupGuide(
                provider: provider,
                kinds: [.token, .bearer],
                defaultKind: .token,
                labelSuggestion: "Pi Agent",
                dashboardURL: nil,
                dashboardCTA: "Run Pi locally",
                oneLineHint: "Pi Agent gateway token from your local install.",
                instructions: [
                    GuideStep(1, "Open Pi gateway", detail: "Launch Pi locally so its OpenAI-compatible gateway is running."),
                    GuideStep(2, "Copy the gateway token", detail: "Pi prints it on first launch; check your terminal logs or config."),
                    GuideStep(3, "Paste it below", detail: "OpenBurnBar uses the token to route chat through Pi.")
                ],
                credentialPlaceholder: "pi_...",
                credentialFooterMarkdown: "Pi runs locally; tokens never leave your machine.",
                supportsHosted: false,
                supportsSelfHosted: true
            )

        case .openCode:
            return ProviderSetupGuide(
                provider: provider,
                kinds: [.session],
                defaultKind: .session,
                labelSuggestion: "OpenCode",
                dashboardURL: URL(string: "https://opencode.ai/docs/go/"),
                dashboardCTA: "Open OpenCode Go docs",
                oneLineHint: "Self-hosted quota sync from a signed-in OpenCode CLI.",
                instructions: [
                    GuideStep(1, "Sign in with OpenCode Go", detail: "Use the OpenCode CLI account you want OpenBurnBar to track."),
                    GuideStep(2, "Run your quota runner where OpenCode is signed in", detail: "The runner reads local OpenCode stats and returns sanitized quota buckets.", codeSnippet: "~/.local/share/opencode/auth.json"),
                    GuideStep(3, "Paste your runner URL below", detail: "OpenBurnBar does not collect OpenCode auth for hosted refresh until OpenCode publishes a stable quota API.")
                ],
                credentialPlaceholder: "https://your-runner.example.com",
                credentialFooterMarkdown: "Self-hosted OpenCode sync keeps auth on your runner and estimates 5h, 7d, and monthly pressure from local CLI stats.",
                supportsHosted: false,
                supportsSelfHosted: true
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

// MARK: - Registry bridge

extension ProviderSetupGuide {

    /// Returns the `BurnBarProviderAuthRegistry` descriptor that matches this
    /// provider, if one exists. The registry is the cross-platform source of
    /// truth for credential metadata (placeholder, dashboard URL, validation).
    /// Hand-coded guides above remain authoritative for numbered instructions
    /// and iOS-specific copy that can't live in the shared registry.
    static func registryDescriptor(for provider: AgentProvider) -> BurnBarProviderAuthDescriptor? {
        let candidates = registryCatalogIDCandidates(for: provider)
        for candidate in candidates {
            if let descriptor = BurnBarProviderAuthRegistry.descriptor(forCatalogProviderID: candidate) {
                return descriptor
            }
        }
        return nil
    }

    /// Returns the canonical primary `BurnBarProviderAuthMethod` for this
    /// provider (used for placeholder text, prefix hints, and validation),
    /// or `nil` if the registry has no descriptor for it.
    static func registryPrimaryMethod(for provider: AgentProvider) -> BurnBarProviderAuthMethod? {
        registryDescriptor(for: provider)?.primaryMethod
    }

    /// Catalog provider IDs to probe in the shared registry. We try the
    /// canonical `providerID.rawValue` first, then per-provider aliases that
    /// the registry expects (e.g. `.kimi` → "moonshot", `.claudeCode` →
    /// "anthropic", `.geminiCLI` → "google").
    private static func registryCatalogIDCandidates(for provider: AgentProvider) -> [String] {
        var ids: [String] = [provider.providerID.rawValue, provider.persistedToken]
        switch provider {
        case .kimi:
            ids.append(contentsOf: ["moonshot", "kimi"])
        case .claudeCode:
            ids.append(contentsOf: ["anthropic", "claude-code", "claude"])
        case .geminiCLI:
            ids.append(contentsOf: ["google", "gemini", "gemini-cli"])
        case .openAI:
            ids.append("openai")
        case .zai:
            ids.append(contentsOf: ["zai", "z-ai", "z.ai", "glm"])
        case .minimax:
            ids.append("minimax")
        case .ollama:
            ids.append("ollama")
        default:
            break
        }
        return ids.compactMap { id in
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    /// Hand-coded guide enriched with registry metadata when available.
    /// Falls through to `guide(for:)` when no descriptor exists. The
    /// hand-coded numbered instructions are always preserved — the registry
    /// only overrides credential placeholder, prefix-hint footer copy, and
    /// the dashboard CTA when the registry's data is more accurate.
    static func registryEnrichedGuide(for provider: AgentProvider) -> ProviderSetupGuide {
        let base = guide(for: provider)
        guard let descriptor = registryDescriptor(for: provider) else { return base }

        let primary = descriptor.primaryMethod
        let placeholder = primary.placeholder.isEmpty ? base.credentialPlaceholder : primary.placeholder
        let dashboardURL = primary.dashboardURL.flatMap(URL.init(string:)) ?? base.dashboardURL
        let dashboardCTA: String = {
            if let label = primary.dashboardLabel, !label.isEmpty { return label }
            return base.dashboardCTA
        }()
        let oneLineHint = descriptor.summary.isEmpty ? base.oneLineHint : descriptor.summary
        let footer: String = {
            var parts: [String] = []
            if !primary.helperText.isEmpty { parts.append(primary.helperText) }
            if let proxy = descriptor.proxyHint, !proxy.isEmpty { parts.append(proxy) }
            if let quota = descriptor.quotaHint, !quota.isEmpty { parts.append(quota) }
            return parts.isEmpty ? base.credentialFooterMarkdown : parts.joined(separator: " ")
        }()

        return ProviderSetupGuide(
            provider: base.provider,
            kinds: base.kinds,
            defaultKind: base.defaultKind,
            labelSuggestion: base.labelSuggestion,
            dashboardURL: dashboardURL,
            dashboardCTA: dashboardCTA,
            oneLineHint: oneLineHint,
            instructions: base.instructions,
            credentialPlaceholder: placeholder,
            credentialFooterMarkdown: footer,
            supportsHosted: base.supportsHosted,
            supportsSelfHosted: base.supportsSelfHosted
        )
    }

    /// Validates `credential` against the registry's per-method validator
    /// when available; otherwise falls back to the existing length heuristic.
    static func registryValidation(
        credential: String,
        for provider: AgentProvider
    ) -> BurnBarProviderAuthValidation {
        guard let primary = registryPrimaryMethod(for: provider) else {
            let trimmed = credential.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return .empty }
            if trimmed.count < 8 { return .warning("That looks too short — make sure you copied the full credential.") }
            return .ok
        }
        return primary.validate(credential)
    }

    /// Capability chips surfaced on the wizard's provider tile / confirm hero.
    /// macOS exposes routed-proxy. iOS only mirrors quota — we still surface
    /// "Routes on Mac" copy so users understand the cross-device picture.
    static func capabilityChips(for provider: AgentProvider) -> [String] {
        guard let descriptor = registryDescriptor(for: provider) else {
            return []
        }
        var chips: [String] = []
        if descriptor.supportsQuotaRefresh { chips.append("Live quota") }
        if descriptor.supportsProxyRouting { chips.append("Routes on Mac") }
        return chips
    }
}

// MARK: - Recommended ordering

extension ProviderSetupGuide {
    /// "Top picks" the wizard surfaces first — the providers most users connect.
    /// Keep this in sync with `AgentProvider.mobileAccountConnectableProviders`;
    /// listing a provider here that the backend can't validate would advertise
    /// a connect flow that always fails.
    static let recommended: [AgentProvider] = [
        .claudeCode,
        .codex,
        .kimi,
        .factory,
        .cursor,
        .minimax,
        .zai,
        .openAI,
    ]

    static func sortedProvidersForOnboarding() -> [AgentProvider] {
        let recommendedSet = Set(recommended)
        let catalog = AgentProvider.mobileAccountConnectableProviders
        let recommendedOrdered = recommended.filter { catalog.contains($0) }
        let rest = catalog
            .filter { !recommendedSet.contains($0) }
            .sorted { $0.displayName < $1.displayName }
        return recommendedOrdered + rest
    }
}
