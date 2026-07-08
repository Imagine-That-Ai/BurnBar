namespace OpenBurnBar.App.Presentation.Dashboard;

/// <summary>Where a <see cref="DashboardUsageSummary"/>'s numbers were sourced from.</summary>
public enum DashboardUsageOrigin
{
    /// <summary>No configured/available source produced data — honest, fail-closed empty state.</summary>
    Empty,

    /// <summary>Local SQLCipher <c>token_usage</c> aggregates (highest signal, on-device).</summary>
    Local,

    /// <summary>Firestore <c>users/{uid}/usage</c> events pulled through the signed-in gateway.</summary>
    Cloud,

    /// <summary>Explicitly enabled labeled demo data (<c>OPENBURNBAR_SAMPLE_MODE</c>).</summary>
    Sample,
}

/// <summary>
/// Aggregated <c>token_usage</c> headline numbers for the Dashboard classic layout.
/// Resolved by <see cref="DashboardUsageSummarySource"/> preferring signal over samples:
/// LIVE local <see cref="OpenBurnBar.Storage.TokenUsageReadSeam"/> (SQLCipher) →
/// the signed-in cloud usage feed → labeled sample → honest empty. <see cref="Origin"/>
/// records which source won so surfaces can label live vs demo data truthfully.
/// </summary>
public sealed record DashboardUsageSummary(
    double SpendThisMonthUsd,
    long TotalTokens,
    long SessionCount,
    bool HasData,
    DashboardUsageOrigin Origin = DashboardUsageOrigin.Empty);
