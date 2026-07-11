using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using OpenBurnBar.App.CloudSync;
using OpenBurnBar.App.Presentation.Quota;
using OpenBurnBar.App.Quota.Acquisition;
using OpenBurnBar.App.Quota.Acquisition.Windows;

namespace OpenBurnBar.App.Quota;

/// <summary>
/// Maps LIVE locally-acquired <see cref="ProviderQuotaSnapshot"/>s (the quota
/// acquisition coordinator: statusline hook, Cursor state.vscdb, Codex
/// wham/usage, Anthropic headers) into the workspace accounts. Reuses the
/// B4 row shape so <see cref="QuotaCloudAccountMapper"/> stays the single
/// bucket-ordering/pressure oracle for both the cloud and local paths.
/// </summary>
internal static class QuotaLiveAccountMapper
{
    /// <summary>Refresh the coordinator and map; empty when unconfigured or dry.</summary>
    public static async Task<IReadOnlyList<QuotaSampleAccount>> TryLoadLiveAsync()
    {
        IReadOnlyList<ProviderQuotaSnapshot> snapshots =
            await WindowsQuotaAcquisitionHost.TryRefreshAsync().ConfigureAwait(false);
        if (snapshots.Count == 0)
        {
            return new List<QuotaSampleAccount>();
        }

        var rows = new List<CloudQuotaSnapshotRow>(snapshots.Count);
        foreach (ProviderQuotaSnapshot snapshot in snapshots)
        {
            if (snapshot.HasBuckets)
            {
                rows.Add(ToRow(snapshot));
            }
        }

        return QuotaCloudAccountMapper.ToAccounts(rows);
    }

    private static CloudQuotaSnapshotRow ToRow(ProviderQuotaSnapshot snapshot)
    {
        var buckets = new List<CloudQuotaBucketRow>(snapshot.Buckets.Count);
        foreach (ProviderQuotaBucket bucket in snapshot.Buckets)
        {
            buckets.Add(new CloudQuotaBucketRow(
                Name: bucket.Key,
                Used: bucket.UsedValue ?? bucket.UsedPercent,
                Limit: bucket.LimitValue,
                Remaining: bucket.RemainingValue,
                Window: bucket.WindowKind.ToString(),
                ResetsAt: bucket.ResetsAt,
                Label: bucket.Label));
        }

        return new CloudQuotaSnapshotRow(
            DocumentId: $"live:{snapshot.Provider}",
            ProviderToken: snapshot.Provider,
            ProviderId: snapshot.Provider,
            AccountId: "local",
            AccountLabel: AccountLabel(snapshot.Source),
            FetchedAt: snapshot.FetchedAt,
            Buckets: buckets);
    }

    private static string AccountLabel(ProviderQuotaSourceKind source) => source switch
    {
        ProviderQuotaSourceKind.LocalCli => "Local CLI",
        ProviderQuotaSourceKind.LocalSession => "Local session",
        _ => "This device",
    };
}
