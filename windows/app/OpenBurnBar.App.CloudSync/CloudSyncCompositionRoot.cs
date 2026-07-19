using OpenBurnBar.CloudSync.AppCheck.Attestation;
using OpenBurnBar.CloudSync.AppCheck.Mint;
using OpenBurnBar.CloudSync.AppCheck.Provider;
using OpenBurnBar.CloudSync.AppCheck.Token;
using OpenBurnBar.CloudSync.Callable;
using OpenBurnBar.CloudSync.Firestore;
using OpenBurnBar.CloudSync.Gateway;
using OpenBurnBar.CloudSync.Offline;
using OpenBurnBar.CloudSync.Sync;

namespace OpenBurnBar.App.CloudSync;

/// <summary>
/// App-level wiring for Firestore REST, callables, offline queue, and App Check.
/// Dev-host callers retain the deterministic mock producer for tests; the
/// shipping WinUI desktop supplies the Windows TPM producer and a live transport.
/// </summary>
public sealed class CloudSyncCompositionRoot
{
    public ICloudSyncGateway Gateway { get; }
    public CallableClient Callable { get; }
    public OfflineWriteQueue OfflineQueue { get; }
    public WindowsAppCheckProvider? AppCheck { get; }
    public ICloudSyncCredentialsProvider Credentials { get; }
    public string FirebaseProjectId { get; }
    public string FirebaseUid { get; }

    public CloudSyncCompositionRoot(
        ICloudSyncGateway gateway,
        CallableClient callable,
        OfflineWriteQueue offlineQueue,
        ICloudSyncCredentialsProvider credentials,
        string firebaseProjectId,
        string firebaseUid,
        WindowsAppCheckProvider? appCheck = null)
    {
        Gateway = gateway;
        Callable = callable;
        OfflineQueue = offlineQueue;
        Credentials = credentials;
        FirebaseProjectId = firebaseProjectId;
        FirebaseUid = firebaseUid;
        AppCheck = appCheck;
    }

    /// <summary>
    /// Dev-host root: static env tokens, mock attestation producer (inert TPM path), fail-closed App Check when mint is unavailable.
    /// </summary>
    public static CloudSyncCompositionRoot CreateDevHost(
        string firebaseProjectId,
        string firebaseUid,
        string? idToken = null,
        string? appCheckToken = null,
        bool requireAppCheckOnFirestore = true)
    {
        idToken ??= Environment.GetEnvironmentVariable("OPENBURNBAR_FIREBASE_ID_TOKEN");
        appCheckToken ??= Environment.GetEnvironmentVariable("OPENBURNBAR_APP_CHECK_TOKEN");

        if (string.IsNullOrWhiteSpace(idToken))
        {
            idToken = "dev-host-unsigned";
        }

        var innerCreds = new StaticCredentialsProvider(new CloudSyncCredentials(idToken, appCheckToken));

        WindowsAppCheckProvider? appCheckProvider = null;
        if (string.IsNullOrEmpty(appCheckToken))
        {
            var clock = SystemClock.Instance;
            var endpoint = AppCheckMintEndpoint.ForProject(firebaseProjectId);
            var mintClient = new AppCheckMintClient(
                endpoint,
                new NoOpAppCheckMintTransport());
            var options = new AppCheckProviderOptions { AppId = "1:openburnbar:web:dev-host" };
            appCheckProvider = new WindowsAppCheckProvider(
                new MockAttestationProducer(new FixedHexNonceSource("0123456789abcdef0123456789abcdef")),
                mintClient,
                new StubFirebaseIdTokenSource(idToken),
                options,
                clock);
        }

        var credentials = new AppCheckCredentialsProvider(innerCreds, appCheckProvider);

        var http = new HttpClientCloudSyncTransport(new HttpClient());
        var database = new FirestoreDatabase(firebaseProjectId);
        var gateway = new FirestoreRestGateway(http, credentials, database, requireAppCheck: requireAppCheckOnFirestore);
        var callable = new CallableClient(http, credentials, new CallableEndpoint("us-central1", firebaseProjectId));
        var queue = new OfflineWriteQueue(gateway, startOnline: true);

        return new CloudSyncCompositionRoot(
            gateway,
            callable,
            queue,
            credentials,
            firebaseProjectId,
            firebaseUid,
            appCheckProvider);
    }

    /// <summary>
    /// Live root: a signed-in <see cref="DesktopOAuthCredentialsProvider"/> supplies
    /// the real Firebase id token for both Firestore auth and the App Check mint.
    /// Production App Check is mandatory: the caller supplies the Windows TPM
    /// producer, live HTTP transport, and provisioned Firebase app id.
    /// </summary>
    public static CloudSyncCompositionRoot CreateWithOAuth(
        DesktopOAuthCredentialsProvider oauth,
        string firebaseProjectId,
        string firebaseUid,
        IAttestationProducer attestationProducer,
        IAppCheckMintTransport appCheckMintTransport,
        string appCheckAppId)
    {
        if (oauth is null) throw new ArgumentNullException(nameof(oauth));
        if (string.IsNullOrWhiteSpace(firebaseProjectId)) throw new ArgumentException("firebaseProjectId is required.", nameof(firebaseProjectId));
        if (string.IsNullOrWhiteSpace(firebaseUid)) throw new ArgumentException("firebaseUid is required.", nameof(firebaseUid));
        if (attestationProducer is null) throw new ArgumentNullException(nameof(attestationProducer));
        if (appCheckMintTransport is null) throw new ArgumentNullException(nameof(appCheckMintTransport));
        if (string.IsNullOrWhiteSpace(appCheckAppId)) throw new ArgumentException("appCheckAppId is required.", nameof(appCheckAppId));
        if (!attestationProducer.RequiresServerChallenge)
        {
            throw new ArgumentException("Production OAuth requires a server-challenge attestation producer.", nameof(attestationProducer));
        }

        var mintClient = new AppCheckMintClient(
            AppCheckMintEndpoint.ForProject(firebaseProjectId),
            appCheckMintTransport);
        var challengeClient = new AppCheckChallengeClient(
            AppCheckChallengeEndpoint.ForProject(firebaseProjectId),
            appCheckMintTransport);
        var options = new AppCheckProviderOptions { AppId = appCheckAppId };
        var appCheckProvider = new WindowsAppCheckProvider(
            attestationProducer,
            mintClient,
            oauth,
            options,
            SystemClock.Instance,
            challengeClient);

        var credentials = new AppCheckCredentialsProvider(oauth, appCheckProvider);
        var http = new HttpClientCloudSyncTransport(new HttpClient());
        var database = new FirestoreDatabase(firebaseProjectId);
        var gateway = new FirestoreRestGateway(http, credentials, database, requireAppCheck: true);
        var callable = new CallableClient(http, credentials, new CallableEndpoint("us-central1", firebaseProjectId));
        var queue = new OfflineWriteQueue(gateway, startOnline: true);

        return new CloudSyncCompositionRoot(
            gateway,
            callable,
            queue,
            credentials,
            firebaseProjectId,
            firebaseUid,
            appCheckProvider);
    }

    /// <summary>
    /// Build the live sync coordinator for the standard per-user domains
    /// (<c>cli_agent_mission_requests</c>, <c>quota_snapshots</c>, <c>memory_facts</c>)
    /// — the poll-then-snapshot-diff loop that pulls real documents through this
    /// root's gateway and raises per-domain change events. Once credentials exist,
    /// this is how the seam-ready surfaces receive live data.
    /// </summary>
    public FirestoreSyncCoordinator CreateLiveSyncCoordinator(
        TimeSpan? pollInterval = null,
        SyncBackoffPolicy? backoff = null,
        ISyncClock? clock = null)
    {
        string uid = FirebaseUid.Trim();
        var domains = new[]
        {
            SyncDomainDefinition.ForCollection(SyncDomains.Missions, $"users/{uid}/cli_agent_mission_requests", limit: 500),
            SyncDomainDefinition.ForCollection(SyncDomains.QuotaSnapshots, $"users/{uid}/quota_snapshots", limit: 500),
            SyncDomainDefinition.ForCollection(SyncDomains.MemoryFacts, $"users/{uid}/memory_facts", limit: 500),
        };
        return new FirestoreSyncCoordinator(Gateway, domains, clock, backoff, pollInterval);
    }

    /// <summary>Stable domain names raised by <see cref="CreateLiveSyncCoordinator"/>.</summary>
    public static class SyncDomains
    {
        public const string Missions = "missions";
        public const string QuotaSnapshots = "quota_snapshots";
        public const string MemoryFacts = "memory_facts";
    }

    private sealed class NoOpAppCheckMintTransport : IAppCheckMintTransport
    {
        public Task<AppCheckMintHttpResponse> SendAsync(AppCheckMintHttpRequest request, CancellationToken cancellationToken = default) =>
            throw AppCheckMintException.Transport("Dev-host App Check mint is not configured.");
    }

    private sealed class StubFirebaseIdTokenSource : IFirebaseIdTokenSource
    {
        private readonly string _token;

        public StubFirebaseIdTokenSource(string token) => _token = token;

        public ValueTask<string?> GetIdTokenAsync(CancellationToken cancellationToken = default) =>
            new(_token);
    }

    private sealed class FixedHexNonceSource : INonceSource
    {
        private readonly string _nonce;
        public FixedHexNonceSource(string nonce) => _nonce = nonce;
        public string NextNonce() => _nonce;
    }

}
