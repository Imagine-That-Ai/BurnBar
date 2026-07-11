using OpenBurnBar.Updater.Core.Crypto;
using OpenBurnBar.Updater.Core.Feed;
using Xunit;

namespace OpenBurnBar.Updater.Tests;

public sealed class FeedReaderTests
{
    // ── Appcast XML ────────────────────────────────────────────────────────

    [Fact]
    public void AppcastParsesAllFields()
    {
        var keyPair = Ed25519UpdateKeyPair.Generate();
        var xml = FeedTestData.Write(
            FeedFormat.Appcast, FeedTestData.Descriptor(keyPair, FeedTestData.Artifact, critical: true));

        var manifest = AppcastFeedReader.TryParse(xml);

        Assert.NotNull(manifest);
        Assert.Equal("1.4.2", manifest!.Version);
        Assert.Equal("1420", manifest.Build);
        Assert.Equal(FeedTestData.Artifact.LongLength, manifest.Length);
        Assert.Equal(Sha256Digest.HexOf(FeedTestData.Artifact), manifest.Sha256);
        Assert.False(string.IsNullOrEmpty(manifest.EdSignatureBase64));
        Assert.True(manifest.Critical);
        Assert.Equal("10.0.19041", manifest.MinimumSystemVersion);
        Assert.StartsWith("https://", manifest.Url);
    }

    [Fact]
    public void AppcastSelectsHighestVersionedItem()
    {
        var xml = """
            <?xml version="1.0" encoding="utf-8"?>
            <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
              <channel>
                <item>
                  <sparkle:shortVersionString>1.2.0</sparkle:shortVersionString>
                  <enclosure url="https://x/old.msix" length="10" type="application/msix" sparkle:sha256="aa" sparkle:edSignature="sig1" />
                </item>
                <item>
                  <sparkle:shortVersionString>1.9.0</sparkle:shortVersionString>
                  <enclosure url="https://x/new.msix" length="20" type="application/msix" sparkle:sha256="bb" sparkle:edSignature="sig2" />
                </item>
                <item>
                  <sparkle:shortVersionString>1.5.0</sparkle:shortVersionString>
                  <enclosure url="https://x/mid.msix" length="15" type="application/msix" sparkle:sha256="cc" sparkle:edSignature="sig3" />
                </item>
              </channel>
            </rss>
            """;

        var manifest = AppcastFeedReader.TryParse(xml);

        Assert.NotNull(manifest);
        Assert.Equal("1.9.0", manifest!.Version);
        Assert.Equal("https://x/new.msix", manifest.Url);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("<rss><channel><item></item></channel></rss>")] // no enclosure/version
    [InlineData("<rss><channel><item><enclosure url=\"https://x\"/></item></channel></rss>")] // no version
    [InlineData("this is not xml <<<")]
    [InlineData("<rss><channel><item><unclosed></channel></rss>")]
    public void AppcastFailsClosedOnMalformedOrIncomplete(string? xml)
    {
        Assert.Null(AppcastFeedReader.TryParse(xml));
    }

    [Fact]
    public void AppcastRejectsExternalDtdEntity()
    {
        // A classic XXE payload: an external/general entity. DTD processing is
        // prohibited, so parsing must fail closed (null), never resolve the file.
        var xxe = """
            <?xml version="1.0"?>
            <!DOCTYPE rss [ <!ENTITY xxe SYSTEM "file:///etc/passwd"> ]>
            <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
              <channel>
                <item>
                  <sparkle:shortVersionString>9.9.9</sparkle:shortVersionString>
                  <enclosure url="https://x/&xxe;" length="1" type="application/msix" sparkle:edSignature="s"/>
                </item>
              </channel>
            </rss>
            """;

        Assert.Null(AppcastFeedReader.TryParse(xxe));
    }

    // ── JSON companion ─────────────────────────────────────────────────────

    [Fact]
    public void JsonParsesAllFields()
    {
        var keyPair = Ed25519UpdateKeyPair.Generate();
        var json = FeedTestData.Write(
            FeedFormat.Json, FeedTestData.Descriptor(keyPair, FeedTestData.Artifact, critical: true));

        var manifest = JsonFeedReader.TryParse(json);

        Assert.NotNull(manifest);
        Assert.Equal("1.4.2", manifest!.Version);
        Assert.Equal("1420", manifest.Build);
        Assert.Equal(FeedTestData.Artifact.LongLength, manifest.Length);
        Assert.Equal(Sha256Digest.HexOf(FeedTestData.Artifact), manifest.Sha256);
        Assert.False(string.IsNullOrEmpty(manifest.EdSignatureBase64));
        Assert.True(manifest.Critical);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("not json")]
    [InlineData("[]")] // wrong root type
    [InlineData("\"a string\"")] // wrong root type
    [InlineData("{\"version\":\"1.0\"}")] // missing downloadUrl
    [InlineData("{\"downloadUrl\":\"https://x\"}")] // missing version
    public void JsonFailsClosedOnMalformedOrIncomplete(string? json)
    {
        Assert.Null(JsonFeedReader.TryParse(json));
    }

    [Fact]
    public void JsonAcceptsSparkleEdSignatureAlias()
    {
        // The macOS latest-macos.json names the field `sparkleEdSignature`; the
        // reader accepts that alias so the two platforms share tooling.
        var json = """
            { "version": "1.4.2", "downloadUrl": "https://x/a.msix",
              "length": 10, "sha256": "aa", "sparkleEdSignature": "AAAA" }
            """;

        var manifest = JsonFeedReader.TryParse(json);
        Assert.NotNull(manifest);
        Assert.Equal("AAAA", manifest!.EdSignatureBase64);
    }
}
