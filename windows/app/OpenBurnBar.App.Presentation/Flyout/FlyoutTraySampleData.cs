using OpenBurnBar.App.Presentation.Dashboard;

namespace OpenBurnBar.App.Presentation.Flyout;

/// <summary>Sample tray snapshot for <c>OPENBURNBAR_SAMPLE_MODE</c>.</summary>
public static class FlyoutTraySampleData
{
    public static FlyoutTraySnapshot Snapshot()
    {
        var command = DashboardCommandSampleData.Snapshot();
        return new FlyoutTraySnapshot(
            TodayMetricLabel: "$12.40",
            WeekMetricLabel: "$48.20",
            MonthMetricLabel: command.OverviewMetricLabel,
            SessionCount: command.SessionCount,
            FreshnessLabel: "Updated just now",
            Sparkline: new[] { 0.2, 0.35, 0.3, 0.5, 0.62, 0.55, 0.8, 0.72, 0.9, 1.0 },
            Providers: command.Providers,
            Insights: new FlyoutInsightCard[]
            {
                new("Spend pace up", "Today is 18% above your 7-day average.", "info"),
                new("Cursor sessions hot", "8 sessions in the current window.", "neutral"),
            },
            Origin: DashboardUsageOrigin.Sample);
    }
}
