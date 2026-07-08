using System;
using System.Collections.Generic;

namespace OpenBurnBar.Integrations.SmartHub.Discovery;

// Portable IPv4 / subnet-candidate + LAN-usability math.
//
// Parity: AgentLens/Services/SmartHub/LocalNetworkDiscovery.swift
//   subnetCandidates / classCCandidates / isUsableLANIPv4 /
//   isUsableLANInterfaceName / ipv4Value(from:String) / dottedIPv4 /
//   classCPrefix / unique / dashboardURLCandidates.
//
// The getifaddrs/getnameinfo interface enumeration + the Bonjour browser are
// platform I/O and live in the Net adapter; everything here is pure arithmetic
// over interface (address, netmask) tuples, so it is proven off-Windows.

public sealed record Ipv4InterfaceInput(string Address, string Netmask);

public static class Ipv4Subnet
{
    /// Enumerates candidate hosts on each interface's subnet (bounded to /21 or
    /// smaller; larger subnets fall back to a /24 sweep), pinned hosts first.
    /// Parity: Swift `subnetCandidates(localIPv4Interfaces:pinnedHosts:)`.
    public static IReadOnlyList<string> SubnetCandidates(
        IReadOnlyList<Ipv4InterfaceInput> interfaces,
        IReadOnlyList<string>? pinnedHosts = null)
    {
        var hosts = new List<string>();
        foreach (var host in pinnedHosts ?? Array.Empty<string>())
        {
            var trimmed = host.Trim();
            if (IsUsableLanIpv4(trimmed))
            {
                hosts.Add(trimmed);
            }
        }

        foreach (var iface in interfaces)
        {
            if (!IsUsableLanIpv4(iface.Address) ||
                Ipv4Value(iface.Address) is not { } addressValue ||
                Ipv4Value(iface.Netmask) is not { } netmaskValue)
            {
                continue;
            }

            var mask = netmaskValue;
            var network = addressValue & mask;
            var broadcast = network | ~mask;
            if (broadcast <= network + 1)
            {
                continue;
            }

            var hostCount = broadcast - network - 1;
            if (hostCount <= 2048)
            {
                for (var value = network + 1; value < broadcast; value++)
                {
                    hosts.Add(DottedIpv4(value));
                }
            }
            else if (ClassCPrefix(iface.Address) is { } prefix)
            {
                for (var suffix = 1; suffix <= 254; suffix++)
                {
                    hosts.Add($"{prefix}.{suffix}");
                }
            }
        }

        return Unique(hosts);
    }

    /// Parity: Swift `classCCandidates(localIPv4Addresses:pinnedHosts:)`.
    public static IReadOnlyList<string> ClassCCandidates(
        IReadOnlyList<string> localIPv4Addresses,
        IReadOnlyList<string>? pinnedHosts = null)
    {
        var hosts = new List<string>();
        foreach (var host in pinnedHosts ?? Array.Empty<string>())
        {
            var trimmed = host.Trim();
            if (IsUsableLanIpv4(trimmed))
            {
                hosts.Add(trimmed);
            }
        }

        foreach (var address in localIPv4Addresses)
        {
            if (!IsUsableLanIpv4(address) || ClassCPrefix(address) is not { } prefix)
            {
                continue;
            }
            for (var suffix = 1; suffix <= 254; suffix++)
            {
                hosts.Add($"{prefix}.{suffix}");
            }
        }

        return Unique(hosts);
    }

    /// Parity: Swift `dashboardURLCandidates(port:path:)` — LAN IP, hostname.local,
    /// and localhost. The preferred address + host name are enumerated by the
    /// platform adapter and passed in.
    public static IReadOnlyList<string> DashboardUrlCandidates(
        string? preferredLanAddress,
        string? localHostName,
        int port = 8787,
        string path = "/render.html")
    {
        var urls = new List<string>();
        if (!string.IsNullOrEmpty(preferredLanAddress))
        {
            urls.Add($"http://{preferredLanAddress}:{port}{path}");
        }
        if (!string.IsNullOrEmpty(localHostName))
        {
            var host = localHostName!
                .ToLowerInvariant()
                .Replace(" ", "-", StringComparison.Ordinal)
                .Replace("'", string.Empty, StringComparison.Ordinal);
            if (host.Length > 0)
            {
                urls.Add($"http://{host}.local:{port}{path}");
            }
        }
        urls.Add($"http://127.0.0.1:{port}{path}");
        return Unique(urls);
    }

    /// Parity: Swift `isUsableLANIPv4(_:)` — rejects loopback / 0.x / link-local /
    /// CGNAT+Tailscale 100.64/10.
    public static bool IsUsableLanIpv4(string address)
    {
        var parts = address.Split('.');
        if (parts.Length != 4)
        {
            return false;
        }
        var octets = new int[4];
        for (var i = 0; i < 4; i++)
        {
            if (!int.TryParse(parts[i], out var octet) || octet < 0 || octet > 255)
            {
                return false;
            }
            octets[i] = octet;
        }
        if (octets[0] == 127 || octets[0] == 0)
        {
            return false;
        }
        if (octets[0] == 169 && octets[1] == 254)
        {
            return false;
        }
        if (octets[0] == 100 && octets[1] >= 64 && octets[1] <= 127)
        {
            return false;
        }
        return true;
    }

    /// Parity: Swift `isUsableLANInterfaceName(_:)` — excludes VPN/tunnel/AWDL/
    /// bridge interfaces.
    public static bool IsUsableLanInterfaceName(string name)
    {
        if (string.IsNullOrEmpty(name))
        {
            return false;
        }
        string[] excluded = { "utun", "ipsec", "ppp", "awdl", "llw", "bridge" };
        foreach (var prefix in excluded)
        {
            if (name.StartsWith(prefix, StringComparison.Ordinal))
            {
                return false;
            }
        }
        return true;
    }

    /// Parity: Swift `ipv4Value(from:String)`.
    public static uint? Ipv4Value(string address)
    {
        var parts = address.Split('.');
        if (parts.Length != 4)
        {
            return null;
        }
        var values = new uint[4];
        for (var i = 0; i < 4; i++)
        {
            if (!uint.TryParse(parts[i], out var value) || value > 255)
            {
                return null;
            }
            values[i] = value;
        }
        return (values[0] << 24) | (values[1] << 16) | (values[2] << 8) | values[3];
    }

    /// Parity: Swift `dottedIPv4(_:)`.
    public static string DottedIpv4(uint value) =>
        $"{(value >> 24) & 0xFF}.{(value >> 16) & 0xFF}.{(value >> 8) & 0xFF}.{value & 0xFF}";

    /// Parity: Swift `classCPrefix(_:)` — the first three octets, or null.
    public static string? ClassCPrefix(string address)
    {
        var parts = address.Split('.');
        return parts.Length == 4 ? $"{parts[0]}.{parts[1]}.{parts[2]}" : null;
    }

    /// Parity: Swift `unique(_:)` — stable de-dup preserving first occurrence.
    public static IReadOnlyList<T> Unique<T>(IEnumerable<T> values)
    {
        var seen = new HashSet<T>();
        var result = new List<T>();
        foreach (var value in values)
        {
            if (seen.Add(value))
            {
                result.Add(value);
            }
        }
        return result;
    }
}
