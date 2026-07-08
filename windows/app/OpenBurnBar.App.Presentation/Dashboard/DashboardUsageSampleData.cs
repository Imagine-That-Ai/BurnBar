namespace OpenBurnBar.App.Presentation.Dashboard;

/// <summary>
/// Deterministic, clearly-labeled demo summary surfaced only when
/// <c>OPENBURNBAR_SAMPLE_MODE</c> is enabled. Production routes never fabricate data;
/// the <see cref="DashboardUsageOrigin.Sample"/> marker lets the UI say so out loud.
/// </summary>
public static class DashboardUsageSampleData
{
    public static DashboardUsageSummary Summary() => new(
        SpendThisMonthUsd: 128.74,
        TotalTokens: 4_820_000,
        SessionCount: 37,
        HasData: true,
        Origin: DashboardUsageOrigin.Sample);
}
