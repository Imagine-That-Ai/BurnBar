// PORTED 1:1 from AgentLens/Views/Settings/Search/SettingsManifest.swift (baseItems, part 1/3).
//
// This partial holds the FIRST run of hand-authored manifest rows in EXACT Swift
// declaration order — Home, Model Proxy, Data & Privacy inventory, the General
// operator wizard, Updates, and the whole General → Appearance / Defaults / Refresh
// / Indexing / Summaries block. Order is load-bearing: SettingsManifest.All is
// `GeneralGroupItems + MiddleGroupItems + ExtrasGroupItems + ProviderItems`, and the
// search engine's stable tie-break falls back to this order.

using System.Collections.Generic;

namespace OpenBurnBar.App.Settings;

public static partial class SettingsManifest
{
    private static IReadOnlyList<SettingsItem> GeneralGroupItems { get; } = new[]
    {
        // MARK: Home
        new SettingsItem(
            id: "home.overview",
            tab: SettingsTab.Home,
            pageRoute: SettingsPageRoute.HomeRoot,
            anchorId: SettingsAnchor.HomeOverview,
            title: "Settings Home",
            subtitle: "System health, quick actions, and attention items",
            keywords: new[] { "home", "overview", "dashboard", "status", "health", "summary", "start", "welcome" }),

        // MARK: Model Proxy (unified local gateway + routing + models)
        new SettingsItem(
            id: "modelProxy.overview",
            tab: SettingsTab.ModelProxy,
            pageRoute: SettingsPageRoute.ModelProxyRoot,
            anchorId: SettingsAnchor.ModelProxyOverview,
            title: "Model Proxy",
            subtitle: "Local OpenAI-compatible gateway — expose models to Cursor, VS Code, any client",
            keywords: new[]
            {
                "proxy", "gateway", "endpoint", "hydrant", "openai", "v1/models",
                "local", "server", "api", "cursor", "vscode", "vs code", "client",
                "expose", "route", "models", "catalog",
            },
            logoProviders: new[] { AgentProvider.ClaudeCode, AgentProvider.OpenAI, AgentProvider.Codex }),
        new SettingsItem(
            id: "modelProxy.endpoint",
            tab: SettingsTab.ModelProxy,
            pageRoute: SettingsPageRoute.ModelProxyRoot,
            anchorId: SettingsAnchor.ModelProxyEndpoint,
            title: "Gateway Endpoint",
            subtitle: "The host:port the local gateway listens on",
            keywords: new[] { "endpoint", "host", "port", "address", "url", "gateway", "proxy" }),
        new SettingsItem(
            id: "modelProxy.routing",
            tab: SettingsTab.ModelProxy,
            pageRoute: SettingsPageRoute.ModelProxyRoot,
            anchorId: SettingsAnchor.ModelProxyRouting,
            title: "Routing Strategy",
            subtitle: "How requests pick a model when the exact name isn't available",
            keywords: new[] { "routing", "strategy", "failover", "fallback", "provider", "family", "exact", "model" }),

        // MARK: Data & Privacy control center
        new SettingsItem(
            id: "dataPrivacy.controlCenter.inventory",
            tab: SettingsTab.DataPrivacy,
            pageRoute: SettingsPageRoute.DataControlCenterRoot,
            anchorId: SettingsAnchor.DataControlCenterInventory,
            title: "Data & Privacy Control Center",
            subtitle: "See, export, delete, recover, and panic-revoke your BurnBar data",
            keywords: new[] { "privacy", "encryption", "vault", "pensieve", "delete", "export", "panic", "zero-knowledge" },
            helpText: "Opens the Pensieve Data & Privacy Control Center inventory and governance controls."),

        // MARK: General → Operator model & setup
        new SettingsItem(
            id: "general.operator.wizard",
            tab: SettingsTab.General,
            pageRoute: SettingsPageRoute.OperatorModel,
            anchorId: SettingsAnchor.OperatorWizard,
            title: "Setup Wizard",
            subtitle: "Run the guided onboarding wizard",
            keywords: new[] { "onboarding", "agents", "detect", "wizard", "setup" },
            helpText: "Detects installed agents, enables indexing, and configures cloud features."),

        // MARK: Updates
        new SettingsItem(
            id: "updates.overview",
            tab: SettingsTab.Updates,
            pageRoute: SettingsPageRoute.UpdatesRoot,
            anchorId: SettingsAnchor.UpdatesOverview,
            title: "App Version",
            subtitle: "See the installed OpenBurnBar version and update channel",
            keywords: new[] { "updates", "version", "build", "channel", "release", "appcast" },
            helpText: "Shows the current app version, build number, source commit, and delivery channel."),
        new SettingsItem(
            id: "updates.automaticChecks",
            tab: SettingsTab.Updates,
            pageRoute: SettingsPageRoute.UpdatesRoot,
            anchorId: SettingsAnchor.UpdatesAutomaticChecks,
            title: "Automatically Check for Updates",
            subtitle: "Check shortly after launch and once a day",
            keywords: new[] { "automatic", "auto", "updates", "check", "daily", "prerelease", "pre-release", "homebrew", "dmg" },
            helpText: "Controls direct-download update checks and optional prerelease/source update behavior."),
        new SettingsItem(
            id: "updates.releaseNotes",
            tab: SettingsTab.Updates,
            pageRoute: SettingsPageRoute.UpdatesRoot,
            anchorId: SettingsAnchor.UpdatesReleaseNotes,
            title: "Release Notes",
            subtitle: "Open the GitHub releases page",
            keywords: new[] { "release notes", "changelog", "github", "download", "latest" },
            helpText: "Links to the release feed for inspecting new versions before installing."),

        // MARK: General → Appearance
        new SettingsItem(
            id: "general.appearance.theme",
            tab: SettingsTab.General,
            pageRoute: SettingsPageRoute.Appearance,
            anchorId: SettingsAnchor.AppearanceTheme,
            title: "Theme",
            subtitle: "System, Light, or Dark appearance",
            keywords: new[] { "dark", "light", "appearance", "mode", "color" },
            helpText: "Choose whether OpenBurnBar follows macOS or pins to Light or Dark."),
        new SettingsItem(
            id: "general.appearance.skin",
            tab: SettingsTab.General,
            pageRoute: SettingsPageRoute.Appearance,
            anchorId: SettingsAnchor.AppearanceSkin,
            title: "App Skin",
            subtitle: "Aurora ember look, or the Editorial paper console skin",
            keywords: new[] { "skin", "editorial", "paper", "aurora", "light", "ink", "coral", "console", "burnbar", "theme" },
            helpText: "Editorial re-skins OpenBurnBar in the light, paper-bright app.burnbar.ai console palette: one coral accent, ink text, hairlines."),
        new SettingsItem(
            id: "general.appearance.glassTransparency",
            tab: SettingsTab.General,
            pageRoute: SettingsPageRoute.Appearance,
            anchorId: SettingsAnchor.AppearanceGlassTransparency,
            title: "Liquid Glass Transparency",
            subtitle: "Make glass surfaces clearer or frostier than the system default",
            keywords: new[] { "glass", "transparency", "translucent", "frosted", "clear", "blur", "liquid", "opacity", "see-through", "material" },
            helpText: "Zero matches this Mac's appearance settings, including Reduce transparency. Slide toward Clear for more see-through glass, or Frosted for more privacy and contrast."),
        new SettingsItem(
            id: "general.appearance.menuBar",
            tab: SettingsTab.General,
            pageRoute: SettingsPageRoute.Appearance,
            anchorId: SettingsAnchor.AppearanceMenuBar,
            title: "Menu Bar Visibility",
            subtitle: "Show the OpenBurnBar icon in the menu bar",
            keywords: new[] { "menubar", "icon", "tray", "hide" }),
        new SettingsItem(
            id: "general.appearance.launchAtLogin",
            tab: SettingsTab.General,
            pageRoute: SettingsPageRoute.Appearance,
            anchorId: SettingsAnchor.AppearanceLaunchAtLogin,
            title: "Launch at Login",
            subtitle: "Start OpenBurnBar automatically when you sign in",
            keywords: new[] { "autostart", "boot", "startup", "login items" }),
        new SettingsItem(
            id: "general.appearance.usePremiumSOTAUX",
            tab: SettingsTab.General,
            pageRoute: SettingsPageRoute.Appearance,
            anchorId: SettingsAnchor.UsePremiumSotaUx,
            title: "Premium SOTA UX",
            subtitle: "Enable cinematic spring physics and specular button shimmers",
            keywords: new[] { "sota", "premium", "ux", "haptic", "spring", "shimmer" }),
        new SettingsItem(
            id: "general.appearance.useWebsiteBackground",
            tab: SettingsTab.General,
            pageRoute: SettingsPageRoute.Appearance,
            anchorId: SettingsAnchor.UseWebsiteBackground,
            title: "Swarm Background",
            subtitle: "Active, reconverging token-ember swarms from burnbar.ai with logo formation",
            keywords: new[] { "swarm", "particles", "ember", "website", "background", "backdrop", "murmuration", "burnbar", "logo" }),
        new SettingsItem(
            id: "general.appearance.useConstellationBackground",
            tab: SettingsTab.General,
            pageRoute: SettingsPageRoute.Appearance,
            anchorId: SettingsAnchor.UseConstellationBackground,
            title: "Constellation Style",
            subtitle: "Calm, slow background where one crest or provider logo at a time resolves from coloured dots, shimmers, and dissolves",
            keywords: new[] { "constellation", "calm", "slow", "ambient", "dots", "logo", "crest", "provider", "shimmer", "dissolve", "background", "swarm", "style" }),
        new SettingsItem(
            id: "general.appearance.useKernelBackdrop",
            tab: SettingsTab.General,
            pageRoute: SettingsPageRoute.Appearance,
            anchorId: SettingsAnchor.UseKernelBackdrop,
            title: "Window Backdrop",
            subtitle: "Live WebGL2 dashboard backdrop with a static native fallback",
            keywords: new[] { "kernel", "kernels", "window", "backdrop", "background", "webgl", "webgl2", "shader", "sota", "ambient", "animated", "fluid", "aurora" },
            helpText: "Enable the experimental kernel field without requiring the native Swarm Background renderer."),
        new SettingsItem(
            id: "general.appearance.backdropKernel",
            tab: SettingsTab.General,
            pageRoute: SettingsPageRoute.Appearance,
            anchorId: SettingsAnchor.BackdropKernel,
            title: "Backdrop Kernel",
            subtitle: "Choose which animated field renders behind the dashboard",
            keywords: new[] { "kernel", "picker", "fluid aurora", "mesh", "moire", "plasma", "lattice", "shader", "field", "window backdrop" }),
        new SettingsItem(
            id: "general.appearance.desktopWallpaperEnabled",
            tab: SettingsTab.General,
            pageRoute: SettingsPageRoute.Appearance,
            anchorId: SettingsAnchor.DesktopWallpaperEnabled,
            title: "Desktop Swarm Wallpaper",
            subtitle: "Render the live swarm as your macOS desktop wallpaper",
            keywords: new[] { "desktop", "wallpaper", "swarm", "macos", "background", "particles" }),
        new SettingsItem(
            id: "general.appearance.desktopWallpaperBackground",
            tab: SettingsTab.General,
            pageRoute: SettingsPageRoute.Appearance,
            anchorId: SettingsAnchor.DesktopWallpaperBackground,
            title: "Desktop Wallpaper Background",
            subtitle: "Choose macOS Desktop, neutral darks, or the Aurora, Crimson, Cyberpunk, Moss, and Solar swarm palettes",
            keywords: new[] { "desktop", "wallpaper", "background", "macos", "amoled", "black", "graphite", "indigo", "aurora", "crimson", "cyberpunk", "moss", "solar", "swarm", "color", "palette" }),
        new SettingsItem(
            id: "general.appearance.desktopWallpaperSpeed",
            tab: SettingsTab.General,
            pageRoute: SettingsPageRoute.Appearance,
            anchorId: SettingsAnchor.DesktopWallpaperSpeed,
            title: "Desktop Wallpaper Speed",
            subtitle: "Dial how quickly the desktop swarm drifts, reforms, and cycles",
            keywords: new[] { "desktop", "wallpaper", "speed", "pace", "dial", "slider", "swarm", "motion", "cycle" }),
        new SettingsItem(
            id: "general.appearance.desktopWallpaperProviderGlyphs",
            tab: SettingsTab.General,
            pageRoute: SettingsPageRoute.Appearance,
            anchorId: SettingsAnchor.DesktopWallpaperProviderGlyphs,
            title: "Customize Provider Glyphs",
            subtitle: "Choose which provider logos render in the desktop swarm wallpaper cycle",
            keywords: new[] { "desktop", "wallpaper", "provider", "glyph", "logo", "customize", "filter", "swarm", "formation" }),
        new SettingsItem(
            id: "general.appearance.desktopWallpaperClickCycle",
            tab: SettingsTab.General,
            pageRoute: SettingsPageRoute.Appearance,
            anchorId: SettingsAnchor.DesktopWallpaperClickCycle,
            title: "Click Desktop to Cycle Shapes",
            subtitle: "Click empty desktop space to inspect swarm symbols, provider logos, Grok, and xAI",
            keywords: new[] { "desktop", "wallpaper", "click", "cycle", "shape", "provider", "logo", "grok", "xai", "x.ai", "inspection" }),

        // MARK: General → Dashboard defaults
        new SettingsItem(
            id: "general.defaults.timeRange",
            tab: SettingsTab.General,
            pageRoute: SettingsPageRoute.DefaultView,
            anchorId: SettingsAnchor.DefaultsTimeRange,
            title: "Default Time Range",
            subtitle: "Window used by charts and totals",
            keywords: new[] { "day", "week", "month", "range", "window", "default" }),
        new SettingsItem(
            id: "general.defaults.usageMode",
            tab: SettingsTab.General,
            pageRoute: SettingsPageRoute.DefaultView,
            anchorId: SettingsAnchor.DefaultsUsageMode,
            title: "Usage Display",
            subtitle: "Show USD spend or token totals (M / B)",
            keywords: new[] { "currency", "tokens", "usd", "dollars", "units" }),

        // MARK: General → Refresh
        new SettingsItem(
            id: "general.refresh.interval",
            tab: SettingsTab.General,
            pageRoute: SettingsPageRoute.DataRefresh,
            anchorId: SettingsAnchor.RefreshInterval,
            title: "Refresh Interval",
            subtitle: "How often OpenBurnBar scans for new sessions",
            keywords: new[] { "polling", "interval", "scan", "rate", "frequency" }),

        // MARK: General → Indexing
        new SettingsItem(
            id: "general.indexing.enabled",
            tab: SettingsTab.General,
            pageRoute: SettingsPageRoute.Indexing,
            anchorId: SettingsAnchor.IndexingToggle,
            title: "Indexing & Search",
            subtitle: "Local conversation indexing and embeddings",
            keywords: new[] { "search", "index", "embeddings", "rag", "rerank" },
            helpText: "Indexed transcripts never leave this Mac unless cloud backup is enabled."),

        // MARK: General → Session summaries
        new SettingsItem(
            id: "general.summaries.auto",
            tab: SettingsTab.General,
            pageRoute: SettingsPageRoute.SessionSummaries,
            anchorId: SettingsAnchor.SummariesAuto,
            title: "Auto-Generate Session Summaries",
            subtitle: "Write a recap after every scan",
            keywords: new[] { "recap", "summary", "session", "auto" }),
    };
}
