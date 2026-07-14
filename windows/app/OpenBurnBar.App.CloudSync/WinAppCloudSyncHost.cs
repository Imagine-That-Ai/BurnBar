using OpenBurnBar.App.Presentation.DataControlCenter;
using OpenBurnBar.App.Presentation.Memories;
using OpenBurnBar.CloudSync.AppCheck.Mint;
using OpenBurnBar.CloudSync.AppCheck.Attestation;

namespace OpenBurnBar.App.CloudSync;

/// <summary>
/// Process-wide composition root, memory store, and callable hub accessors.
/// Shipping WinUI code enters through the mandatory OAuth + TPM App Check path;
/// <see cref="ConfigureForDevHost"/> is retained for deterministic host tooling.
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
            DomainCoreShadowEvidenceUploader.Configure(_root);
        }
    }

    /// <summary>
    /// Live root wiring backed by a signed-in desktop OAuth provider (real Firebase
    /// id token). Flips <see cref="Root"/> to the OAuth-authenticated gateway so the
    /// seam-ready surfaces read live Firestore data. TPM App Check is mandatory.
    /// </summary>
    public static void ConfigureWithOAuth(
        DesktopOAuthCredentialsProvider oauth,
        string firebaseProjectId,
        string firebaseUid,
        byte[] vaultKey,
        IAttestationProducer attestationProducer,
        IAppCheckMintTransport appCheckMintTransport,
        string appCheckAppId)
    {
        if (oauth is null) throw new ArgumentNullException(nameof(oauth));
        lock (Gate)
        {
            _vaultKey = vaultKey;
            _isSignedIn = () => oauth.IsSignedIn;
            _root = CloudSyncCompositionRoot.CreateWithOAuth(
                oauth,
                firebaseProjectId,
                firebaseUid,
                attestationProducer,
                appCheckMintTransport,
                appCheckAppId);
            _memory = new CloudSyncMemoryStore(_root.Gateway, firebaseUid, vaultKey);
            _quotaSnapshots = new CloudSyncQuotaSnapshotStore(_root.Gateway, firebaseUid);
            DomainCoreShadowEvidenceUploader.Configure(_root);
        }
    }

    /// <summary>
    /// Ensure the provider is signed in (runs the browser loopback flow if needed),
    /// derive the Firebase uid from the resulting session, and wire the live root.
    /// Returns the signed-in uid.
    /// </summary>
    public static async Task<string> ConfigureWithOAuthAsync(
        DesktopOAuthCredentialsProvider oauth,
        string firebaseProjectId,
        byte[] vaultKey,
        IAttestationProducer attestationProducer,
        IAppCheckMintTransport appCheckMintTransport,
        string appCheckAppId,
        CancellationToken cancellationToken = default)
    {
        if (oauth is null) throw new ArgumentNullException(nameof(oauth));
        FirebaseOAuthSession session = oauth.CurrentSession
            ?? await oauth.SignInAsync(cancellationToken).ConfigureAwait(false);
        ConfigureWithOAuth(
            oauth,
            firebaseProjectId,
            session.Uid,
            vaultKey,
            attestationProducer,
            appCheckMintTransport,
            appCheckAppId);
        return session.Uid;
    }

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
