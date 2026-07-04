namespace OpenBurnBar.App.Presentation.Dashboard;

/// <summary>
/// Aggregated <c>token_usage</c> headline numbers for the Dashboard classic layout.
/// Sourced from <see cref="OpenBurnBar.Storage.TokenUsageReadSeam"/> when SQLCipher is configured.
/// </summary>
public sealed record DashboardUsageSummary(
    double SpendThisMonthUsd,
    long TotalTokens,
    long SessionCount,
    bool HasData);