using System.Collections.Generic;
using System.Linq;

namespace OpenBurnBar.App.Shell;

/// <summary>
/// One sidebar destination in the WinUI <c>NavigationView</c> app frame — the Windows
/// analog of a macOS <c>NavigationSplitView</c> sidebar row / <c>DashboardMainRoute</c>
/// (<c>AgentLens/Views/Dashboard/DashboardNavigationModel.swift</c>).
///
/// Phase 3 W6-SHELL ships the frame with all 12 destinations <b>stubbed</b>: selecting one
/// navigates a content <c>Frame</c> to a placeholder that names the surface. The real
/// surfaces (Buckets A/B/C of the Phase-3 plan) replace those placeholders one by one; the
/// catalog here is the stable seam they plug into.
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
        new("dataControlCenter", "Data Control Center","Local & synced data",             "\uE964"),
        new("switcher",          "Switcher",           "Accounts & sign-in",              "\uE748"),
        new("onboarding",        "Onboarding",         "First-run setup",                 "\uE897"),
        new("settings",          "Settings",           "Preferences & configuration",     "\uE713", isFooter: true),
    };

    /// <summary>Menu (non-footer) destinations, in order.</summary>
    public static IEnumerable<NavDestination> Menu => All.Where(d => !d.IsFooter);

    /// <summary>Footer destinations, in order.</summary>
    public static IEnumerable<NavDestination> Footer => All.Where(d => d.IsFooter);

    /// <summary>The default destination shown on launch.</summary>
    public static NavDestination Default => All[0];

    /// <summary>Resolve a destination by its <see cref="NavDestination.Key"/>, or <c>null</c>.</summary>
    public static NavDestination? Find(string? key) =>
        key is null ? null : All.FirstOrDefault(d => d.Key == key);
}
