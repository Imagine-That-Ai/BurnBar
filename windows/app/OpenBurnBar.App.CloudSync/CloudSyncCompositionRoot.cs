using OpenBurnBar.CloudSync.AppCheck.Attestation;
using OpenBurnBar.CloudSync.AppCheck.Mint;
using OpenBurnBar.CloudSync.AppCheck.Provider;
using OpenBurnBar.CloudSync.AppCheck.Token;
using OpenBurnBar.CloudSync.Callable;
using OpenBurnBar.CloudSync.Firestore;
using OpenBurnBar.CloudSync.Gateway;
using OpenBurnBar.CloudSync.Offline;

namespace OpenBurnBar.App.CloudSync;

/// <summary>
/// App-level wiring for Firestore REST, callables, offline queue, and App Check (mock attestation until WS-D TPM).
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