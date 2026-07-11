// The pinned update key (Phase 5 · signed distribution).

using System;
using OpenBurnBar.Dist.UpdateFeed;
using Xunit;

namespace OpenBurnBar.Dist.Tests;

public sealed class PinnedUpdateKeyTests
{
    [Fact]
    public void ValidPublicKey_IsAccepted()
    {
        var keys = DistTestSupport.NewKeyPair();
        var pinned = PinnedUpdateKey.FromBytes(keys.PublicKey);
        Assert.Equal(keys.PublicKeyBase64, pinned.ToBase64());
    }

    [Fact]
    public void WrongLengthKey_IsRejected()
    {
        Assert.Throws<ArgumentException>(() => PinnedUpdateKey.FromBytes(new byte[16]));
    }

    [Fact]
    public void AllZeroPlaceholderKey_IsRejected_FailClosed()
    {
        // A build that never injected the real pin must refuse to trust ANY update.
        Assert.Throws<ArgumentException>(() => PinnedUpdateKey.FromBytes(new byte[32]));
    }

    [Fact]
    public void FromBase64_ParsesValidKey()
    {
        var keys = DistTestSupport.NewKeyPair();
        var pinned = PinnedUpdateKey.FromBase64(keys.PublicKeyBase64);
        Assert.Equal(keys.PublicKeyBase64, pinned.ToBase64());
    }

    [Fact]
    public void FromBase64_RejectsNonBase64()
    {
        Assert.Throws<ArgumentException>(() => PinnedUpdateKey.FromBase64("@@@ not base64 @@@"));
    }

    [Fact]
    public void TryFromBase64_FailsClosedOnPlaceholder()
    {
        var placeholder = Convert.ToBase64String(new byte[32]);
        Assert.False(PinnedUpdateKey.TryFromBase64(placeholder, out var key));
        Assert.Null(key);
    }

    [Fact]
    public void TryFromBase64_SucceedsOnRealKey()
    {
        var keys = DistTestSupport.NewKeyPair();
        Assert.True(PinnedUpdateKey.TryFromBase64(keys.PublicKeyBase64, out var key));
        Assert.NotNull(key);
    }

    [Fact]
    public void DerivePublicKey_MatchesTheGeneratedPublicKey()
    {
        // The release pipeline recovers the pinned public key from the private seed alone; that
        // derived key must equal the key pair's own public half.
        var keys = DistTestSupport.NewKeyPair();
        var derived = new UpdateFeedSigner().DerivePublicKey(keys.PrivateKey);
        Assert.Equal(keys.PublicKey, derived);
    }
}
