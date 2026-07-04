namespace OpenBurnBar.App.Presentation.Insights;

/// <summary>Which renderer a widget's data maps to (the portable analog of the macOS render switch).</summary>
public enum InsightRenderKind
{
    Skeleton,
    Kpi,
    Line,
    Bar,
    Donut,
    Heatmap,
    Scatter,
    Sankey,
    Radar,
    Funnel,
    Quota,
    Narrative,
    Recommendation,
    Empty,
    Error,
}

/// <summary>
/// Maps an <see cref="InsightWidgetData"/> to the renderer that draws it — the C# analog of
/// the exhaustive <c>switch</c> in the macOS <c>InsightWidgetRenderer</c>. Keeping the dispatch
/// as pure data lets the unit tests prove that every data variant has a home (no silent
/// fall-through) without needing a WinUI host.
/// </summary>
public static class InsightRenderPlan
{
    /// <summary>Resolve the renderer for a (possibly null) data payload.</summary>
    public static InsightRenderKind Resolve(InsightWidgetData? data) => data switch
    {
        null => InsightRenderKind.Skeleton,
        KpiData => InsightRenderKind.Kpi,
        TimeSeriesData => InsightRenderKind.Line,
        RankingData => InsightRenderKind.Bar,
        DistributionData => InsightRenderKind.Donut,
        HeatmapData => InsightRenderKind.Heatmap,
        ScatterData => InsightRenderKind.Scatter,
        SankeyData => InsightRenderKind.Sankey,
        RadarData => InsightRenderKind.Radar,
        FunnelData => InsightRenderKind.Funnel,
        QuotaData => InsightRenderKind.Quota,
        NarrativeData => InsightRenderKind.Narrative,
        RecommendationData => InsightRenderKind.Recommendation,
        EmptyData => InsightRenderKind.Empty,
        ErrorData => InsightRenderKind.Error,
        _ => InsightRenderKind.Error,
    };
}
