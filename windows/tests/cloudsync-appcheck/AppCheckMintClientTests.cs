using System;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using OpenBurnBar.CloudSync.AppCheck.Attestation;
using OpenBurnBar.CloudSync.AppCheck.Mint;
using Xunit;

namespace OpenBurnBar.CloudSync.AppCheck.Tests;

/// <summary>
/// The portable mint client owns the Firebase-callable wire contract and fails
/// CLOSED on every non-success outcome.
/// </summary>
public sealed class AppCheckMintClientTests
{
    private static readonly AppCheckMintEndpoint Endpoint =
        AppCheckMintEndpoint.ForProject("openburnbar-test");

    private static WindowsAttestationClaim SampleClaim()
    {
        var nonce = "0123456789abcdef0123456789abcdef";
        return new WindowsAttestationClaim
        {
            Kind = "mock",
            AppId = TestConstants.PlaceholderAppId,
            Nonce = nonce,
            IssuedAtMs = 1_700_000_000_000,
            Mac = MockAttestationMac.Sign(TestConstants.PlaceholderAppId, nonce, 1_700_000_000_000),
        };
    }

    [Fact]
    public async Task Encodes_the_callable_request_wire_shape_exactly()
    {
        var transport = FakeMintTransport.Success("appcheck-jwt", 30 * 60 * 1000, TestConstants.PlaceholderAppId);
        var client = new AppCheckMintClient(Endpoint, transport);

        await client.MintAsync(SampleClaim(), TestConstants.SampleIdToken, nowMillis: 1_700_000_000_000, ttlMillisRequest: 1800000);

        var request = transport.LastRequest!;
        Assert.Equal("POST", request.Method);
        Assert.Equal(Endpoint.Url.ToString(), request.Url);

        var auth = request.Headers.Single(h => h.Name == "Authorization");
        Assert.Equal($"Bearer {TestConstants.SampleIdToken}", auth.Value);
        Assert.Contains(request.Headers, h => h.Name == "Content-Type" && h.Value == "application/json");

        // Firebase callable envelope: { data: { attestation: {...}, ttlMillis } }.
        using var doc = JsonDocument.Parse(transport.LastBodyUtf8!);
        var data = doc.RootElement.GetProperty("data");
        var att = data.GetProperty("attestation");
        Assert.Equal("mock", att.GetProperty("kind").GetString());
        Assert.Equal(TestConstants.PlaceholderAppId, att.GetProperty("appId").GetString());
        Assert.Equal("0123456789abcdef0123456789abcdef", att.GetProperty("nonce").GetString());
        Assert.Equal(1_700_000_000_000, att.GetProperty("issuedAtMs").GetInt64());
        Assert.Equal(
            MockAttestationMac.Sign(TestConstants.PlaceholderAppId, "0123456789abcdef0123456789abcdef", 1_700_000_000_000),
            att.GetProperty("mac").GetString());
        Assert.Equal(1800000, data.GetProperty("ttlMillis").GetInt64());
    }

    [Fact]
    public async Task Omits_ttl_when_not_requested()
    {
        var transport = FakeMintTransport.Success("jwt", 30 * 60 * 1000, TestConstants.PlaceholderAppId);
        var client = new AppCheckMintClient(Endpoint, transport);

        await client.MintAsync(SampleClaim(), TestConstants.SampleIdToken, nowMillis: 1);

        using var doc = JsonDocument.Parse(transport.LastBodyUtf8!);
        Assert.False(doc.RootElement.GetProperty("data").TryGetProperty("ttlMillis", out _));
    }

    [Fact]
    public async Task Decodes_success_into_a_token_stamped_with_now()
    {
        var transport = FakeMintTransport.Success("the-appcheck-jwt", 45 * 60 * 1000, TestConstants.PlaceholderAppId);
        var client = new AppCheckMintClient(Endpoint, transport);

        var token = await client.MintAsync(SampleClaim(), TestConstants.SampleIdToken, nowMillis: 5000);

        Assert.Equal("the-appcheck-jwt", token.Token);
        Assert.Equal(45 * 60 * 1000, token.TtlMillis);
        Assert.Equal(TestConstants.PlaceholderAppId, token.AppId);
        Assert.Equal(5000, token.MintedAtMs);
        Assert.Equal(5000 + 45 * 60 * 1000, token.ExpiresAtMs);
    }

    [Fact]
    public async Task Empty_id_token_fails_closed_before_any_send()
    {
        var transport = FakeMintTransport.Success("jwt", 30 * 60 * 1000, TestConstants.PlaceholderAppId);
        var client = new AppCheckMintClient(Endpoint, transport);

        var ex = await Assert.ThrowsAsync<AppCheckMintException>(
            () => client.MintAsync(SampleClaim(), "", nowMillis: 1));
        Assert.Equal(AppCheckMintFailure.MissingIdToken, ex.Failure);
        Assert.Equal(0, transport.CallCount); // never hit the network
    }

    [Theory]
    [InlineData(401)]
    [InlineData(403)]
    [InlineData(429)]
    [InlineData(500)]
    public async Task Non_2xx_fails_closed_as_rejected(int status)
    {
        var transport = FakeMintTransport.Rejecting(status);
        var client = new AppCheckMintClient(Endpoint, transport);

        var ex = await Assert.ThrowsAsync<AppCheckMintException>(
            () => client.MintAsync(SampleClaim(), TestConstants.SampleIdToken, nowMillis: 1));
        Assert.Equal(AppCheckMintFailure.Rejected, ex.Failure);
        Assert.Equal(status, ex.StatusCode);
    }

    [Fact]
    public async Task Error_envelope_on_http_200_fails_closed()
    {
        // Some callable errors arrive with a 200 + { error }. Treat as rejection.
        var transport = new FakeMintTransport(_ =>
            new AppCheckMintHttpResponse(200, TestConstants.ErrorBody("permission-denied", "No verifier accepted this claim.")));
        var client = new AppCheckMintClient(Endpoint, transport);

        var ex = await Assert.ThrowsAsync<AppCheckMintException>(
            () => client.MintAsync(SampleClaim(), TestConstants.SampleIdToken, nowMillis: 1));
        Assert.Equal(AppCheckMintFailure.Rejected, ex.Failure);
    }

    [Fact]
    public async Task Ok_false_fails_closed()
    {
        var transport = new FakeMintTransport(_ =>
            new AppCheckMintHttpResponse(200, "{\"result\":{\"ok\":false}}"));
        var client = new AppCheckMintClient(Endpoint, transport);

        var ex = await Assert.ThrowsAsync<AppCheckMintException>(
            () => client.MintAsync(SampleClaim(), TestConstants.SampleIdToken, nowMillis: 1));
        Assert.Equal(AppCheckMintFailure.Rejected, ex.Failure);
    }

    [Theory]
    [InlineData("{\"result\":{\"ok\":true,\"ttlMillis\":1800000,\"appId\":\"x\"}}")]              // missing token
    [InlineData("{\"result\":{\"ok\":true,\"appCheckToken\":\"\",\"ttlMillis\":1800000,\"appId\":\"x\"}}")] // empty token
    [InlineData("{\"result\":{\"ok\":true,\"appCheckToken\":\"j\",\"appId\":\"x\"}}")]            // missing ttl
    [InlineData("{\"result\":{\"ok\":true,\"appCheckToken\":\"j\",\"ttlMillis\":0,\"appId\":\"x\"}}")] // non-positive ttl
    [InlineData("{\"result\":{\"ok\":true,\"appCheckToken\":\"j\",\"ttlMillis\":1800000}}")]      // missing appId
    [InlineData("{\"nope\":true}")]                                                                // no result
    [InlineData("not-json-at-all")]                                                                // garbage body
    public async Task Malformed_success_bodies_fail_closed(string body)
    {
        var transport = new FakeMintTransport(_ => new AppCheckMintHttpResponse(200, body));
        var client = new AppCheckMintClient(Endpoint, transport);

        var ex = await Assert.ThrowsAsync<AppCheckMintException>(
            () => client.MintAsync(SampleClaim(), TestConstants.SampleIdToken, nowMillis: 1));
        Assert.Contains(ex.Failure, new[] { AppCheckMintFailure.MalformedResponse, AppCheckMintFailure.Rejected });
    }
}
