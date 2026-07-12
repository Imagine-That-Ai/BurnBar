// Strict feed JSON (de)serialization (Phase 5 · signed distribution).

using System.Linq;
using OpenBurnBar.Dist.UpdateFeed;
using Xunit;

namespace OpenBurnBar.Dist.Tests;

public sealed class UpdateFeedJsonTests
{
    private static UpdateFeedDocument SampleFeed()
    {
        var keys = DistTestSupport.NewKeyPair();
        var x64 = DistTestSupport.Sign(DistTestSupport.SampleEntry(platform: UpdatePlatform.WinX64), keys);
        var arm = DistTestSupport.Sign(DistTestSupport.SampleEntry(platform: UpdatePlatform.WinArm64), keys);
        return new UpdateFeedDocument
        {
            GeneratedAtUtc = new System.DateTimeOffset(2026, 7, 4, 1, 2, 3, System.TimeSpan.Zero),
            Entries = new[] { x64, arm },
        };
    }

    [Fact]
    public void Serialize_ThenParse_RoundTrips()
    {
        var feed = SampleFeed();
        var json = UpdateFeedJson.Serialize(feed);

        Assert.True(UpdateFeedJson.TryParse(json, out var parsed, out var error), error);
        Assert.NotNull(parsed);
        Assert.Equal(feed.Entries.Count, parsed!.Entries.Count);
        Assert.Equal(feed.Entries[0].Version, parsed.Entries[0].Version);
        Assert.Equal(feed.Entries[0].Platform, parsed.Entries[0].Platform);
        Assert.Equal(feed.Entries[0].Signature, parsed.Entries[0].Signature);
        Assert.Equal(feed.Entries[1].Platform, parsed.Entries[1].Platform);
    }

    [Fact]
    public void ParsedEntry_StillVerifiesUnderPinnedKey()
    {
        // A round-tripped signature must still authenticate — proves JSON escaping (e.g. '+' in
        // base64) does not corrupt the signature bytes.
        var keys = DistTestSupport.NewKeyPair();
        var signed = DistTestSupport.Sign(DistTestSupport.SampleEntry(), keys);
        var feed = new UpdateFeedDocument { Entries = new[] { signed } };

        Assert.True(UpdateFeedJson.TryParse(UpdateFeedJson.Serialize(feed), out var parsed, out _));
        var entry = parsed!.Entries.Single();
        Assert.True(DistTestSupport.VerifierFor(keys).VerifyDescriptor(entry).IsAuthentic);
    }

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("not json")]
    [InlineData("[]")]
    [InlineData("{\"schemaVersion\":1}")]
    public void MalformedFeed_FailsClosed(string json)
    {
        Assert.False(UpdateFeedJson.TryParse(json, out var parsed, out var error));
        Assert.Null(parsed);
        Assert.NotEmpty(error);
    }

    [Fact]
    public void MissingRequiredEntryField_FailsClosed()
    {
        // A feed whose sole entry omits "sha256".
        const string json = """
        {
          "schemaVersion": 1,
          "feed": "openburnbar-windows",
          "generatedAtUtc": "2026-07-04T00:00:00Z",
          "entries": [
            {
              "version": "1.0.28",
              "platform": "win-x64",
              "channel": "stable",
              "url": "https://dl.openburnbar.dev/x.zip",
              "sizeBytes": 10,
              "publishedAtUtc": "2026-07-04T00:00:00Z",
              "ed25519Signature": "AAAA"
            }
          ]
        }
        """;
        Assert.False(UpdateFeedJson.TryParse(json, out _, out var error));
        Assert.Contains("sha256", error);
    }

    [Fact]
    public void UnknownPlatformToken_FailsClosed()
    {
        const string json = """
        {
          "schemaVersion": 1,
          "feed": "openburnbar-windows",
          "generatedAtUtc": "2026-07-04T00:00:00Z",
          "entries": [
            {
              "version": "1.0.28",
              "platform": "win-riscv",
              "channel": "stable",
              "url": "https://dl.openburnbar.dev/x.zip",
              "sizeBytes": 10,
              "sha256": "26e7da660aecb7e1d8cd19ace3abfcac87ce476bb87b5cbecca438dbc085992c",
              "publishedAtUtc": "2026-07-04T00:00:00Z",
              "ed25519Signature": "AAAA"
            }
          ]
        }
        """;
        Assert.False(UpdateFeedJson.TryParse(json, out _, out var error));
        Assert.Contains("platform", error);
    }

    [Fact]
    public void UnknownExtraProperties_AreIgnored()
    {
        const string json = """
        {
          "schemaVersion": 1,
          "feed": "openburnbar-windows",
          "generatedAtUtc": "2026-07-04T00:00:00Z",
          "futureField": {"nested": true},
          "entries": [
            {
              "version": "1.0.28",
              "platform": "win-x64",
              "channel": "stable",
              "url": "https://dl.openburnbar.dev/x.zip",
              "sizeBytes": 10,
              "sha256": "26e7da660aecb7e1d8cd19ace3abfcac87ce476bb87b5cbecca438dbc085992c",
              "minimumOsBuild": 17763,
              "critical": false,
              "publishedAtUtc": "2026-07-04T00:00:00Z",
              "releaseNotesUrl": "",
              "ed25519Signature": "AAAA",
              "unknownEntryField": 42
            }
          ]
        }
        """;
        Assert.True(UpdateFeedJson.TryParse(json, out var parsed, out var error), error);
        Assert.Single(parsed!.Entries);
    }
}
