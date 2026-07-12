using OpenBurnBar.Updater.Core.Crypto;
using OpenBurnBar.Updater.Core.Feed;
using OpenBurnBar.Updater.Core.Verification;
using OpenBurnBar.Updater.Core.Versioning;
using Xunit;

namespace OpenBurnBar.Updater.Tests;

/// <summary>
/// The R19 pin-verify crux, hammered from every attack angle. "valid" always
/// means a real Ed25519 signature over the real artifact by the pinned key.
/// </summary>
public sealed class UpdateFeedVerifierTests
{
    private static readonly UpdateVersion Installed = UpdateVersion.Parse("1.0.0");

    private static UpdateFeedVerifier VerifierFor(Ed25519UpdateKeyPair pinnedKey) =>
        new(pinnedKey.Verifier());

    // ── Happy path ─────────────────────────────────────────────────────────

    [Theory]
    [InlineData(FeedFormat.Appcast)]
    [InlineData(FeedFormat.Json)]
    public void ValidSignedFeedIsAccepted(FeedFormat format)
    {
        var pinnedKey = Ed25519UpdateKeyPair.Generate();
        var feed = FeedTestData.Write(format, FeedTestData.Descriptor(pinnedKey, FeedTestData.Artifact));

        var decision = VerifierFor(pinnedKey).Decide(feed, format, Installed, FeedTestData.Artifact);

        Assert.Equal(UpdateStatus.UpdateAvailable, decision.Status);
        Assert.True(decision.ShouldInstall);
        Assert.Equal("1.4.2", decision.Manifest!.Version);
    }

    // ── The security crux: the pinned signature is the authoritative gate ────

    [Fact]
    public void TamperedPayloadIsRejected()
    {
        var pinnedKey = Ed25519UpdateKeyPair.Generate();
        var feed = FeedTestData.Write(
            FeedFormat.Json, FeedTestData.Descriptor(pinnedKey, FeedTestData.Artifact));

        var tampered = (byte[])FeedTestData.Artifact.Clone();
        tampered[5] ^= 0xFF;

        var decision = VerifierFor(pinnedKey).Decide(feed, FeedFormat.Json, Installed, tampered);

        Assert.Equal(UpdateStatus.Rejected, decision.Status);
        // The length still matches, so it fails at the SHA-256 fast check.
        Assert.Equal(RejectionReason.Sha256Mismatch, decision.Reason);
        Assert.False(decision.ShouldInstall);
    }

    [Fact]
    public void SignatureBeatsRewrittenSha256()
    {
        // THE test that proves the Ed25519 pin — not the sha256 — is the real
        // gate. Attacker swaps in a malicious payload AND rewrites the feed's
        // length + sha256 to match it, keeping the ORIGINAL signature. The
        // length + sha256 fast checks now pass, but the pinned Ed25519 verify
        // over the malicious bytes fails, so the update is still rejected.
        var pinnedKey = Ed25519UpdateKeyPair.Generate();
        var honest = FeedTestData.Descriptor(pinnedKey, FeedTestData.Artifact);

        var malicious = new byte[FeedTestData.Artifact.Length];
        for (var i = 0; i < malicious.Length; i++)
        {
            malicious[i] = (byte)(FeedTestData.Artifact[i] ^ 0xA5);
        }

        var forgedFeedDescriptor = honest with
        {
            Length = malicious.LongLength,
            Sha256 = Sha256Digest.HexOf(malicious), // rewritten to match the payload
            // EdSignatureBase64 stays the ORIGINAL signature over the honest bytes.
        };
        var feed = JsonFeedWriter.Write(forgedFeedDescriptor);

        var decision = VerifierFor(pinnedKey).Decide(feed, FeedFormat.Json, Installed, malicious);

        Assert.Equal(UpdateStatus.Rejected, decision.Status);
        Assert.Equal(RejectionReason.SignatureInvalid, decision.Reason);
    }

    [Fact]
    public void WrongKeyIsRejected()
    {
        // The feed is signed by the attacker's key; the client pins a different key.
        var attackerKey = Ed25519UpdateKeyPair.Generate();
        var pinnedKey = Ed25519UpdateKeyPair.Generate();
        var feed = FeedTestData.Write(
            FeedFormat.Json, FeedTestData.Descriptor(attackerKey, FeedTestData.Artifact));

        var decision = VerifierFor(pinnedKey).Decide(feed, FeedFormat.Json, Installed, FeedTestData.Artifact);

        Assert.Equal(UpdateStatus.Rejected, decision.Status);
        Assert.Equal(RejectionReason.SignatureInvalid, decision.Reason);
    }

    [Fact]
    public void ReSignedWithAuthenticodeButNotFeedKeyStillRejected()
    {
        // Models R19: an attacker who owns a valid Authenticode certificate (a
        // DIFFERENT key) re-signs a malicious artifact and its feed. The pinned
        // FEED key is independent of the code-signing cert, so this fails.
        var authenticodeStyleKey = Ed25519UpdateKeyPair.Generate();
        var pinnedFeedKey = Ed25519UpdateKeyPair.Generate();

        var malicious = (byte[])FeedTestData.Artifact.Clone();
        malicious[0] = 0x00;
        var feed = FeedTestData.Write(
            FeedFormat.Json, FeedTestData.Descriptor(authenticodeStyleKey, malicious));

        var decision = VerifierFor(pinnedFeedKey).Decide(feed, FeedFormat.Json, Installed, malicious);

        Assert.Equal(UpdateStatus.Rejected, decision.Status);
        Assert.Equal(RejectionReason.SignatureInvalid, decision.Reason);
    }

    // ── Version / downgrade ──────────────────────────────────────────────────

    [Fact]
    public void DowngradeIsBlockedEvenWithValidSignature()
    {
        var pinnedKey = Ed25519UpdateKeyPair.Generate();
        // A perfectly, validly signed OLDER build (1.4.2 < installed 2.0.0).
        var feed = FeedTestData.Write(
            FeedFormat.Json, FeedTestData.Descriptor(pinnedKey, FeedTestData.Artifact, version: "1.4.2"));

        var decision = VerifierFor(pinnedKey)
            .Decide(feed, FeedFormat.Json, UpdateVersion.Parse("2.0.0"), FeedTestData.Artifact);

        Assert.Equal(UpdateStatus.DowngradeBlocked, decision.Status);
        Assert.False(decision.ShouldInstall);
    }

    [Fact]
    public void EqualVersionIsUpToDate()
    {
        var pinnedKey = Ed25519UpdateKeyPair.Generate();
        var feed = FeedTestData.Write(
            FeedFormat.Json, FeedTestData.Descriptor(pinnedKey, FeedTestData.Artifact, version: "1.4.2"));

        var decision = VerifierFor(pinnedKey)
            .Decide(feed, FeedFormat.Json, UpdateVersion.Parse("1.4.2"), FeedTestData.Artifact);

        Assert.Equal(UpdateStatus.UpToDate, decision.Status);
        Assert.False(decision.ShouldInstall);
    }

    [Fact]
    public void MalformedFeedVersionIsRejected()
    {
        var pinnedKey = Ed25519UpdateKeyPair.Generate();
        var descriptor = FeedTestData.Descriptor(pinnedKey, FeedTestData.Artifact) with { Version = "not-a-version" };
        var feed = JsonFeedWriter.Write(descriptor);

        var decision = VerifierFor(pinnedKey).Decide(feed, FeedFormat.Json, Installed, FeedTestData.Artifact);

        Assert.Equal(UpdateStatus.Rejected, decision.Status);
        Assert.Equal(RejectionReason.MalformedFeedVersion, decision.Reason);
    }

    // ── Integrity metadata ───────────────────────────────────────────────────

    [Fact]
    public void Sha256MismatchIsRejected()
    {
        var pinnedKey = Ed25519UpdateKeyPair.Generate();
        var descriptor = FeedTestData.Descriptor(pinnedKey, FeedTestData.Artifact) with
        {
            Sha256 = new string('a', 64), // wrong but well-formed hex
        };
        var feed = JsonFeedWriter.Write(descriptor);

        var decision = VerifierFor(pinnedKey).Decide(feed, FeedFormat.Json, Installed, FeedTestData.Artifact);

        Assert.Equal(UpdateStatus.Rejected, decision.Status);
        Assert.Equal(RejectionReason.Sha256Mismatch, decision.Reason);
    }

    [Fact]
    public void LengthMismatchIsRejected()
    {
        var pinnedKey = Ed25519UpdateKeyPair.Generate();
        var descriptor = FeedTestData.Descriptor(pinnedKey, FeedTestData.Artifact) with
        {
            Length = FeedTestData.Artifact.Length + 1,
        };
        var feed = JsonFeedWriter.Write(descriptor);

        var decision = VerifierFor(pinnedKey).Decide(feed, FeedFormat.Json, Installed, FeedTestData.Artifact);

        Assert.Equal(UpdateStatus.Rejected, decision.Status);
        Assert.Equal(RejectionReason.LengthMismatch, decision.Reason);
    }

    [Fact]
    public void MissingSignatureIsRejected()
    {
        var pinnedKey = Ed25519UpdateKeyPair.Generate();
        var descriptor = FeedTestData.Descriptor(pinnedKey, FeedTestData.Artifact) with
        {
            EdSignatureBase64 = "",
        };
        var feed = JsonFeedWriter.Write(descriptor);

        var decision = VerifierFor(pinnedKey).Decide(feed, FeedFormat.Json, Installed, FeedTestData.Artifact);

        Assert.Equal(UpdateStatus.Rejected, decision.Status);
        Assert.Equal(RejectionReason.MissingSignature, decision.Reason);
    }

    [Fact]
    public void MissingSha256IsRejected()
    {
        // A feed that omits sha256 entirely (the release input always emits one,
        // so this is exercised at the manifest/VerifyArtifact layer directly).
        var pinnedKey = Ed25519UpdateKeyPair.Generate();
        var manifest = new UpdateManifest
        {
            Version = "1.4.2",
            Url = "https://dl.openburnbar.app/windows/OpenBurnBar-Setup-1.4.2.msix",
            Length = FeedTestData.Artifact.LongLength,
            Sha256 = null,
            EdSignatureBase64 = pinnedKey.SignBase64(FeedTestData.Artifact),
        };

        var verification = VerifierFor(pinnedKey).VerifyArtifact(manifest, FeedTestData.Artifact);

        Assert.False(verification.Verified);
        Assert.Equal(RejectionReason.MissingSha256, verification.Reason);
    }

    [Fact]
    public void GarbageSignatureBase64IsRejected()
    {
        var pinnedKey = Ed25519UpdateKeyPair.Generate();
        var descriptor = FeedTestData.Descriptor(pinnedKey, FeedTestData.Artifact) with
        {
            EdSignatureBase64 = "!!!not base64!!!",
        };
        var feed = JsonFeedWriter.Write(descriptor);

        var decision = VerifierFor(pinnedKey).Decide(feed, FeedFormat.Json, Installed, FeedTestData.Artifact);

        Assert.Equal(UpdateStatus.Rejected, decision.Status);
        Assert.Equal(RejectionReason.SignatureInvalid, decision.Reason);
    }

    // ── Malformed feed ───────────────────────────────────────────────────────

    [Theory]
    [InlineData(FeedFormat.Appcast, "not xml <<<")]
    [InlineData(FeedFormat.Appcast, "")]
    [InlineData(FeedFormat.Json, "not json")]
    [InlineData(FeedFormat.Json, "{}")]
    public void MalformedFeedFailsClosed(FeedFormat format, string feed)
    {
        var pinnedKey = Ed25519UpdateKeyPair.Generate();

        var decision = VerifierFor(pinnedKey).Decide(feed, format, Installed, FeedTestData.Artifact);

        Assert.Equal(UpdateStatus.Rejected, decision.Status);
        Assert.Equal(RejectionReason.MalformedFeed, decision.Reason);
    }

    // ── Pin plumbing ─────────────────────────────────────────────────────────

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("not-base64")]
    [InlineData("YWJj")] // valid base64, 3 bytes — not 32
    public void TryCreateReturnsNullForBadPinSoHostFailsClosed(string? pin)
    {
        Assert.Null(UpdateFeedVerifier.TryCreate(pin));
    }

    [Fact]
    public void TryCreateSucceedsForValidPin()
    {
        var pinnedKey = Ed25519UpdateKeyPair.Generate();
        var verifier = UpdateFeedVerifier.TryCreate(pinnedKey.PublicKeyBase64);

        Assert.NotNull(verifier);
        Assert.Equal(pinnedKey.PublicKeyBase64, verifier!.PinnedPublicKeyBase64);
    }

    // ── Two-stage API mirrors the real download flow ─────────────────────────

    [Fact]
    public void EvaluateFeedFlagsCandidateWithoutBytes()
    {
        var pinnedKey = Ed25519UpdateKeyPair.Generate();
        var feed = FeedTestData.Write(FeedFormat.Json, FeedTestData.Descriptor(pinnedKey, FeedTestData.Artifact));

        var evaluation = VerifierFor(pinnedKey).EvaluateFeed(feed, FeedFormat.Json, Installed);

        Assert.Equal(FeedEvaluationStatus.CandidateAvailable, evaluation.Status);
        Assert.NotNull(evaluation.Manifest);

        // Then the second stage verifies the downloaded bytes.
        var verification = VerifierFor(pinnedKey).VerifyArtifact(evaluation.Manifest!, FeedTestData.Artifact);
        Assert.True(verification.Verified);
    }
}
