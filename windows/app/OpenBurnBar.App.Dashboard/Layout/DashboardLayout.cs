using System;
using System.Collections.Generic;

namespace OpenBurnBar.App.Dashboard.Layout;

/// <summary>
/// The named dashboard *layout* concept the overview renders — a C# port of the
/// shared <c>DashboardLayout</c> enum in
/// <c>OpenBurnBarCore/.../SharedModels/ThemePrimitives.swift</c>. The five "Liquid
/// Glass Studio" concepts plus <see cref="Classic"/> (the information-dense scroll).
/// </summary>
/// <remarks>
/// The <see cref="DashboardLayoutMeta.RawValue"/> strings and
/// <see cref="DashboardLayoutMeta.StorageKey"/> are shared VERBATIM across
/// platforms (same <c>@AppStorage("dashboardLayout")</c>), so a Windows selection
/// round-trips through the same preference key a future iOS/Android build reads.
/// </remarks>
public enum DashboardLayout
{
    /// <summary>The information-dense vertical scroll overview. The safe fallback.</summary>
    Classic,

    /// <summary>Provider list + open hero swarm field + a bottom data band.</summary>
    Aurora,

    /// <summary>Bento grid: provider panel, big burn card, framed swarm stage, data row.</summary>
    Nebula,

    /// <summary>Centered command column: search/Hermes bar over a full swarm stage.</summary>
    Constellation,

    /// <summary>Mission-control grid: spend-share rail, four KPI tiles, routing swarm.</summary>
    Cockpit,

    /// <summary>Full-bleed kernel-forward hero + three floating glass stat cards. The default.</summary>
    Atelier,
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

    /// <summary>The out-of-box default — the design phase's "keeper".</summary>
    public const DashboardLayout Default = DashboardLayout.Atelier;

    /// <summary>All layouts in canonical (switcher) order — matches Swift <c>allCases</c>.</summary>
    public static readonly IReadOnlyList<DashboardLayout> All = new[]
    {
        DashboardLayout.Classic,
        DashboardLayout.Aurora,
        DashboardLayout.Nebula,
        DashboardLayout.Constellation,
        DashboardLayout.Cockpit,
        DashboardLayout.Atelier,
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
        _ => "atelier",
    };

    public static string DisplayName(this DashboardLayout layout) => layout switch
    {
        DashboardLayout.Classic => "Classic",
        DashboardLayout.Aurora => "Aurora",
        DashboardLayout.Nebula => "Nebula",
        DashboardLayout.Constellation => "Constellation",
        DashboardLayout.Cockpit => "Cockpit",
        DashboardLayout.Atelier => "Atelier",
        _ => "Atelier",
    };

    /// <summary>The SF Symbol name — kept for cross-platform parity with the Swift enum.</summary>
    public static string SymbolName(this DashboardLayout layout) => layout switch
    {
        DashboardLayout.Classic => "rectangle.grid.1x2",
        DashboardLayout.Aurora => "sun.haze",
        DashboardLayout.Nebula => "rectangle.grid.2x2",
        DashboardLayout.Constellation => "sparkles",
        DashboardLayout.Cockpit => "gauge.with.dots.needle.67percent",
        DashboardLayout.Atelier => "paintpalette",
        _ => "paintpalette",
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
