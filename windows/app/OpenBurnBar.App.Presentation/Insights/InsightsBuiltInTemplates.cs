using System;
using System.Collections.Generic;
using System.Linq;

namespace OpenBurnBar.App.Presentation.Insights;

/// <summary>
/// The eight ready-to-go canvas templates the user can stamp — a port of the macOS
/// <c>InsightsBuiltInTemplates</c> (<c>AgentLens/Views/Insights/InsightsBuiltInTemplates.swift</c>).
///
/// Each template ships as a plain literal so the first-run experience is instantly useful:
/// no LLM round-trip and (on Windows) no data engine needed to render a real, populated
/// canvas — each widget carries deterministic <see cref="InsightSampleData"/> keyed by a
/// stable seed. Icon glyphs are Segoe MDL2 Assets code points (approximate; final icon
/// parity is a design pass).
/// </summary>
public static class InsightsBuiltInTemplates
{
    private static readonly object Gate = new();
    private static Func<InsightWidgetKind, int, InsightWidgetData?>? _realDataResolver;
    private static IReadOnlyList<InsightCanvasTemplate>? _all;
    private static int _resolverVersion;

    /// <summary>
    /// Optional override for real data resolution. When set, KPI tiles use this
    /// instead of <see cref="InsightSampleData"/>. The app-level page sets this
    /// to read from the SQLCipher DB (via WindowsStorageDevHost).
    /// </summary>
    public static Func<InsightWidgetKind, int, InsightWidgetData?>? RealDataResolver
    {
        get
        {
            lock (Gate)
            {
                return _realDataResolver;
            }
        }

        set
        {
            lock (Gate)
            {
                _realDataResolver = value;
                _all = null;
                _resolverVersion++;
            }
        }
    }

    /// <summary>All templates, in gallery order (matches the macOS ordering).</summary>
    public static IReadOnlyList<InsightCanvasTemplate> All
    {
        get
        {
            Func<InsightWidgetKind, int, InsightWidgetData?>? resolver;
            int version;
            lock (Gate)
            {
                if (_all is { } cached)
                {
                    return cached;
                }

                resolver = _realDataResolver;
                version = _resolverVersion;
            }

            IReadOnlyList<InsightCanvasTemplate> built = BuildAll(resolver);

            lock (Gate)
            {
                if (_all is { } cached)
                {
                    return cached;
                }

                if (_resolverVersion == version)
                {
                    _all = built;
                    return _all;
                }
            }

            return All;
        }
    }

    /// <summary>Resolve a template by its stable string id.</summary>
    public static InsightCanvasTemplate? Find(string? id)
        => id is null ? null : All.FirstOrDefault(t => t.Id == id);

    private static IReadOnlyList<InsightCanvasTemplate> BuildAll(
        Func<InsightWidgetKind, int, InsightWidgetData?>? resolver) => new[]
    {
        Today(resolver),
        CostAudit(resolver),
        AgentFocus(resolver),
        ModelFocus(resolver),
        UseCaseLibrary(resolver),
        QuotaHealth(resolver),
        QuarterlyReview(resolver),
        Anomalies(resolver),
    };

    private static InsightWidget W(
        Func<InsightWidgetKind, int, InsightWidgetData?>? resolver,
        InsightWidgetKind kind,
        string title,
        int seed)
    {
        InsightWidgetData? realData = resolver?.Invoke(kind, seed);
        return InsightWidget.Create(kind, title, realData ?? InsightSampleData.ForKind(kind, seed));
    }

    private static InsightCanvasTemplate Today(Func<InsightWidgetKind, int, InsightWidgetData?>? resolver) => new(
        Id: "today",
        Title: "Today",
        Summary: "A daily snapshot of cost, sessions, cache, and your top model.",
        Glyph: "\uE706", // brightness / sun
        Theme: InsightTheme.Aurora,
        Widgets: new List<InsightWidget>
        {
            W(resolver, InsightWidgetKind.KpiTile, "Cost", 1),
            W(resolver, InsightWidgetKind.KpiTile, "Sessions", 2),
            W(resolver, InsightWidgetKind.KpiTile, "Cache hit", 3),
            W(resolver, InsightWidgetKind.KpiTile, "Tokens", 4),
            W(resolver, InsightWidgetKind.TimeSeriesLine, "Today by provider", 5),
            W(resolver, InsightWidgetKind.Heatmap, "When you worked", 6),
            W(resolver, InsightWidgetKind.Narrative, "Today's narrative", 7),
            W(resolver, InsightWidgetKind.QuotaPulse, "Quota pulse", 8),
        });

    private static InsightCanvasTemplate CostAudit(Func<InsightWidgetKind, int, InsightWidgetData?>? resolver) => new(
        Id: "cost-audit-7d",
        Title: "Cost Audit (7d)",
        Summary: "Where the money went last week.",
        Glyph: "\uE8C7", // money
        Theme: InsightTheme.Ember,
        Widgets: new List<InsightWidget>
        {
            W(resolver, InsightWidgetKind.KpiTile, "7d cost", 11),
            W(resolver, InsightWidgetKind.KpiTile, "Avg / session", 12),
            W(resolver, InsightWidgetKind.TimeSeriesArea, "Cost trend", 13),
            W(resolver, InsightWidgetKind.Donut, "Spend by model", 14),
            W(resolver, InsightWidgetKind.Scatter, "Efficiency frontier", 15),
            W(resolver, InsightWidgetKind.BarRanking, "Top spenders", 16),
            W(resolver, InsightWidgetKind.Forecast, "Next 7d projection", 17),
            W(resolver, InsightWidgetKind.Recommendation, "Top recommendation", 18),
        });

    private static InsightCanvasTemplate AgentFocus(Func<InsightWidgetKind, int, InsightWidgetData?>? resolver) => new(
        Id: "agent-focus",
        Title: "Agent Focus",
        Summary: "What each agent is being used for.",
        Glyph: "\uE716", // people
        Theme: InsightTheme.Whimsy,
        Widgets: new List<InsightWidget>
        {
            W(resolver, InsightWidgetKind.Heatmap, "Focuses by agent", 21),
            W(resolver, InsightWidgetKind.Radar, "Top agents — capability fingerprint", 22),
            W(resolver, InsightWidgetKind.Donut, "Common use cases", 23),
            W(resolver, InsightWidgetKind.BarRanking, "Recent sessions", 24),
        });

    private static InsightCanvasTemplate ModelFocus(Func<InsightWidgetKind, int, InsightWidgetData?>? resolver) => new(
        Id: "model-focus",
        Title: "Model Focus",
        Summary: "Where each model excels.",
        Glyph: "\uE964", // cpu / chip
        Theme: InsightTheme.Mercury,
        Widgets: new List<InsightWidget>
        {
            W(resolver, InsightWidgetKind.Donut, "Model mix", 31),
            W(resolver, InsightWidgetKind.Heatmap, "Focuses by model", 32),
            W(resolver, InsightWidgetKind.Scatter, "Cost-per-Mtoken vs. volume", 33),
            W(resolver, InsightWidgetKind.Narrative, "Model shift", 34),
        });

    private static InsightCanvasTemplate UseCaseLibrary(Func<InsightWidgetKind, int, InsightWidgetData?>? resolver) => new(
        Id: "use-case-library",
        Title: "Use-Case Library",
        Summary: "Tags, clusters, and examples.",
        Glyph: "\uE8EC", // tag
        Theme: InsightTheme.Aurora,
        Widgets: new List<InsightWidget>
        {
            W(resolver, InsightWidgetKind.Donut, "Use case clusters", 41),
            W(resolver, InsightWidgetKind.Heatmap, "Agent × focus", 42),
            W(resolver, InsightWidgetKind.BarRanking, "Top sessions", 43),
        });

    private static InsightCanvasTemplate QuotaHealth(Func<InsightWidgetKind, int, InsightWidgetData?>? resolver) => new(
        Id: "quota-health",
        Title: "Quota Health",
        Summary: "How close you are to your provider caps.",
        Glyph: "\uE9D9", // gauge
        Theme: InsightTheme.Ember,
        Widgets: new List<InsightWidget>
        {
            W(resolver, InsightWidgetKind.QuotaPulse, "Quota pulse", 51),
            W(resolver, InsightWidgetKind.Recommendation, "Headroom suggestion", 52),
            W(resolver, InsightWidgetKind.TimeSeriesLine, "Usage trend", 53),
        });

    private static InsightCanvasTemplate QuarterlyReview(Func<InsightWidgetKind, int, InsightWidgetData?>? resolver) => new(
        Id: "quarterly-review",
        Title: "Quarterly Review",
        Summary: "90 days at a glance.",
        Glyph: "\uE787", // calendar
        Theme: InsightTheme.Mercury,
        Widgets: new List<InsightWidget>
        {
            W(resolver, InsightWidgetKind.KpiTile, "90d cost", 61),
            W(resolver, InsightWidgetKind.KpiTile, "Sessions", 62),
            W(resolver, InsightWidgetKind.TimeSeriesArea, "Cost over 90d", 63),
            W(resolver, InsightWidgetKind.Funnel, "Conversion", 64),
            W(resolver, InsightWidgetKind.BarRanking, "Top 10 models", 65),
            W(resolver, InsightWidgetKind.Narrative, "Highlights", 66),
        });

    private static InsightCanvasTemplate Anomalies(Func<InsightWidgetKind, int, InsightWidgetData?>? resolver) => new(
        Id: "anomalies",
        Title: "Anomalies",
        Summary: "Outlier days, spikes, and dips.",
        Glyph: "\uE7BA", // warning
        Theme: InsightTheme.Ember,
        Widgets: new List<InsightWidget>
        {
            W(resolver, InsightWidgetKind.BarRanking, "Anomaly table", 71),
            W(resolver, InsightWidgetKind.TimeSeriesLine, "Cost with anomalies", 72),
            W(resolver, InsightWidgetKind.Sankey, "Sessions on outlier days", 73),
            W(resolver, InsightWidgetKind.Narrative, "Per-anomaly explanation", 74),
        });
}
