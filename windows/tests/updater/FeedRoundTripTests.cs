using OpenBurnBar.Updater.Core.Crypto;
using OpenBurnBar.Updater.Core.Feed;
using Xunit;

namespace OpenBurnBar.Updater.Tests;

public sealed class FeedRoundTripTests
{
    [Theory]
    [InlineData(FeedFormat.Appcast)]
    [InlineData(FeedFormat.Json)]
    public void WriteThenReadPreservesEveryVerifiableField(FeedFormat format)
    {
        var keyPair = Ed25519UpdateKeyPair.Generate();
        var descriptor = FeedTestData.Descriptor(keyPair, FeedTestData.Artifact);

        var feed = FeedTestData.Write(format, descriptor);
        var manifest = format == FeedFormat.Appcast
            ? AppcastFeedReader.TryParse(feed)
            : JsonFeedReader.TryParse(feed);

        Assert.NotNull(manifest);
        Assert.Equal(descriptor.Version, manifest!.Version);
        Assert.Equal(descriptor.Build, manifest.Build);
        Assert.Equal(descriptor.DownloadUrl, manifest.Url);
        Assert.Equal(descriptor.Length, manifest.Length);
        Assert.Equal(descriptor.Sha256, manifest.Sha256);
        Assert.Equal(descriptor.EdSignatureBase64, manifest.EdSignatureBase64);
        Assert.Equal(descriptor.DescriptorSignatureBase64, manifest.DescriptorSignatureBase64);
        Assert.Equal(descriptor.Channel, manifest.Channel);
        Assert.Equal(descriptor.MinimumSystemVersion, manifest.MinimumSystemVersion);
    }

    [Theory]
    [InlineData(FeedFormat.Appcast)]
    [InlineData(FeedFormat.Json)]
    public void NonDefaultChannelRoundTripsAndStillPinVerifies(FeedFormat format)
    {
        // The descriptor signature binds the channel, so a non-default channel
        // MUST survive write -> read or the generator's self-verification (and
        // every client) would reject its own feed.
        var keyPair = Ed25519UpdateKeyPair.Generate();
        var descriptor = FeedTestData.Descriptor(
            keyPair, FeedTestData.Artifact, channel: "beta");

        var feed = FeedTestData.Write(format, descriptor);
        var manifest = format == FeedFormat.Appcast
            ? AppcastFeedReader.TryParse(feed)
            : JsonFeedReader.TryParse(feed);

        Assert.NotNull(manifest);
        Assert.Equal("beta", manifest!.Channel);

        var verifier = new OpenBurnBar.Updater.Core.Verification.UpdateFeedVerifier(keyPair.Verifier());
        var verification = verifier.VerifyArtifact(manifest, FeedTestData.Artifact);
        Assert.True(verification.Verified);
    }

    [Fact]
    public void AppcastAndJsonYieldEquivalentManifests()
    {
        var keyPair = Ed25519UpdateKeyPair.Generate();
        var descriptor = FeedTestData.Descriptor(keyPair, FeedTestData.Artifact, critical: true);

        var fromXml = AppcastFeedReader.TryParse(AppcastFeedWriter.Write(descriptor));
        var fromJson = JsonFeedReader.TryParse(JsonFeedWriter.Write(descriptor));

        Assert.NotNull(fromXml);
        Assert.NotNull(fromJson);
        Assert.Equal(fromXml!.Version, fromJson!.Version);
        Assert.Equal(fromXml.Build, fromJson.Build);
        Assert.Equal(fromXml.Url, fromJson.Url);
        Assert.Equal(fromXml.Length, fromJson.Length);
        Assert.Equal(fromXml.Sha256, fromJson.Sha256);
        Assert.Equal(fromXml.EdSignatureBase64, fromJson.EdSignatureBase64);
        Assert.Equal(fromXml.DescriptorSignatureBase64, fromJson.DescriptorSignatureBase64);
        Assert.Equal(fromXml.Channel, fromJson.Channel);
        Assert.Equal(fromXml.Critical, fromJson.Critical);
    }

    [Fact]
    public void XmlEscapesSpecialCharactersInReleaseNotesUrl()
    {
        var keyPair = Ed25519UpdateKeyPair.Generate();
        var descriptor = FeedTestData.Descriptor(keyPair, FeedTestData.Artifact) with
        {
            ReleaseNotesUrl = "https://x/notes?a=1&b=2&c=<z>",
        };

        var xml = AppcastFeedWriter.Write(descriptor);

        Assert.Contains("&amp;", xml);
        Assert.DoesNotContain("&b=2", xml.Replace("&amp;", string.Empty));
        // The escaped document is still well-formed enough to round-trip.
        Assert.NotNull(AppcastFeedReader.TryParse(xml));
    }
}
