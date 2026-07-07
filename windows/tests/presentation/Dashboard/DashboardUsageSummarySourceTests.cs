using System;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.Presentation.Dashboard;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests.Dashboard;

/// <summary>
/// Proves the Dashboard usage precedence ladder (the QuotaAccountsSource analog):
/// LIVE local → signed-in cloud → labeled sample → honest empty (fail-closed), plus the
/// invariant that cloud is not consulted when local already has data.
/// </summary>
public sealed class DashboardUsageSummarySourceTests
{
    private static DashboardUsageSummary Empty() => new(0, 0, 0, false);

    private static DashboardUsageSummary WithData(double spend, long tokens, long sessions) =>
        new(spend, tokens, sessions, true);

    private static Task<DashboardUsageSummary?> CloudOf(DashboardUsageSummary? value) =>
        Task.FromResult(value);

    [Fact]
    public async Task Local_data_wins_and_cloud_is_not_consulted()
    {
        var cloudCalled = false;

        DashboardUsageSummary result = await DashboardUsageSummarySource.ResolveAsync(
            loadLocal: () => WithData(10, 100, 3),
            loadCloud: _ =>
            {
                cloudCalled = true;
                return CloudOf(WithData(999, 9, 9));
            },
            sample: DashboardUsageSampleData.Summary,
            sampleModeEnabled: true);

        Assert.Equal(DashboardUsageOrigin.Local, result.Origin);
        Assert.Equal(10, result.SpendThisMonthUsd);
        Assert.Equal(100, result.TotalTokens);
        Assert.False(cloudCalled);
    }

    [Fact]
    public async Task Cloud_used_when_local_empty()
    {
        DashboardUsageSummary result = await DashboardUsageSummarySource.ResolveAsync(
            loadLocal: Empty,
            loadCloud: _ => CloudOf(WithData(42, 5000, 7)),
            sample: DashboardUsageSampleData.Summary,
            sampleModeEnabled: true);

        Assert.Equal(DashboardUsageOrigin.Cloud, result.Origin);
        Assert.Equal(42, result.SpendThisMonthUsd);
        Assert.Equal(7, result.SessionCount);
    }

    [Fact]
    public async Task Sample_used_when_local_and_cloud_empty_and_sample_mode_on()
    {
        DashboardUsageSummary result = await DashboardUsageSummarySource.ResolveAsync(
            loadLocal: Empty,
            loadCloud: _ => CloudOf(null),
            sample: DashboardUsageSampleData.Summary,
            sampleModeEnabled: true);

        Assert.Equal(DashboardUsageOrigin.Sample, result.Origin);
        Assert.True(result.HasData);
    }

    [Fact]
    public async Task Cloud_result_without_data_falls_through_to_sample()
    {
        DashboardUsageSummary result = await DashboardUsageSummarySource.ResolveAsync(
            loadLocal: Empty,
            loadCloud: _ => CloudOf(new DashboardUsageSummary(0, 0, 0, false, DashboardUsageOrigin.Cloud)),
            sample: DashboardUsageSampleData.Summary,
            sampleModeEnabled: true);

        Assert.Equal(DashboardUsageOrigin.Sample, result.Origin);
    }

    [Fact]
    public async Task Empty_when_signed_out_and_sample_mode_off()
    {
        // Signed out = no cloud delegate at all; sample mode off -> honest empty.
        DashboardUsageSummary result = await DashboardUsageSummarySource.ResolveAsync(
            loadLocal: Empty,
            loadCloud: null,
            sample: DashboardUsageSampleData.Summary,
            sampleModeEnabled: false);

        Assert.Equal(DashboardUsageOrigin.Empty, result.Origin);
        Assert.False(result.HasData);
    }

    [Fact]
    public async Task Empty_when_signed_in_but_no_data_and_sample_mode_off()
    {
        DashboardUsageSummary result = await DashboardUsageSummarySource.ResolveAsync(
            loadLocal: Empty,
            loadCloud: _ => CloudOf(null),
            sample: DashboardUsageSampleData.Summary,
            sampleModeEnabled: false);

        Assert.Equal(DashboardUsageOrigin.Empty, result.Origin);
        Assert.False(result.HasData);
    }

    [Fact]
    public async Task Null_local_loader_throws()
    {
        await Assert.ThrowsAsync<ArgumentNullException>(() =>
            DashboardUsageSummarySource.ResolveAsync(loadLocal: null!));
    }

    [Fact]
    public async Task Cancellation_token_is_forwarded_to_cloud_loader()
    {
        using var cts = new CancellationTokenSource();
        CancellationToken observed = default;

        await DashboardUsageSummarySource.ResolveAsync(
            loadLocal: Empty,
            loadCloud: ct =>
            {
                observed = ct;
                return CloudOf(null);
            },
            sample: DashboardUsageSampleData.Summary,
            sampleModeEnabled: false,
            cancellationToken: cts.Token);

        Assert.Equal(cts.Token, observed);
    }
}
