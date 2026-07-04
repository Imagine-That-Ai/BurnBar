using System.Collections.Generic;
using System.Threading.Tasks;
using OpenBurnBar.App.CloudSync;

namespace OpenBurnBar.App.Quota;

/// <summary>
/// Resolves quota workspace accounts: Firestore snapshots when B4 is configured,
/// otherwise the explicit dev-host sample set.
/// </summary>
internal static class QuotaAccountsSource
{
    public static async Task<IReadOnlyList<QuotaSampleAccount>> LoadAsync()
    {
        CloudSyncCompositionRoot? root = WinAppCloudSyncHost.Root;
        if (root is null)
        {
            return QuotaSampleData.Accounts();
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