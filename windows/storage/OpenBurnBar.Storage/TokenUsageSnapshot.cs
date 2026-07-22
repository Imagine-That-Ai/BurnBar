using System;
using System.Collections.Generic;

namespace OpenBurnBar.Storage;

public sealed record TokenUsageAggregateRow(
    string Id,
    string DisplayName,
    string ProviderId,
    double CostUsd,
    long TotalTokens,
    int SessionCount);

/// <summary>Cost, token, and session totals from one consistently filtered window.</summary>
public sealed record TokenUsageWindowTotals(
    double CostUsd,
    long TotalTokens,
    long SessionCount)
{
    public bool HasData => CostUsd > 0 || TotalTokens > 0 || SessionCount > 0;
}

public sealed record TokenUsageAggregateSnapshot(
    double TodayCostUsd,
    double WeekCostUsd,
    double MonthCostUsd,
    long TotalTokens,
    int SessionCount,
    DateTimeOffset? LastActivityAt,
    IReadOnlyList<double> DailyCostSeries,
    IReadOnlyList<TokenUsageAggregateRow> Providers,
    IReadOnlyList<TokenUsageAggregateRow> Models)
{
    public bool HasData => SessionCount > 0 || TotalTokens > 0 || MonthCostUsd > 0;

    public static TokenUsageAggregateSnapshot Empty { get; } = new(
        0,
        0,
        0,
        0,
        0,
        null,
        Array.Empty<double>(),
        Array.Empty<TokenUsageAggregateRow>(),
        Array.Empty<TokenUsageAggregateRow>());
}
