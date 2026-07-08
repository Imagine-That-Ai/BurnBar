using System.Collections.Generic;
using System.Linq;
using OpenBurnBar.Integrations.SmartHub.Discovery;
using Xunit;

namespace OpenBurnBar.Integrations.Tests;

public class Ipv4SubnetTests
{
    [Fact]
    public void SubnetCandidates_Slash24_EnumeratesHostRange()
    {
        var interfaces = new[] { new Ipv4InterfaceInput("192.168.1.10", "255.255.255.0") };
        var hosts = Ipv4Subnet.SubnetCandidates(interfaces);
        Assert.Equal(254, hosts.Count);
        Assert.Contains("192.168.1.1", hosts);
        Assert.Contains("192.168.1.254", hosts);
        Assert.DoesNotContain("192.168.1.0", hosts);   // network
        Assert.DoesNotContain("192.168.1.255", hosts);  // broadcast
    }

    [Fact]
    public void SubnetCandidates_PinnedHostsComeFirst()
    {
        var interfaces = new[] { new Ipv4InterfaceInput("192.168.1.10", "255.255.255.0") };
        var hosts = Ipv4Subnet.SubnetCandidates(interfaces, new[] { "10.0.0.5" });
        Assert.Equal("10.0.0.5", hosts[0]);
    }

    [Fact]
    public void ClassCCandidates_Produces254Hosts()
    {
        var hosts = Ipv4Subnet.ClassCCandidates(new[] { "192.168.1.10" });
        Assert.Equal(254, hosts.Count);
        Assert.Contains("192.168.1.200", hosts);
    }

    [Theory]
    [InlineData("192.168.1.5", true)]
    [InlineData("10.0.0.1", true)]
    [InlineData("127.0.0.1", false)]
    [InlineData("0.0.0.0", false)]
    [InlineData("169.254.1.1", false)]
    [InlineData("100.64.0.1", false)]  // CGNAT / Tailscale
    [InlineData("100.128.0.1", true)]  // outside CGNAT range
    [InlineData("256.1.1.1", false)]
    [InlineData("not.an.ip", false)]
    public void IsUsableLanIpv4(string address, bool expected)
    {
        Assert.Equal(expected, Ipv4Subnet.IsUsableLanIpv4(address));
    }

    [Theory]
    [InlineData("en0", true)]
    [InlineData("eth0", true)]
    [InlineData("utun3", false)]
    [InlineData("ipsec0", false)]
    [InlineData("awdl0", false)]
    [InlineData("bridge100", false)]
    [InlineData("", false)]
    public void IsUsableLanInterfaceName(string name, bool expected)
    {
        Assert.Equal(expected, Ipv4Subnet.IsUsableLanInterfaceName(name));
    }

    [Fact]
    public void Ipv4Value_And_DottedIpv4_RoundTrip()
    {
        Assert.Equal(0xC0A80105u, Ipv4Subnet.Ipv4Value("192.168.1.5"));
        Assert.Equal("192.168.1.5", Ipv4Subnet.DottedIpv4(0xC0A80105u));
        Assert.Null(Ipv4Subnet.Ipv4Value("1.2.3"));
        Assert.Null(Ipv4Subnet.Ipv4Value("300.1.1.1"));
    }

    [Fact]
    public void Unique_PreservesFirstOccurrenceOrder()
    {
        Assert.Equal(new[] { 1, 2, 3 }, Ipv4Subnet.Unique(new[] { 1, 2, 2, 3, 1 }).ToArray());
    }

    [Fact]
    public void DashboardUrlCandidates_ComposesLanHostAndLocalhost()
    {
        var urls = Ipv4Subnet.DashboardUrlCandidates("192.168.1.5", "Alberto's Mac", 8787, "/render.html");
        Assert.Contains("http://192.168.1.5:8787/render.html", urls);
        Assert.Contains("http://albertos-mac.local:8787/render.html", urls);
        Assert.Contains("http://127.0.0.1:8787/render.html", urls);
    }

    [Fact]
    public void ClassCPrefix()
    {
        Assert.Equal("192.168.1", Ipv4Subnet.ClassCPrefix("192.168.1.42"));
        Assert.Null(Ipv4Subnet.ClassCPrefix("1.2.3"));
    }
}
