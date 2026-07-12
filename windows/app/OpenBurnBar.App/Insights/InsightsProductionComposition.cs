using System;
using OpenBurnBar.App.Configuration;
using OpenBurnBar.App.Presentation.Dashboard;
using OpenBurnBar.App.Presentation.Insights;

namespace OpenBurnBar.App.Insights;

/// <summary>
/// Production Insights composition: reinstall the fail-closed sample gate and
/// <see cref="CloudSyncInsightSource"/> resolver against a given usage summary.
/// Call before materializing or stamping templates so data is not frozen from the
/// first page-construct snapshot for the whole session.
/// </summary>
/// <remarks>
/// This type is also linked into <c>OpenBurnBar.App.Insights.Runtime.Tests</c> (macOS-
/// runnable). Keep dependencies portable — no WinUI types. The page loads usage via
/// <c>DashboardUsageProvider.Load()</c> then calls <see cref="Install"/>.
/// </remarks>
public static class InsightsProductionComposition
{
    /// <summary>
    /// Set <see cref="InsightsBuiltInTemplates"/> gates from <see cref="RuntimeDataMode"/>,
    /// install the production resolver for <paramref name="summary"/>, and return that summary
    /// (also drives the Sample preview chip). Invalidates the template cache via the resolver setter.
    /// </summary>
    public static DashboardUsageSummary Install(DashboardUsageSummary summary)
    {
        ArgumentNullException.ThrowIfNull(summary);
        InsightsBuiltInTemplates.SampleFallbackEnabled = RuntimeDataMode.SampleModeEnabled;
        InsightsBuiltInTemplates.RealDataResolver = (kind, seed) =>
            CloudSyncInsightSource.Resolve(kind, seed, summary);
        return summary;
    }
}
