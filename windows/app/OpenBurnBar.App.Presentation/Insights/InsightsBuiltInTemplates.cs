using System;
using System.Collections.Generic;
using System.Linq;

namespace OpenBurnBar.App.Presentation.Insights;

/// <summary>
/// The eight ready-to-go canvas templates the user can stamp — a port of the macOS
/// <c>InsightsBuiltInTemplates</c> (<c>AgentLens/Views/Insights/InsightsBuiltInTemplates.swift</c>).
///
/// Production default: missing live data resolves to honest empty widgets
/// (<see cref="InsightEmptyData"/>). Deterministic <see cref="InsightSampleData"/> is
/// only injected when <see cref="SampleFallbackEnabled"/> is explicitly on (opt-in demo
/// via <c>OPENBURNBAR_SAMPLE_MODE</c>, or unit tests that exercise sample generators).
/// Icon glyphs are Segoe MDL2 Assets code points (approximate; final icon parity is a
/// design pass).
/// </summary>
public static class InsightsBuiltInTemplates
{
    private static readonly object Gate = new();
    private static Func<InsightWidgetKind, int, InsightWidgetData?>? _realDataResolver;
    private static bool _sampleFallbackEnabled;
    private static IReadOnlyList<InsightCanvasTemplate>? _all;
    private static int _resolverVersion;

    /// <summary>
    /// Optional override for real data resolution. When set, the resolver result wins
    /// over empty/sample fallbacks. The app-level page installs a production resolver
    /// that reads KPI tiles from the SQLCipher / cloud usage summary.
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

    /// <summary>
    /// When true, unresolved widgets receive deterministic <see cref="InsightSampleData"/>.
    /// Defaults to <c>false</c> so production paths cannot silently paint demo series.
    /// The WinUI Insights page sets this from <c>RuntimeDataMode.SampleModeEnabled</c>;
    /// unit tests that need sample generators enable it in a try/finally.
    /// </summary>
    public static bool SampleFallbackEnabled
    {
        get
        {
            lock (Gate)
            {
                return _sampleFallbackEnabled;
            }
        }

        set
        {
            lock (Gate)
            {
                if (_sampleFallbackEnabled == value)
                {
                    return;
                }

                _sampleFallbackEnabled = value;
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
            bool sampleFallback;
            int version;
            lock (Gate)
            {
                if (_all is { } cached)
                {
                    return cached;
                }

                resolver = _realDataResolver;
                sampleFallback = _sampleFallbackEnabled;
                version = _resolverVersion;
            }

            IReadOnlyList<InsightCanvasTemplate> built = BuildAll(resolver, sampleFallback);

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
        Func<InsightWidgetKind, int, InsightWidgetData?>? resolver,
        bool sampleFallback) => new[]
    {
        Today(resolver, sampleFallback),
        CostAudit(resolver, sampleFallback),
        AgentFocus(resolver, sampleFallback),
        ModelFocus(resolver, sampleFallback),
        UseCaseLibrary(resolver, sampleFallback),
        QuotaHealth(resolver, sampleFallback),
        QuarterlyReview(resolver, sampleFallback),
        Anomalies(resolver, sampleFallback),
    };

    private static InsightWidget W(
        Func<InsightWidgetKind, int, InsightWidgetData?>? resolver,
        bool sampleFallback,
        InsightWidgetKind kind,
        string title,
        int seed)
    {
        InsightWidgetData? realData = resolver?.Invoke(kind, seed);
        if (realData is not null)
        {
            return InsightWidget.Create(kind, title, realData);
        }

        InsightWidgetData data = sampleFallback
            ? InsightSampleData.ForKind(kind, seed)
            : InsightEmptyData.ForKind(kind, seed);
        return InsightWidget.Create(kind, title, data);
    }

    private static InsightCanvasTemplate Today(
        Func<InsightWidgetKind, int, InsightWidgetData?>? resolver,
        bool sampleFallback) => new(
        Id: "today",
        Title: "Today",
        Summary: "A daily snapshot of cost, sessions, cache, and your top model.",
        Glyph: "\uE706", // brightness / sun
        Theme: InsightTheme.Aurora,
        Widgets: new List<InsightWidget>
        {
            W(resolver, sampleFallback, InsightWidgetKind.KpiTile, "Cost", 1),
            W(resolver, sampleFallback, InsightWidgetKind.KpiTile, "Sessions", 2),
            W(resolver, sampleFallback, InsightWidgetKind.KpiTile, "Cache hit", 3),
            W(resolver, sampleFallback, InsightWidgetKind.KpiTile, "Tokens", 4),
            W(resolver, sampleFallback, InsightWidgetKind.TimeSeriesLine, "Today by provider", 5),
            W(resolver, sampleFallback, InsightWidgetKind.Heatmap, "When you worked", 6),
            W(resolver, sampleFallback, InsightWidgetKind.Narrative, "Today's narrative", 7),
            W(resolver, sampleFallback, InsightWidgetKind.QuotaPulse, "Quota pulse", 8),
        });

    private static InsightCanvasTemplate CostAudit(
        Func<InsightWidgetKind, int, InsightWidgetData?>? resolver,
        bool sampleFallback) => new(
        Id: "cost-audit-7d",
        Title: "Cost Audit (7d)",
        Summary: "Where the money went last week.",
        Glyph: "\uE8C7", // money
        Theme: InsightTheme.Ember,
        Widgets: new List<InsightWidget>
        {
            W(resolver, sampleFallback, InsightWidgetKind.KpiTile, "7d cost", 11),
            W(resolver, sampleFallback, InsightWidgetKind.KpiTile, "Avg / session", 12),
            W(resolver, sampleFallback, InsightWidgetKind.TimeSeriesArea, "Cost trend", 13),
            W(resolver, sampleFallback, InsightWidgetKind.Donut, "Spend by model", 14),
            W(resolver, sampleFallback, InsightWidgetKind.Scatter, "Efficiency frontier", 15),
            W(resolver, sampleFallback, InsightWidgetKind.BarRanking, "Top spenders", 16),
            W(resolver, sampleFallback, InsightWidgetKind.Forecast, "Next 7d projection", 17),
            W(resolver, sampleFallback, InsightWidgetKind.Recommendation, "Top recommendation", 18),
        });

    private static InsightCanvasTemplate AgentFocus(
        Func<InsightWidgetKind, int, InsightWidgetData?>? resolver,
        bool sampleFallback) => new(
        Id: "agent-focus",
        Title: "Agent Focus",
        Summary: "What each agent is being used for.",
        Glyph: "\uE716", // people
        Theme: InsightTheme.Whimsy,
        Widgets: new List<InsightWidget>
        {
            W(resolver, sampleFallback, InsightWidgetKind.Heatmap, "Focuses by agent", 21),
            W(resolver, sampleFallback, InsightWidgetKind.Radar, "Top agents — capability fingerprint", 22),
            W(resolver, sampleFallback, InsightWidgetKind.Donut, "Common use cases", 23),
            W(resolver, sampleFallback, InsightWidgetKind.BarRanking, "Recent sessions", 24),
        });

    private static InsightCanvasTemplate ModelFocus(
        Func<InsightWidgetKind, int, InsightWidgetData?>? resolver,
        bool sampleFallback) => new(
        Id: "model-focus",
        Title: "Model Focus",
        Summary: "Where each model excels.",
        Glyph: "\uE964", // cpu / chip
        Theme: InsightTheme.Mercury,
        Widgets: new List<InsightWidget>
        {
            W(resolver, sampleFallback, InsightWidgetKind.Donut, "Model mix", 31),
            W(resolver, sampleFallback, InsightWidgetKind.Heatmap, "Focuses by model", 32),
            W(resolver, sampleFallback, InsightWidgetKind.Scatter, "Cost-per-Mtoken vs. volume", 33),
            W(resolver, sampleFallback, InsightWidgetKind.Narrative, "Model shift", 34),
        });

    private static InsightCanvasTemplate UseCaseLibrary(
        Func<InsightWidgetKind, int, InsightWidgetData?>? resolver,
        bool sampleFallback) => new(
        Id: "use-case-library",
        Title: "Use-Case Library",
        Summary: "Tags, clusters, and examples.",
        Glyph: "\uE8EC", // tag
        Theme: InsightTheme.Aurora,
        Widgets: new List<InsightWidget>
        {
            W(resolver, sampleFallback, InsightWidgetKind.Donut, "Use case clusters", 41),
            W(resolver, sampleFallback, InsightWidgetKind.Heatmap, "Agent × focus", 42),
            W(resolver, sampleFallback, InsightWidgetKind.BarRanking, "Top sessions", 43),
        });

    private static InsightCanvasTemplate QuotaHealth(
        Func<InsightWidgetKind, int, InsightWidgetData?>? resolver,
        bool sampleFallback) => new(
        Id: "quota-health",
        Title: "Quota Health",
        Summary: "How close you are to your provider caps.",
        Glyph: "\uE9D9", // gauge
        Theme: InsightTheme.Ember,
        Widgets: new List<InsightWidget>
        {
            W(resolver, sampleFallback, InsightWidgetKind.QuotaPulse, "Quota pulse", 51),
            W(resolver, sampleFallback, InsightWidgetKind.Recommendation, "Headroom suggestion", 52),
            W(resolver, sampleFallback, InsightWidgetKind.TimeSeriesLine, "Usage trend", 53),
        });

    private static InsightCanvasTemplate QuarterlyReview(
        Func<InsightWidgetKind, int, InsightWidgetData?>? resolver,
        bool sampleFallback) => new(
        Id: "quarterly-review",
        Title: "Quarterly Review",
        Summary: "90 days at a glance.",
        Glyph: "\uE787", // calendar
        Theme: InsightTheme.Mercury,
        Widgets: new List<InsightWidget>
        {
            W(resolver, sampleFallback, InsightWidgetKind.KpiTile, "90d cost", 61),
            W(resolver, sampleFallback, InsightWidgetKind.KpiTile, "Sessions", 62),
            W(resolver, sampleFallback, InsightWidgetKind.TimeSeriesArea, "Cost over 90d", 63),
            W(resolver, sampleFallback, InsightWidgetKind.Funnel, "Conversion", 64),
            W(resolver, sampleFallback, InsightWidgetKind.BarRanking, "Top 10 models", 65),
            W(resolver, sampleFallback, InsightWidgetKind.Narrative, "Highlights", 66),
        });

    private static InsightCanvasTemplate Anomalies(
        Func<InsightWidgetKind, int, InsightWidgetData?>? resolver,
        bool sampleFallback) => new(
        Id: "anomalies",
        Title: "Anomalies",
        Summary: "Outlier days, spikes, and dips.",
        Glyph: "\uE7BA", // warning
        Theme: InsightTheme.Ember,
        Widgets: new List<InsightWidget>
        {
            W(resolver, sampleFallback, InsightWidgetKind.BarRanking, "Anomaly table", 71),
            W(resolver, sampleFallback, InsightWidgetKind.TimeSeriesLine, "Cost with anomalies", 72),
            W(resolver, sampleFallback, InsightWidgetKind.Sankey, "Sessions on outlier days", 73),
            W(resolver, sampleFallback, InsightWidgetKind.Narrative, "Per-anomaly explanation", 74),
        });
}
