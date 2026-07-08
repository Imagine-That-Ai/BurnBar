using System;
using System.Collections.Generic;

namespace OpenBurnBar.App.Presentation.Insights;

/// <summary>
/// Concrete, value-typed data shapes the chart renderers actually consume — a port of the
/// macOS <c>InsightWidgetData</c> enum
/// (<c>OpenBurnBarCore/.../Insights/InsightWidgetData.swift</c>).
///
/// Modeled as a sealed record hierarchy so the Win2D renderer + the render-plan dispatcher
/// can pattern-match exhaustively (the C# analog of the Swift <c>switch</c> over the data
/// enum). Once a chart is reading an <see cref="InsightWidgetData"/> it never reaches back
/// into a store — that is what makes widgets reorderable, exportable, and snapshot-able.
/// </summary>
public abstract record InsightWidgetData;

/// <summary>Single headline metric with an optional delta pill + sparkline (KPI tile).</summary>
public sealed record KpiData(
    string MetricLabel,
    double Value,
    ValueFormat ValueFormat,
    double? Delta = null,
    bool DeltaIsPercent = true,
    IReadOnlyList<double>? Sparkline = null,
    string? ContextLabel = null) : InsightWidgetData
{
    public IReadOnlyList<double> SparklinePoints => Sparkline ?? Array.Empty<double>();
}

/// <summary>One point on a time-series line/area chart.</summary>
public sealed record TimeSeriesPoint(DateTimeOffset Date, double Value);

/// <summary>One named series (a line) on a time-series chart.</summary>
public sealed record TimeSeriesSeries(
    string Id,
    string Name,
    IReadOnlyList<TimeSeriesPoint> Points,
    string? ColorHex = null);

/// <summary>A multi-series trend (line or area).</summary>
public sealed record TimeSeriesData(
    IReadOnlyList<TimeSeriesSeries> Series,
    string XAxisLabel,
    string YAxisLabel,
    ValueFormat YFormat) : InsightWidgetData;

/// <summary>One horizontal bar in a Top-N ranking.</summary>
public sealed record RankingRow(
    string Id,
    string Label,
    double Value,
    string? SecondaryLabel = null,
    string? ColorHex = null);

/// <summary>A ranked list drawn as horizontal bars.</summary>
public sealed record RankingData(
    IReadOnlyList<RankingRow> Rows,
    ValueFormat ValueFormat,
    string DimensionLabel) : InsightWidgetData;

/// <summary>One slice of a donut / pie.</summary>
public sealed record DistributionSlice(
    string Id,
    string Label,
    double Value,
    string? ColorHex = null);

/// <summary>A proportional distribution drawn as a donut.</summary>
public sealed record DistributionData(
    IReadOnlyList<DistributionSlice> Slices,
    ValueFormat ValueFormat,
    double Total) : InsightWidgetData;

/// <summary>
/// A dense grid of values (default 7 day-of-week rows × 24 hour columns, but encoded
/// generically). <see cref="Cells"/> is row-major: <c>Cells[row][col]</c>.
/// </summary>
public sealed record HeatmapData(
    IReadOnlyList<string> RowLabels,
    IReadOnlyList<string> ColumnLabels,
    IReadOnlyList<IReadOnlyList<double>> Cells,
    ValueFormat ValueFormat) : InsightWidgetData;

/// <summary>One bubble on a scatter plot.</summary>
public sealed record ScatterPoint(
    string Id,
    string Label,
    double X,
    double Y,
    double Size = 1,
    string? ColorHex = null);

/// <summary>A scatter / bubble chart.</summary>
public sealed record ScatterData(
    IReadOnlyList<ScatterPoint> Points,
    string XAxisLabel,
    string YAxisLabel,
    ValueFormat XFormat,
    ValueFormat YFormat) : InsightWidgetData;

/// <summary>A sankey flow node.</summary>
public sealed record SankeyNode(string Id, string Label, string? ColorHex = null);

/// <summary>A weighted sankey flow link between two node ids.</summary>
public sealed record SankeyLink(string Source, string Target, double Value);

/// <summary>A flow diagram (rendered as two proportional node columns).</summary>
public sealed record SankeyData(
    IReadOnlyList<SankeyNode> Nodes,
    IReadOnlyList<SankeyLink> Links) : InsightWidgetData;

/// <summary>One capability fingerprint (a polygon) on a radar chart.</summary>
public sealed record RadarSeries(
    string Id,
    string Name,
    IReadOnlyList<double> Values,
    string? ColorHex = null);

/// <summary>A radar / spider chart over a shared set of axes.</summary>
public sealed record RadarData(
    IReadOnlyList<string> Axes,
    IReadOnlyList<RadarSeries> Series) : InsightWidgetData;

/// <summary>One step of a funnel.</summary>
public sealed record FunnelStep(string Id, string Label, double Count);

/// <summary>A funnel (monotonically narrowing steps).</summary>
public sealed record FunnelData(IReadOnlyList<FunnelStep> Steps) : InsightWidgetData;

/// <summary>One provider bucket in the quota pulse.</summary>
public sealed record QuotaBucket(
    string Id,
    string ProviderLabel,
    string BucketName,
    double Used,
    double? Limit,
    string? ColorHex = null)
{
    /// <summary>Fraction used, clamped to [0,1]; 0 when there is no positive limit.</summary>
    public double Fraction => Limit is > 0 ? Math.Clamp(Used / Limit.Value, 0, 1) : 0;
}

/// <summary>The quota pulse (a set of provider usage gauges).</summary>
public sealed record QuotaData(IReadOnlyList<QuotaBucket> Buckets) : InsightWidgetData;

/// <summary>An LLM-authored narrative card.</summary>
public sealed record NarrativeData(
    string Headline,
    string Body,
    IReadOnlyList<string>? Bullets = null,
    NarrativeTone Tone = NarrativeTone.Neutral) : InsightWidgetData
{
    public IReadOnlyList<string> BulletPoints => Bullets ?? Array.Empty<string>();
}

/// <summary>Tone accent for a narrative card.</summary>
public enum NarrativeTone
{
    Positive,
    Neutral,
    Warning,
    Negative,
}

/// <summary>An LLM-authored recommendation card.</summary>
public sealed record RecommendationData(
    string Headline,
    string Rationale,
    string Action,
    string? EstimatedImpact = null,
    RecommendationConfidence Confidence = RecommendationConfidence.Medium) : InsightWidgetData;

/// <summary>Confidence level for a recommendation.</summary>
public enum RecommendationConfidence
{
    Low,
    Medium,
    High,
}

/// <summary>A widget whose data could not be produced.</summary>
public sealed record ErrorData(string Message) : InsightWidgetData;

/// <summary>A widget with no data yet (renders a skeleton).</summary>
public sealed record EmptyData(string Reason) : InsightWidgetData;
