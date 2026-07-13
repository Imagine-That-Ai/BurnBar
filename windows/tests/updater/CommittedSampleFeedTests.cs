using System;
using System.IO;
using OpenBurnBar.Updater.Core.Feed;
using OpenBurnBar.Updater.Core.Verification;
using OpenBurnBar.Updater.Core.Versioning;
using Xunit;

namespace OpenBurnBar.Updater.Tests;

/// <summary>
/// Proves the ACTUAL committed sample feed under
/// windows/packaging/updater/feed is a genuine, pin-verifiable feed — not a
/// decorative template. The fixtures are LINKED (not copied) from that
/// directory, so this test verifies exactly what ships.
/// </summary>
public sealed class CommittedSampleFeedTests
{
    private static readonly UpdateVersion Installed = UpdateVersion.Parse("1.0.0");

    private static string FixturePath(string name) =>
        Path.Combine(AppContext.BaseDirectory, "Fixtures", name);

    private static string PinnedKey() => File.ReadAllText(FixturePath("pinned-update-key.pub")).Trim();

    private static byte[] Artifact() => File.ReadAllBytes(FixturePath("sample-artifact.txt"));

    private static UpdateFeedVerifier Verifier()
    {
        var verifier = UpdateFeedVerifier.TryCreate(PinnedKey());
        Assert.NotNull(verifier);
        return verifier!;
    }

    [Theory]
    [InlineData("appcast-windows.xml", FeedFormat.Appcast)]
    [InlineData("latest-windows.json", FeedFormat.Json)]
    public void CommittedFeedVerifiesToUpdateAvailable(string fixture, FeedFormat format)
    {
        var feed = File.ReadAllText(FixturePath(fixture));

        var decision = Verifier().Decide(feed, format, Installed, Artifact());

        Assert.Equal(UpdateStatus.UpdateAvailable, decision.Status);
        Assert.True(decision.ShouldInstall);
        Assert.Equal("1.4.2", decision.Manifest!.Version);
    }

    [Fact]
    public void AppcastAndJsonAgreeOnTheCommittedRelease()
    {
        var fromXml = AppcastFeedReader.TryParse(File.ReadAllText(FixturePath("appcast-windows.xml")));
        var fromJson = JsonFeedReader.TryParse(File.ReadAllText(FixturePath("latest-windows.json")));

        Assert.NotNull(fromXml);
        Assert.NotNull(fromJson);
        Assert.Equal(fromXml!.Version, fromJson!.Version);
        Assert.Equal(fromXml.Sha256, fromJson.Sha256);
        Assert.Equal(fromXml.EdSignatureBase64, fromJson.EdSignatureBase64);
        Assert.Equal(fromXml.DescriptorSignatureBase64, fromJson.DescriptorSignatureBase64);
        Assert.Equal(fromXml.Channel, fromJson.Channel);
        Assert.Equal(fromXml.Length, fromJson.Length);
    }

    [Fact]
    public void OneByteArtifactEditFlipsCommittedFeedToRejected()
    {
        var feed = File.ReadAllText(FixturePath("latest-windows.json"));
        var tampered = Artifact();
        tampered[0] ^= 0x01;

        var decision = Verifier().Decide(feed, FeedFormat.Json, Installed, tampered);

        Assert.Equal(UpdateStatus.Rejected, decision.Status);
        // Byte length is unchanged, so it trips the SHA-256 check first.
        Assert.Equal(RejectionReason.Sha256Mismatch, decision.Reason);
    }

    [Fact]
    public void CommittedArtifactIsLfByteStable_SoThePinnedFeedVerifiesOnEveryPlatform()
    {
        // Regression guard for the Windows CRLF hazard. The feed's length / sha256 /
        // Ed25519 signature are all computed over the EXACT bytes of sample-artifact.txt.
        // If git autocrlf rewrote LF -> CRLF on checkout, the artifact would grow and the
        // verifier would fail LengthMismatch-first, flipping every CommittedSampleFeed test
        // red on Windows while it stayed green on macOS. .gitattributes now pins the fixture
        // to LF on all platforms; assert the checked-out bytes are actually unconverted here,
        // so a future autocrlf regression fails THIS test with a self-explaining message
        // instead of a cryptic wrong-RejectionReason four tests over.
        var artifact = Artifact();
        Assert.DoesNotContain((byte)'\r', artifact);

        var declaredLength = JsonFeedReader.TryParse(File.ReadAllText(FixturePath("latest-windows.json")))!.Length;
        Assert.NotNull(declaredLength);
        Assert.Equal(declaredLength!.Value, (long)artifact.Length);
    }

    [Fact]
    public void CommittedFeedIsRejectedUnderADifferentPin()
    {
        // Sanity: the committed signature is bound to the committed pin. A
        // different pinned key must reject the very same feed + artifact.
        var otherPin = OpenBurnBar.Updater.Core.Crypto.Ed25519UpdateKeyPair.Generate().PublicKeyBase64;
        var verifier = UpdateFeedVerifier.TryCreate(otherPin)!;

        var decision = verifier.Decide(
            File.ReadAllText(FixturePath("latest-windows.json")), FeedFormat.Json, Installed, Artifact());

        Assert.Equal(UpdateStatus.Rejected, decision.Status);
        Assert.Equal(RejectionReason.SignatureInvalid, decision.Reason);
    }
}
