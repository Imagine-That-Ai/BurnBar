// PORTED 1:1 from AgentLens/Views/Settings/SettingsTab.swift
// (enum SettingsTab + enum SettingsSection + extensions).
//
// The macOS enum also carries an accentColor (DesignSystem.Colors.*) and SF-Symbol
// icon names. Those are macOS-render concerns; this portable model keeps the parts
// the search index + shell IA need (Title, Subtitle, Section, LogoProviders, plus
// the stable RawValue + SF-symbol icon name as 1:1 data). The WinUI shell maps the
// SF-symbol name to a Segoe Fluent glyph and the tab to a Pensieve accent brush —
// see SettingsTabVisuals in windows/app/OpenBurnBar.App/Settings/.

using System.Collections.Generic;
using System.Linq;

namespace OpenBurnBar.App.Settings;

/// <summary>Available settings tabs in the sidebar navigation (Swift <c>SettingsTab</c>).</summary>
public enum SettingsTab
{
    Home,
    General,
    Updates,
    Daemon,
    Account,
    Cloud,
    Agents,
    ModelProxy,
    Alerts,
    Notifications,
    DevicesAndSync,
    TextExpansion,
    Media,
    DataPrivacy,
    ComputerUse,
    Pets,
}

/// <summary>Groups sidebar tabs into labeled sections (Swift <c>SettingsSection</c>).</summary>
public enum SettingsSection
{
    Home,
    AgentsAndModels,
    LookAndFeel,
    AccountAndSync,
    System,
    Extras,
}

/// <summary>Display + grouping metadata for <see cref="SettingsTab"/> / <see cref="SettingsSection"/>.</summary>
public static class SettingsTabMetadata
{
    /// <summary>Swift enum <c>rawValue</c> (camelCase case name) — used for legacy deep-link resolution.</summary>
    public static string RawValue(SettingsTab tab) => tab switch
    {
        SettingsTab.Home => "home",
        SettingsTab.General => "general",
        SettingsTab.Updates => "updates",
        SettingsTab.Daemon => "daemon",
        SettingsTab.Account => "account",
        SettingsTab.Cloud => "cloud",
        SettingsTab.Agents => "agents",
        SettingsTab.ModelProxy => "modelProxy",
        SettingsTab.Alerts => "alerts",
        SettingsTab.Notifications => "notifications",
        SettingsTab.DevicesAndSync => "devicesAndSync",
        SettingsTab.TextExpansion => "textExpansion",
        SettingsTab.Media => "media",
        SettingsTab.DataPrivacy => "dataPrivacy",
        SettingsTab.ComputerUse => "computerUse",
        SettingsTab.Pets => "pets",
        _ => throw new ArgumentOutOfRangeException(nameof(tab), tab, null),
    };

    public static string Title(SettingsTab tab) => tab switch
    {
        SettingsTab.Home => "Home",
        SettingsTab.General => "General",
        SettingsTab.Updates => "Updates",
        SettingsTab.Daemon => "Engine Room",
        SettingsTab.Account => "Account",
        SettingsTab.Cloud => "Cloud",
        SettingsTab.Agents => "Agents",
        SettingsTab.ModelProxy => "Model Proxy",
        SettingsTab.Alerts => "Alerts",
        SettingsTab.Notifications => "Notifications",
        SettingsTab.DevicesAndSync => "Devices & Sync",
        SettingsTab.TextExpansion => "Text Expansion",
        SettingsTab.Media => "Media & Sharing",
        SettingsTab.DataPrivacy => "Data & Privacy",
        SettingsTab.ComputerUse => "Computer Use",
        SettingsTab.Pets => "Pets",
        _ => throw new ArgumentOutOfRangeException(nameof(tab), tab, null),
    };

    public static string Subtitle(SettingsTab tab) => tab switch
    {
        SettingsTab.Home => "Health, attention items, and quick actions",
        SettingsTab.General => "Appearance, dashboard defaults, refresh, indexing, summaries",
        SettingsTab.Updates => "App version, automatic updates, release channel",
        SettingsTab.Daemon => "Daemon lifecycle, controller runtime",
        SettingsTab.Account => "Sign-in, subscription, account actions",
        SettingsTab.Cloud => "OpenBurnBar Cloud — hosted refresh, backup, Hermes anywhere",
        SettingsTab.Agents => "Cloud keys, local CLIs, and local runtimes",
        SettingsTab.ModelProxy => "Local gateway endpoint, routing strategy, model catalog",
        SettingsTab.Alerts => "Spend thresholds, daily digest",
        SettingsTab.Notifications => "Local pings, Telegram, calendar",
        SettingsTab.DevicesAndSync => "Cloud sync, trusted devices, smart displays",
        SettingsTab.TextExpansion => "&& triggers, snippets, keyboard sync, and LLM previews",
        SettingsTab.Media => "Mercury file transfer, screen share, calls — permissions and partner preferences",
        SettingsTab.DataPrivacy => "Pensieve vault, exports, deletion, recovery, and panic controls",
        SettingsTab.ComputerUse => "Agent Watch, browser driving, Mac input, approvals, and audit chain",
        SettingsTab.Pets => "Desktop companion, pet picker, agent brain, and summon hotkey",
        _ => throw new ArgumentOutOfRangeException(nameof(tab), tab, null),
    };

    /// <summary>The SF-Symbol name (macOS 1:1). The WinUI shell maps this to a Segoe Fluent glyph.</summary>
    public static string SymbolName(SettingsTab tab) => tab switch
    {
        SettingsTab.Home => "house.fill",
        SettingsTab.General => "gearshape.fill",
        SettingsTab.Updates => "arrow.down.circle.fill",
        SettingsTab.Daemon => "cpu.fill",
        SettingsTab.Account => "person.crop.circle.fill",
        SettingsTab.Cloud => "sparkles",
        SettingsTab.Agents => "cpu.fill",
        SettingsTab.ModelProxy => "network",
        SettingsTab.Alerts => "bell.fill",
        SettingsTab.Notifications => "bell.badge.fill",
        SettingsTab.DevicesAndSync => "macbook.and.iphone",
        SettingsTab.TextExpansion => "text.cursor",
        SettingsTab.Media => "play.rectangle.on.rectangle",
        SettingsTab.DataPrivacy => "lock.shield.fill",
        SettingsTab.ComputerUse => "cursorarrow.click.2",
        SettingsTab.Pets => "pawprint.fill",
        _ => throw new ArgumentOutOfRangeException(nameof(tab), tab, null),
    };

    public static IReadOnlyList<AgentProvider> LogoProviders(SettingsTab tab) => tab switch
    {
        SettingsTab.Agents => new[] { AgentProvider.ClaudeCode, AgentProvider.Codex, AgentProvider.OpenCode, AgentProvider.Hermes },
        SettingsTab.ModelProxy => new[] { AgentProvider.ClaudeCode, AgentProvider.OpenAI, AgentProvider.Codex },
        _ => Array.Empty<AgentProvider>(),
    };

    /// <summary>Which sidebar section this tab belongs to.</summary>
    public static SettingsSection Section(SettingsTab tab) => tab switch
    {
        SettingsTab.Home => SettingsSection.Home,
        SettingsTab.Agents or SettingsTab.ModelProxy => SettingsSection.AgentsAndModels,
        SettingsTab.General => SettingsSection.LookAndFeel,
        SettingsTab.Account or SettingsTab.Cloud or SettingsTab.Alerts
            or SettingsTab.Notifications or SettingsTab.DevicesAndSync => SettingsSection.AccountAndSync,
        SettingsTab.Daemon or SettingsTab.Updates or SettingsTab.DataPrivacy => SettingsSection.System,
        SettingsTab.TextExpansion or SettingsTab.Media or SettingsTab.ComputerUse or SettingsTab.Pets => SettingsSection.Extras,
        _ => throw new ArgumentOutOfRangeException(nameof(tab), tab, null),
    };

    /// <summary>All tabs in sidebar display order (home first, then each visible section).</summary>
    public static IReadOnlyList<SettingsTab> VisibleTabs
    {
        get
        {
            var tabs = new List<SettingsTab> { SettingsTab.Home };
            foreach (var section in SettingsSectionMetadata.VisibleSections)
            {
                tabs.AddRange(SettingsSectionMetadata.Tabs(section));
            }
            return tabs;
        }
    }

    /// <summary>
    /// Resolves a tab from either the current raw value or a legacy sidebar raw value
    /// (Swift <c>SettingsTab.resolving(legacyRawValue:)</c>).
    /// </summary>
    public static SettingsTab? ResolvingLegacyRawValue(string raw)
    {
        foreach (var tab in Enum.GetValues<SettingsTab>())
        {
            if (RawValue(tab) == raw) return tab;
        }
        return raw switch
        {
            "providers" or "routingPools" or "connections" or "switcher" or "hermes" => SettingsTab.Agents,
            "gateway" or "proxy" or "modelProxy" => SettingsTab.ModelProxy,
            _ => (SettingsTab?)null,
        };
    }
}

/// <summary>Section titles + ordered tab membership (Swift <c>SettingsSection</c> extension).</summary>
public static class SettingsSectionMetadata
{
    public static string Title(SettingsSection section) => section switch
    {
        SettingsSection.Home => "",
        SettingsSection.AgentsAndModels => "Agents & Models",
        SettingsSection.LookAndFeel => "Look & Feel",
        SettingsSection.AccountAndSync => "Account & Sync",
        SettingsSection.System => "System",
        SettingsSection.Extras => "More",
        _ => throw new ArgumentOutOfRangeException(nameof(section), section, null),
    };

    /// <summary>Tabs in display order within this section.</summary>
    public static IReadOnlyList<SettingsTab> Tabs(SettingsSection section) => section switch
    {
        SettingsSection.Home => new[] { SettingsTab.Home },
        SettingsSection.AgentsAndModels => new[] { SettingsTab.Agents, SettingsTab.ModelProxy },
        SettingsSection.LookAndFeel => new[] { SettingsTab.General },
        SettingsSection.AccountAndSync => new[]
        {
            SettingsTab.Account, SettingsTab.Cloud, SettingsTab.DevicesAndSync,
            SettingsTab.Alerts, SettingsTab.Notifications,
        },
        SettingsSection.System => new[] { SettingsTab.Daemon, SettingsTab.Updates, SettingsTab.DataPrivacy },
        SettingsSection.Extras => new[]
        {
            SettingsTab.TextExpansion, SettingsTab.Media, SettingsTab.ComputerUse, SettingsTab.Pets,
        },
        _ => throw new ArgumentOutOfRangeException(nameof(section), section, null),
    };

    /// <summary>Sections that render in the sidebar, in order (home handled separately).</summary>
    public static IReadOnlyList<SettingsSection> VisibleSections =>
        Enum.GetValues<SettingsSection>().Where(s => s != SettingsSection.Home).ToArray();
}
