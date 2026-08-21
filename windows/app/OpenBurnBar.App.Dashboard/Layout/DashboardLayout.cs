using System;
using System.Collections.Generic;

namespace OpenBurnBar.App.Dashboard.Layout;

/// <summary>
/// The dashboard *layout* the overview renders — a C# port of the shared
/// <c>DashboardLayout</c> enum in
/// <c>OpenBurnBarCore/.../SharedModels/ThemePrimitives.swift</c>. Each case is a
/// different way of reading the same data, not a different backdrop.
/// </summary>
/// <remarks>
/// The <see cref="DashboardLayoutMeta.RawValue"/> strings and
/// <see cref="DashboardLayoutMeta.StorageKey"/> are shared VERBATIM across
/// platforms (same <c>@AppStorage("dashboardLayout")</c>), so a Windows selection
/// round-trips through the same preference key a future iOS/Android build reads.
/// The enum member names are the original design-phase codenames and are kept as
/// opaque ids; <see cref="DashboardLayoutMeta.DisplayName"/> carries the names a
/// user actually sees.
/// </remarks>
public enum DashboardLayout
{
    /// <summary>"Ledger" — one dense ordered scroll, no hero. The safe fallback.</summary>
    Classic,

    /// <summary>"Focus" — one number above the fold, everything else collapsed under it.</summary>
    Aurora,

    /// <summary>"Bento" — equal-weight tile grid with no reading order.</summary>
    Nebula,

    /// <summary>"Ask" — the question box leads and the page assembles from it.</summary>
    Constellation,

    /// <summary>"Cockpit" — gauges, live routing, alarm states, cache hit rate.</summary>
    Cockpit,

    /// <summary>"Canvas" — full-bleed kernel, editorial headline, minimal numbers.</summary>
    Atelier,

    /// <summary>"Stream" — a chronological river of sessions, spikes and alerts.</summary>
    Stream,

    /// <summary>"Atlas" — ranked side-by-side provider and model comparison with deltas.</summary>
    Atlas,
}

/// <summary>
/// Presentation + persistence metadata for <see cref="DashboardLayout"/> — the C#
/// home for the Swift enum's computed properties (<c>rawValue</c>, <c>displayName</c>,
/// <c>symbolName</c>, <c>isKernelForward</c>, <c>storageKey</c>, <c>current</c>).
/// </summary>
public static class DashboardLayoutMeta
{
    /// <summary><c>ApplicationData</c> / <c>@AppStorage</c> key — shared verbatim across platforms.</summary>
    public const string StorageKey = "dashboardLayout";

    /// <summary>
    /// The out-of-box default. Focus rather than Canvas: Canvas is the ambient
    /// second-display surface whose thesis is deliberately to show almost nothing,
    /// which makes a poor first impression on a primary monitor. Focus opens on the
    /// one thing that needs a decision. Kept in lockstep with Swift
    /// (<c>DashboardLayout.current</c>) and TypeScript (<c>DEFAULT_DASHBOARD_LAYOUT</c>).
    /// </summary>
    public const DashboardLayout Default = DashboardLayout.Aurora;

    /// <summary>All layouts in canonical (switcher) order — matches Swift <c>allCases</c>.</summary>
    public static readonly IReadOnlyList<DashboardLayout> All = new[]
    {
        DashboardLayout.Classic,
        DashboardLayout.Aurora,
        DashboardLayout.Nebula,
        DashboardLayout.Constellation,
        DashboardLayout.Cockpit,
        DashboardLayout.Atelier,
        DashboardLayout.Stream,
        DashboardLayout.Atlas,
    };

    /// <summary>The stable persisted string. Renaming these orphans saved preferences.</summary>
    public static string RawValue(this DashboardLayout layout) => layout switch
    {
        DashboardLayout.Classic => "classic",
        DashboardLayout.Aurora => "aurora",
        DashboardLayout.Nebula => "nebula",
        DashboardLayout.Constellation => "constellation",
        DashboardLayout.Cockpit => "cockpit",
        DashboardLayout.Atelier => "atelier",
        DashboardLayout.Stream => "stream",
        DashboardLayout.Atlas => "atlas",
        _ => "atelier",
    };

    public static string DisplayName(this DashboardLayout layout) => layout switch
    {
        DashboardLayout.Classic => "Ledger",
        DashboardLayout.Aurora => "Focus",
        DashboardLayout.Nebula => "Bento",
        DashboardLayout.Constellation => "Ask",
        DashboardLayout.Cockpit => "Cockpit",
        DashboardLayout.Atelier => "Canvas",
        DashboardLayout.Stream => "Stream",
        DashboardLayout.Atlas => "Atlas",
        _ => "Canvas",
    };

    /// <summary>Who the layout is for, in one line. Mirrors the Swift <c>tagline</c>.</summary>
    public static string Tagline(this DashboardLayout layout) => layout switch
    {
        DashboardLayout.Classic => "Every row, in order",
        DashboardLayout.Aurora => "One number, front and centre",
        DashboardLayout.Nebula => "Equal tiles, scan anywhere",
        DashboardLayout.Constellation => "Ask first, results follow",
        DashboardLayout.Cockpit => "Instruments and alarm states",
        DashboardLayout.Atelier => "Ambient, for a second screen",
        DashboardLayout.Stream => "What happened, newest first",
        DashboardLayout.Atlas => "Side by side, with deltas",
        _ => "Ambient, for a second screen",
    };

    /// <summary>The SF Symbol name — kept for cross-platform parity with the Swift enum.</summary>
    public static string SymbolName(this DashboardLayout layout) => layout switch
    {
        DashboardLayout.Classic => "list.bullet.rectangle",
        DashboardLayout.Aurora => "largecircle.fill.circle",
        DashboardLayout.Nebula => "square.grid.2x2",
        DashboardLayout.Constellation => "text.magnifyingglass",
        DashboardLayout.Cockpit => "gauge.with.dots.needle.67percent",
        DashboardLayout.Atelier => "photo.artframe",
        DashboardLayout.Stream => "arrow.down.right.and.arrow.up.left.circle",
        DashboardLayout.Atlas => "chart.bar.xaxis",
        _ => "photo.artframe",
    };

    /// <summary>
    /// The nearest Segoe MDL2 Assets glyph code point for the WinUI FontIcon switcher
    /// (approximate; final icon parity is a design pass, exactly as the NavCatalog notes).
    /// Returned as a hex code point so the source carries no private-use characters;
    /// <see cref="Glyph"/> materialises the actual glyph string.
    /// </summary>
    public static int GlyphCodePoint(this DashboardLayout layout) => layout switch
    {
        DashboardLayout.Classic => 0xE8A9,       // ViewAll  - dense list
        DashboardLayout.Aurora => 0xE706,        // Brightness - sun.haze
        DashboardLayout.Nebula => 0xE80A,        // GridView - bento
        DashboardLayout.Constellation => 0xE734, // FavoriteStar - sparkles
        DashboardLayout.Cockpit => 0xE9D9,       // Diagnostic - gauge
        DashboardLayout.Atelier => 0xE790,       // Color - paintpalette
        DashboardLayout.Stream => 0xE81C,        // History - a time-ordered river
        DashboardLayout.Atlas => 0xE9D2,         // BarChart4 - ranked comparison
        _ => 0xE790,
    };

    /// <summary>The Segoe MDL2 glyph string for the switcher FontIcon.</summary>
    public static string Glyph(this DashboardLayout layout) => char.ConvertFromUtf32(layout.GlyphCodePoint());

    /// <summary>
    /// Whether the concept is kernel-forward (full-bleed backdrop is the hero) versus a
    /// structured panel layout. Drives small-window fallbacks.
    /// </summary>
    public static bool IsKernelForward(this DashboardLayout layout) => layout switch
    {
        DashboardLayout.Constellation or DashboardLayout.Atelier => true,
        _ => false,
    };

    /// <summary>
    /// Parse a persisted raw value, falling back to <see cref="Default"/> on unknown
    /// input — the exact contract of Swift's <c>DashboardLayout.current</c>.
    /// </summary>
    public static DashboardLayout Parse(string? raw)
    {
        if (raw is null)
        {
            return Default;
        }

        foreach (DashboardLayout layout in All)
        {
            if (string.Equals(layout.RawValue(), raw, StringComparison.Ordinal))
            {
                return layout;
            }
        }

        return Default;
    }
}
