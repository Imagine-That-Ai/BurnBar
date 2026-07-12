using System;
using System.Collections.Generic;
using System.Linq;

namespace OpenBurnBar.App.Presentation.Insights;

/// <summary>
/// Deterministic sample data for every chart kind — opt-in demonstration only.
/// Production paths must not call this unless <c>OPENBURNBAR_SAMPLE_MODE</c> is on
/// (see <see cref="InsightsBuiltInTemplates.SampleFallbackEnabled"/> and
/// <c>CloudSyncInsightSource</c>). Prefer <see cref="InsightEmptyData"/> for
/// production no-data widgets.
///
/// Every generator is a pure function of a small integer seed + an anchor date so
/// unit tests can pin exact output (known seed → known bar heights / radar values).
/// </summary>
public static class InsightSampleData
{
    /// <summary>Stable anchor so sample time-series land on predictable dates.</summary>
    public static readonly DateTimeOffset Anchor = new(2026, 7, 1, 0, 0, 0, TimeSpan.Zero);

    private static readonly string[] Providers = { "Claude", "OpenAI", "Gemini", "Groq", "Mistral" };
    private static readonly string[] Models =
    {
        "claude-opus-4", "gpt-5", "gemini-2.5-pro", "claude-sonnet-4", "o3", "llama-4-70b",
    };
    private static readonly string[] DayLabels = { "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" };

    /// <summary>Produce sample data appropriate for a widget kind (null for LLM/error kinds handled elsewhere).</summary>
    public static InsightWidgetData ForKind(InsightWidgetKind kind, int seed = 0) => kind switch
    {
        InsightWidgetKind.KpiTile => Kpi(seed),
        InsightWidgetKind.TimeSeriesLine => TimeSeries(seed, ValueFormat.Currency),
        InsightWidgetKind.TimeSeriesArea => TimeSeries(seed, ValueFormat.Tokens),
        InsightWidgetKind.Forecast => TimeSeries(seed, ValueFormat.Currency),
        InsightWidgetKind.BarRanking => Ranking(seed),
        InsightWidgetKind.Donut => Distribution(seed),
        InsightWidgetKind.Heatmap => Heatmap(seed),
        InsightWidgetKind.Scatter => Scatter(seed),
        InsightWidgetKind.Sankey => Sankey(seed),
        InsightWidgetKind.Radar => Radar(seed),
        InsightWidgetKind.Funnel => Funnel(seed),
        InsightWidgetKind.QuotaPulse => Quota(seed),
        InsightWidgetKind.Narrative => Narrative(seed),
        InsightWidgetKind.Recommendation => Recommendation(seed),
        InsightWidgetKind.Error => new ErrorData("Sample error surface"),
        _ => new EmptyData("No sample data"),
    };

    // ── Deterministic pseudo-random (splitmix-ish, pure) ─────────────────────────

    private static double Frac(int seed, int i)
    {
        unchecked
        {
            uint x = (uint)((seed * 2654435761u) + ((uint)i * 40503u) + 0x9E3779B9u);
            x ^= x >> 15;
            x *= 0x2C1B3C6Du;
            x ^= x >> 12;
            return (x & 0xFFFF) / 65535.0;
        }
    }

    public static KpiData Kpi(int seed)
    {
        double value = 120 + (Frac(seed, 1) * 900);
        double delta = (Frac(seed, 2) - 0.5) * 0.4;
        var spark = Enumerable.Range(0, 12).Select(i => 40 + (Frac(seed, 10 + i) * 60)).ToList();
        return new KpiData(
            MetricLabel: "Cost",
            Value: Math.Round(value, 2),
            ValueFormat: ValueFormat.Currency,
            Delta: Math.Round(delta, 3),
            DeltaIsPercent: true,
            Sparkline: spark,
            ContextLabel: "vs. previous period");
    }

    public static TimeSeriesData TimeSeries(int seed, ValueFormat format)
    {
        var series = new List<TimeSeriesSeries>();
        for (int s = 0; s < 3; s++)
        {
            var points = new List<TimeSeriesPoint>();
            for (int d = 0; d < 14; d++)
            {
                double v = 20 + (Frac(seed + s, d) * 80) + (d * 2);
                points.Add(new TimeSeriesPoint(Anchor.AddDays(d), Math.Round(v, 2)));
            }

            series.Add(new TimeSeriesSeries($"series-{s}", Providers[s % Providers.Length], points));
        }

        return new TimeSeriesData(series, "Day", "Cost", format);
    }

    public static RankingData Ranking(int seed)
    {
        var rows = Enumerable.Range(0, 6)
            .Select(i => new RankingRow(
                Id: $"rank-{i}",
                Label: Models[i % Models.Length],
                Value: Math.Round(50 + (Frac(seed, i) * 950), 2)))
            .OrderByDescending(r => r.Value)
            .ToList();
        return new RankingData(rows, ValueFormat.Currency, "Model");
    }

    public static DistributionData Distribution(int seed)
    {
        var slices = Enumerable.Range(0, 5)
            .Select(i => new DistributionSlice(
                Id: $"slice-{i}",
                Label: Models[i % Models.Length],
                Value: Math.Round(100 + (Frac(seed, i) * 400), 2)))
            .ToList();
        double total = slices.Sum(s => s.Value);
        return new DistributionData(slices, ValueFormat.Tokens, total);
    }

    public static HeatmapData Heatmap(int seed)
    {
        var cells = new List<IReadOnlyList<double>>();
        for (int r = 0; r < 7; r++)
        {
            var row = new List<double>();
            for (int c = 0; c < 24; c++)
            {
                row.Add(Math.Round(Frac(seed + r, c) * 100, 1));
            }

            cells.Add(row);
        }

        var cols = Enumerable.Range(0, 24).Select(h => h.ToString("00")).ToList();
        return new HeatmapData(DayLabels.ToList(), cols, cells, ValueFormat.Count);
    }

    public static ScatterData Scatter(int seed)
    {
        var points = Enumerable.Range(0, 8)
            .Select(i => new ScatterPoint(
                Id: $"pt-{i}",
                Label: Models[i % Models.Length],
                X: Math.Round(Frac(seed, i) * 1000, 2),
                Y: Math.Round(Frac(seed, 100 + i) * 500, 2),
                Size: 1 + (Frac(seed, 200 + i) * 3)))
            .ToList();
        return new ScatterData(points, "Tokens", "Cost", ValueFormat.Tokens, ValueFormat.Currency);
    }

    public static SankeyData Sankey(int seed)
    {
        var nodes = new List<SankeyNode>
        {
            new("claude", "Claude"),
            new("openai", "OpenAI"),
            new("gemini", "Gemini"),
            new("code", "Code"),
            new("chat", "Chat"),
            new("research", "Research"),
        };
        var links = new List<SankeyLink>
        {
            new("claude", "code", Math.Round(50 + (Frac(seed, 1) * 150), 1)),
            new("claude", "chat", Math.Round(20 + (Frac(seed, 2) * 80), 1)),
            new("openai", "code", Math.Round(30 + (Frac(seed, 3) * 90), 1)),
            new("openai", "research", Math.Round(10 + (Frac(seed, 4) * 60), 1)),
            new("gemini", "chat", Math.Round(15 + (Frac(seed, 5) * 70), 1)),
            new("gemini", "research", Math.Round(25 + (Frac(seed, 6) * 55), 1)),
        };
        return new SankeyData(nodes, links);
    }

    public static RadarData Radar(int seed)
    {
        var axes = new List<string> { "Code", "Chat", "Research", "Debug", "Review", "Docs" };
        var series = Enumerable.Range(0, 2)
            .Select(s => new RadarSeries(
                Id: $"agent-{s}",
                Name: Providers[s % Providers.Length],
                Values: Enumerable.Range(0, axes.Count).Select(a => Math.Round(0.2 + (Frac(seed + s, a) * 0.8), 3)).ToList()))
            .ToList();
        return new RadarData(axes, series);
    }

    public static FunnelData Funnel(int seed)
    {
        double start = 1000;
        var steps = new List<FunnelStep>();
        string[] labels = { "Opened", "Prompted", "Ran", "Kept" };
        for (int i = 0; i < labels.Length; i++)
        {
            start *= 0.55 + (Frac(seed, i) * 0.25);
            steps.Add(new FunnelStep($"step-{i}", labels[i], Math.Round(start)));
        }

        return new FunnelData(steps);
    }

    public static QuotaData Quota(int seed)
    {
        var buckets = Enumerable.Range(0, 4)
            .Select(i => new QuotaBucket(
                Id: $"bucket-{i}",
                ProviderLabel: Providers[i % Providers.Length],
                BucketName: i % 2 == 0 ? "5h window" : "weekly",
                Used: Math.Round(Frac(seed, i) * 100, 1),
                Limit: 100))
            .ToList();
        return new QuotaData(buckets);
    }

    public static NarrativeData Narrative(int seed)
        => new(
            Headline: "Spend held steady this week",
            Body: "Total cost was flat versus the previous period while token volume rose, indicating better cache utilization. Run an investigation for the full breakdown.",
            Bullets: new List<string> { "Cache hit rate up 6pts", "Opus share down 4pts", "No anomalous days" },
            Tone: Frac(seed, 1) > 0.5 ? NarrativeTone.Positive : NarrativeTone.Neutral);

    public static RecommendationData Recommendation(int seed)
        => new(
            Headline: "Shift routine chat to a cheaper model",
            Rationale: "Half of chat-tagged sessions used a frontier model for low-complexity turns.",
            Action: "Route chat to sonnet-class by default; keep opus for code + review.",
            EstimatedImpact: "~18% lower weekly cost",
            Confidence: Frac(seed, 1) > 0.5 ? RecommendationConfidence.High : RecommendationConfidence.Medium);
}
