import Foundation
import OpenBurnBarCore

// MARK: - Settings Manifest (macOS)

/// Hand-authored index of every searchable control inside macOS Settings.
///
/// Each entry binds a user-facing label and its synonym set to a `pageRoute`
/// (detail screen) and `anchorID` (scroll target) so `SettingsRouter` can
/// land the user on the exact row, not just the section.
///
/// To add a new searchable item:
/// 1. Add an entry below.
/// 2. Add a matching `SettingsAnchor.<id>` if one doesn't exist.
/// 3. On the destination view, attach `.id(SettingsAnchor.<id>)` to the row.
/// 4. For focus-able controls, register the `focusID` against a
///    `@FocusState` in the destination.
enum SettingsManifest {

    static let all: [SettingsItem] = baseItems + localDBoxItems + providerItems

    private static let baseItems: [SettingsItem] = [
        // MARK: Home

        SettingsItem(
            id: "home.overview",
            tab: .home,
            pageRoute: .homeRoot,
            anchorID: SettingsAnchor.homeOverview,
            title: "Settings Home",
            subtitle: "System health, quick actions, and attention items",
            keywords: ["home", "overview", "dashboard", "status", "health", "summary", "start", "welcome"]
        ),

        // MARK: Model Proxy (unified local gateway + routing + models)

        SettingsItem(
            id: "modelProxy.overview",
            tab: .modelProxy,
            pageRoute: .modelProxyRoot,
            anchorID: SettingsAnchor.modelProxyOverview,
            title: "Model Proxy",
            subtitle: "Local OpenAI-compatible gateway — expose models to Cursor, VS Code, any client",
            keywords: [
                "proxy", "gateway", "endpoint", "hydrant", "openai", "v1/models",
                "local", "server", "api", "cursor", "vscode", "vs code", "client",
                "expose", "route", "models", "catalog"
            ],
            logoProviders: [.claudeCode, .openAI, .codex]
        ),
        SettingsItem(
            id: "modelProxy.endpoint",
            tab: .modelProxy,
            pageRoute: .modelProxyRoot,
            anchorID: SettingsAnchor.modelProxyEndpoint,
            title: "Gateway Endpoint",
            subtitle: "The host:port the local gateway listens on",
            keywords: ["endpoint", "host", "port", "address", "url", "gateway", "proxy"]
        ),
        SettingsItem(
            id: "modelProxy.routing",
            tab: .modelProxy,
            pageRoute: .modelProxyRoot,
            anchorID: SettingsAnchor.modelProxyRouting,
            title: "Routing Strategy",
            subtitle: "How requests pick a model when the exact name isn't available",
            keywords: ["routing", "strategy", "failover", "fallback", "provider", "family", "exact", "model"]
        ),

        SettingsItem(
            id: "dataPrivacy.controlCenter.inventory",
            tab: .dataPrivacy,
            pageRoute: .dataControlCenterRoot,
            anchorID: SettingsAnchor.dataControlCenterInventory,
            title: "Data & Privacy Control Center",
            subtitle: "See, export, delete, recover, and panic-revoke your BurnBar data",
            keywords: ["privacy", "encryption", "vault", "pensieve", "delete", "export", "panic", "zero-knowledge"],
            helpText: "Opens the Pensieve Data & Privacy Control Center inventory and governance controls."
        ),

        // MARK: General → Operator model & setup

        SettingsItem(
            id: "general.operator.wizard",
            tab: .general,
            pageRoute: .operatorModel,
            anchorID: SettingsAnchor.operatorWizard,
            title: "Setup Wizard",
            subtitle: "Run the guided onboarding wizard",
            keywords: ["onboarding", "agents", "detect", "wizard", "setup"],
            helpText: "Detects installed agents, enables indexing, and configures cloud features."
        ),

        // MARK: Updates

        SettingsItem(
            id: "updates.overview",
            tab: .updates,
            pageRoute: .updatesRoot,
            anchorID: SettingsAnchor.updatesOverview,
            title: "App Version",
            subtitle: "See the installed OpenBurnBar version and update channel",
            keywords: ["updates", "version", "build", "channel", "release", "appcast"],
            helpText: "Shows the current app version, build number, source commit, and delivery channel."
        ),
        SettingsItem(
            id: "updates.automaticChecks",
            tab: .updates,
            pageRoute: .updatesRoot,
            anchorID: SettingsAnchor.updatesAutomaticChecks,
            title: "Automatically Check for Updates",
            subtitle: "Check shortly after launch and once a day",
            keywords: ["automatic", "auto", "updates", "check", "daily", "prerelease", "pre-release", "homebrew", "dmg"],
            helpText: "Controls direct-download update checks and optional prerelease/source update behavior."
        ),
        SettingsItem(
            id: "updates.releaseNotes",
            tab: .updates,
            pageRoute: .updatesRoot,
            anchorID: SettingsAnchor.updatesReleaseNotes,
            title: "Release Notes",
            subtitle: "Open the GitHub releases page",
            keywords: ["release notes", "changelog", "github", "download", "latest"],
            helpText: "Links to the release feed for inspecting new versions before installing."
        ),

        // MARK: General → Appearance

        SettingsItem(
            id: "general.appearance.theme",
            tab: .general,
            pageRoute: .appearance,
            anchorID: SettingsAnchor.appearanceTheme,
            title: "Theme",
            subtitle: "System, Light, or Dark appearance",
            keywords: ["dark", "light", "appearance", "mode", "color"],
            helpText: "Choose whether OpenBurnBar follows macOS or pins to Light or Dark."
        ),
        SettingsItem(
            id: "general.appearance.skin",
            tab: .general,
            pageRoute: .appearance,
            anchorID: SettingsAnchor.appearanceSkin,
            title: "App Skin",
            subtitle: "Aurora ember look, or the Editorial paper console skin",
            keywords: ["skin", "editorial", "paper", "aurora", "light", "ink", "coral", "console", "burnbar", "theme"],
            helpText: "Editorial re-skins OpenBurnBar in the light, paper-bright app.burnbar.ai console palette: one coral accent, ink text, hairlines."
        ),
        SettingsItem(
            id: "general.appearance.glassTransparency",
            tab: .general,
            pageRoute: .appearance,
            anchorID: SettingsAnchor.appearanceGlassTransparency,
            title: "Liquid Glass Transparency",
            subtitle: "Make glass surfaces clearer or frostier than the system default",
            keywords: ["glass", "transparency", "translucent", "frosted", "clear", "blur", "liquid", "opacity", "see-through", "material"],
            helpText: "Zero matches this Mac's appearance settings, including Reduce transparency. Slide toward Clear for more see-through glass, or Frosted for more privacy and contrast."
        ),
        SettingsItem(
            id: "general.appearance.glassRefraction",
            tab: .general,
            pageRoute: .appearance,
            anchorID: SettingsAnchor.appearanceGlassRefraction,
            title: "Liquid Glass Refraction",
            subtitle: "How strongly glass bends the living backdrop behind it",
            // Deliberately disjoint from the transparency item's keywords: two rows that
            // both answer "glass" would make the search result a coin flip.
            keywords: ["refraction", "refract", "bend", "lens", "lensing", "optics", "dispersion", "caustics", "depth", "thickness"],
            helpText: "Transparency controls how much you see through the glass; this controls how much it bends what is behind it. The midpoint is exactly what the active theme intends — left for a flatter, calmer pane, right for a heavier optical block."
        ),
        SettingsItem(
            id: "general.appearance.menuBar",
            tab: .general,
            pageRoute: .appearance,
            anchorID: SettingsAnchor.appearanceMenuBar,
            title: "Menu Bar Visibility",
            subtitle: "Show the OpenBurnBar icon in the menu bar",
            keywords: ["menubar", "icon", "tray", "hide"]
        ),
        SettingsItem(
            id: "general.appearance.launchAtLogin",
            tab: .general,
            pageRoute: .appearance,
            anchorID: SettingsAnchor.appearanceLaunchAtLogin,
            title: "Launch at Login",
            subtitle: "Start OpenBurnBar automatically when you sign in",
            keywords: ["autostart", "boot", "startup", "login items"]
        ),
        SettingsItem(
            id: "general.appearance.usePremiumSOTAUX",
            tab: .general,
            pageRoute: .appearance,
            anchorID: SettingsAnchor.usePremiumSOTAUX,
            title: "Premium SOTA UX",
            subtitle: "Enable cinematic spring physics and specular button shimmers",
            keywords: ["sota", "premium", "ux", "haptic", "spring", "shimmer"]
        ),
        SettingsItem(
            id: "general.appearance.useWebsiteBackground",
            tab: .general,
            pageRoute: .appearance,
            anchorID: SettingsAnchor.useWebsiteBackground,
            title: "Swarm Background",
            subtitle: "Active, reconverging token-ember swarms from burnbar.ai with logo formation",
            keywords: ["swarm", "particles", "ember", "website", "background", "backdrop", "murmuration", "burnbar", "logo"]
        ),
        SettingsItem(
            id: "general.appearance.useConstellationBackground",
            tab: .general,
            pageRoute: .appearance,
            anchorID: SettingsAnchor.useConstellationBackground,
            title: "Constellation Style",
            subtitle: "Calm, slow background where one crest or provider logo at a time resolves from coloured dots, shimmers, and dissolves",
            keywords: ["constellation", "calm", "slow", "ambient", "dots", "logo", "crest", "provider", "shimmer", "dissolve", "background", "swarm", "style"]
        ),
        SettingsItem(
            id: "general.appearance.useKernelBackdrop",
            tab: .general,
            pageRoute: .appearance,
            anchorID: SettingsAnchor.useKernelBackdrop,
            title: "Window Backdrop",
            subtitle: "Live WebGL2 dashboard backdrop with a static native fallback",
            keywords: ["kernel", "kernels", "window", "backdrop", "background", "webgl", "webgl2", "shader", "sota", "ambient", "animated", "fluid", "aurora"],
            helpText: "Enable the experimental kernel field without requiring the native Swarm Background renderer."
        ),
        SettingsItem(
            id: "general.appearance.backdropKernel",
            tab: .general,
            pageRoute: .appearance,
            anchorID: SettingsAnchor.backdropKernel,
            title: "Backdrop Kernel",
            subtitle: "Choose which animated field renders behind the dashboard",
            keywords: ["kernel", "picker", "fluid aurora", "mesh", "moire", "plasma", "lattice", "shader", "field", "window backdrop"]
        ),
        SettingsItem(
            id: "general.appearance.desktopWallpaperEnabled",
            tab: .general,
            pageRoute: .appearance,
            anchorID: SettingsAnchor.desktopWallpaperEnabled,
            title: "Desktop Swarm Wallpaper",
            subtitle: "Render the live swarm as your macOS desktop wallpaper",
            keywords: ["desktop", "wallpaper", "swarm", "macos", "background", "particles"]
        ),
        SettingsItem(
            id: "general.appearance.desktopWallpaperBackground",
            tab: .general,
            pageRoute: .appearance,
            anchorID: SettingsAnchor.desktopWallpaperBackground,
            title: "Desktop Wallpaper Background",
            subtitle: "Choose macOS Desktop, neutral darks, or the Aurora, Crimson, Cyberpunk, Moss, and Solar swarm palettes",
            keywords: ["desktop", "wallpaper", "background", "macos", "amoled", "black", "graphite", "indigo", "aurora", "crimson", "cyberpunk", "moss", "solar", "swarm", "color", "palette"]
        ),
        SettingsItem(
            id: "general.appearance.desktopWallpaperSpeed",
            tab: .general,
            pageRoute: .appearance,
            anchorID: SettingsAnchor.desktopWallpaperSpeed,
            title: "Desktop Wallpaper Speed",
            subtitle: "Dial how quickly the desktop swarm drifts, reforms, and cycles",
            keywords: ["desktop", "wallpaper", "speed", "pace", "dial", "slider", "swarm", "motion", "cycle"]
        ),
        SettingsItem(
            id: "general.appearance.desktopWallpaperProviderGlyphs",
            tab: .general,
            pageRoute: .appearance,
            anchorID: SettingsAnchor.desktopWallpaperProviderGlyphs,
            title: "Customize Provider Glyphs",
            subtitle: "Choose which provider logos render in the desktop swarm wallpaper cycle",
            keywords: ["desktop", "wallpaper", "provider", "glyph", "logo", "customize", "filter", "swarm", "formation"]
        ),
        SettingsItem(
            id: "general.appearance.desktopWallpaperClickCycle",
            tab: .general,
            pageRoute: .appearance,
            anchorID: SettingsAnchor.desktopWallpaperClickCycle,
            title: "Click Desktop to Cycle Shapes",
            subtitle: "Click empty desktop space to inspect swarm symbols, provider logos, Grok, and xAI",
            keywords: ["desktop", "wallpaper", "click", "cycle", "shape", "provider", "logo", "grok", "xai", "x.ai", "inspection"]
        ),

        // MARK: General → Dashboard defaults

        SettingsItem(
            id: "general.defaults.timeRange",
            tab: .general,
            pageRoute: .defaultView,
            anchorID: SettingsAnchor.defaultsTimeRange,
            title: "Default Time Range",
            subtitle: "Window used by charts and totals",
            keywords: ["day", "week", "month", "range", "window", "default"]
        ),
        SettingsItem(
            id: "general.defaults.usageMode",
            tab: .general,
            pageRoute: .defaultView,
            anchorID: SettingsAnchor.defaultsUsageMode,
            title: "Usage Display",
            subtitle: "Show USD spend or token totals (M / B)",
            keywords: ["currency", "tokens", "usd", "dollars", "units"]
        ),

        // MARK: General → Refresh

        SettingsItem(
            id: "general.refresh.interval",
            tab: .general,
            pageRoute: .dataRefresh,
            anchorID: SettingsAnchor.refreshInterval,
            title: "Refresh Interval",
            subtitle: "How often OpenBurnBar scans for new sessions",
            keywords: ["polling", "interval", "scan", "rate", "frequency"]
        ),

        // MARK: General → Indexing

        SettingsItem(
            id: "general.indexing.enabled",
            tab: .general,
            pageRoute: .indexing,
            anchorID: SettingsAnchor.indexingToggle,
            title: "Indexing & Search",
            subtitle: "Local conversation indexing and embeddings",
            keywords: ["search", "index", "embeddings", "rag", "rerank"],
            helpText: "Indexed transcripts never leave this Mac unless cloud backup is enabled."
        ),
        SettingsItem(
            id: "general.indexing.memory",
            tab: .general,
            pageRoute: .indexing,
            anchorID: SettingsAnchor.indexingMemory,
            title: "Memory (Pensieve) Controls",
            subtitle: "On-device memory: learning toggle, high-recall, review pending, reset, sealed cloud backup opt-in",
            keywords: ["memory", "pensieve", "remember", "recall", "learn", "preferences", "consent", "reset memory", "review memories", "approved memories", "high-recall", "memory controls"],
            helpText: "Opens the on-device Memory controls. Free on this Mac — no Cloud plan required; sealed cloud backup of approved memories is a separate opt-in."
        ),
        SettingsItem(
            id: "general.indexing.memoryDeviceSync",
            tab: .general,
            pageRoute: .indexing,
            anchorID: SettingsAnchor.indexingMemoryDeviceSync,
            title: "Sync Memories to My Other Devices",
            subtitle: "Opt-in sub-toggle of cloud backup: read your own approved memories back down onto this Mac from your other signed-in devices",
            keywords: ["memory", "sync", "device sync", "cross-device", "pull", "download", "data vault", "pensieve", "backup", "other devices"],
            helpText: "Requires \"Back up approved memories\" and the Data Vault plan (Pro Max or Ultra). Off by default even when backup is already on."
        ),
        SettingsItem(
            id: "general.indexing.memoryCloudModels",
            tab: .general,
            pageRoute: .indexing,
            anchorID: SettingsAnchor.indexingMemoryCloudModels,
            title: "Cloud Models for Memory (Pro)",
            subtitle: "Opt-in: frontier models for memory extraction, reconciliation, embeddings, rerank and answers on your own keys or subscription",
            keywords: ["memory", "pro", "cloud models", "openrouter", "vercel", "anthropic", "openai", "claude code", "codex", "retention", "daily cap", "blind"],
            helpText: "Pro. Off by default. Providers you consent to receive redacted memory text directly from this Mac; BurnBar never receives your memory data."
        ),

        // MARK: General → Session summaries

        SettingsItem(
            id: "general.summaries.auto",
            tab: .general,
            pageRoute: .sessionSummaries,
            anchorID: SettingsAnchor.summariesAuto,
            title: "Auto-Generate Session Summaries",
            subtitle: "Write a recap after every scan",
            keywords: ["recap", "summary", "session", "auto"]
        ),

        // MARK: AI Inbox

        SettingsItem(
            id: "aiInbox.overview",
            tab: .aiInbox,
            pageRoute: .aiInboxRoot,
            anchorID: SettingsAnchor.aiInboxOverview,
            title: "AI Inbox",
            subtitle: "Background analyst that flags unfinished agent work",
            keywords: [
                "ai inbox", "inbox", "smart inbox", "attention", "unfinished",
                "analyst", "summaries", "agent inbox", "tray"
            ],
            helpText: "Turn on the background analyst that reads recent agent sessions and surfaces what needs attention."
        ),
        SettingsItem(
            id: SettingsDeepLinkRouting.aiInboxItemID,
            tab: .aiInbox,
            pageRoute: .aiInboxRoot,
            anchorID: SettingsAnchor.aiInboxEnable,
            title: "Run the AI Inbox",
            subtitle: "Enable or disable the background analyst",
            keywords: [
                "enable inbox", "run inbox", "turn on inbox", "ai inbox",
                "inbox toggle", "background analyst"
            ]
        ),

        // MARK: Daemon → Lifecycle

        SettingsItem(
            id: "daemon.lifecycle.status",
            tab: .daemon,
            pageRoute: .daemonLifecycle,
            anchorID: SettingsAnchor.daemonStatus,
            title: "Daemon Lifecycle",
            subtitle: "Install, repair, and watch the local daemon",
            keywords: ["daemon", "service", "install", "repair", "health"]
        ),

        // MARK: Daemon → HTTP gateway

        SettingsItem(
            id: "daemon.gateway.enabled",
            tab: .daemon,
            pageRoute: .httpGateway,
            anchorID: SettingsAnchor.gatewayEnabled,
            title: "HTTP Gateway",
            subtitle: "Expose an OpenAI-compatible API on a local port",
            keywords: ["api", "openai", "gateway", "endpoint", "hydrant"]
        ),
        SettingsItem(
            id: "daemon.gateway.host",
            tab: .daemon,
            pageRoute: .httpGateway,
            anchorID: SettingsAnchor.gatewayHost,
            focusID: SettingsFocus.gatewayHost,
            title: "Gateway Host",
            subtitle: "Bind address for the gateway server",
            keywords: ["host", "bind", "address", "127.0.0.1", "localhost"]
        ),
        SettingsItem(
            id: "daemon.gateway.port",
            tab: .daemon,
            pageRoute: .httpGateway,
            anchorID: SettingsAnchor.gatewayPort,
            focusID: SettingsFocus.gatewayPort,
            title: "Gateway Port",
            subtitle: "TCP port the gateway listens on",
            keywords: ["port", "tcp", "8317", "hydrant"]
        ),
        SettingsItem(
            id: "daemon.gateway.token",
            tab: .daemon,
            pageRoute: .httpGateway,
            anchorID: SettingsAnchor.gatewayAuthToken,
            focusID: SettingsFocus.gatewayAuthToken,
            title: "Gateway Auth Token",
            subtitle: "Required for non-loopback bindings",
            keywords: ["token", "auth", "bearer", "secret"]
        ),

        // MARK: Daemon → Controller runtime

        SettingsItem(
            id: "daemon.controller.enabled",
            tab: .daemon,
            pageRoute: .controllerRuntime,
            anchorID: SettingsAnchor.controllerEnabled,
            title: "Controller Runtime",
            subtitle: "Mirror daemon missions and replay state",
            keywords: ["controller", "runtime", "missions", "operator", "replay"]
        ),
        SettingsItem(
            id: "daemon.controller.refresh",
            tab: .daemon,
            pageRoute: .controllerRuntime,
            anchorID: SettingsAnchor.controllerRefresh,
            title: "Controller Refresh Cadence",
            subtitle: "How often to mirror runtime state",
            keywords: ["refresh", "cadence", "polling", "mirror"]
        ),
        SettingsItem(
            id: "daemon.controller.simulator",
            tab: .daemon,
            pageRoute: .controllerRuntime,
            anchorID: SettingsAnchor.controllerSimulator,
            title: "Simulator Tools",
            subtitle: "Expose replay and simulator controls",
            keywords: ["simulator", "replay", "operator", "preview"]
        ),

        // MARK: Account

        SettingsItem(
            id: "account.signIn",
            tab: .account,
            pageRoute: .accountRoot,
            anchorID: SettingsAnchor.accountSignIn,
            title: "Sign In",
            subtitle: "Sign in with Apple, Google, or email",
            keywords: ["login", "apple", "google", "email", "signin"]
        ),
        SettingsItem(
            id: "account.subscription",
            tab: .account,
            pageRoute: .accountRoot,
            anchorID: SettingsAnchor.accountSubscription,
            title: "Subscription",
            subtitle: "OpenBurnBar Cloud plan and billing",
            keywords: ["plan", "subscription", "billing", "premium", "upgrade"]
        ),
        SettingsItem(
            id: "account.delete",
            tab: .account,
            pageRoute: .accountRoot,
            anchorID: SettingsAnchor.accountDelete,
            title: "Delete Account",
            subtitle: "Permanently remove your cloud account",
            keywords: ["delete", "remove", "wipe", "gdpr"]
        ),

        // MARK: Cloud

        SettingsItem(
            id: "cloud.overview",
            tab: .cloud,
            pageRoute: .cloudRoot,
            anchorID: SettingsAnchor.cloudOverview,
            title: "OpenBurnBar Cloud",
            subtitle: "Hosted refresh, backup, remote MCP clients, and member status",
            keywords: ["cloud", "member", "pro", "hosted", "backup", "remote mcp", "subscription", "billing", "relay"]
        ),
        SettingsItem(
            id: "cloud.remoteMCP",
            tab: .cloud,
            pageRoute: .cloudRoot,
            anchorID: SettingsAnchor.cloudRemoteMCP,
            title: "Remote MCP — Memory for your AI tools",
            subtitle: "Connect Codex, Claude Code, and more to your sealed Pensieve memory",
            keywords: ["remote mcp", "mcp", "memory", "pensieve", "recall", "sealed", "search", "codex", "claude code", "droid", "kimi", "endpoint", "shim", "hosted mcp", "tour", "how memory works"]
        ),
        SettingsItem(
            id: "cloud.remoteMCP.connect",
            tab: .cloud,
            pageRoute: .cloudRoot,
            anchorID: SettingsAnchor.cloudRemoteMCPConnect,
            title: "Link this Mac's CLI (Remote MCP)",
            subtitle: "One-tap setup for supported AI tools — or copy the endpoint by hand",
            keywords: ["link cli", "remote mcp", "mcp", "endpoint", "shim", "connect", "setup", "codex", "claude code"]
        ),
        SettingsItem(
            id: "cloud.remoteMCP.doctor",
            tab: .cloud,
            pageRoute: .cloudRoot,
            anchorID: SettingsAnchor.cloudRemoteMCPDoctor,
            title: "Memory MCP Doctor",
            subtitle: "Check that the memory link is healthy",
            keywords: ["doctor", "remote mcp", "mcp", "diagnose", "health check", "troubleshoot", "link", "connection"]
        ),
        SettingsItem(
            id: "cloud.memoryTour",
            tab: .cloud,
            pageRoute: .cloudRoot,
            anchorID: SettingsAnchor.cloudMemoryTour,
            title: "How Memory works — one-minute tour",
            subtitle: "Meet the Pensieve, see the controls, learn the recall prompts",
            keywords: ["memory tour", "how memory works", "pensieve tour", "walkthrough", "memory mcp tour", "guide", "recall", "sealed", "tour"]
        ),

        // MARK: Agents (unified Connections + Account Switcher + AI Environments tab)

        SettingsItem(
            id: "agents.accounts",
            tab: .agents,
            pageRoute: .agentsAccounts,
            anchorID: SettingsAnchor.agentsAccounts,
            title: "Add Account",
            subtitle: "Bring API keys for OpenAI, Anthropic, and other providers — add many keys per provider for automatic failover",
            keywords: [
                "agent", "agents",
                "connect", "connections", "account", "accounts", "add", "key", "api key",
                "openai", "anthropic", "claude", "claude code", "opencode", "open code",
                "factory", "kimi", "moonshot", "minimax", "zai", "z.ai", "deepseek", "ollama",
                "provider", "providers", "plan", "plans"
            ],
            logoProviders: [.claudeCode, .openAI, .openCode, .factory]
        ),
        SettingsItem(
            id: "agents.clis",
            tab: .agents,
            pageRoute: .agentsCLIs,
            anchorID: SettingsAnchor.agentsCLIs,
            title: "Connect a CLI",
            subtitle: "Wire Claude Code, Codex, OpenCode, Forge, or Droid to your local gateway and switch between CLI profiles",
            keywords: [
                "agent", "agents",
                "cli", "app", "apps", "connect", "wire", "wiring", "claude code", "codex",
                "opencode", "open code", "forge", "droid", "factory",
                // Legacy "routing pool" / "hydrant" vocabulary still resolves here.
                "routing", "routing pool", "routing pools", "pool", "pools",
                "fire hydrant", "hydrant", "gateway", "failover", "fallback",
                "oauth", "api key", "auth",
                // Account Switcher vocabulary forwarded here.
                "switcher", "profile", "profiles", "reserve", "primary",
                "swap", "credentials", "isolated"
            ],
            logoProviders: [.claudeCode, .codex, .openCode, .factory]
        ),
        SettingsItem(
            id: "agents.runtimes",
            tab: .agents,
            pageRoute: .agentsRuntimes,
            anchorID: SettingsAnchor.agentsRuntimes,
            title: "Runtimes & Relays",
            subtitle: "Local Hermes, Pi, and OpenClaw runtimes plus their iPhone/iPad relays",
            keywords: [
                "agent", "agents",
                "runtime", "runtimes", "hermes", "pi", "pi agent", "openclaw", "open claw",
                "gateway", "engine", "engines", "relay", "remote", "tunnel", "webapi",
                "ai environment", "ai environments", "chat engine"
            ],
            logoProviders: [.hermes, .piAgent, .openClaw]
        ),
        SettingsItem(
            id: "agents.models",
            tab: .agents,
            pageRoute: .agentsModels,
            anchorID: SettingsAnchor.agentsModels,
            title: "Models & Providers",
            subtitle: "Every model the local gateway can serve right now — grouped by provider and account, with route-readiness and quota state",
            keywords: [
                "agent", "agents",
                "model", "models", "model catalog", "catalog", "directory",
                "provider", "providers", "advertised", "exposed", "proxy",
                "gateway", "v1/models", "endpoint", "routes", "routing",
                "claude", "gpt", "sonnet", "opus", "kimi", "minimax", "deepseek",
                "openai", "anthropic", "browse", "list", "view", "see"
            ],
            logoProviders: [.claudeCode, .openAI, .openCode, .kimi]
        ),
        SettingsItem(
            id: "agents.advanced",
            tab: .agents,
            pageRoute: .agentsAdvanced,
            anchorID: SettingsAnchor.agentsAdvanced,
            title: "Advanced Routing, Gateway, Browsers & Setup",
            subtitle: "Exact model failover, provider-family routing, local gateway, browser profiles, chat engines, Hermes models, inventory, setup wizard",
            keywords: [
                "agent", "agents",
                "advanced", "router", "router mode", "routing strategy",
                "exact model failover", "same model", "same-model", "never swap model",
                "provider family", "gateway", "host", "port", "token", "bearer",
                "loopback", "log sources", "logs", "smart hubs", "quota",
                "browser", "chrome", "safari", "profile",
                "chat engine", "engine", "engines", "model", "models", "hermes model",
                "inventory", "import", "setup", "setup wizard", "wizard"
            ],
            logoProviders: [.claudeCode, .openAI, .hermes]
        ),
        SettingsItem(
            id: "agents.quotaDisplay",
            tab: .agents,
            pageRoute: .agentsAdvanced,
            anchorID: SettingsAnchor.agentsQuotaDisplay,
            title: "Quota Popover",
            subtitle: "Choose which provider quotas appear in the menu-bar drop-down",
            keywords: [
                "agent", "agents", "quota", "quotas", "popover", "drop down", "dropdown",
                "menu bar", "menubar", "visible", "hide", "show", "provider", "providers",
                "codex", "claude", "opencode", "factory", "cursor", "grok"
            ],
            logoProviders: [.codex, .claudeCode, .openCode, .factory]
        ),

        // MARK: Alerts

        SettingsItem(
            id: "alerts.dailySpend",
            tab: .alerts,
            pageRoute: .alertsRoot,
            anchorID: SettingsAnchor.alertsDailySpend,
            focusID: SettingsFocus.alertsDailySpend,
            title: "Daily Spend Threshold",
            subtitle: "Notify when today's USD crosses this number",
            keywords: ["spend", "budget", "threshold", "limit", "alert", "usd"]
        ),
        SettingsItem(
            id: "alerts.digest",
            tab: .alerts,
            pageRoute: .alertsRoot,
            anchorID: SettingsAnchor.alertsDigest,
            title: "Daily Digest",
            subtitle: "Receive a daily summary of spend and tokens",
            keywords: ["digest", "daily", "summary", "morning"]
        ),

        // MARK: Notifications

        SettingsItem(
            id: "notifications.local",
            tab: .notifications,
            pageRoute: .notificationsRoot,
            anchorID: SettingsAnchor.notificationsLocal,
            title: "Local Notifications",
            subtitle: "Banner alerts on this Mac",
            keywords: ["banner", "notification", "alert", "local", "ping"]
        ),
        SettingsItem(
            id: "notifications.telegram",
            tab: .notifications,
            pageRoute: .notificationsRoot,
            anchorID: SettingsAnchor.notificationsTelegram,
            title: "Telegram",
            subtitle: "Bot token and chat ID for Telegram alerts",
            keywords: ["telegram", "bot", "chat id", "messenger"]
        ),
        SettingsItem(
            id: "notifications.calendar",
            tab: .notifications,
            pageRoute: .notificationsRoot,
            anchorID: SettingsAnchor.notificationsCalendar,
            title: "Calendar",
            subtitle: "Mirror digests to a calendar of your choice",
            keywords: ["calendar", "ical", "google calendar", "event"]
        ),

        // MARK: Devices & Sync

        SettingsItem(
            id: "devices.cloudSync",
            tab: .devicesAndSync,
            pageRoute: .devicesAndSyncRoot,
            anchorID: SettingsAnchor.cloudSyncToggle,
            title: "Cloud Sync",
            subtitle: "Sync usage and conversations to OpenBurnBar Cloud",
            keywords: ["sync", "cloud", "firebase", "backup", "ios", "android"]
        ),
        SettingsItem(
            id: "devices.trusted",
            tab: .devicesAndSync,
            pageRoute: .devicesAndSyncRoot,
            anchorID: SettingsAnchor.trustedDevices,
            title: "Trusted Devices",
            subtitle: "Manage which devices can read your data",
            keywords: ["devices", "trusted", "pairing", "phone", "tablet"]
        ),
        SettingsItem(
            id: "devices.smartDisplays",
            tab: .devicesAndSync,
            pageRoute: .devicesAndSyncRoot,
            anchorID: SettingsAnchor.smartDisplays,
            title: "Smart Displays",
            subtitle: "Cast cost glances to Nest Hub, Pixel Tablet, and Pixel Clock",
            keywords: ["nest", "hub", "pixel", "clock", "display", "cast"]
        ),
        SettingsItem(
            id: "devices.hermesBodies",
            tab: .devicesAndSync,
            pageRoute: .devicesAndSyncRoot,
            anchorID: SettingsAnchor.hermesBodies,
            title: "Hermes Bodies",
            subtitle: "Each Mac's Hermes identity — name, hardware, and presence",
            keywords: ["hermes", "body", "mac", "machine", "fleet", "war", "room", "rename"]
        ),
        SettingsItem(
            id: "devices.hermesRoom",
            tab: .devicesAndSync,
            pageRoute: .devicesAndSyncRoot,
            anchorID: SettingsAnchor.hermesRoom,
            title: "Hermes Room",
            subtitle: "Pick which Mac serves Hermes — the others stay linked and ready",
            keywords: ["hermes", "room", "swap", "move", "wire", "link", "war", "machine"]
        ),
        SettingsItem(
            id: "devices.commandBoard",
            tab: .devicesAndSync,
            pageRoute: .devicesAndSyncRoot,
            anchorID: SettingsAnchor.commandBoard,
            title: "Command Board",
            subtitle: "Every run across every machine, with who started it and what it cost",
            keywords: ["command", "board", "runs", "started", "by", "cost", "flame", "war", "fleet"]
        ),

        // MARK: Text Expansion

        SettingsItem(
            id: "textExpansion.snippets",
            tab: .textExpansion,
            pageRoute: .textExpansionRoot,
            anchorID: SettingsAnchor.textExpansionSnippets,
            title: "Snippets",
            subtitle: "Manage && triggers, static expansions, and LLM preview snippets",
            keywords: ["text expansion", "snippet", "textexpander", "trigger", "keyboard", "llm", "rewrite"],
            helpText: "Creates user-defined snippets that expand from &&trigger tokens inside OpenBurnBar and opted-in system typing surfaces."
        ),
        SettingsItem(
            id: "textExpansion.runtime",
            tab: .textExpansion,
            pageRoute: .textExpansionRoot,
            anchorID: SettingsAnchor.textExpansionRuntime,
            title: "Expansion Runtime",
            subtitle: "Control in-app expansion, Mac global expansion, keyboard snapshots, and LLM preview behavior",
            keywords: ["runtime", "global", "mac", "ime", "keyboard extension", "full access", "preview"]
        ),

        // MARK: Media & Sharing

        SettingsItem(
            id: "media.permissions",
            tab: .media,
            pageRoute: .mediaRoot,
            anchorID: SettingsAnchor.mediaPermissions,
            title: "Media Permissions",
            subtitle: "Camera, microphone, screen sharing, and file-transfer readiness for Mercury sessions",
            keywords: [
                "media", "mercury", "permissions", "camera", "microphone", "mic",
                "screen recording", "screen share", "file transfer", "voice call",
                "video call", "sharing", "iroh"
            ]
        ),

        // MARK: Computer Use

        SettingsItem(
            id: "computerUse.readiness",
            tab: .computerUse,
            pageRoute: .computerUseRoot,
            anchorID: SettingsAnchor.computerUseReadiness,
            title: "Computer Use Readiness",
            subtitle: "Agent Watch, browser automation, Mac input, approvals, and audit chain",
            keywords: [
                "computer use", "agent watch", "browser", "playwright", "mac input",
                "approval", "panic", "audit", "accessibility"
            ],
            helpText: "Shows local permission state and the controls needed to validate Computer Use on this Mac."
        ),

        SettingsItem(
            id: "computerUse.permissionsSetup",
            tab: .computerUse,
            pageRoute: .computerUseRoot,
            anchorID: SettingsAnchor.computerUsePermissionsSetup,
            title: "Re-run Mac Permissions Setup",
            subtitle: "Walk through Screen Recording, Accessibility, Camera, Mic, Full Disk, and Automation in order",
            keywords: [
                "permissions", "screen recording", "accessibility", "camera", "microphone",
                "mic", "full disk access", "fda", "automation", "applescript", "tcc", "reset"
            ],
            helpText: "Reopens the step-by-step Mac permissions wizard so an existing user can grant anything they skipped during onboarding."
        ),

        // MARK: Pets

        SettingsItem(
            id: "pets.companion",
            tab: .pets,
            pageRoute: .petsRoot,
            anchorID: SettingsAnchor.petsCompanion,
            title: "Desktop Pet",
            subtitle: "Show, pick, and summon the companion, including the pet's answering agent",
            keywords: [
                "pet", "pets", "companion", "desktop pet", "summon", "hide",
                "hotkey", "paw", "agent", "brain", "answering agent", "mascot"
            ],
            helpText: "Opens the desktop companion controls for visibility, pet form selection, and the enabled answering-agent picker."
        ),

        // MARK: Account Switcher — now lives inside Agents → CLIs / Advanced.

        SettingsItem(
            id: "switcher.browser",
            tab: .agents,
            pageRoute: .agentsAdvanced,
            anchorID: SettingsAnchor.switcherBrowser,
            title: "Browser Profiles",
            subtitle: "Launch isolated browser profiles per provider (now under Agents → Advanced)",
            keywords: ["browser", "profile", "chrome", "safari", "firefox", "switcher"]
        ),
        SettingsItem(
            id: "switcher.cli",
            tab: .agents,
            pageRoute: .agentsCLIs,
            anchorID: SettingsAnchor.switcherCLI,
            title: "CLI Profiles",
            subtitle: "Swap CLI credentials between Claude / Codex / OpenCode accounts (now under Agents → CLIs)",
            keywords: ["cli", "profile", "credentials", "swap", "switcher"],
            logoProviders: [.claudeCode, .codex, .openCode, .factory]
        ),

        // MARK: Hermes / AI environments — now live inside Agents → Runtimes / Advanced.

        SettingsItem(
            id: "hermes.connections",
            tab: .agents,
            pageRoute: .agentsAdvanced,
            anchorID: SettingsAnchor.hermesConnections,
            title: "Chat Engines",
            subtitle: "Choose which chat engines appear in OpenBurnBar (now under Agents → Advanced)",
            keywords: ["hermes", "pi", "connection", "engine", "chat", "codex", "claude", "openclaw"],
            logoProviders: [.hermes, .piAgent, .openClaw, .claudeCode, .codex]
        ),
        SettingsItem(
            id: "hermes.models",
            tab: .agents,
            pageRoute: .agentsAdvanced,
            anchorID: SettingsAnchor.hermesModels,
            title: "Hermes Models",
            subtitle: "Default models exposed by Hermes (now under Agents → Advanced)",
            keywords: ["model", "hermes", "claude", "gpt", "llm"],
            logoProviders: [.hermes, .claudeCode, .openAI, .geminiCLI]
        ),
        SettingsItem(
            id: "hermes.gateway.url",
            tab: .agents,
            pageRoute: .agentsRuntimes,
            anchorID: SettingsAnchor.hermesGatewayURL,
            focusID: SettingsFocus.hermesGatewayURL,
            title: "Hermes Gateway URL",
            subtitle: "Base URL of the Hermes webapi gateway (now under Agents → Runtimes)",
            keywords: ["gateway", "url", "endpoint", "webapi", "hermes"],
            logoProviders: [.hermes]
        ),
        SettingsItem(
            id: "hermes.gateway.token",
            tab: .agents,
            pageRoute: .agentsRuntimes,
            anchorID: SettingsAnchor.hermesGatewayToken,
            focusID: SettingsFocus.hermesGatewayToken,
            title: "Hermes Gateway Token",
            subtitle: "Bearer token used to authenticate to the gateway (now under Agents → Runtimes)",
            keywords: ["bearer", "token", "secret", "gateway", "hermes"],
            logoProviders: [.hermes]
        ),
        SettingsItem(
            id: "hermes.pi.hosts",
            tab: .agents,
            pageRoute: .agentsRuntimes,
            anchorID: SettingsAnchor.hermesPiHosts,
            title: "Pi Agent Base URL",
            subtitle: "Gateway endpoint for local Pi runtimes (now under Agents → Runtimes)",
            keywords: ["pi", "raspberry", "host", "edge", "gateway", "url"],
            logoProviders: [.piAgent]
        ),
        SettingsItem(
            id: "hermes.relay",
            tab: .agents,
            pageRoute: .agentsRuntimes,
            anchorID: SettingsAnchor.hermesRelay,
            title: "Hermes Remote Relay",
            subtitle: "Reach Hermes from the cloud relay endpoint (now under Agents → Runtimes)",
            keywords: ["hermes", "relay", "remote", "tunnel", "cloud"],
            logoProviders: [.hermes]
        ),
        SettingsItem(
            id: "hermes.pi.relay",
            tab: .agents,
            pageRoute: .agentsRuntimes,
            anchorID: SettingsAnchor.hermesPiRelay,
            title: "Pi Remote Relay",
            subtitle: "Reach Pi from the cloud relay endpoint (now under Agents → Runtimes)",
            keywords: ["pi", "raspberry", "relay", "remote", "tunnel", "cloud"],
            logoProviders: [.piAgent]
        ),

        // MARK: The Elder Wand — analysis-model fusion configurator (Cloud Pro)

        SettingsItem(
            id: "agents.analysisConfigurator",
            tab: .agents,
            pageRoute: .analysisConfigurator,
            anchorID: SettingsAnchor.analysisConfigurator,
            title: "Analysis Models",
            subtitle: "Build a panel of models and a judge for The Elder Wand",
            keywords: ["elder wand", "fusion", "panel", "judge", "analysis models"],
            helpText: "Opens The Elder Wand configurator: pick the analysis panel and judge model, set a tool-call budget, and save named presets."
        ),
        SettingsItem(
            id: "agents.fusionImpact",
            tab: .agents,
            pageRoute: .fusionImpact,
            anchorID: SettingsAnchor.fusionImpact,
            title: "Fusion Impact",
            subtitle: "What The Elder Wand spent — fusion versus normal, per model, this period",
            keywords: [
                "elder wand", "fusion", "impact", "spend", "cost", "receipt",
                "how much", "per model", "this month", "last 30 days",
                "fusion searches", "quota", "multiplier", "cost of certainty"
            ],
            helpText: "Opens the standing Fusion Impact screen: fusion-versus-normal spend over the period, per-model contribution, fusion run tally, and the fusion-search quota meter."
        )
    ]

    /// Map of anchor IDs back to the page route that owns them — used by
    /// destination views to know whether they should consume the pending
    /// anchor.
    static let anchorIndex: [String: SettingsPageRoute] = {
        var index: [String: SettingsPageRoute] = [:]
        for item in all { index[item.anchorID] = item.pageRoute }
        return index
    }()

    /// Anchors that are wired to concrete rows/controls in the macOS Settings
    /// UI. Coverage tests compare this against `all` so search cannot index a
    /// setting that has no scroll target.
    static let visibleAnchorIDs: Set<String> = Set([
        SettingsAnchor.homeOverview,
        SettingsAnchor.modelProxyOverview,
        SettingsAnchor.modelProxyEndpoint,
        SettingsAnchor.modelProxyRouting,
        SettingsAnchor.operatorWizard,
        SettingsAnchor.appearanceTheme,
        SettingsAnchor.appearanceSkin,
        SettingsAnchor.appearanceGlassTransparency,
        SettingsAnchor.appearanceGlassRefraction,
        SettingsAnchor.appearanceMenuBar,
        SettingsAnchor.appearanceLaunchAtLogin,
        SettingsAnchor.usePremiumSOTAUX,
        SettingsAnchor.useWebsiteBackground,
        SettingsAnchor.useConstellationBackground,
        SettingsAnchor.useKernelBackdrop,
        SettingsAnchor.backdropKernel,
        SettingsAnchor.desktopWallpaperEnabled,
        SettingsAnchor.desktopWallpaperBackground,
        SettingsAnchor.desktopWallpaperSpeed,
        SettingsAnchor.desktopWallpaperProviderGlyphs,
        SettingsAnchor.desktopWallpaperClickCycle,
        SettingsAnchor.defaultsTimeRange,
        SettingsAnchor.defaultsUsageMode,
        SettingsAnchor.refreshInterval,
        SettingsAnchor.indexingToggle,
        SettingsAnchor.indexingMemory,
        SettingsAnchor.indexingMemoryCloudModels,
        SettingsAnchor.summariesAuto,
        SettingsAnchor.aiInboxOverview,
        SettingsAnchor.aiInboxEnable,
        SettingsAnchor.updatesOverview,
        SettingsAnchor.updatesAutomaticChecks,
        SettingsAnchor.updatesReleaseNotes,
        SettingsAnchor.daemonStatus,
        SettingsAnchor.gatewayEnabled,
        SettingsAnchor.gatewayHost,
        SettingsAnchor.gatewayPort,
        SettingsAnchor.gatewayAuthToken,
        SettingsAnchor.controllerEnabled,
        SettingsAnchor.controllerRefresh,
        SettingsAnchor.controllerSimulator,
        SettingsAnchor.accountSignIn,
        SettingsAnchor.accountSubscription,
        SettingsAnchor.accountDelete,
        SettingsAnchor.cloudOverview,
        SettingsAnchor.cloudRemoteMCP,
        SettingsAnchor.cloudRemoteMCPConnect,
        SettingsAnchor.cloudRemoteMCPDoctor,
        SettingsAnchor.cloudMemoryTour,
        SettingsAnchor.agentsAccounts,
        SettingsAnchor.agentsCLIs,
        SettingsAnchor.agentsRuntimes,
        SettingsAnchor.agentsModels,
        SettingsAnchor.agentsAdvanced,
        SettingsAnchor.agentsQuotaDisplay,
        SettingsAnchor.agentsLocalDBox,
        SettingsAnchor.alertsDailySpend,
        SettingsAnchor.alertsDigest,
        SettingsAnchor.notificationsLocal,
        SettingsAnchor.notificationsTelegram,
        SettingsAnchor.notificationsCalendar,
        SettingsAnchor.cloudSyncToggle,
        SettingsAnchor.trustedDevices,
        SettingsAnchor.smartDisplays,
        SettingsAnchor.hermesBodies,
        SettingsAnchor.hermesRoom,
        SettingsAnchor.commandBoard,
        SettingsAnchor.textExpansionSnippets,
        SettingsAnchor.textExpansionRuntime,
        SettingsAnchor.mediaPermissions,
        SettingsAnchor.dataControlCenterInventory,
        SettingsAnchor.computerUseReadiness,
        SettingsAnchor.computerUsePermissionsSetup,
        SettingsAnchor.petsCompanion,
        SettingsAnchor.switcherBrowser,
        SettingsAnchor.switcherCLI,
        SettingsAnchor.hermesConnections,
        SettingsAnchor.hermesModels,
        SettingsAnchor.hermesGatewayURL,
        SettingsAnchor.hermesGatewayToken,
        SettingsAnchor.hermesPiHosts,
        SettingsAnchor.hermesRelay,
        SettingsAnchor.hermesPiRelay,
        SettingsAnchor.analysisConfigurator,
        SettingsAnchor.fusionImpact
    ]).union(providerItems.map(\.anchorID)).union(localDBoxAnchors)

#if !DISTRIBUTION_MAS
    private static let localDBoxItems: [SettingsItem] = [
        SettingsItem(
            id: "agents.localDBox",
            tab: .agents,
            pageRoute: .agentsRoot,
            anchorID: SettingsAnchor.agentsLocalDBox,
            title: "Local D box",
            subtitle: "List live Grok Bot D local-box agents by UUID and send one a prompt. Default off. Developer ID only.",
            keywords: [
                "agent", "agents",
                "local d", "local d box", "grok bot d", "grokd", "box",
                "1337", "1338", "8787", "uuid", "listagents", "sendprompt"
            ]
        )
    ]
    private static let localDBoxAnchors: Set<String> = [SettingsAnchor.agentsLocalDBox]
#else
    private static let localDBoxItems: [SettingsItem] = []
    private static let localDBoxAnchors: Set<String> = []
#endif

    private static let providerItems: [SettingsItem] = {
        AgentProvider.allCases
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            .map { provider in
                SettingsItem(
                    id: providerItemID(for: provider),
                    tab: .agents,
                    pageRoute: .agentsAccounts,
                    anchorID: providerAnchor(for: provider),
                    title: provider.displayName,
                    subtitle: "\(provider.displayName) accounts, keys, and quota signals",
                    keywords: providerKeywords(for: provider),
                    logoProviders: [provider]
                )
            }
    }()

    private static func providerItemID(for provider: AgentProvider) -> String {
        provider == .openCode ? "providers.openCode" : "providers.\(provider.persistedToken)"
    }

    /// Per-provider scroll anchor. The Connections page itself only renders
    /// three anchored sections, so these per-provider IDs scroll the user to
    /// the top of the Accounts section in practice — they exist so each
    /// provider has its own unique manifest entry for search.
    private static func providerAnchor(for provider: AgentProvider) -> String {
        "agents.account.\(provider.persistedToken)"
    }

    private static func providerKeywords(for provider: AgentProvider) -> [String] {
        var keywords: [String] = [
            provider.persistedToken,
            provider.providerID.rawValue,
            "provider",
            "account",
            "quota",
            "logs",
            "routing",
            "failover"
        ]

        switch provider {
        case .claudeCode:
            keywords += ["claude", "anthropic", "claude code", "claude cli", "sonnet", "opus"]
        case .codex:
            keywords += ["openai codex", "codex cli", "chatgpt", "openai"]
        case .openCode:
            keywords += ["opencode", "open code", "opencode go", "open code go", "cli"]
        case .openAI:
            keywords += ["open ai", "openai", "gpt", "chatgpt"]
        case .geminiCLI:
            keywords += ["gemini", "google", "google ai", "gemini cli"]
        case .antigravity:
            keywords += ["antigravity", "gemini", "antigravity cli", "google"]
        case .kiloCode:
            keywords += ["kilo", "kilo code", "kilocode"]
        case .rooCode:
            keywords += ["roo", "roo code", "roocode"]
        case .forgeDev:
            keywords += ["forge", "forge dev", "forgedev"]
        case .openClaw:
            keywords += ["open claw", "openclaw"]
        case .piAgent:
            keywords += ["pi", "raspberry", "pi agent"]
        case .kimi:
            keywords += ["moonshot", "kimi k2"]
        case .zai:
            keywords += ["z.ai", "z-ai", "zai"]
        case .minimax:
            keywords += ["mini max", "minimax"]
        case .mimo:
            keywords += ["mimo", "xiaomi", "xiaomi mimo", "token plan"]
        case .copilot:
            keywords += ["github", "github copilot"]
        default:
            break
        }

        return Array(Set(keywords)).sorted()
    }
}
