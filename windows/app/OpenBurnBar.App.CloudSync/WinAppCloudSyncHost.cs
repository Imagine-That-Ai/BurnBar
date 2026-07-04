using OpenBurnBar.App.Configuration;
using OpenBurnBar.App.Presentation.DataControlCenter;
using OpenBurnBar.App.Presentation.Memories;
using OpenBurnBar.CloudSync.Crypto;

namespace OpenBurnBar.App.CloudSync;

/// <summary>
/// Dev-host singleton wiring: composition root, memory store, and callable hub accessors.
/// Desktop OAuth remains deferred — use env tokens via <see cref="CloudSyncCompositionRoot.CreateDevHost"/>.
/// </summary>
public static class WinAppCloudSyncHost
{
    private static readonly object Gate = new();
    private static CloudSyncCompositionRoot? _root;
    private static CloudSyncMemoryStore? _memory;
    private static CloudSyncQuotaSnapshotStore? _quotaSnapshots;
    private static byte[]? _vaultKey;
    private static Func<bool> _isSignedIn = () => false;

    public static CloudSyncCompositionRoot? Root
    {
        get { lock (Gate) return _root; }
    }

    public static bool TryGetMemoryStore(out CloudSyncMemoryStore? store)
    {
        lock (Gate)
        {
            store = _memory;
            return store is not null;
        }
    }

    public static bool TryGetQuotaSnapshotStore(out CloudSyncQuotaSnapshotStore? store)
    {
        lock (Gate)
        {
            store = _quotaSnapshots;
            return store is not null;
        }
    }

    public static void ConfigureForDevHost(
        string firebaseProjectId,
        string firebaseUid,
        byte[] vaultKey,
        Func<bool>? isSignedIn = null,
        string? idToken = null,
        string? appCheckToken = null)
    {
        lock (Gate)
        {
            _vaultKey = vaultKey;
            _isSignedIn = isSignedIn ?? (() => !string.IsNullOrEmpty(firebaseUid));
            _root = CloudSyncCompositionRoot.CreateDevHost(
                firebaseProjectId,
                firebaseUid,
                idToken,
                appCheckToken,
                requireAppCheckOnFirestore: string.IsNullOrEmpty(appCheckToken));
            _memory = new CloudSyncMemoryStore(_root.Gateway, firebaseUid, vaultKey);
            _quotaSnapshots = new CloudSyncQuotaSnapshotStore(_root.Gateway, firebaseUid);
        }
    }

    public static void ConfigureFromAppConfiguration()
    {
        AppConfiguration config = AppConfiguration.Current;
        string? uid = config.EffectiveFirebaseUid();
        if (string.IsNullOrWhiteSpace(uid))
        {
            return;
        }

        string project = config.EffectiveFirebaseProjectId();
        byte[] vaultKey = CloudVaultCrypto.GenerateVaultKey();
        string? keyB64 = config.EffectiveVaultKeyB64();
        if (!string.IsNullOrWhiteSpace(keyB64))
        {
            vaultKey = Convert.FromBase64String(keyB64);
        }

        ConfigureForDevHost(
            project,
            uid,
            vaultKey,
            idToken: config.EffectiveFirebaseIdToken(),
            appCheckToken: config.EffectiveAppCheckToken());
    }

    public static void ConfigureFromEnvironment() => ConfigureFromAppConfiguration();

    public static DataControlCenterViewModel CreateDataControlViewModel()
    {
        CloudSyncCompositionRoot? root = Root;
        if (root is null)
        {
            return new DataControlCenterViewModel();
        }

        var hub = new CloudSyncCallableHub(root.Callable, () =>
        {
            lock (Gate) return _isSignedIn();
        });
        return new DataControlCenterViewModel(hub);
    }

    public static MemoryReviewInboxModel? CreateMemoryInboxModel(MemoryScope? scope = null)
    {
        if (!TryGetMemoryStore(out CloudSyncMemoryStore? store) || store is null)
        {
            return null;
        }

        scope ??= new MemoryScope();
        return new MemoryReviewInboxModel(
            scope,
            req => store.LoadPageAsync(req),
            id => store.OpenBodyAsync(id),
            (id, status) => store.SetStatusAsync(id, status));
    }
}