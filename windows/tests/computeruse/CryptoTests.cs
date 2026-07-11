using System;
using System.Text;
using OpenBurnBar.ComputerUse.Core.Crypto;
using Xunit;

namespace OpenBurnBar.ComputerUse.Tests;

public sealed class CanonicalJsonTests
{
    [Fact]
    public void SortsKeysAscendingRegardlessOfInsertionOrder()
    {
        var a = new CanonicalJsonObject().Set("zeta", 1).Set("alpha", 2).Set("mid", 3);
        var b = new CanonicalJsonObject().Set("mid", 3).Set("alpha", 2).Set("zeta", 1);

        Assert.Equal("{\"alpha\":2,\"mid\":3,\"zeta\":1}", CanonicalJson.EncodeToString(a));
        Assert.Equal(CanonicalJson.EncodeToString(a), CanonicalJson.EncodeToString(b));
    }

    [Fact]
    public void OmitsNullMembers()
    {
        var value = new CanonicalJsonObject().Set("present", "x").Set("absent", null);
        Assert.Equal("{\"present\":\"x\"}", CanonicalJson.EncodeToString(value));
    }

    [Fact]
    public void DoesNotEscapeForwardSlashButEscapesControlChars()
    {
        var value = new CanonicalJsonObject().Set("url", "https://a/b").Set("tab", "x\ty");
        Assert.Equal("{\"tab\":\"x\\ty\",\"url\":\"https://a/b\"}", CanonicalJson.EncodeToString(value));
    }

    [Fact]
    public void EncodesNestedObjectsAndStringArrays()
    {
        var nested = new CanonicalJsonObject().Set("k", "v");
        var value = new CanonicalJsonObject()
            .Set("arr", new[] { "b", "a" })
            .Set("obj", nested);
        Assert.Equal("{\"arr\":[\"b\",\"a\"],\"obj\":{\"k\":\"v\"}}", CanonicalJson.EncodeToString(value));
    }
}

public sealed class Ed25519Tests
{
    [Fact]
    public void SignThenVerifyRoundTrips()
    {
        var keyPair = Ed25519KeyPair.Generate();
        var message = Encoding.UTF8.GetBytes("computer-use capability body");

        var signature = keyPair.Signer().Sign(message);

        Assert.Equal(Ed25519.SignatureSize, signature.Length);
        Assert.True(keyPair.Verifier().Verify(message, signature));
    }

    [Fact]
    public void WrongKeyDoesNotVerify()
    {
        var signer = Ed25519KeyPair.Generate();
        var other = Ed25519KeyPair.Generate();
        var message = Encoding.UTF8.GetBytes("payload");

        var signature = signer.Signer().Sign(message);

        Assert.False(other.Verifier().Verify(message, signature));
    }

    [Fact]
    public void TamperedMessageDoesNotVerify()
    {
        var keyPair = Ed25519KeyPair.Generate();
        var message = Encoding.UTF8.GetBytes("payload");
        var signature = keyPair.Signer().Sign(message);

        var tampered = Encoding.UTF8.GetBytes("payloaD");

        Assert.False(keyPair.Verifier().Verify(tampered, signature));
    }

    [Fact]
    public void RebuildingFromSeedReproducesSameKeyAndVerifies()
    {
        var keyPair = Ed25519KeyPair.Generate();
        var rebuilt = Ed25519KeyPair.FromSeed(keyPair.PrivateKeyRaw);

        Assert.Equal(keyPair.PublicKeyBase64, rebuilt.PublicKeyBase64);

        var message = Encoding.UTF8.GetBytes("cross-instance");
        var signature = keyPair.Signer().Sign(message);
        Assert.True(rebuilt.Verifier().Verify(message, signature));
    }

    [Fact]
    public void PublicKeyBase64RoundTripsThroughFromBase64PublicKey()
    {
        var keyPair = Ed25519KeyPair.Generate();
        var verifier = Ed25519Verifier.FromBase64PublicKey(keyPair.PublicKeyBase64);
        Assert.NotNull(verifier);

        var message = Encoding.UTF8.GetBytes("via base64 key");
        var signature = keyPair.Signer().Sign(message);
        Assert.True(verifier!.Verify(message, signature));
    }

    [Fact]
    public void MalformedPublicKeyBase64ReturnsNull()
    {
        Assert.Null(Ed25519Verifier.FromBase64PublicKey("not-base64!!"));
        Assert.Null(Ed25519Verifier.FromBase64PublicKey(Convert.ToBase64String(new byte[8])));
        Assert.Null(Ed25519Verifier.FromBase64PublicKey(string.Empty));
    }

    [Fact]
    public void AuditHasherIsDeterministicAndDistinct()
    {
        var a = new CanonicalJsonObject().Set("x", 1);
        var b = new CanonicalJsonObject().Set("x", 2);

        Assert.Equal(AuditHasher.Current.Hash(a), AuditHasher.Current.Hash(a));
        Assert.NotEqual(AuditHasher.Current.Hash(a), AuditHasher.Current.Hash(b));
        Assert.Equal(64, AuditHasher.Current.Hash(a).Length);
        Assert.Equal(64, AuditHasher.GenesisParentHashHex.Length);
    }
}
