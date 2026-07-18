using System;
using System.Text.Json;
using System.Threading.Tasks;
using OpenBurnBar.CloudSync.AppCheck.Mint;
using Xunit;

namespace OpenBurnBar.CloudSync.AppCheck.Tests;

public sealed class AppCheckChallengeClientTests
{
    [Fact]
    public async Task IssueAsync_SendsAuthenticatedAppBinding_AndDecodesChallenge()
    {
        var transport = new FakeMintTransport(_ => new AppCheckMintHttpResponse(
            200,
            "{\"result\":{\"ok\":true,\"challengeId\":\"challenge-0123456789abcdef\",\"nonce\":\"nonce-0123456789abcdef\",\"expiresAtMs\":1900000120000}}"));
        var client = new AppCheckChallengeClient(
            AppCheckChallengeEndpoint.ForUrl(new Uri("https://example.test/challenge")),
            transport);

        var challenge = await client.IssueAsync(TestConstants.PlaceholderAppId, TestConstants.SampleIdToken);

        Assert.Equal("challenge-0123456789abcdef", challenge.ChallengeId);
        Assert.Equal("nonce-0123456789abcdef", challenge.Nonce);
        Assert.Equal(1_900_000_120_000, challenge.ExpiresAtMs);
        Assert.Equal("https://example.test/challenge", transport.LastRequest?.Url);
        Assert.Contains(
            transport.LastRequest!.Headers,
            header => header.Name == "Authorization" && header.Value == $"Bearer {TestConstants.SampleIdToken}");
        using var body = JsonDocument.Parse(transport.LastRequest.Body);
        Assert.Equal(
            TestConstants.PlaceholderAppId,
            body.RootElement.GetProperty("data").GetProperty("appId").GetString());
    }

    [Fact]
    public async Task IssueAsync_RejectsMalformedOrDeniedResponse_FailClosed()
    {
        var denied = new AppCheckChallengeClient(
            AppCheckChallengeEndpoint.ForUrl(new Uri("https://example.test/challenge")),
            FakeMintTransport.Rejecting(403));
        await Assert.ThrowsAsync<AppCheckMintException>(() =>
            denied.IssueAsync(TestConstants.PlaceholderAppId, TestConstants.SampleIdToken));

        var malformed = new AppCheckChallengeClient(
            AppCheckChallengeEndpoint.ForUrl(new Uri("https://example.test/challenge")),
            new FakeMintTransport(_ => new AppCheckMintHttpResponse(200, "{\"result\":{\"ok\":true}}")));
        await Assert.ThrowsAsync<AppCheckMintException>(() =>
            malformed.IssueAsync(TestConstants.PlaceholderAppId, TestConstants.SampleIdToken));
    }

    [Fact]
    public async Task IssueAsync_RejectsOutOfRangeExpiry_FailClosed()
    {
        var client = new AppCheckChallengeClient(
            AppCheckChallengeEndpoint.ForUrl(new Uri("https://example.test/challenge")),
            new FakeMintTransport(_ => new AppCheckMintHttpResponse(
                200,
                "{\"result\":{\"ok\":true,\"challengeId\":\"challenge-0123456789abcdef\",\"nonce\":\"nonce-0123456789abcdef\",\"expiresAtMs\":9223372036854775808}}")));

        await Assert.ThrowsAsync<AppCheckMintException>(() =>
            client.IssueAsync(TestConstants.PlaceholderAppId, TestConstants.SampleIdToken));
    }
}
