using System.Collections.Generic;
using System.Globalization;
using OpenBurnBar.App.CloudSync;
using OpenBurnBar.App.Presentation.Dashboard;
using OpenBurnBar.CloudSync.Callable;
using OpenBurnBar.CloudSync.Firestore;
using OpenBurnBar.CloudSync.Gateway;
using OpenBurnBar.CloudSync.Offline;
using Xunit;

namespace OpenBurnBar.App.CloudSync.Tests;

/// <summary>
/// The bucket-A payoff of the OAuth keystone (#1304): once a signed-in credential exists,
/// the composition root's gateway drives REAL per-user data across the Authored surfaces.
/// This exercises the same triple every seam-ready surface reads — <c>root.Gateway</c> +
/// <c>root.FirebaseUid</c> + <c>root.Credentials</c> — against a fake Firestore backend,
/// proving Dashboard usage and Quota flow real data when signed in and fail closed when not.
/// (MissionControl's FirestoreMissionDispatchHost and the DCC CloudSyncCallableHub have their
/// own round-trip suites; this is the cross-surface credential-gate proof.)
/// </summary>
public sealed class SignedInSurfaceDataFlowTests
{
    private const string Uid = "user_signed_in";
    private const string ProjectId = "proj-test";

    private static readonly DateTimeOffset FixedNow = DateTimeOffset.Parse(
        "2026-07-15T12:00:00Z", CultureInfo.InvariantCulture);

    // A transport that must never be hit — the cross-surface reads go through the gateway,
    // not the callable client, so this proves we never fall back to a live network call.
    private sealed class UnusedTransport : ICloudSyncHttpTransport
    {
        public Task<CloudSyncHttpResponse> SendAsync(CloudSyncHttpRequest request, CancellationToken cancellationToken = default)
            => throw new NotSupportedException("Callable transport must not be exercised by surface reads.");
    }

    private static CloudSyncCompositionRoot SignedInRoot(FakeCloudSyncGateway gateway)
    {
        var credentials = new OpenBurnBar.CloudSync.Gateway.StaticCredentialsProvider(
            new CloudSyncCredentials("id-token-signed-in"));
        var callable = new CallableClient(new UnusedTransport(), credentials, new CallableEndpoint("us-central1", ProjectId));
        var queue = new OfflineWriteQueue(gateway, startOnline: false);
        return new CloudSyncCompositionRoot(gateway, callable, queue, credentials, ProjectId, Uid);
    }

    private static void SeedUsage(FakeCloudSyncGateway gateway)
    {
        var july = DateTimeOffset.Parse("2026-07-05T09:00:00Z", CultureInfo.InvariantCulture);
        var fields = CloudSyncFields.From(new Dictionary<string, CloudSyncValue>
        {
            ["totalTokens"] = CloudSyncValue.Of(9000),
            ["costUSD"] = CloudSyncValue.Of(12.5),
            ["sessionId"] = CloudSyncValue.Of("sess-1"),
            ["recordedAt"] = CloudSyncValue.Of(july),
        });
        gateway.SetDocumentData(fields, $"users/{Uid}/usage/dev_1");
    }

    private static void SeedQuota(FakeCloudSyncGateway gateway)
    {
        var fetchedAt = DateTimeOffset.Parse("2026-07-14T12:00:00Z", CultureInfo.InvariantCulture);
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
                }),
            }),
        });
        gateway.SetDocumentData(fields, $"users/{Uid}/quota_snapshots/codex_work_codex-local");
    }

    [Fact]
    public async Task Signed_in_root_exposes_the_credential_and_uid_surfaces_read()
    {
        var gateway = new FakeCloudSyncGateway();
        CloudSyncCompositionRoot root = SignedInRoot(gateway);

        Assert.Equal(Uid, root.FirebaseUid);
        CloudSyncCredentials creds = await root.Credentials.GetCredentialsAsync();
        Assert.Equal("id-token-signed-in", creds.IdToken);
    }

    [Fact]
    public async Task Signed_in_dashboard_usage_flows_real_cloud_data_through_the_root_gateway()
    {
        var gateway = new FakeCloudSyncGateway();
        SeedUsage(gateway);
        CloudSyncCompositionRoot root = SignedInRoot(gateway);

        var store = new CloudSyncUsageSummaryStore(root.Gateway, root.FirebaseUid, clock: () => FixedNow);

        // Compose exactly as DashboardUsageProvider does: local empty (fresh Windows box),
        // signed-in cloud usage available -> Cloud wins.
        DashboardUsageSummary summary = await DashboardUsageSummarySource.ResolveAsync(
            loadLocal: () => new DashboardUsageSummary(0, 0, 0, false),
            loadCloud: store.LoadSummaryAsync,
            sample: DashboardUsageSampleData.Summary,
            sampleModeEnabled: false);

        Assert.Equal(DashboardUsageOrigin.Cloud, summary.Origin);
        Assert.True(summary.HasData);
        Assert.Equal(12.5, summary.SpendThisMonthUsd, 3);
        Assert.Equal(9000, summary.TotalTokens);
        Assert.Equal(1, summary.SessionCount);
    }

    [Fact]
    public async Task Signed_in_quota_flows_real_cloud_snapshots_through_the_root_gateway()
    {
        var gateway = new FakeCloudSyncGateway();
        SeedQuota(gateway);
        CloudSyncCompositionRoot root = SignedInRoot(gateway);

        var store = new CloudSyncQuotaSnapshotStore(root.Gateway, root.FirebaseUid);
        IReadOnlyList<CloudQuotaSnapshotRow> rows = await store.LoadSnapshotsAsync();

        Assert.Single(rows);
        Assert.Equal("codex", rows[0].ProviderToken);
    }

    [Fact]
    public async Task Signed_out_dashboard_usage_fails_closed_to_empty()
    {
        // Signed out = no cloud delegate (the App provider passes null when Root is null),
        // local empty, sample mode off -> honest empty state, never fabricated data.
        DashboardUsageSummary summary = await DashboardUsageSummarySource.ResolveAsync(
            loadLocal: () => new DashboardUsageSummary(0, 0, 0, false),
            loadCloud: null,
            sample: DashboardUsageSampleData.Summary,
            sampleModeEnabled: false);

        Assert.Equal(DashboardUsageOrigin.Empty, summary.Origin);
        Assert.False(summary.HasData);
    }

    [Fact]
    public async Task Signed_in_but_no_cloud_docs_yields_no_cloud_data_then_empty()
    {
        var gateway = new FakeCloudSyncGateway(); // signed in, but empty backend
        CloudSyncCompositionRoot root = SignedInRoot(gateway);
        var store = new CloudSyncUsageSummaryStore(root.Gateway, root.FirebaseUid, clock: () => FixedNow);

        DashboardUsageSummary summary = await DashboardUsageSummarySource.ResolveAsync(
            loadLocal: () => new DashboardUsageSummary(0, 0, 0, false),
            loadCloud: store.LoadSummaryAsync,
            sample: DashboardUsageSampleData.Summary,
            sampleModeEnabled: false);

        Assert.Equal(DashboardUsageOrigin.Empty, summary.Origin);
        Assert.False(summary.HasData);
    }
}
