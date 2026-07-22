using System.Collections.Generic;
using System.Globalization;
using OpenBurnBar.App.CloudSync;
using OpenBurnBar.App.Presentation.Dashboard;
using OpenBurnBar.CloudSync.Firestore;
using OpenBurnBar.CloudSync.Gateway;
using Xunit;

namespace OpenBurnBar.App.CloudSync.Tests;

/// <summary>
/// Proves the Dashboard's live cloud usage source aggregates real Mac-uploaded
/// <c>users/{uid}/usage</c> events (UsageSyncService.swift) into the headline summary
/// through the fake Firestore gateway with one consistent selected window for
/// spend, tokens, and sessions, mirroring TokenUsageReadSeam.
/// </summary>
public sealed class CloudSyncUsageSummaryStoreTests
{
    private const string Uid = "user_test_usage";

    // Deterministic "now" so calendar and rolling windows are stable.
    private static readonly DateTimeOffset FixedNow = DateTimeOffset.Parse(
        "2026-07-15T12:00:00Z", CultureInfo.InvariantCulture);

    private static CloudSyncFields UsageDoc(
        long totalTokens,
        double? costUSD,
        string? sessionId,
        DateTimeOffset recordedAt)
    {
        var fields = new Dictionary<string, CloudSyncValue>
        {
            ["totalTokens"] = CloudSyncValue.Of(totalTokens),
            ["recordedAt"] = CloudSyncValue.Of(recordedAt),
        };
        if (costUSD is { } cost)
        {
            fields["costUSD"] = CloudSyncValue.Of(cost);
        }
        if (sessionId is not null)
        {
            fields["sessionId"] = CloudSyncValue.Of(sessionId);
        }
        return CloudSyncFields.From(fields);
    }

    private static CloudSyncUsageSummaryStore Store(FakeCloudSyncGateway gateway) =>
        new(gateway, Uid, clock: () => FixedNow);

    [Fact]
    public async Task ThisMonth_FiltersSpendTokensAndSessionsConsistently()
    {
        var gateway = new FakeCloudSyncGateway();
        var store = Store(gateway);
        var july = DateTimeOffset.Parse("2026-07-04T09:00:00Z", CultureInfo.InvariantCulture);
        var alsoJuly = DateTimeOffset.Parse("2026-07-10T22:00:00Z", CultureInfo.InvariantCulture);
        var june = DateTimeOffset.Parse("2026-06-28T09:00:00Z", CultureInfo.InvariantCulture);

        // Two July rows (this month) + one June row (excluded from every metric).
        gateway.SetDocumentData(UsageDoc(1200, 3.50, "sess-a", july), $"{store.CollectionPath}/dev_1");
        gateway.SetDocumentData(UsageDoc(800, 1.25, "sess-a", alsoJuly), $"{store.CollectionPath}/dev_2");
        gateway.SetDocumentData(UsageDoc(500, 9.99, "sess-b", june), $"{store.CollectionPath}/dev_3");

        DashboardUsageSummary? summary = await store.LoadSummaryAsync();

        Assert.NotNull(summary);
        Assert.True(summary!.HasData);
        Assert.Equal(DashboardUsageOrigin.Cloud, summary.Origin);
        Assert.Equal(4.75, summary.TotalCostUsd, 3);      // 3.50 + 1.25 (June's 9.99 excluded)
        Assert.Equal(2000, summary.TotalTokens);           // July rows only
        Assert.Equal(1, summary.SessionCount);             // sess-a only
        Assert.Equal(DashboardUsageWindow.ThisMonth, summary.Window);
    }

    [Fact]
    public async Task AllTime_IncludesRowsOutsideTheCurrentMonth()
    {
        var gateway = new FakeCloudSyncGateway();
        var store = Store(gateway);
        var july = DateTimeOffset.Parse("2026-07-04T09:00:00Z", CultureInfo.InvariantCulture);
        var june = DateTimeOffset.Parse("2026-06-28T09:00:00Z", CultureInfo.InvariantCulture);

        gateway.SetDocumentData(UsageDoc(1200, 3.50, "sess-a", july), $"{store.CollectionPath}/dev_1");
        gateway.SetDocumentData(UsageDoc(500, 9.99, "sess-b", june), $"{store.CollectionPath}/dev_2");

        DashboardUsageSummary? summary = await store.LoadSummaryAsync(DashboardUsageWindow.AllTime);

        Assert.NotNull(summary);
        Assert.Equal(13.49, summary!.TotalCostUsd, 3);
        Assert.Equal(1700, summary.TotalTokens);
        Assert.Equal(2, summary.SessionCount);
        Assert.Equal(DashboardUsageWindow.AllTime, summary.Window);
    }

    [Fact]
    public async Task Empty_collection_returns_null_so_caller_treats_as_no_cloud_data()
    {
        var gateway = new FakeCloudSyncGateway();
        var store = Store(gateway);

        DashboardUsageSummary? summary = await store.LoadSummaryAsync();

        Assert.Null(summary);
    }

    [Fact]
    public async Task Rows_without_cost_still_count_tokens_and_sessions()
    {
        var gateway = new FakeCloudSyncGateway();
        var store = Store(gateway);
        var july = DateTimeOffset.Parse("2026-07-04T09:00:00Z", CultureInfo.InvariantCulture);

        gateway.SetDocumentData(UsageDoc(640, costUSD: null, "sess-x", july), $"{store.CollectionPath}/dev_1");

        DashboardUsageSummary? summary = await store.LoadSummaryAsync();

        Assert.NotNull(summary);
        Assert.True(summary!.HasData);
        Assert.Equal(0, summary.TotalCostUsd);
        Assert.Equal(640, summary.TotalTokens);
        Assert.Equal(1, summary.SessionCount);
    }

    [Fact]
    public async Task Integer_and_string_encoded_numbers_are_decoded()
    {
        var gateway = new FakeCloudSyncGateway();
        var store = Store(gateway);
        var july = DateTimeOffset.Parse("2026-07-08T09:00:00Z", CultureInfo.InvariantCulture);

        // costUSD written as a string (defensive: some encoders stringify decimals).
        var fields = CloudSyncFields.From(new Dictionary<string, CloudSyncValue>
        {
            ["totalTokens"] = CloudSyncValue.Of(300),
            ["costUSD"] = CloudSyncValue.Of("2.5"),
            ["sessionId"] = CloudSyncValue.Of("sess-str"),
            ["recordedAt"] = CloudSyncValue.Of(july.ToString("O", CultureInfo.InvariantCulture)),
        });
        gateway.SetDocumentData(fields, $"{store.CollectionPath}/dev_str");

        DashboardUsageSummary? summary = await store.LoadSummaryAsync();

        Assert.NotNull(summary);
        Assert.Equal(2.5, summary!.TotalCostUsd, 3);
        Assert.Equal(300, summary.TotalTokens);
        Assert.Equal(1, summary.SessionCount);
    }
}
