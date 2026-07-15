using OpenBurnBar.App.Configuration;
using OpenBurnBar.App.Presentation.DataControlCenter;
using OpenBurnBar.App.Presentation.Memories;
using OpenBurnBar.CloudSync.AppCheck.Attestation;
using OpenBurnBar.CloudSync.AppCheck.Mint;
using OpenBurnBar.CloudSync.Crypto;

namespace OpenBurnBar.App.CloudSync;

/// <summary>
/// Desktop composition singleton: live OAuth roots are restored from the
/// protected session store when available; static tokens remain an explicit
/// dev-host fallback.
/// </summary>
public static class WinAppCloudSyncHost
{
    private static readonly object Gate = new();
    private static CloudSyncCompositionRoot? _root;
    private static CloudSyncMemoryStore? _memory;
    private static CloudSyncQuotaSnapshotStore? _quotaSnapshots;
    private static byte[]? _vaultKey;
    private static Func<bool> _isSignedIn = () => false;
    private static Func<IAttestationProducer>? _appCheckAttestationProducerFactory;
    private static Func<IAppCheckMintTransport>? _appCheckMintTransportFactory;

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

    /// <summary>
    /// Register the platform App Check composition used by the real desktop
    /// OAuth path. The WinUI app supplies the TPM producer and HTTP transport only
    /// when staging App Check is explicitly configured; portable tests leave this
    /// hook unset and retain the deterministic mock path.
    /// </summary>
    public static void ConfigurePlatformAppCheck(
        Func<IAttestationProducer> attestationProducerFactory,
        Func<IAppCheckMintTransport> mintTransportFactory)
    {
        if (attestationProducerFactory is null) throw new ArgumentNullException(nameof(attestationProducerFactory));
        if (mintTransportFactory is null) throw new ArgumentNullException(nameof(mintTransportFactory));
        lock (Gate)
        {
            _appCheckAttestationProducerFactory = attestationProducerFactory;
            _appCheckMintTransportFactory = mintTransportFactory;
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
    /// seam-ready surfaces read live Firestore data. App Check stays optional via
    /// <paramref name="appCheckMintTransport"/>.
    /// </summary>
    public static void ConfigureWithOAuth(
        DesktopOAuthCredentialsProvider oauth,
        string firebaseProjectId,
        string firebaseUid,
        byte[] vaultKey,
        IAppCheckMintTransport? appCheckMintTransport = null,
        IAttestationProducer? appCheckAttestationProducer = null)
    {
        if (oauth is null) throw new ArgumentNullException(nameof(oauth));
        if (appCheckMintTransport is null && appCheckAttestationProducer is null)
        {
            (appCheckMintTransport, appCheckAttestationProducer) = TryCreatePlatformAppCheck();
        }
        lock (Gate)
        {
            _vaultKey = vaultKey;
            _isSignedIn = () => oauth.IsSignedIn;
            _root = CloudSyncCompositionRoot.CreateWithOAuth(
                oauth,
                firebaseProjectId,
                firebaseUid,
                appCheckMintTransport,
                appCheckAttestationProducer: appCheckAttestationProducer);
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
        IAppCheckMintTransport? appCheckMintTransport = null,
        IAttestationProducer? appCheckAttestationProducer = null,
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
            appCheckMintTransport,
            appCheckAttestationProducer);
        return session.Uid;
    }

    public static void ConfigureFromAppConfiguration()
    {
        AppConfiguration config = AppConfiguration.Current;
        string project = config.EffectiveFirebaseProjectId();
        byte[] vaultKey = CloudVaultCrypto.GenerateVaultKey();
        string? keyB64 = config.EffectiveVaultKeyB64();
        if (!string.IsNullOrWhiteSpace(keyB64))
        {
            vaultKey = Convert.FromBase64String(keyB64);
        }

        // Restore a previously completed browser sign-in without opening a
        // browser on launch. The credentials provider loads its protected
        // Firebase session and passive accessors remain non-interactive.
        DesktopOAuthCredentialsProvider? oauth = CloudAuthProductionComposition.TryCreateOAuthCredentialsProvider();
        FirebaseOAuthSession? session = SelectRestorableSession(
            oauth?.CurrentSession,
            DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
        if (oauth is not null && session is not null)
        {
            ConfigureWithOAuth(oauth, project, session.Uid, vaultKey);
            return;
        }

        string? uid = config.EffectiveFirebaseUid();
        if (string.IsNullOrWhiteSpace(uid))
        {
            return;
        }

        ConfigureForDevHost(
            project,
            uid,
            vaultKey,
            idToken: config.EffectiveFirebaseIdToken(),
            appCheckToken: config.EffectiveAppCheckToken());
    }

    internal static FirebaseOAuthSession? SelectRestorableSession(
        FirebaseOAuthSession? session,
        long nowMillis) =>
        session is not null
        && !string.IsNullOrWhiteSpace(session.Uid)
        && !session.IsExpired(nowMillis)
            ? session
            : null;

    public static void ConfigureFromEnvironment() => ConfigureFromAppConfiguration();

    private static (IAppCheckMintTransport? Transport, IAttestationProducer? Producer)
        TryCreatePlatformAppCheck()
    {
        Func<IAttestationProducer>? producerFactory;
        Func<IAppCheckMintTransport>? transportFactory;
        lock (Gate)
        {
            producerFactory = _appCheckAttestationProducerFactory;
            transportFactory = _appCheckMintTransportFactory;
        }

        // A half-configured platform hook must not silently select a mock or
        // attach an unpaired transport. The OAuth path remains id-token-only.
        if (producerFactory is null || transportFactory is null)
        {
            return (null, null);
        }

        return (transportFactory(), producerFactory());
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
