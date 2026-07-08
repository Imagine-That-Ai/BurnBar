using System;
using System.Linq;
using OpenBurnBar.Integrations.SmartHub.Discovery;
using Xunit;

namespace OpenBurnBar.Integrations.Tests;

public class MdnsAdvertisementTests
{
    private static MdnsService HubService() => new(
        InstanceName: "OpenBurnBar Mac",
        ServiceType: MdnsAdvertisement.SmartHubServiceType,
        HostName: "mac.local",
        Port: 8787,
        Ipv4: "192.168.1.50",
        TxtEntries: new[] { "path=/render.html", "tp=rolling5h" });

    [Fact]
    public void Advertisement_HasPtrAnswerAndSrvTxtAAdditionals()
    {
        var parsed = DnsMessage.Parse(MdnsAdvertisement.BuildAdvertisementBytes(HubService()));

        Assert.Equal(DnsMessage.ResponseFlags, parsed.Flags);
        var ptr = Assert.Single(parsed.Answers);
        Assert.Equal("_openburnbar-hub._tcp.local", ptr.Name);
        Assert.Equal("OpenBurnBar Mac._openburnbar-hub._tcp.local", ptr.PtrTarget);

        Assert.Contains(parsed.Additionals, r => r.Srv is { Port: 8787, Target: "mac.local" });
        Assert.Contains(parsed.Additionals, r => r.ATarget == "192.168.1.50");
        Assert.Contains(parsed.Additionals, r => r.TxtEntries is not null && r.TxtEntries.Contains("path=/render.html"));
    }

    [Fact]
    public void ParseBrowseResponse_ResolvesInstance()
    {
        var bytes = MdnsAdvertisement.BuildAdvertisementBytes(HubService());
        var instance = Assert.Single(MdnsAdvertisement.ParseBrowseResponse(bytes));

        Assert.Equal("OpenBurnBar Mac._openburnbar-hub._tcp.local", instance.InstanceFqdn);
        Assert.Equal("OpenBurnBar Mac", instance.InstanceName);
        Assert.Equal("_openburnbar-hub._tcp.local", instance.ServiceTypeName);
        Assert.Equal("mac.local", instance.Host);
        Assert.Equal((ushort)8787, instance.Port);
        Assert.Equal(new[] { "192.168.1.50" }, instance.Ipv4Addresses);
        Assert.Contains("tp=rolling5h", instance.TxtEntries);
    }

    [Fact]
    public void ExtractAwtrixHosts_FiltersByAwtrixPrefix()
    {
        var awtrix = new MdnsService(
            InstanceName: "awtrix_3f21",
            ServiceType: MdnsAdvertisement.HttpServiceType,
            HostName: "awtrix.local",
            Port: 80,
            Ipv4: "192.168.1.60",
            TxtEntries: Array.Empty<string>());

        var hosts = MdnsAdvertisement.ExtractAwtrixHosts(MdnsAdvertisement.BuildAdvertisementBytes(awtrix));
        Assert.Equal(new[] { "192.168.1.60" }, hosts);

        // A non-AWTRIX _http._tcp service is ignored.
        var other = new MdnsService(
            InstanceName: "printer",
            ServiceType: MdnsAdvertisement.HttpServiceType,
            HostName: "printer.local",
            Port: 80,
            Ipv4: "192.168.1.61",
            TxtEntries: Array.Empty<string>());
        Assert.Empty(MdnsAdvertisement.ExtractAwtrixHosts(MdnsAdvertisement.BuildAdvertisementBytes(other)));
    }

    [Fact]
    public void ExtractAwtrixHosts_RejectsNonLanAddresses()
    {
        var loopback = new MdnsService(
            InstanceName: "awtrix_loop",
            ServiceType: MdnsAdvertisement.HttpServiceType,
            HostName: "awtrix.local",
            Port: 80,
            Ipv4: "127.0.0.1",
            TxtEntries: Array.Empty<string>());
        Assert.Empty(MdnsAdvertisement.ExtractAwtrixHosts(MdnsAdvertisement.BuildAdvertisementBytes(loopback)));
    }

    [Fact]
    public void BuildAdvertisement_RejectsInstanceNameWithDot()
    {
        var bad = HubService() with { InstanceName = "bad.name" };
        Assert.Throws<ArgumentException>(() => MdnsAdvertisement.BuildAdvertisement(bad));
    }
}
