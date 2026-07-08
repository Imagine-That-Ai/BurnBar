using System;
using System.Collections.Generic;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using OpenBurnBar.Integrations.SmartHub.Discovery;

namespace OpenBurnBar.Integrations.SmartHub.Net;

// Live LAN interface enumeration feeding the pure Ipv4Subnet math.
//
// Parity: the getifaddrs half of LocalNetworkDiscovery. It surfaces each usable
// up/running non-loopback IPv4 interface's (address, netmask) plus a preferred
// address and the host name; all subnet-candidate + dashboard-URL derivation
// stays in the tested portable core.

public sealed class NetworkInterfaceLanEnumerator : ILanInterfaceEnumerator
{
    public IReadOnlyList<Ipv4InterfaceInput> Enumerate()
    {
        var results = new List<Ipv4InterfaceInput>();
        foreach (var nic in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (nic.OperationalStatus != OperationalStatus.Up ||
                nic.NetworkInterfaceType == NetworkInterfaceType.Loopback ||
                !Ipv4Subnet.IsUsableLanInterfaceName(nic.Name))
            {
                continue;
            }

            foreach (var addr in nic.GetIPProperties().UnicastAddresses)
            {
                if (addr.Address.AddressFamily != AddressFamily.InterNetwork)
                {
                    continue;
                }
                var address = addr.Address.ToString();
                if (!Ipv4Subnet.IsUsableLanIpv4(address))
                {
                    continue;
                }
                var netmask = NetmaskString(addr);
                if (netmask is not null)
                {
                    results.Add(new Ipv4InterfaceInput(address, netmask));
                }
            }
        }
        return results;
    }

    public string? PreferredLanAddress()
    {
        var interfaces = Enumerate();
        return interfaces.Count > 0 ? interfaces[0].Address : null;
    }

    public string? LocalHostName()
    {
        try
        {
            return Dns.GetHostName();
        }
        catch (SocketException)
        {
            return null;
        }
    }

    private static string? NetmaskString(UnicastIPAddressInformation addr)
    {
        // IPv4Mask is populated on most platforms; fall back to deriving from the
        // prefix length when the runtime leaves it as None.
        var mask = addr.IPv4Mask;
        if (mask is not null && !mask.Equals(IPAddress.None) && mask.AddressFamily == AddressFamily.InterNetwork)
        {
            var octets = mask.GetAddressBytes();
            if (octets.Length == 4 && (octets[0] | octets[1] | octets[2] | octets[3]) != 0)
            {
                return mask.ToString();
            }
        }

        var prefix = addr.PrefixLength;
        if (prefix is > 0 and <= 32)
        {
            uint bits = prefix == 32 ? 0xFFFFFFFFu : ~(0xFFFFFFFFu >> prefix);
            return Ipv4Subnet.DottedIpv4(bits);
        }
        return null;
    }
}
