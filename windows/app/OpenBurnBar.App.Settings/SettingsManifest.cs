// PORTED 1:1 from AgentLens/Views/Settings/Search/SettingsManifest.swift (assembly + provider items).
//
// Hand-authored index of every searchable control inside Settings. The base rows
// live, in exact Swift order, across the three SettingsManifest.Items.*.cs partials;
// this file assembles All = BaseItems + ProviderItems and reproduces the derived
// tables (AnchorIndex, VisibleAnchorIDs) plus the per-provider row generator.

using System.Collections.Generic;
using System.Linq;

namespace OpenBurnBar.App.Settings;

/// <summary>Hand-authored searchable-control index for Settings (Swift <c>SettingsManifest</c>).</summary>
public static partial class SettingsManifest
{
    // The base-row arrays live in sibling partials (SettingsManifest.Items.*.cs). Static
    // field initialization order across partial files is unspecified, so every derived
    // table is Lazy — each factory (a named static method, analyzed as a normal method
    // body so its static reads are treated as fully-initialized) runs on first access,
    // well after all field initializers have completed. Correct AND nullable-flow clean.
    private static readonly Lazy<IReadOnlyList<SettingsItem>> LazyBaseItems = new(BuildBaseItems);

    private static readonly Lazy<IReadOnlyList<SettingsItem>> LazyProviderItems = new(BuildProviderItems);

    private static readonly Lazy<IReadOnlyList<SettingsItem>> LazyAll = new(BuildAll);

    private static IReadOnlyList<SettingsItem> BuildBaseItems() =>
        GeneralGroupItems.Concat(MiddleGroupItems).Concat(ExtrasGroupItems).ToArray();

    private static IReadOnlyList<SettingsItem> BuildAll() =>
        BaseItems.Concat(ProviderItems).ToArray();

    /// <summary>Every searchable row: hand-authored base rows then generated provider rows.</summary>
    public static IReadOnlyList<SettingsItem> All => LazyAll.Value;

    /// <summary>The hand-authored base rows in exact Swift declaration order.</summary>
    public static IReadOnlyList<SettingsItem> BaseItems => LazyBaseItems.Value;

    /// <summary>One generated row per <see cref="AgentProvider"/>, sorted by display name.</summary>
    public static IReadOnlyList<SettingsItem> ProviderItems => LazyProviderItems.Value;

    /// <summary>
    /// Map of anchor id → owning page route, used by destination pages to know whether
    /// they should consume the pending anchor.
    /// </summary>
    public static IReadOnlyDictionary<string, SettingsPageRoute> AnchorIndex => LazyAnchorIndex.Value;

    private static readonly Lazy<IReadOnlyDictionary<string, SettingsPageRoute>> LazyAnchorIndex =
        new(() => BuildAnchorIndex());

    private static Dictionary<string, SettingsPageRoute> BuildAnchorIndex()
    {
        var index = new Dictionary<string, SettingsPageRoute>();
        foreach (var item in All)
        {
            index[item.AnchorId] = item.PageRoute; // last-writer-wins, matching the Swift dictionary build
        }
        return index;
    }

    /// <summary>
    /// Anchors wired to concrete rows/controls in the Settings UI. Coverage tests
    /// compare this against <see cref="All"/> so search cannot index a setting with no
    /// scroll target.
    /// </summary>
    public static IReadOnlyCollection<string> VisibleAnchorIDs => LazyVisibleAnchorIDs.Value;

    private static readonly Lazy<IReadOnlyCollection<string>> LazyVisibleAnchorIDs = new(() => BuildVisibleAnchorIDs());

    private static HashSet<string> BuildVisibleAnchorIDs()
    {
        var set = new HashSet<string>
        {
            SettingsAnchor.HomeOverview,
            SettingsAnchor.ModelProxyOverview,
            SettingsAnchor.ModelProxyEndpoint,
            SettingsAnchor.ModelProxyRouting,
            SettingsAnchor.OperatorWizard,
            SettingsAnchor.AppearanceTheme,
            SettingsAnchor.AppearanceSkin,
            SettingsAnchor.AppearanceGlassTransparency,
            SettingsAnchor.AppearanceMenuBar,
            SettingsAnchor.AppearanceLaunchAtLogin,
            SettingsAnchor.UsePremiumSotaUx,
            SettingsAnchor.UseWebsiteBackground,
            SettingsAnchor.UseConstellationBackground,
            SettingsAnchor.UseKernelBackdrop,
            SettingsAnchor.BackdropKernel,
            SettingsAnchor.DesktopWallpaperEnabled,
            SettingsAnchor.DesktopWallpaperBackground,
            SettingsAnchor.DesktopWallpaperSpeed,
            SettingsAnchor.DesktopWallpaperProviderGlyphs,
            SettingsAnchor.DesktopWallpaperClickCycle,
            SettingsAnchor.DefaultsTimeRange,
            SettingsAnchor.DefaultsUsageMode,
            SettingsAnchor.RefreshInterval,
            SettingsAnchor.IndexingToggle,
            SettingsAnchor.SummariesAuto,
            SettingsAnchor.UpdatesOverview,
            SettingsAnchor.UpdatesAutomaticChecks,
            SettingsAnchor.UpdatesReleaseNotes,
            SettingsAnchor.DaemonStatus,
            SettingsAnchor.GatewayEnabled,
            SettingsAnchor.GatewayHost,
            SettingsAnchor.GatewayPort,
            SettingsAnchor.GatewayAuthToken,
            SettingsAnchor.ControllerEnabled,
            SettingsAnchor.ControllerRefresh,
            SettingsAnchor.ControllerSimulator,
            SettingsAnchor.AccountSignIn,
            SettingsAnchor.AccountSubscription,
            SettingsAnchor.AccountDelete,
            SettingsAnchor.CloudOverview,
            SettingsAnchor.AgentsAccounts,
            SettingsAnchor.AgentsCLIs,
            SettingsAnchor.AgentsRuntimes,
            SettingsAnchor.AgentsModels,
            SettingsAnchor.AgentsAdvanced,
            SettingsAnchor.AgentsQuotaDisplay,
            SettingsAnchor.AlertsDailySpend,
            SettingsAnchor.AlertsDigest,
            SettingsAnchor.NotificationsLocal,
            SettingsAnchor.NotificationsTelegram,
            SettingsAnchor.NotificationsCalendar,
            SettingsAnchor.CloudSyncToggle,
            SettingsAnchor.TrustedDevices,
            SettingsAnchor.SmartDisplays,
            SettingsAnchor.TextExpansionSnippets,
            SettingsAnchor.TextExpansionRuntime,
            SettingsAnchor.MediaPermissions,
            SettingsAnchor.DataControlCenterInventory,
            SettingsAnchor.ComputerUseReadiness,
            SettingsAnchor.ComputerUsePermissionsSetup,
            SettingsAnchor.PetsCompanion,
            SettingsAnchor.SwitcherBrowser,
            SettingsAnchor.SwitcherCLI,
            SettingsAnchor.HermesConnections,
            SettingsAnchor.HermesModels,
            SettingsAnchor.HermesGatewayURL,
            SettingsAnchor.HermesGatewayToken,
            SettingsAnchor.HermesPiHosts,
            SettingsAnchor.HermesRelay,
            SettingsAnchor.HermesPiRelay,
            SettingsAnchor.AnalysisConfigurator,
            SettingsAnchor.FusionImpact,
        };
        foreach (var item in ProviderItems)
        {
            set.Add(item.AnchorId);
        }
        return set;
    }

    // MARK: - Provider row generation (Swift `providerItems`)

    private static SettingsItem[] BuildProviderItems() =>
        AgentProviderMetadata.AllCases
            .OrderBy(AgentProviderMetadata.DisplayName, StringComparer.InvariantCultureIgnoreCase)
            .Select(provider => new SettingsItem(
                id: ProviderItemID(provider),
                tab: SettingsTab.Agents,
                pageRoute: SettingsPageRoute.AgentsAccounts,
                anchorId: ProviderAnchor(provider),
                title: AgentProviderMetadata.DisplayName(provider),
                subtitle: $"{AgentProviderMetadata.DisplayName(provider)} accounts, keys, and quota signals",
                keywords: ProviderKeywords(provider),
                logoProviders: new[] { provider }))
            .ToArray();

    private static string ProviderItemID(AgentProvider provider) =>
        provider == AgentProvider.OpenCode
            ? "providers.openCode"
            : $"providers.{AgentProviderMetadata.PersistedToken(provider)}";

    /// <summary>
    /// Per-provider scroll anchor. The Accounts page renders three anchored sections,
    /// so these per-provider ids scroll to the top of Accounts in practice — they exist
    /// so each provider has its own unique manifest entry for search.
    /// </summary>
    private static string ProviderAnchor(AgentProvider provider) =>
        $"agents.account.{AgentProviderMetadata.PersistedToken(provider)}";

    private static IReadOnlyList<string> ProviderKeywords(AgentProvider provider)
    {
        var keywords = new List<string>
        {
            AgentProviderMetadata.PersistedToken(provider),
            AgentProviderMetadata.ProviderIdRawValue(provider),
            "provider",
            "account",
            "quota",
            "logs",
            "routing",
            "failover",
        };

        keywords.AddRange(provider switch
        {
            AgentProvider.ClaudeCode => new[] { "claude", "anthropic", "claude code", "claude cli", "sonnet", "opus" },
            AgentProvider.Codex => new[] { "openai codex", "codex cli", "chatgpt", "openai" },
            AgentProvider.OpenCode => new[] { "opencode", "open code", "opencode go", "open code go", "cli" },
            AgentProvider.OpenAI => new[] { "open ai", "openai", "gpt", "chatgpt" },
            AgentProvider.GeminiCLI => new[] { "gemini", "google", "google ai", "gemini cli" },
            AgentProvider.Antigravity => new[] { "antigravity", "gemini", "antigravity cli", "google" },
            AgentProvider.KiloCode => new[] { "kilo", "kilo code", "kilocode" },
            AgentProvider.RooCode => new[] { "roo", "roo code", "roocode" },
            AgentProvider.ForgeDev => new[] { "forge", "forge dev", "forgedev" },
            AgentProvider.OpenClaw => new[] { "open claw", "openclaw" },
            AgentProvider.PiAgent => new[] { "pi", "raspberry", "pi agent" },
            AgentProvider.Kimi => new[] { "moonshot", "kimi k2" },
            AgentProvider.Zai => new[] { "z.ai", "z-ai", "zai" },
            AgentProvider.MiniMax => new[] { "mini max", "minimax" },
            AgentProvider.Mimo => new[] { "mimo", "xiaomi", "xiaomi mimo", "token plan" },
            AgentProvider.Copilot => new[] { "github", "github copilot" },
            _ => Array.Empty<string>(),
        });

        // Swift `Array(Set(keywords)).sorted()` — dedup, then ordinal-lexicographic sort.
        return keywords.Distinct().OrderBy(k => k, StringComparer.Ordinal).ToArray();
    }
}
