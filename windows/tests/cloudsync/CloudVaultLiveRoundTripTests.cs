using OpenBurnBar.CloudSync.Crypto;
using Xunit;

namespace OpenBurnBar.CloudSync.Crypto.Tests;

public sealed class CloudVaultLiveRoundTripTests
{
    [Fact]
    public void SealThenOpenUtf8_RecoversPlaintext()
    {
        string recovered = CloudVaultLiveRoundTrip.SealThenOpenUtf8("windows-live-roundtrip-payload");
        Assert.Equal("windows-live-roundtrip-payload", recovered);
    }

    [Fact]
    public void SealThenOpen_EmptyPlaintext_Works()
    {
        byte[] recovered = CloudVaultLiveRoundTrip.SealThenOpen(
            System.Array.Empty<byte>(),
            "uid",
            "col",
            "doc",
            "field");
        Assert.Empty(recovered);
    }
}
