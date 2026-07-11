using System;
using System.Threading.Tasks;
using OpenBurnBar.CloudSync.AppCheck.Attestation;
using Xunit;

namespace OpenBurnBar.CloudSync.AppCheck.Tests;

/// <summary>The mock producer assembles a well-formed, server-acceptable claim.</summary>
public sealed class MockAttestationProducerTests
{
    [Fact]
    public async Task Produces_a_mock_claim_bound_to_app_id_and_now()
    {
        var producer = new MockAttestationProducer(new SequenceNonceSource("0123456789abcdef0123456789abcdef"));
        var claim = await producer.ProduceAsync(TestConstants.PlaceholderAppId, 1_700_000_000_000);

        Assert.Equal("mock", claim.Kind);
        Assert.Equal(MockAttestationMac.Kind, producer.Kind);
        Assert.Equal(TestConstants.PlaceholderAppId, claim.AppId);
        Assert.Equal("0123456789abcdef0123456789abcdef", claim.Nonce);
        Assert.Equal(1_700_000_000_000, claim.IssuedAtMs);

        // The MAC must be exactly what the server recomputes for these fields.
        var expected = MockAttestationMac.Sign(claim.AppId, claim.Nonce, claim.IssuedAtMs);
        Assert.Equal(expected, claim.Mac);
        // And that equals the committed golden vector for this triplet.
        Assert.Equal("3ba8400316adbdd0a7a88afa21faad6fd3e1df789790b0772b0bcb303f8733b0", claim.Mac);
    }

    [Fact]
    public async Task Random_nonce_source_satisfies_server_bounds()
    {
        var producer = new MockAttestationProducer();
        var claim = await producer.ProduceAsync(TestConstants.PlaceholderAppId, 1_700_000_000_000);

        Assert.InRange(claim.Nonce.Length, MockAttestationMac.MinNonceLength, MockAttestationMac.MaxNonceLength);
        Assert.Matches("^[0-9a-f]+$", claim.Nonce);
    }

    [Fact]
    public async Task Successive_claims_use_distinct_nonces()
    {
        var producer = new MockAttestationProducer();
        var a = await producer.ProduceAsync(TestConstants.PlaceholderAppId, 1);
        var b = await producer.ProduceAsync(TestConstants.PlaceholderAppId, 1);
        Assert.NotEqual(a.Nonce, b.Nonce); // single-use nonces defeat replay
    }

    [Fact]
    public async Task Wrong_secret_produces_a_mac_the_server_would_reject()
    {
        var good = new MockAttestationProducer(new SequenceNonceSource("nonce0123456789abcdef"));
        var bad = new MockAttestationProducer(new SequenceNonceSource("nonce0123456789abcdef"), "attacker-secret");

        var goodClaim = await good.ProduceAsync(TestConstants.PlaceholderAppId, 42);
        var badClaim = await bad.ProduceAsync(TestConstants.PlaceholderAppId, 42);

        Assert.Equal(goodClaim.Nonce, badClaim.Nonce);
        Assert.NotEqual(goodClaim.Mac, badClaim.Mac);
    }

    [Fact]
    public async Task Empty_app_id_throws()
    {
        var producer = new MockAttestationProducer();
        await Assert.ThrowsAsync<ArgumentException>(() => producer.ProduceAsync("", 1).AsTask());
    }

    [Fact]
    public void Random_nonce_source_rejects_too_short_byte_length()
    {
        Assert.Throws<ArgumentOutOfRangeException>(() => new RandomNonceSource(4));
    }
}
