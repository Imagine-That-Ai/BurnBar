using System;
using System.Net;
using OpenBurnBar.CloudSync.AppCheck.Windows;
using Xunit;

namespace OpenBurnBar.CloudSync.AppCheck.Windows.Tests;

public sealed class TrustedProxyAddressParserTests
{
    [Fact]
    public void Empty_configuration_disables_forwarded_header_trust()
    {
        Assert.Empty(TrustedProxyAddressParser.Parse(null));
        Assert.Empty(TrustedProxyAddressParser.Parse("   "));
    }

    [Fact]
    public void Parses_exact_IPv4_and_IPv6_proxy_addresses()
    {
        var parsed = TrustedProxyAddressParser.Parse("10.0.0.4, 2001:db8::17");

        Assert.Equal(new[] { IPAddress.Parse("10.0.0.4"), IPAddress.Parse("2001:db8::17") }, parsed);
    }

    [Fact]
    public void Invalid_or_CIDR_proxy_entries_fail_closed()
    {
        Assert.Throws<InvalidOperationException>(() =>
            TrustedProxyAddressParser.Parse("proxy.internal"));
        Assert.Throws<InvalidOperationException>(() =>
            TrustedProxyAddressParser.Parse("10.0.0.0/24"));
    }
}
