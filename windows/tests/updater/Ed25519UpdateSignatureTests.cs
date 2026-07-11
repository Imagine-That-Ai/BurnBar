using System;
using System.Text;
using OpenBurnBar.Updater.Core.Crypto;
using Xunit;

namespace OpenBurnBar.Updater.Tests;

public sealed class Ed25519UpdateSignatureTests
{
    private static readonly byte[] Message = Encoding.UTF8.GetBytes("installer bytes");

    [Fact]
    public void RealSignatureVerifiesAgainstPinnedKey()
    {
        var keyPair = Ed25519UpdateKeyPair.Generate();
        var signature = keyPair.Sign(Message);

        Assert.True(keyPair.Verifier().Verify(Message, signature));
        Assert.Equal(Ed25519Sizes.SignatureSize, signature.Length);
    }

    [Fact]
    public void TamperedMessageIsRejected()
    {
        var keyPair = Ed25519UpdateKeyPair.Generate();
        var signature = keyPair.Sign(Message);

        var tampered = (byte[])Message.Clone();
        tampered[0] ^= 0x01;

        Assert.False(keyPair.Verifier().Verify(tampered, signature));
    }

    [Fact]
    public void WrongKeyIsRejected()
    {
        var signingKey = Ed25519UpdateKeyPair.Generate();
        var otherKey = Ed25519UpdateKeyPair.Generate();
        var signature = signingKey.Sign(Message);

        Assert.False(otherKey.Verifier().Verify(Message, signature));
    }

    [Fact]
    public void WrongLengthSignatureFailsClosedWithoutThrowing()
    {
        var keyPair = Ed25519UpdateKeyPair.Generate();
        Assert.False(keyPair.Verifier().Verify(Message, new byte[10]));
        Assert.False(keyPair.Verifier().Verify(Message, Array.Empty<byte>()));
    }

    [Fact]
    public void DeterministicFromSeed()
    {
        Span<byte> seed = stackalloc byte[Ed25519Sizes.KeySize];
        for (var i = 0; i < seed.Length; i++)
        {
            seed[i] = (byte)(i + 1);
        }

        var a = Ed25519UpdateKeyPair.FromSeed(seed);
        var b = Ed25519UpdateKeyPair.FromSeed(seed);

        Assert.Equal(a.PublicKeyBase64, b.PublicKeyBase64);
        // Ed25519 is deterministic: the same seed + message yields the same signature.
        Assert.Equal(a.SignBase64(Message), b.SignBase64(Message));
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("not base64 !!!")]
    [InlineData("YWJj")] // "abc" — valid base64 but only 3 bytes, not 32.
    public void MalformedPinnedKeyReturnsNullSoCallerFailsClosed(string? pin)
    {
        Assert.Null(Ed25519UpdateSignatureVerifier.FromBase64PublicKey(pin));
    }

    [Fact]
    public void ValidPinnedKeyRoundTripsBase64()
    {
        var keyPair = Ed25519UpdateKeyPair.Generate();
        var verifier = Ed25519UpdateSignatureVerifier.FromBase64PublicKey(keyPair.PublicKeyBase64);

        Assert.NotNull(verifier);
        Assert.Equal(keyPair.PublicKeyBase64, verifier!.PinnedPublicKeyBase64);
    }
}
