using System.Collections.Generic;
using System.Linq;
using OpenBurnBar.Integrations.Cast.Discovery;
using OpenBurnBar.Integrations.Cast.Model;
using Xunit;

namespace OpenBurnBar.Integrations.Cast.Tests;

public sealed class CastMdnsTests
{
    // A captured Google Cast mDNS advertisement (a full DNS response with
    // PTR + SRV + TXT + A records and RFC 1035 name compression), for a
    // "Living Room Hub" Nest Hub at 192.168.1.42:8009. Generated from a wire
    // builder and pinned here so the committed parser must decode it exactly.
    private static readonly byte[] CapturedAdvertisement =
    {
        0x00, 0x00, 0x84, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x03, 0x0B, 0x5F, 0x67, 0x6F,
        0x6F, 0x67, 0x6C, 0x65, 0x63, 0x61, 0x73, 0x74, 0x04, 0x5F, 0x74, 0x63, 0x70, 0x05, 0x6C, 0x6F,
        0x63, 0x61, 0x6C, 0x00, 0x00, 0x0C, 0x00, 0x01, 0x00, 0x00, 0x00, 0x78, 0x00, 0x17, 0x14, 0x47,
        0x6F, 0x6F, 0x67, 0x6C, 0x65, 0x2D, 0x4E, 0x65, 0x73, 0x74, 0x2D, 0x48, 0x75, 0x62, 0x2D, 0x31,
        0x32, 0x33, 0x34, 0xC0, 0x0C, 0xC0, 0x2E, 0x00, 0x21, 0x80, 0x01, 0x00, 0x00, 0x00, 0x78, 0x00,
        0x16, 0x00, 0x00, 0x00, 0x00, 0x1F, 0x49, 0x0D, 0x31, 0x32, 0x33, 0x34, 0x61, 0x62, 0x63, 0x64,
        0x2D, 0x35, 0x36, 0x37, 0x38, 0xC0, 0x1D, 0xC0, 0x2E, 0x00, 0x10, 0x80, 0x01, 0x00, 0x00, 0x11,
        0x94, 0x00, 0x3F, 0x13, 0x69, 0x64, 0x3D, 0x61, 0x62, 0x63, 0x64, 0x31, 0x32, 0x33, 0x34, 0x64,
        0x65, 0x61, 0x64, 0x62, 0x65, 0x65, 0x66, 0x12, 0x6D, 0x64, 0x3D, 0x47, 0x6F, 0x6F, 0x67, 0x6C,
        0x65, 0x20, 0x4E, 0x65, 0x73, 0x74, 0x20, 0x48, 0x75, 0x62, 0x12, 0x66, 0x6E, 0x3D, 0x4C, 0x69,
        0x76, 0x69, 0x6E, 0x67, 0x20, 0x52, 0x6F, 0x6F, 0x6D, 0x20, 0x48, 0x75, 0x62, 0x04, 0x63, 0x61,
        0x3D, 0x34, 0xC0, 0x57, 0x00, 0x01, 0x80, 0x01, 0x00, 0x00, 0x00, 0x78, 0x00, 0x04, 0xC0, 0xA8,
        0x01, 0x2A,
    };

    [Fact]
    public void Parse_CapturedAdvertisement_ReconstructsTheDevice()
    {
        var devices = CastMdnsAdvertisement.Parse(CapturedAdvertisement);

        var device = Assert.Single(devices);
        Assert.Equal("Google-Nest-Hub-1234", device.ServiceName);
        Assert.Equal("Living Room Hub", device.FriendlyName);
        Assert.Equal("Google Nest Hub", device.Model);
        Assert.Equal("abcd1234deadbeef", device.Identifier);
        Assert.Equal("192.168.1.42", device.Host);
        Assert.Equal(8009, device.Port);
        Assert.True(device.SupportsDisplay); // ca=4 → video_out bit set
        Assert.Equal(CastIconKind.NestHub, device.IconKind);
    }

    [Fact]
    public void ParseDnsMessage_ExposesTheRecordSections()
    {
        var message = DnsMessage.Parse(CapturedAdvertisement);
        Assert.True(message.IsResponse);
        Assert.Single(message.Answers);
        Assert.Equal(DnsRecordType.Ptr, message.Answers[0].Type);
        Assert.Equal(CastMdnsAdvertisement.ServiceType, message.Answers[0].Name);

        var srv = message.AllRecords().Single(r => r.Type == DnsRecordType.Srv);
        Assert.Equal(8009, srv.SrvPort);
        Assert.Equal("1234abcd-5678.local", srv.SrvTarget);

        var a = message.AllRecords().Single(r => r.Type == DnsRecordType.A);
        Assert.Equal("192.168.1.42", a.AAddress);
    }

    [Fact]
    public void BuildGoogleCastQuery_ProducesAValidPtrQuestion()
    {
        var query = DnsSdBrowseQuery.BuildGoogleCastQuery();
        var message = DnsMessage.Parse(query);

        Assert.False(message.IsResponse);
        var question = Assert.Single(message.Questions);
        Assert.Equal(CastMdnsAdvertisement.ServiceType, question.Name);
        Assert.Equal(DnsRecordType.Ptr, question.Type);
        Assert.Equal(1, question.Class); // IN
    }

    [Fact]
    public void BuildGoogleCastQuery_HeaderIsAStandardSingleQuestionQuery()
    {
        var query = DnsSdBrowseQuery.BuildGoogleCastQuery();
        // id=0, flags=0, qd=1, an=0, ns=0, ar=0
        Assert.Equal(0x00, query[0]);
        Assert.Equal(0x00, query[1]);
        Assert.Equal(0x00, query[2]);
        Assert.Equal(0x00, query[3]);
        Assert.Equal(0x00, query[4]);
        Assert.Equal(0x01, query[5]); // qdcount = 1
    }

    [Theory]
    [InlineData(4, "Nest Mini", "x", true)]     // ca video_out bit forces display
    [InlineData(0, "Google Nest Hub", "x", true)] // "hub"
    [InlineData(0, "Chromecast", "x", true)]      // "chromecast"
    [InlineData(0, "Nest Mini", "x", false)]      // "mini"
    [InlineData(0, "Nest Audio", "x", false)]     // "audio"
    [InlineData(0, "Mystery Cast", "x", true)]    // unknown → allow
    public void InferSupportsDisplay_MatchesTheHeuristic(int ca, string model, string serviceName, bool expected)
        => Assert.Equal(expected, CastCapabilities.InferSupportsDisplay(ca, model, serviceName));

    [Fact]
    public void TxtRecord_FallsBackToServiceNameWhenFieldsAbsent()
    {
        var parsed = CastTxtRecord.Parse(new[] { "ca=1", "rs=" }, "MyCast-9999");
        Assert.Equal("MyCast-9999", parsed.FriendlyName);
        Assert.Equal(CastTxtRecord.DefaultModel, parsed.Model);
        Assert.Equal("MyCast-9999", parsed.Identifier);
        Assert.Equal(1, parsed.CapabilityFlags);
    }

    [Fact]
    public void DiscoveryMerge_KeepsTheHigherScoringDuplicateAndSortsDisplayFirst()
    {
        var sparse = new CastDevice
        {
            ServiceName = "Hub-1",
            FriendlyName = "Hub-1", // no distinct name
            Host = "",              // unresolved
            Port = 8009,
            Model = CastTxtRecord.DefaultModel,
            Identifier = "Hub-1",
            SupportsDisplay = true,
        };
        var rich = sparse with
        {
            FriendlyName = "Kitchen Hub",
            Host = "192.168.1.5",
            Model = "Google Nest Hub",
            Identifier = "uuid-1",
        };
        var speaker = new CastDevice
        {
            ServiceName = "Speaker-2",
            FriendlyName = "Bedroom Speaker",
            Host = "192.168.1.6",
            Port = 8009,
            Model = "Nest Mini",
            Identifier = "uuid-2",
            SupportsDisplay = false,
        };

        var merged = CastDiscoveryMerge.Merge(new[] { sparse, rich, speaker });

        Assert.Equal(2, merged.Count);
        // Display-capable ("Kitchen Hub") sorts before the audio-only speaker.
        Assert.Equal("Kitchen Hub", merged[0].FriendlyName);
        Assert.Equal("192.168.1.5", merged[0].Host); // the richer duplicate won
        Assert.Equal("Bedroom Speaker", merged[1].FriendlyName);
    }

    [Fact]
    public void DiscoveryScore_RewardsCompleteness()
    {
        var bare = new CastDevice
        {
            ServiceName = "X",
            FriendlyName = "X",
            Host = "",
            Port = 8009,
            Model = CastTxtRecord.DefaultModel,
            Identifier = "X",
        };
        var full = bare with
        {
            FriendlyName = "Living Room",
            Host = "10.0.0.2",
            Model = "Google Nest Hub Max",
            Identifier = "uuid",
        };

        Assert.Equal(0, CastDiscoveryMerge.Score(bare));
        Assert.Equal(4 + 2 + 1 + 1, CastDiscoveryMerge.Score(full));
    }
}
