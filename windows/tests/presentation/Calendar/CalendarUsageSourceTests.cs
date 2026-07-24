using System;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.Presentation.Calendar;
using OpenBurnBar.App.Presentation.Dashboard;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests.Calendar;

/// <summary>
/// Proves the Calendar usage precedence ladder (the
/// <see cref="DashboardUsageSummarySource"/> analog): LIVE local → signed-in
/// cloud → labeled sample → honest empty (fail-closed), plus the invariant that
/// cloud is not consulted when local already has data.
/// </summary>
public sealed class CalendarUsageSourceTests
{
    private static CalendarUsageData Empty() => CalendarUsageData.Empty;

    private static CalendarUsageData WithRows(int count)
    {
        var rows = new CalendarUsageRow[count];
        for (int i = 0; i < count; i++)
        {
            rows[i] = new CalendarUsageRow(
                $"u-{i}",
                "Codex",
                "sess-1",
                "proj",
                "model",
                10,
                5,
                0,
                0,
                0,
                15,
                0.5,
                new DateTimeOffset(2026, 7, 6, 10, 0, 0, TimeSpan.Zero));
        }

        return new CalendarUsageData(rows, DashboardUsageOrigin.Empty);
    }

    private static Task<CalendarUsageData?> CloudOf(CalendarUsageData? value) =>
        Task.FromResult(value);

    [Fact]
    public async Task Local_data_wins_and_cloud_is_not_consulted()
    {
        var cloudCalled = false;

        CalendarUsageData result = await CalendarUsageSource.ResolveAsync(
            loadLocal: () => WithRows(2),
            loadCloud: _ =>
            {
                cloudCalled = true;
                return CloudOf(WithRows(9));
            },
            sample: () => WithRows(3),
            sampleModeEnabled: true);

        Assert.Equal(DashboardUsageOrigin.Local, result.Origin);
        Assert.Equal(2, result.Rows.Count);
        Assert.False(cloudCalled);
    }

    [Fact]
    public async Task Cloud_used_when_local_empty()
    {
        CalendarUsageData result = await CalendarUsageSource.ResolveAsync(
            loadLocal: Empty,
            loadCloud: _ => CloudOf(WithRows(4)),
            sample: () => WithRows(3),
            sampleModeEnabled: true);

        Assert.Equal(DashboardUsageOrigin.Cloud, result.Origin);
        Assert.Equal(4, result.Rows.Count);
    }

    [Fact]
    public async Task Sample_used_when_local_and_cloud_empty_and_sample_mode_on()
    {
        CalendarUsageData result = await CalendarUsageSource.ResolveAsync(
            loadLocal: Empty,
            loadCloud: _ => CloudOf(null),
            sample: () => WithRows(3),
            sampleModeEnabled: true);

        Assert.Equal(DashboardUsageOrigin.Sample, result.Origin);
        Assert.Equal(3, result.Rows.Count);
    }

    [Fact]
    public async Task Cloud_result_without_rows_falls_through_to_sample()
    {
        CalendarUsageData result = await CalendarUsageSource.ResolveAsync(
            loadLocal: Empty,
            loadCloud: _ => CloudOf(new CalendarUsageData(
                Array.Empty<CalendarUsageRow>(),
                DashboardUsageOrigin.Cloud)),
            sample: () => WithRows(3),
            sampleModeEnabled: true);

        Assert.Equal(DashboardUsageOrigin.Sample, result.Origin);
    }

    [Fact]
    public async Task Empty_when_signed_out_and_sample_mode_off()
    {
        // Signed out = no cloud delegate at all; sample mode off → honest empty.
        CalendarUsageData result = await CalendarUsageSource.ResolveAsync(
            loadLocal: Empty,
            loadCloud: null,
            sample: () => WithRows(3),
            sampleModeEnabled: false);

        Assert.Equal(DashboardUsageOrigin.Empty, result.Origin);
        Assert.False(result.HasData);
        Assert.Empty(result.Rows);
    }

    [Fact]
    public async Task Empty_when_signed_in_but_no_data_and_sample_mode_off()
    {
        CalendarUsageData result = await CalendarUsageSource.ResolveAsync(
            loadLocal: Empty,
            loadCloud: _ => CloudOf(null),
            sample: () => WithRows(3),
            sampleModeEnabled: false);

        Assert.Equal(DashboardUsageOrigin.Empty, result.Origin);
        Assert.False(result.HasData);
    }

    [Fact]
    public async Task Null_local_loader_throws()
    {
        await Assert.ThrowsAsync<ArgumentNullException>(() =>
            CalendarUsageSource.ResolveAsync(loadLocal: null!));
    }

    [Fact]
    public async Task Cancellation_token_is_forwarded_to_cloud_loader()
    {
        using var cts = new CancellationTokenSource();
        CancellationToken observed = default;

        await CalendarUsageSource.ResolveAsync(
            loadLocal: Empty,
            loadCloud: ct =>
            {
                observed = ct;
                return CloudOf(null);
            },
            sample: () => WithRows(1),
            sampleModeEnabled: false,
            cancellationToken: cts.Token);

        Assert.Equal(cts.Token, observed);
    }
}
