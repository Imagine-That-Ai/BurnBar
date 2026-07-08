using System.Text;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using OpenBurnBar.CloudSync.Callable;
using OpenBurnBar.CloudSync.Gateway;
using OpenBurnBar.CloudSync.Json;
using Xunit;

namespace OpenBurnBar.CloudSync.Tests;

/// <summary>
/// Proves the Firebase callable request <c>{data}</c> / response <c>{result}</c> /
/// error <c>{error}</c> envelope against the real <c>mintWindowsAppCheckToken</c>
/// (AC-011) contract fixtures, plus an end-to-end invoke through the transport.
/// </summary>
public sealed class CallableEnvelopeTests
{
    private static MintWindowsAppCheckTokenRequest SampleRequest() => new()
    {
        Attestation = new WindowsAttestationClaim
        {
            Kind = "mock",
            AppId = "1:1234567890:web:abcdef0123456789",
            Nonce = "0123456789abcdef0123",
            IssuedAtMs = 1720000000000,
            Mac = "deadbeefcafef00d",
        },
        TtlMillis = 1800000,
    };

    [Fact]
    public void Request_body_matches_the_committed_envelope_fixture()
    {
        byte[] actual = CallableClient.BuildRequestBody(SampleRequest());

        byte[] fixture = Fixtures.ReadBytes("callable", "mint_appcheck_request.json");
        byte[] expected = CanonicalJson.SerializeToUtf8Bytes(JsonNode.Parse(fixture)!);

        Assert.Equal(Encoding.UTF8.GetString(expected), Encoding.UTF8.GetString(actual));
    }

    [Fact]
    public void Success_response_parses_into_the_result_payload()
    {
        byte[] fixture = Fixtures.ReadBytes("callable", "mint_appcheck_response.json");
        MintWindowsAppCheckTokenResult result = CallableClient.ParseResponse<MintWindowsAppCheckTokenResult>(fixture);

        Assert.True(result.Ok);
        Assert.Equal("eyJhbGciOi.appcheck.tok", result.AppCheckToken);
        Assert.Equal(1800000, result.TtlMillis);
        Assert.Equal("1:1234567890:web:abcdef0123456789", result.AppId);
    }

    [Fact]
    public void Error_response_throws_a_callable_exception_with_the_status()
    {
        byte[] fixture = Fixtures.ReadBytes("callable", "mint_appcheck_error.json");

        CallableException ex = Assert.Throws<CallableException>(() =>
            CallableClient.ParseResponse<MintWindowsAppCheckTokenResult>(fixture));
        Assert.Equal("UNAUTHENTICATED", ex.Error.Status);
        Assert.Contains("Sign in", ex.Error.Message);
    }

    [Fact]
    public async Task Invoke_posts_the_data_envelope_with_auth_and_appcheck_headers()
    {
        string responseBody = Fixtures.ReadText("callable", "mint_appcheck_response.json");
        var transport = new RecordingTransport(_ => RecordingTransport.Json(200, responseBody));
        var client = new CallableClient(
            transport,
            new StaticCredentialsProvider(new CloudSyncCredentials("id-token", "appcheck-tok")),
            new CallableEndpoint("us-central1", "openburnbar-demo"));

        MintWindowsAppCheckTokenResult result = await client
            .InvokeAsync<MintWindowsAppCheckTokenRequest, MintWindowsAppCheckTokenResult>(
                "mintWindowsAppCheckToken", SampleRequest());

        Assert.Equal(HttpVerb.Post, transport.LastRequest.Method);
        Assert.Equal("https://us-central1-openburnbar-demo.cloudfunctions.net/mintWindowsAppCheckToken",
            transport.LastRequest.Url);
        Assert.Equal("Bearer id-token", transport.LastRequest.Headers["Authorization"]);
        Assert.Equal("appcheck-tok", transport.LastRequest.Headers["X-Firebase-AppCheck"]);
        Assert.StartsWith("{\"data\":", transport.LastRequestBodyText());
        Assert.True(result.Ok);
    }

    [Fact]
    public async Task Invoke_surfaces_a_structured_error_on_non_success()
    {
        string errorBody = Fixtures.ReadText("callable", "mint_appcheck_error.json");
        var transport = new RecordingTransport(_ => RecordingTransport.Json(401, errorBody));
        var client = new CallableClient(
            transport,
            new StaticCredentialsProvider(new CloudSyncCredentials("id-token")),
            new CallableEndpoint("us-central1", "openburnbar-demo"));

        CallableException ex = await Assert.ThrowsAsync<CallableException>(() =>
            client.InvokeAsync<MintWindowsAppCheckTokenRequest, MintWindowsAppCheckTokenResult>(
                "mintWindowsAppCheckToken", SampleRequest()));
        Assert.Equal("UNAUTHENTICATED", ex.Error.Status);
    }
}
