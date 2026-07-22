using System;
using System.Collections.Generic;
using OpenBurnBar.App.Presentation.Dashboard;
using OpenBurnBar.App.UsageRuntime;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests.Dashboard;

public sealed class UsageRuntimePresentationProjectionTests
{
    [Fact]
    public void Dashboard_projection_applies_selected_window_without_all_time_fallback()
    {
        DateTimeOffset now = LocalNoon();
        UsageRuntimeState state = State(
            Usage("active", "Codex", "active-session", now.AddDays(-2), 1.25, 2_000),
            Usage("old", "Claude", "old-session", now.AddDays(-10), 99, 90_000));

        DashboardCommandSnapshot result = UsageRuntimePresentationProjection.ToDashboardCommandSnapshot(
            state,
            DashboardUsageWindow.Last7Days,
            displayTokens: false,
            now);

        Assert.Equal(1.25, result.TotalCostUsd, precision: 6);
        Assert.Equal(2_000, result.TotalTokens);
        Assert.Equal(1, result.SessionCount);
        Assert.Equal("$1.25", result.OverviewMetricLabel);
        Assert.Equal("Last 7 Days", result.TimeRangeDisplayName);
        Assert.Equal("Codex", Assert.Single(result.Providers).DisplayName);
    }

    [Fact]
    public void Dashboard_projection_switches_visible_metrics_and_ranking_to_tokens()
    {
        DateTimeOffset now = LocalNoon();
        UsageRuntimeState state = State(
            Usage("tokens", "Codex", "session-a", now.AddHours(-2), 0.01, 20_000),
            Usage("cost", "Claude", "session-b", now.AddHours(-1), 20, 100));

        DashboardCommandSnapshot result = UsageRuntimePresentationProjection.ToDashboardCommandSnapshot(
            state,
            DashboardUsageWindow.Today,
            displayTokens: true,
            now);

        Assert.Equal("20.1K", result.OverviewMetricLabel);
        Assert.Equal("Codex", result.Providers[0].DisplayName);
        Assert.Equal("20K", result.Providers[0].MetricLabel);
        Assert.Equal("100", result.Providers[1].MetricLabel);
    }

    [Fact]
    public void Flyout_projection_uses_selected_window_for_sessions_and_providers()
    {
        DateTimeOffset now = LocalNoon();
        UsageRuntimeState state = State(
            Usage("current", "Codex", "session-a", now.AddHours(-2), 1, 1_000),
            Usage("old", "Claude", "session-b", now.AddDays(-45), 3, 3_000));

        var result = UsageRuntimePresentationProjection.ToFlyoutSnapshot(
            state,
            DashboardUsageWindow.AllTime,
            displayTokens: true,
            now);

        Assert.Equal("1K", result.TodayMetricLabel);
        Assert.Equal(2, result.SessionCount);
        Assert.Equal(2, result.Providers.Count);
        Assert.Equal(7, result.Sparkline.Count);
        Assert.Equal(1_000, result.Sparkline[6]);
    }

    [Fact]
    public void Empty_token_projection_preserves_selected_window_and_token_units()
    {
        DashboardCommandSnapshot dashboard = UsageRuntimePresentationProjection.ToDashboardCommandSnapshot(
            UsageRuntimeState.NotStarted,
            DashboardUsageWindow.Last30Days,
            displayTokens: true);
        var flyout = UsageRuntimePresentationProjection.ToFlyoutSnapshot(
            UsageRuntimeState.NotStarted,
            DashboardUsageWindow.Last30Days,
            displayTokens: true);

        Assert.Equal("0", dashboard.OverviewMetricLabel);
        Assert.Equal("Last 30 Days", dashboard.TimeRangeDisplayName);
        Assert.Equal("0", flyout.TodayMetricLabel);
        Assert.Equal("0", flyout.WeekMetricLabel);
        Assert.Equal("0", flyout.MonthMetricLabel);
    }

    private static UsageRuntimeState State(params UsageEngineRecord[] usages) => new(
        UsageRuntimePhase.Ready,
        UsageScanReason.Manual,
        new UsageRuntimeSnapshot(usages, Array.Empty<UsageEngineConversation>(), DateTimeOffset.Now),
        Array.Empty<UsageProviderScanResult>(),
        DateTimeOffset.Now,
        null,
        "Ready");

    private static DateTimeOffset LocalNoon() => new(DateTime.Today.AddHours(12));

    private static UsageEngineRecord Usage(
        string id,
        string provider,
        string sessionId,
        DateTimeOffset end,
        double costUsd,
        long totalTokens) => new()
    {
        Id = id,
        Provider = provider,
        SessionId = sessionId,
        ProjectName = "BurnBar",
        Model = $"{provider}-model",
        TotalTokens = totalTokens,
        CostNanoUsd = checked((long)(costUsd * 1_000_000_000d)),
        StartUnixMilliseconds = end.AddMinutes(-1).ToUnixTimeMilliseconds(),
        EndUnixMilliseconds = end.ToUnixTimeMilliseconds(),
        CreatedUnixMilliseconds = end.ToUnixTimeMilliseconds(),
        UsageSource = "test",
        ProviderId = provider.ToLowerInvariant(),
        ProvenanceMethod = "test",
        ProvenanceConfidence = "exact",
        EstimatorVersion = "test-v1",
    };
}
