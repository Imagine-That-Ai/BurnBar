using System.Collections.Generic;
using System.Globalization;
using OpenBurnBar.App.CloudSync;
using OpenBurnBar.CloudSync.Firestore;
using OpenBurnBar.CloudSync.Gateway;
using Xunit;

namespace OpenBurnBar.App.CloudSync.Tests;

public sealed class CloudSyncQuotaSnapshotRoundTripTests
{
    private const string Uid = "user_test_quota";

    [Fact]
    public async Task FakeGateway_QuotaSnapshot_DecodesDisplayableRow()
    {
        var gateway = new FakeCloudSyncGateway();
        var store = new CloudSyncQuotaSnapshotStore(gateway, Uid);
        var fetchedAt = DateTimeOffset.Parse("2026-07-04T12:00:00Z", CultureInfo.InvariantCulture);
        var resetAt = DateTimeOffset.Parse("2026-07-04T17:00:00Z", CultureInfo.InvariantCulture);

        var fields = CloudSyncFields.From(new Dictionary<string, CloudSyncValue>
        {
            ["provider"] = CloudSyncValue.Of("codex"),
            ["providerID"] = CloudSyncValue.Of("codex"),
            ["accountID"] = CloudSyncValue.Of("work"),
            ["accountLabel"] = CloudSyncValue.Of("Work"),
            ["fetchedAt"] = CloudSyncValue.Of(fetchedAt),
            ["buckets"] = CloudSyncValue.Of(new List<CloudSyncValue>
            {
                CloudSyncValue.Of(new Dictionary<string, CloudSyncValue>
                {
                    ["name"] = CloudSyncValue.Of("codex-5h"),
                    ["used"] = CloudSyncValue.Of(25.0),
                    ["limit"] = CloudSyncValue.Of(100.0),
                    ["remaining"] = CloudSyncValue.Of(75.0),
                    ["window"] = CloudSyncValue.Of("rollingHours"),
                    ["resetsAt"] = CloudSyncValue.Of(resetAt),
                    ["meta"] = CloudSyncValue.Of(new Dictionary<string, CloudSyncValue>
                    {
                        ["label"] = CloudSyncValue.Of("5-hour window"),
                    }),
                }),
            }),
        });

        gateway.SetDocumentData(fields, $"{store.CollectionPath}/codex_work_codex-local");

        IReadOnlyList<CloudQuotaSnapshotRow> rows = await store.LoadSnapshotsAsync();
        Assert.Single(rows);
        Assert.Equal("codex", rows[0].ProviderToken);
    }
}