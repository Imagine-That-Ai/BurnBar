using System.Collections.Generic;
using System.Threading.Tasks;
using OpenBurnBar.App.Configuration;
using OpenBurnBar.App.CloudSync;

namespace OpenBurnBar.App.Quota;

/// <summary>
/// Resolves quota workspace accounts, preferring signal over samples:
/// (1) LIVE locally-acquired snapshots (the quota acquisition coordinator —
/// statusline hook, Cursor state.vscdb, Codex wham/usage, Anthropic headers);
/// (2) B4 Firestore snapshots when configured; (3) an empty production state or
/// the explicitly enabled sample set (dev host).
/// </summary>
internal static class QuotaAccountsSource
{
    public static async Task<IReadOnlyList<QuotaSampleAccount>> LoadAsync()
    {
        IReadOnlyList<QuotaSampleAccount> live =
            await QuotaLiveAccountMapper.TryLoadLiveAsync().ConfigureAwait(false);
        if (live.Count > 0)
        {
            return live;
        }

        CloudSyncCompositionRoot? root = WinAppCloudSyncHost.Root;
        if (root is null)
        {
            return RuntimeDataMode.SampleModeEnabled
                ? QuotaSampleData.Accounts()
                : new List<QuotaSampleAccount>();
        }

        var store = new CloudSyncQuotaSnapshotStore(root.Gateway, root.FirebaseUid);
        IReadOnlyList<CloudQuotaSnapshotRow> rows = await store.LoadSnapshotsAsync().ConfigureAwait(false);
        if (rows.Count == 0)
        {
            return new List<QuotaSampleAccount>();
        }

        return QuotaCloudAccountMapper.ToAccounts(rows);
    }
}