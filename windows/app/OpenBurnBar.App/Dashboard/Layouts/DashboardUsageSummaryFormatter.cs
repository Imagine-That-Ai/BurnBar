using System.Globalization;
using OpenBurnBar.App.Presentation.Dashboard;

namespace OpenBurnBar.App.Dashboard.Layouts;

internal static class DashboardUsageSummaryFormatter
{
    public static string Spend(DashboardUsageSummary summary) => summary.HasData ? $"${summary.TotalCostUsd:0.##}" : "—";

    public static string Tokens(DashboardUsageSummary summary) => summary.HasData ? FormatTokenCount(summary.TotalTokens) : "—";

    public static string Sessions(DashboardUsageSummary summary) => summary.HasData ? summary.SessionCount.ToString(CultureInfo.InvariantCulture) : "—";

    public static string Providers(DashboardUsageSummary summary) => summary.HasData ? "Live" : "—";

    public static string BurnPerDay(DashboardUsageSummary summary)
    {
        if (!summary.HasData || summary.Window == DashboardUsageWindow.AllTime)
        {
            return "—";
        }

        double days = summary.Window switch
        {
            DashboardUsageWindow.Today => 1,
            DashboardUsageWindow.Last7Days => 7,
            DashboardUsageWindow.Last30Days => 30,
            DashboardUsageWindow.ThisMonth => Math.Max(1, DateTimeOffset.Now.Day),
            _ => 1,
        };
        return $"${summary.TotalCostUsd / days:0.##}";
    }

    public static string CacheHit(DashboardUsageSummary summary) => summary.HasData ? "Live" : "—";

    public static string Detail(DashboardUsageSummary summary, string configuredSource) =>
        summary.Origin switch
        {
            DashboardUsageOrigin.Local => "Live SQLCipher usage aggregates.",
            DashboardUsageOrigin.Cloud => "Live cloud usage aggregates (synced from your Mac).",
            DashboardUsageOrigin.Sample => "Sample mode — labeled demo usage, not live.",
            _ => OpenBurnBar.App.Configuration.RuntimeDataMode.EmptyStateDetail(configuredSource),
        };

    private static string FormatTokenCount(long tokens)
    {
        if (tokens >= 1_000_000)
        {
            return $"{tokens / 1_000_000.0:0.#}M";
        }

        if (tokens >= 1_000)
        {
            return $"{tokens / 1_000.0:0.#}K";
        }

        return tokens.ToString(CultureInfo.InvariantCulture);
    }
}
