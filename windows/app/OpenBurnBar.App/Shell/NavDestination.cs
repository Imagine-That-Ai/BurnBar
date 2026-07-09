using System.Collections.Generic;
using System.Linq;

namespace OpenBurnBar.App.Shell;

/// <summary>
/// One top-level app destination — the Windows peer of a macOS
/// <c>DashboardMainRoute</c> / Command Deck section
/// (<c>AgentLens/Views/Dashboard/DashboardNavigationModel.swift</c>).
///
/// These are <b>not</b> the Dashboard Command sidebar rows (those are Overview /
/// providers / models, owned by <c>DashboardCommandSidebar</c>). Catalog entries
/// feed the section switcher menu + Command Palette.
/// </summary>
public sealed class NavDestination
{
    public NavDestination(string key, string title, string subtitle, string glyph, bool isFooter = false)
    {
        Key = key;
        Title = title;
        Subtitle = subtitle;
        Glyph = glyph;
        IsFooter = isFooter;
    }

    /// <summary>Stable identifier used as the NavigationViewItem tag + Frame navigation parameter.</summary>
    public string Key { get; }

    /// <summary>Sidebar label (matches the macOS route title where one exists).</summary>
    public string Title { get; }

    /// <summary>Secondary description (matches the macOS route subtitle where one exists).</summary>
    public string Subtitle { get; }

    /// <summary>Segoe MDL2 Assets glyph for the sidebar + palette rows.</summary>
    public string Glyph { get; }

    /// <summary>Whether this destination lives in the NavigationView footer (e.g. Settings).</summary>
    public bool IsFooter { get; }
}

/// <summary>
/// The canonical, ordered set of the 12 top-level surfaces the shell exposes. Kept in one
/// place so the NavigationView, the Command Palette, and later the real pages all agree.
/// Glyphs are Segoe MDL2 Assets code points (approximate; final icon parity is a design pass).
/// </summary>
public static class NavCatalog
{
    /// <summary>The 12 destinations named in the W6-SHELL lane, in sidebar order.</summary>
    public static IReadOnlyList<NavDestination> All { get; } = new List<NavDestination>
    {
        new("dashboard",         "Dashboard",          "All providers + models",          "\uE80F"),
        new("chat",              "Chat",               "Full-canvas chat",                "\uE8BD"),
        new("insights",          "Insights",           "Editorial brief & anomalies",     "\uE9D2"),
        new("quota",             "Quota",              "Subscriptions & limits",          "\uE9D9"),
        new("sessionLogs",       "Session Logs",       "Indexed conversations",           "\uE81C"),
        new("memory",            "Memory",             "Review what OpenBurnBar learned", "\uEA37"),
        new("missionControl",    "Mission Control",    "Active runs & tasks",             "\uE7C1"),
        new("budget",            "Budget",             "Spend rules & limits",            "\uE8C7"),
        new("dataControlCenter", "Data & Privacy",     "Govern every data domain",        "\uE964"),
        new("switcher",          "Switcher",           "Accounts & sign-in",              "\uE748"),
        new("onboarding",        "Onboarding",         "First-run setup",                 "\uE897"),
        new("settings",          "Settings",           "Preferences & configuration",     "\uE713", isFooter: true),
    };

    /// <summary>
    /// Secondary surfaces that are resolvable + navigable but are NOT sidebar rows — the Windows
    /// analog of macOS surfaces gated behind a Settings leaf / chat-header entry rather than one of
    /// the 12 top-level nav destinations. Kept out of <see cref="All"/> so the 12-row sidebar +
    /// Ctrl 1..9 parity holds; surfaced through the Command Palette so they stay reachable, and
    /// resolved by <see cref="SurfacePageResolver"/> the same as any destination.
    ///
    /// Elder Wand (<c>.gatedFeature(.elderWand)</c>, macOS "Analysis Models") is the first: reached
    /// here from the palette until the integration wave wires its live Settings-leaf / chat-header
    /// entry. See <c>windows/app/OpenBurnBar.App/ElderWand/ElderWandConfiguratorView.xaml</c>.
    /// </summary>
    public static IReadOnlyList<NavDestination> Auxiliary { get; } = new List<NavDestination>
    {
        new("elderWand", "Analysis Models", "Elder Wand analysis, judge & research budget", "\uE734"),
    };

    /// <summary>Menu (non-footer) destinations, in order.</summary>
    public static IEnumerable<NavDestination> Menu => All.Where(d => !d.IsFooter);

    /// <summary>Footer destinations, in order.</summary>
    public static IEnumerable<NavDestination> Footer => All.Where(d => d.IsFooter);

    /// <summary>The default destination shown on launch.</summary>
    public static NavDestination Default => All[0];

    /// <summary>
    /// Resolve a destination by its <see cref="NavDestination.Key"/> across the sidebar catalog
    /// (<see cref="All"/>) and the palette-only <see cref="Auxiliary"/> surfaces, or <c>null</c>.
    /// </summary>
    public static NavDestination? Find(string? key) =>
        key is null
            ? null
            : All.FirstOrDefault(d => d.Key == key) ?? Auxiliary.FirstOrDefault(d => d.Key == key);
}
