// The security kernel: pinned Ed25519 verification of update offers (Phase 5).
//
// These are the tests that matter most: a genuinely signed offer verifies; ANY tamper, wrong
// key, or malformed input is fail-closed (never authentic, never throws).

using System;
using System.Text;
using OpenBurnBar.Dist.UpdateFeed;
using Xunit;

namespace OpenBurnBar.Dist.Tests;

public sealed class Ed25519UpdateFeedVerifierTests
{
    [Fact]
    public void GenuinelySignedEntry_VerifiesUnderPinnedKey()
    {
        var keys = DistTestSupport.NewKeyPair();
        var signed = DistTestSupport.Sign(DistTestSupport.SampleEntry(), keys);

        var result = DistTestSupport.VerifierFor(keys).VerifyDescriptor(signed);

        Assert.True(result.IsAuthentic);
        Assert.Equal(UpdateVerificationFailure.None, result.Failure);
        Assert.NotNull(result.Entry);
    }

    [Fact]
    public void SignatureFromDifferentKey_IsRejected()
    {
        var signingKeys = DistTestSupport.NewKeyPair();
        var pinnedKeys = DistTestSupport.NewKeyPair(); // a DIFFERENT pinned key
        var signed = DistTestSupport.Sign(DistTestSupport.SampleEntry(), signingKeys);

        var result = DistTestSupport.VerifierFor(pinnedKeys).VerifyDescriptor(signed);

        Assert.False(result.IsAuthentic);
        Assert.Equal(UpdateVerificationFailure.InvalidSignature, result.Failure);
    }

    [Theory]
    [InlineData("url")]
    [InlineData("version")]
    [InlineData("sha256")]
    [InlineData("size")]
    [InlineData("critical")]
    [InlineData("minOsBuild")]
    [InlineData("channel")]
    [InlineData("platform")]
    [InlineData("publishedAt")]
    [InlineData("releaseNotesUrl")]
    public void TamperingAnySignedField_IsRejected(string field)
    {
        var keys = DistTestSupport.NewKeyPair();
        var original = DistTestSupport.SampleEntry();
        var signed = DistTestSupport.Sign(original, keys);

        // Mutate exactly one signed field, preserving the original signature.
        var tampered = field switch
        {
            "url" => signed with { Url = signed.Url + "?evil=1" },
            "version" => signed with { Version = "1.0.29" },
            "sha256" => signed with { Sha256 = new string('a', 64) },
            "size" => signed with { SizeBytes = signed.SizeBytes + 1 },
            "critical" => signed with { Critical = !signed.Critical },
            "minOsBuild" => signed with { MinimumOsBuild = signed.MinimumOsBuild + 1 },
            "channel" => signed with { Channel = UpdateChannel.Beta },
            "platform" => signed with { Platform = UpdatePlatform.WinArm64 },
            "publishedAt" => signed with { PublishedAtUtc = signed.PublishedAtUtc.AddSeconds(1) },
            "releaseNotesUrl" => signed with { ReleaseNotesUrl = "https://evil.example/notes" },
            _ => throw new ArgumentOutOfRangeException(nameof(field)),
        };

        var result = DistTestSupport.VerifierFor(keys).VerifyDescriptor(tampered);

        Assert.False(result.IsAuthentic);
    }

    [Fact]
    public void MissingSignature_IsRejected()
    {
        var keys = DistTestSupport.NewKeyPair();
        var unsigned = DistTestSupport.SampleEntry(); // Signature == ""

        var result = DistTestSupport.VerifierFor(keys).VerifyDescriptor(unsigned);

        Assert.False(result.IsAuthentic);
        Assert.Equal(UpdateVerificationFailure.MissingSignature, result.Failure);
    }

    [Fact]
    public void SignatureWrongLength_IsRejectedWithoutThrowing()
    {
        var keys = DistTestSupport.NewKeyPair();
        var entry = DistTestSupport.SampleEntry() with
        {
            Signature = Convert.ToBase64String(new byte[10]), // not 64 bytes
        };

        var result = DistTestSupport.VerifierFor(keys).VerifyDescriptor(entry);

        Assert.False(result.IsAuthentic);
        Assert.Equal(UpdateVerificationFailure.MalformedSignature, result.Failure);
    }

    [Fact]
    public void SignatureNotBase64_IsRejectedWithoutThrowing()
    {
        var keys = DistTestSupport.NewKeyPair();
        var entry = DistTestSupport.SampleEntry() with { Signature = "!!! not base64 !!!" };

        var result = DistTestSupport.VerifierFor(keys).VerifyDescriptor(entry);

        Assert.False(result.IsAuthentic);
        Assert.Equal(UpdateVerificationFailure.MalformedSignature, result.Failure);
    }

    [Fact]
    public void MalformedDescriptorField_IsRejectedWithoutThrowing()
    {
        var keys = DistTestSupport.NewKeyPair();
        // A signature that is well-formed length-wise, but the descriptor is malformed (bad sha256),
        // so canonicalization throws internally and must be caught → fail-closed.
        var entry = DistTestSupport.SampleEntry() with
        {
            Sha256 = "too-short",
            Signature = Convert.ToBase64String(new byte[64]),
        };

        var result = DistTestSupport.VerifierFor(keys).VerifyDescriptor(entry);

        Assert.False(result.IsAuthentic);
        Assert.Equal(UpdateVerificationFailure.MalformedDescriptor, result.Failure);
    }

    [Fact]
    public void ArtifactContent_MatchesSignedSha256()
    {
        var bytes = Encoding.UTF8.GetBytes("hello-artifact");
        // sha256("hello-artifact") == SampleSha256 (see DistTestSupport).
        var entry = DistTestSupport.SampleEntry() with { Sha256 = DistTestSupport.SampleSha256 };

        Assert.True(Ed25519UpdateFeedVerifier.VerifyArtifactContent(entry, bytes));
    }

    [Fact]
    public void ArtifactContent_MismatchIsRejected()
    {
        var bytes = Encoding.UTF8.GetBytes("tampered-artifact");
        var entry = DistTestSupport.SampleEntry() with { Sha256 = DistTestSupport.SampleSha256 };

        Assert.False(Ed25519UpdateFeedVerifier.VerifyArtifactContent(entry, bytes));
    }

    [Fact]
    public void ArtifactContent_UppercaseSignedHash_StillMatches()
    {
        var bytes = Encoding.UTF8.GetBytes("hello-artifact");
        var entry = DistTestSupport.SampleEntry() with { Sha256 = DistTestSupport.SampleSha256.ToUpperInvariant() };

        Assert.True(Ed25519UpdateFeedVerifier.VerifyArtifactContent(entry, bytes));
    }

    [Fact]
    public void SignThenVerify_IsDeterministicAcrossFreshVerifierInstances()
    {
        var keys = DistTestSupport.NewKeyPair();
        var signed = DistTestSupport.Sign(DistTestSupport.SampleEntry(), keys);

        // A brand-new verifier built from the same pinned key still authenticates.
        var pinned = PinnedUpdateKey.FromBase64(keys.PublicKeyBase64);
        var result = new Ed25519UpdateFeedVerifier(pinned).VerifyDescriptor(signed);

        Assert.True(result.IsAuthentic);
    }
}
