using System.Collections.Generic;
using OpenBurnBar.Integrations.SmartHub.Discovery;
using Xunit;

namespace OpenBurnBar.Integrations.Tests;

public class DnsNameTests
{
    [Fact]
    public void Encode_ServiceType_ExactBytes()
    {
        var bytes = DnsName.Encode("_http._tcp.local");
        var expected = new byte[]
        {
            0x05, 0x5f, 0x68, 0x74, 0x74, 0x70, // "_http"
            0x04, 0x5f, 0x74, 0x63, 0x70,       // "_tcp"
            0x05, 0x6c, 0x6f, 0x63, 0x61, 0x6c, // "local"
            0x00,
        };
        Assert.Equal(expected, bytes);
    }

    [Fact]
    public void Encode_TrailingDot_IsIgnored()
    {
        Assert.Equal(DnsName.Encode("local"), DnsName.Encode("local."));
    }

    [Fact]
    public void Encode_Root_IsSingleNull()
    {
        Assert.Equal(new byte[] { 0x00 }, DnsName.Encode(""));
    }

    [Fact]
    public void Decode_RoundTrips()
    {
        var bytes = DnsName.Encode("OpenBurnBar._openburnbar-hub._tcp.local");
        var (name, next) = DnsName.Decode(bytes, 0);
        Assert.Equal("OpenBurnBar._openburnbar-hub._tcp.local", name);
        Assert.Equal(bytes.Length, next);
    }

    [Fact]
    public void Decode_FollowsCompressionPointer()
    {
        // "abc.local" at offset 0, then a pointer to the "local" label (offset 4).
        var buffer = new byte[]
        {
            0x03, (byte)'a', (byte)'b', (byte)'c',      // idx 0..3
            0x05, (byte)'l', (byte)'o', (byte)'c', (byte)'a', (byte)'l', // idx 4..9
            0x00,                                        // idx 10
            0xC0, 0x04,                                  // idx 11..12 pointer -> idx 4
        };

        var (name1, next1) = DnsName.Decode(buffer, 0);
        Assert.Equal("abc.local", name1);
        Assert.Equal(11, next1);

        var (name2, next2) = DnsName.Decode(buffer, 11);
        Assert.Equal("local", name2);
        Assert.Equal(13, next2); // after the 2-byte pointer, not after the target
    }
}

public class DnsRecordsTests
{
    [Fact]
    public void ARecord_RoundTripsExactBytes()
    {
        var rdata = DnsRecords.BuildARData("192.168.1.5");
        Assert.Equal(new byte[] { 0xC0, 0xA8, 0x01, 0x05 }, rdata);
        Assert.Equal("192.168.1.5", DnsRecords.ParseARData(rdata));
    }

    [Fact]
    public void TxtRecord_LengthPrefixedEntries()
    {
        var rdata = DnsTxt.BuildRData(new[] { "path=/render.html", "v=3" });
        Assert.Equal((byte)17, rdata[0]);
        Assert.Equal((byte)3, rdata[18]);
        Assert.Equal(new[] { "path=/render.html", "v=3" }, DnsTxt.ParseRData(rdata));
    }

    [Fact]
    public void TxtRecord_Empty_IsSingleNullByte()
    {
        var rdata = DnsTxt.BuildRData(System.Array.Empty<string>());
        Assert.Equal(new byte[] { 0x00 }, rdata);
        Assert.Empty(DnsTxt.ParseRData(rdata));
    }

    [Fact]
    public void SrvRecord_EncodesPriorityWeightPortTarget()
    {
        var rdata = DnsRecords.BuildSrvRData(0, 0, 8787, "mac.local");
        // priority(0) weight(0) port(8787=0x2253) then encoded "mac.local".
        Assert.Equal(new byte[] { 0x00, 0x00, 0x00, 0x00, 0x22, 0x53 }, rdata[..6]);
        var (target, _) = DnsName.Decode(rdata, 6);
        Assert.Equal("mac.local", target);
    }

    [Fact]
    public void BigEndian_ReadWriteRoundTrip()
    {
        var buffer = new List<byte>();
        DnsRecords.WriteUInt16(buffer, 0x2253);
        DnsRecords.WriteUInt32(buffer, 0xDEADBEEF);
        var bytes = buffer.ToArray();
        Assert.Equal((ushort)0x2253, DnsRecords.ReadUInt16(bytes, 0));
        Assert.Equal(0xDEADBEEFu, DnsRecords.ReadUInt32(bytes, 2));
    }
}

public class DnsMessageTests
{
    [Fact]
    public void BrowseQuery_HeaderAndQuestion()
    {
        var bytes = MdnsAdvertisement.BuildBrowseQueryBytes("_openburnbar-hub._tcp", "local");
        // header: id=0, flags=0, qd=1, an=0, ns=0, ar=0
        Assert.Equal(new byte[] { 0x00, 0x00, 0x00, 0x00, 0x00, 0x01 }, bytes[..6]);

        var parsed = DnsMessage.Parse(bytes);
        Assert.Single(parsed.Questions);
        Assert.Equal("_openburnbar-hub._tcp.local", parsed.Questions[0].Name);
        Assert.Equal((ushort)DnsRecordType.Ptr, parsed.Questions[0].Type);
    }

    [Fact]
    public void BuildParse_RoundTripsAllSections()
    {
        var message = new DnsMessage { Id = 0, Flags = DnsMessage.ResponseFlags };
        message.Answers.Add(new DnsResourceRecord("host.local", (ushort)DnsRecordType.A, DnsClass.Internet, 120,
            DnsRecords.BuildARData("10.0.0.7")));
        message.Additionals.Add(new DnsResourceRecord("svc._tcp.local", (ushort)DnsRecordType.Txt, DnsClass.Internet, 120,
            DnsTxt.BuildRData(new[] { "k=v" })));

        var parsed = DnsMessage.Parse(message.Build());
        Assert.Equal(DnsMessage.ResponseFlags, parsed.Flags);
        Assert.Single(parsed.Answers);
        Assert.Equal("10.0.0.7", parsed.Answers[0].ATarget);
        Assert.Single(parsed.Additionals);
        Assert.Equal(new[] { "k=v" }, parsed.Additionals[0].TxtEntries);
    }
}
