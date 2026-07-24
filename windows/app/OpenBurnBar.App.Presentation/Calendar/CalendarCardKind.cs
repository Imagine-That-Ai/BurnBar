using System;
using System.Collections.Generic;

namespace OpenBurnBar.App.Presentation.Calendar;

/// <summary>
/// The registry of every analytics card the Calendar surface can render for the
/// current day selection. Port of macOS <c>CalendarCardKind</c>
/// (<c>CalendarPageLayout.swift</c>): each kind carries its own editorial
/// metadata, and adding a card = add a case here, prepare its data in
/// <see cref="CalendarSelectionSnapshot"/>, and give it a renderer arm in the page.
/// </summary>
public enum CalendarCardKind
{
    Kpis,
    BurnOverSelection,
    ProviderMix,
    ModelMix,
    HourOfDayHeatmap,
    ProjectFocus,
    CacheRoi,
    ReasoningShare,
}

/// <summary>Editorial + layout metadata for <see cref="CalendarCardKind"/>.</summary>
public static class CalendarCardKindMetadata
{
    /// <summary>All kinds in registry order (the default layout order).</summary>
    public static IReadOnlyList<CalendarCardKind> All { get; } = new[]
    {
        CalendarCardKind.Kpis,
        CalendarCardKind.BurnOverSelection,
        CalendarCardKind.ProviderMix,
        CalendarCardKind.ModelMix,
        CalendarCardKind.HourOfDayHeatmap,
        CalendarCardKind.ProjectFocus,
        CalendarCardKind.CacheRoi,
        CalendarCardKind.ReasoningShare,
    };

    /// <summary>Stable persisted id (JSON <c>kind</c> value; matches the macOS rawValue).</summary>
    public static string Id(CalendarCardKind kind) => kind switch
    {
        CalendarCardKind.Kpis => "kpis",
        CalendarCardKind.BurnOverSelection => "burnOverSelection",
        CalendarCardKind.ProviderMix => "providerMix",
        CalendarCardKind.ModelMix => "modelMix",
        CalendarCardKind.HourOfDayHeatmap => "hourOfDayHeatmap",
        CalendarCardKind.ProjectFocus => "projectFocus",
        CalendarCardKind.CacheRoi => "cacheROI",
        CalendarCardKind.ReasoningShare => "reasoningShare",
        _ => throw new ArgumentOutOfRangeException(nameof(kind), kind, "Unknown calendar card kind."),
    };

    /// <summary>Inverse of <see cref="Id"/>; <c>null</c> for unknown persisted values (dropped on decode).</summary>
    public static CalendarCardKind? KindForId(string? id) => id switch
    {
        "kpis" => CalendarCardKind.Kpis,
        "burnOverSelection" => CalendarCardKind.BurnOverSelection,
        "providerMix" => CalendarCardKind.ProviderMix,
        "modelMix" => CalendarCardKind.ModelMix,
        "hourOfDayHeatmap" => CalendarCardKind.HourOfDayHeatmap,
        "projectFocus" => CalendarCardKind.ProjectFocus,
        "cacheROI" => CalendarCardKind.CacheRoi,
        "reasoningShare" => CalendarCardKind.ReasoningShare,
        _ => null,
    };

    public static string Title(CalendarCardKind kind) => kind switch
    {
        CalendarCardKind.Kpis => "Key Numbers",
        CalendarCardKind.BurnOverSelection => "Burn Over Selection",
        CalendarCardKind.ProviderMix => "Provider Mix",
        CalendarCardKind.ModelMix => "Model Mix",
        CalendarCardKind.HourOfDayHeatmap => "When You Burn",
        CalendarCardKind.ProjectFocus => "Project Focus",
        CalendarCardKind.CacheRoi => "Cache Savings",
        CalendarCardKind.ReasoningShare => "Reasoning Share",
        _ => throw new ArgumentOutOfRangeException(nameof(kind), kind, "Unknown calendar card kind."),
    };

    /// <summary>One-line "why it matters" — rendered as the card's footer microcopy.</summary>
    public static string WhyItMatters(CalendarCardKind kind) => kind switch
    {
        CalendarCardKind.Kpis => "The selection at a glance — spend, volume, sessions, cadence.",
        CalendarCardKind.BurnOverSelection => "Day-by-day spend across the selected days.",
        CalendarCardKind.ProviderMix => "Where the money actually goes across providers.",
        CalendarCardKind.ModelMix => "Which models earn their keep — and which quietly dominate.",
        CalendarCardKind.HourOfDayHeatmap => "Your true working rhythm inside the selection.",
        CalendarCardKind.ProjectFocus => "Which projects the selected days actually funded.",
        CalendarCardKind.CacheRoi => "Prompt caching pays rent. This is the receipt.",
        CalendarCardKind.ReasoningShare => "Extended thinking is a hidden line item. Watch its share.",
        _ => throw new ArgumentOutOfRangeException(nameof(kind), kind, "Unknown calendar card kind."),
    };

    // Segoe MDL2 Assets glyphs — approximate Windows stand-ins for the macOS SF
    // Symbols (final icon parity is a design pass; same convention as NavCatalog).
    private const string GlyphCalculator = "\uE8EF";      // number.square
    private const string GlyphChart = "\uE9D2";           // chart.bar (Insights chart family)
    private const string GlyphDonut = "\uE9D9";           // chart.pie (Quota donut family)
    private const string GlyphCode = "\uE943";            // cube.transparent (code/dev family)
    private const string GlyphClock = "\uE917";           // clock.badge
    private const string GlyphProjects = "\uE8B7";        // scope (NavCatalog Projects glyph)
    private const string GlyphSave = "\uE74E";            // archivebox → Save/receipt
    private const string GlyphAi = "\uE99A";              // brain (ProviderMetadata AI family)
    private const string GlyphFallback = "\uE734";        // spark family

    /// <summary>Segoe MDL2 Assets glyph for the card header.</summary>
    public static string Glyph(CalendarCardKind kind) => kind switch
    {
        CalendarCardKind.Kpis => GlyphCalculator,
        CalendarCardKind.BurnOverSelection => GlyphChart,
        CalendarCardKind.ProviderMix => GlyphDonut,
        CalendarCardKind.ModelMix => GlyphCode,
        CalendarCardKind.HourOfDayHeatmap => GlyphClock,
        CalendarCardKind.ProjectFocus => GlyphProjects,
        CalendarCardKind.CacheRoi => GlyphSave,
        CalendarCardKind.ReasoningShare => GlyphAi,
        _ => GlyphFallback,
    };

    /// <summary>
    /// Grid span in columns (the analytics grid is 3 columns wide; 3 = full
    /// width). Surfaced in the UI as S/M/L sizes.
    /// </summary>
    public static int DefaultSpan(CalendarCardKind kind) => kind switch
    {
        CalendarCardKind.Kpis or CalendarCardKind.BurnOverSelection or CalendarCardKind.HourOfDayHeatmap => 3,
        _ => 1,
    };
}
