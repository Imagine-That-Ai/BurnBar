// PORTED 1:1 from AgentLens/Views/Settings/Search/SettingsManifest.swift (baseItems, part 3/3).
//
// EXACT Swift order concludes: Text Expansion, Media & Sharing, Computer Use, Pets,
// the Account-Switcher rows (now under Agents), the Hermes / AI-environment rows
// (now under Agents), and The Elder Wand analysis-model / fusion-impact rows.

using System.Collections.Generic;

namespace OpenBurnBar.App.Settings;

public static partial class SettingsManifest
{
    private static IReadOnlyList<SettingsItem> ExtrasGroupItems { get; } = new[]
    {
        // MARK: Text Expansion
        new SettingsItem(
            id: "textExpansion.snippets",
            tab: SettingsTab.TextExpansion,
            pageRoute: SettingsPageRoute.TextExpansionRoot,
            anchorId: SettingsAnchor.TextExpansionSnippets,
            title: "Snippets",
            subtitle: "Manage && triggers, static expansions, and LLM preview snippets",
            keywords: new[] { "text expansion", "snippet", "textexpander", "trigger", "keyboard", "llm", "rewrite" },
            helpText: "Creates user-defined snippets that expand from &&trigger tokens inside OpenBurnBar and opted-in system typing surfaces."),
        new SettingsItem(
            id: "textExpansion.runtime",
            tab: SettingsTab.TextExpansion,
            pageRoute: SettingsPageRoute.TextExpansionRoot,
            anchorId: SettingsAnchor.TextExpansionRuntime,
            title: "Expansion Runtime",
            subtitle: "Control in-app expansion, Mac global expansion, keyboard snapshots, and LLM preview behavior",
            keywords: new[] { "runtime", "global", "mac", "ime", "keyboard extension", "full access", "preview" }),

        // MARK: Media & Sharing
        new SettingsItem(
            id: "media.permissions",
            tab: SettingsTab.Media,
            pageRoute: SettingsPageRoute.MediaRoot,
            anchorId: SettingsAnchor.MediaPermissions,
            title: "Media Permissions",
            subtitle: "Camera, microphone, screen sharing, and file-transfer readiness for Mercury sessions",
            keywords: new[]
            {
                "media", "mercury", "permissions", "camera", "microphone", "mic",
                "screen recording", "screen share", "file transfer", "voice call",
                "video call", "sharing", "iroh",
            }),

        // MARK: Computer Use
        new SettingsItem(
            id: "computerUse.readiness",
            tab: SettingsTab.ComputerUse,
            pageRoute: SettingsPageRoute.ComputerUseRoot,
            anchorId: SettingsAnchor.ComputerUseReadiness,
            title: "Computer Use Readiness",
            subtitle: "Agent Watch, browser automation, Mac input, approvals, and audit chain",
            keywords: new[]
            {
                "computer use", "agent watch", "browser", "playwright", "mac input",
                "approval", "panic", "audit", "accessibility",
            },
            helpText: "Shows local permission state and the controls needed to validate Computer Use on this Mac."),
        new SettingsItem(
            id: "computerUse.permissionsSetup",
            tab: SettingsTab.ComputerUse,
            pageRoute: SettingsPageRoute.ComputerUseRoot,
            anchorId: SettingsAnchor.ComputerUsePermissionsSetup,
            title: "Re-run Mac Permissions Setup",
            subtitle: "Walk through Screen Recording, Accessibility, Camera, Mic, Full Disk, and Automation in order",
            keywords: new[]
            {
                "permissions", "screen recording", "accessibility", "camera", "microphone",
                "mic", "full disk access", "fda", "automation", "applescript", "tcc", "reset",
            },
            helpText: "Reopens the step-by-step Mac permissions wizard so an existing user can grant anything they skipped during onboarding."),

        // MARK: Pets
        new SettingsItem(
            id: "pets.companion",
            tab: SettingsTab.Pets,
            pageRoute: SettingsPageRoute.PetsRoot,
            anchorId: SettingsAnchor.PetsCompanion,
            title: "Desktop Pet",
            subtitle: "Show, pick, and summon the companion, including the pet's answering agent",
            keywords: new[]
            {
                "pet", "pets", "companion", "desktop pet", "summon", "hide",
                "hotkey", "paw", "agent", "brain", "answering agent", "mascot",
            },
            helpText: "Opens the desktop companion controls for visibility, pet form selection, and the enabled answering-agent picker."),

        // MARK: Account Switcher — now lives inside Agents → CLIs / Advanced.
        new SettingsItem(
            id: "switcher.browser",
            tab: SettingsTab.Agents,
            pageRoute: SettingsPageRoute.AgentsAdvanced,
            anchorId: SettingsAnchor.SwitcherBrowser,
            title: "Browser Profiles",
            subtitle: "Launch isolated browser profiles per provider (now under Agents → Advanced)",
            keywords: new[] { "browser", "profile", "chrome", "safari", "firefox", "switcher" }),
        new SettingsItem(
            id: "switcher.cli",
            tab: SettingsTab.Agents,
            pageRoute: SettingsPageRoute.AgentsCLIs,
            anchorId: SettingsAnchor.SwitcherCLI,
            title: "CLI Profiles",
            subtitle: "Swap CLI credentials between Claude / Codex / OpenCode accounts (now under Agents → CLIs)",
            keywords: new[] { "cli", "profile", "credentials", "swap", "switcher" },
            logoProviders: new[] { AgentProvider.ClaudeCode, AgentProvider.Codex, AgentProvider.OpenCode, AgentProvider.Factory }),

        // MARK: Hermes / AI environments — now live inside Agents → Runtimes / Advanced.
        new SettingsItem(
            id: "hermes.connections",
            tab: SettingsTab.Agents,
            pageRoute: SettingsPageRoute.AgentsAdvanced,
            anchorId: SettingsAnchor.HermesConnections,
            title: "Chat Engines",
            subtitle: "Choose which chat engines appear in OpenBurnBar (now under Agents → Advanced)",
            keywords: new[] { "hermes", "pi", "connection", "engine", "chat", "codex", "claude", "openclaw" },
            logoProviders: new[] { AgentProvider.Hermes, AgentProvider.PiAgent, AgentProvider.OpenClaw, AgentProvider.ClaudeCode, AgentProvider.Codex }),
        new SettingsItem(
            id: "hermes.models",
            tab: SettingsTab.Agents,
            pageRoute: SettingsPageRoute.AgentsAdvanced,
            anchorId: SettingsAnchor.HermesModels,
            title: "Hermes Models",
            subtitle: "Default models exposed by Hermes (now under Agents → Advanced)",
            keywords: new[] { "model", "hermes", "claude", "gpt", "llm" },
            logoProviders: new[] { AgentProvider.Hermes, AgentProvider.ClaudeCode, AgentProvider.OpenAI, AgentProvider.GeminiCLI }),
        new SettingsItem(
            id: "hermes.gateway.url",
            tab: SettingsTab.Agents,
            pageRoute: SettingsPageRoute.AgentsRuntimes,
            anchorId: SettingsAnchor.HermesGatewayURL,
            focusId: SettingsFocus.HermesGatewayURL,
            title: "Hermes Gateway URL",
            subtitle: "Base URL of the Hermes webapi gateway (now under Agents → Runtimes)",
            keywords: new[] { "gateway", "url", "endpoint", "webapi", "hermes" },
            logoProviders: new[] { AgentProvider.Hermes }),
        new SettingsItem(
            id: "hermes.gateway.token",
            tab: SettingsTab.Agents,
            pageRoute: SettingsPageRoute.AgentsRuntimes,
            anchorId: SettingsAnchor.HermesGatewayToken,
            focusId: SettingsFocus.HermesGatewayToken,
            title: "Hermes Gateway Token",
            subtitle: "Bearer token used to authenticate to the gateway (now under Agents → Runtimes)",
            keywords: new[] { "bearer", "token", "secret", "gateway", "hermes" },
            logoProviders: new[] { AgentProvider.Hermes }),
        new SettingsItem(
            id: "hermes.pi.hosts",
            tab: SettingsTab.Agents,
            pageRoute: SettingsPageRoute.AgentsRuntimes,
            anchorId: SettingsAnchor.HermesPiHosts,
            title: "Pi Agent Base URL",
            subtitle: "Gateway endpoint for local Pi runtimes (now under Agents → Runtimes)",
            keywords: new[] { "pi", "raspberry", "host", "edge", "gateway", "url" },
            logoProviders: new[] { AgentProvider.PiAgent }),
        new SettingsItem(
            id: "hermes.relay",
            tab: SettingsTab.Agents,
            pageRoute: SettingsPageRoute.AgentsRuntimes,
            anchorId: SettingsAnchor.HermesRelay,
            title: "Hermes Remote Relay",
            subtitle: "Reach Hermes from the cloud relay endpoint (now under Agents → Runtimes)",
            keywords: new[] { "hermes", "relay", "remote", "tunnel", "cloud" },
            logoProviders: new[] { AgentProvider.Hermes }),
        new SettingsItem(
            id: "hermes.pi.relay",
            tab: SettingsTab.Agents,
            pageRoute: SettingsPageRoute.AgentsRuntimes,
            anchorId: SettingsAnchor.HermesPiRelay,
            title: "Pi Remote Relay",
            subtitle: "Reach Pi from the cloud relay endpoint (now under Agents → Runtimes)",
            keywords: new[] { "pi", "raspberry", "relay", "remote", "tunnel", "cloud" },
            logoProviders: new[] { AgentProvider.PiAgent }),

        // MARK: The Elder Wand — analysis-model fusion configurator (Cloud Pro)
        new SettingsItem(
            id: "agents.analysisConfigurator",
            tab: SettingsTab.Agents,
            pageRoute: SettingsPageRoute.AnalysisConfigurator,
            anchorId: SettingsAnchor.AnalysisConfigurator,
            title: "Analysis Models",
            subtitle: "Build a panel of models and a judge for The Elder Wand",
            keywords: new[] { "elder wand", "fusion", "panel", "judge", "analysis models" },
            helpText: "Opens The Elder Wand configurator: pick the analysis panel and judge model, set a tool-call budget, and save named presets."),
        new SettingsItem(
            id: "agents.fusionImpact",
            tab: SettingsTab.Agents,
            pageRoute: SettingsPageRoute.FusionImpact,
            anchorId: SettingsAnchor.FusionImpact,
            title: "Fusion Impact",
            subtitle: "What The Elder Wand spent — fusion versus normal, per model, this period",
            keywords: new[]
            {
                "elder wand", "fusion", "impact", "spend", "cost", "receipt",
                "how much", "per model", "this month", "last 30 days",
                "fusion searches", "quota", "multiplier", "cost of certainty",
            },
            helpText: "Opens the standing Fusion Impact screen: fusion-versus-normal spend over the period, per-model contribution, fusion run tally, and the fusion-search quota meter."),
    };
}
