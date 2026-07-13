using System.Net.Http;
using OpenBurnBar.App.CloudSync;
using OpenBurnBar.CloudSync.AppCheck.Attestation;
using OpenBurnBar.CloudSync.AppCheck.Mint;
using OpenBurnBar.CloudSync.AppCheck.Token;
using Xunit;

namespace OpenBurnBar.App.CloudSync.Tests;

public sealed class CloudSyncCompositionRootTests
{
    [Fact]
    public void OAuth_root_uses_the_platform_attestation_producer_when_supplied()
    {
        var options = new DesktopOAuthOptions
        {
            ClientId = "test-client",
            FirebaseApiKey = "test-key",
        };
        using var http = new HttpClient();
        var identity = new FirebaseIdentityClient(http, options);
        var flow = new DesktopOAuthLoopbackFlow(options, new NoOpBrowser(), identity, SystemClock.Instance);
        using var oauth = new DesktopOAuthCredentialsProvider(options, flow, identity, SystemClock.Instance);
        using var mintTransport = new NoOpMintTransport();

        CloudSyncCompositionRoot root = CloudSyncCompositionRoot.CreateWithOAuth(
            oauth,
            "project-test",
            "uid-test",
            mintTransport,
            appCheckAttestationProducer: new RecordingProducer());

        Assert.NotNull(root.AppCheck);
        Assert.Equal("tpm-test", root.AppCheck!.AttestationKind);
    }

    private sealed class RecordingProducer : IAttestationProducer
    {
        public string Kind => "tpm-test";

        public ValueTask<WindowsAttestationClaim> ProduceAsync(
            string appId,
            long nowMillis,
            CancellationToken cancellationToken = default) =>
            throw new NotSupportedException("The composition test only inspects the selected producer.");
    }

    private sealed class NoOpBrowser : IBrowserLauncher
    {
        public void Launch(Uri authorizationUrl) => throw new NotSupportedException();
    }

    private sealed class NoOpMintTransport : IAppCheckMintTransport, IDisposable
    {
        public Task<AppCheckMintHttpResponse> SendAsync(
            AppCheckMintHttpRequest request,
            CancellationToken cancellationToken = default) =>
            throw new NotSupportedException("The composition test does not mint a token.");

        public void Dispose() { }
    }
}
