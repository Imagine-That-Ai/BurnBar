namespace OpenBurnBar.App.Presentation.Insights;

/// <summary>
/// The registry of widget kinds the Insights canvas can render — a port of the macOS
/// <c>InsightWidgetKind</c> (<c>OpenBurnBarCore/.../Insights/InsightWidgetKind.swift</c>).
///
/// This Windows-port lane ships the deterministic, locally-drawable chart family: KPI,
/// time-series (line/area), bar ranking, donut, heatmap, scatter, sankey, radar, funnel,
/// plus the LLM-authored narrative/recommendation cards. The macOS enum carries a few more
/// LLM-only kinds (mermaid/ascii/composed) that arrive with the Insights data engine lane;
/// keeping the shared subset in sync is intentional.
/// </summary>
public enum InsightWidgetKind
{
    KpiTile,
    TimeSeriesLine,
    TimeSeriesArea,
    BarRanking,
    Donut,
    Heatmap,
    Scatter,
    Sankey,
    Radar,
    Funnel,
    QuotaPulse,
    Forecast,
    Narrative,
    Recommendation,
    Error,
}

/// <summary>
/// Per-kind presentation metadata (label, sidebar glyph, default grid span). Split out from
/// the enum so the pure data stays trivially serializable. Every method is a total function
/// over <see cref="InsightWidgetKind"/>, exercised exhaustively by the unit tests.
/// </summary>
public static class InsightWidgetKindInfo
{
    /// <summary>User-facing label for the add-widget menu + inspector picker (parity with Swift).</summary>
    public static string DisplayName(InsightWidgetKind kind) => kind switch
    {
        InsightWidgetKind.KpiTile => "KPI Tile",
        InsightWidgetKind.TimeSeriesLine => "Trend (Line)",
        InsightWidgetKind.TimeSeriesArea => "Trend (Area)",
        InsightWidgetKind.BarRanking => "Top-N Ranking",
        InsightWidgetKind.Donut => "Donut",
        InsightWidgetKind.Heatmap => "Heatmap",
        InsightWidgetKind.Scatter => "Scatter",
        InsightWidgetKind.Sankey => "Sankey Flow",
        InsightWidgetKind.Radar => "Radar",
        InsightWidgetKind.Funnel => "Funnel",
        InsightWidgetKind.QuotaPulse => "Quota Pulse",
        InsightWidgetKind.Forecast => "Forecast",
        InsightWidgetKind.Narrative => "Narrative",
        InsightWidgetKind.Recommendation => "Recommendation",
        InsightWidgetKind.Error => "Error",
        _ => "Widget",
    };

    /// <summary>
    /// Segoe MDL2 Assets glyph shown on the widget-header chip and in the add menu. The macOS
    /// enum uses SF Symbols; this is the closest MDL2 analog per kind (final icon parity is a
    /// design pass, tracked the same way the shell tracks its nav glyphs).
    /// </summary>
    public static string Glyph(InsightWidgetKind kind) => kind switch
    {
        InsightWidgetKind.KpiTile => "\uE8C7",          // number / money tile
        InsightWidgetKind.TimeSeriesLine => "\uE9D2",   // line chart
        InsightWidgetKind.TimeSeriesArea => "\uE9D2",
        InsightWidgetKind.BarRanking => "\uE9D9",       // bars / gauge
        InsightWidgetKind.Donut => "\uE9D9",            // pie / donut
        InsightWidgetKind.Heatmap => "\uE964",          // data grid
        InsightWidgetKind.Scatter => "\uE964",          // dots / scatter
        InsightWidgetKind.Sankey => "\uE7C1",           // flow / branch
        InsightWidgetKind.Radar => "\uE9D2",            // radial
        InsightWidgetKind.Funnel => "\uE71C",           // filter / funnel
        InsightWidgetKind.QuotaPulse => "\uE9D9",       // gauge
        InsightWidgetKind.Forecast => "\uE9D2",         // trending
        InsightWidgetKind.Narrative => "\uE8BD",        // quote / text
        InsightWidgetKind.Recommendation => "\uE734",   // lightbulb / star
        InsightWidgetKind.Error => "\uE783",            // error
        _ => "\uE9D2",
    };

    /// <summary>
    /// Default placement: how many columns/rows the widget claims when freshly added on a
    /// 12-column canvas. Direct port of the Swift <c>defaultSpan</c> for the shared kinds.
    /// </summary>
    public static (int Columns, int Rows) DefaultSpan(InsightWidgetKind kind) => kind switch
    {
        InsightWidgetKind.KpiTile => (3, 2),
        InsightWidgetKind.TimeSeriesLine => (8, 3),
        InsightWidgetKind.TimeSeriesArea => (8, 3),
        InsightWidgetKind.BarRanking => (4, 4),
        InsightWidgetKind.Donut => (4, 3),
        InsightWidgetKind.Heatmap => (6, 3),
        InsightWidgetKind.Scatter => (6, 4),
        InsightWidgetKind.Sankey => (12, 4),
        InsightWidgetKind.Radar => (6, 4),
        InsightWidgetKind.Funnel => (4, 4),
        InsightWidgetKind.QuotaPulse => (6, 3),
        InsightWidgetKind.Forecast => (8, 3),
        InsightWidgetKind.Narrative => (8, 3),
        InsightWidgetKind.Recommendation => (8, 3),
        InsightWidgetKind.Error => (4, 2),
        _ => (4, 3),
    };

    /// <summary>Whether the kind is authored by the LLM rather than drawn from local data.</summary>
    public static bool IsLLMAuthored(InsightWidgetKind kind) => kind switch
    {
        InsightWidgetKind.Narrative => true,
        InsightWidgetKind.Recommendation => true,
        _ => false,
    };
}
