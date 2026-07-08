// DNS-SD (RFC 6763) browse-query builder for _googlecast._tcp.local. Mirrors the
// PTR question a multicast-DNS browser puts on 224.0.0.251:5353 to enumerate
// Cast services. The Windows adapter can use the OS Dnssd watcher, but building
// the exact query bytes keeps the wire contract provable off-Windows.

using System;
using System.Collections.Generic;
using System.Text;

namespace OpenBurnBar.Integrations.Cast.Discovery;

/// <summary>Builds the multicast-DNS PTR browse query for Cast service discovery.</summary>
public static class DnsSdBrowseQuery
{
    /// <summary>The mDNS multicast group address.</summary>
    public const string MulticastAddress = "224.0.0.251";

    /// <summary>The mDNS UDP port.</summary>
    public const int MulticastPort = 5353;

    /// <summary>
    /// Build a standard mDNS query packet asking for PTR records of
    /// <c>_googlecast._tcp.local</c>. Uses transaction id 0, no flags (a
    /// standard multicast query), one question, class IN.
    /// </summary>
    public static byte[] BuildGoogleCastQuery()
        => Build(CastMdnsAdvertisement.ServiceType, DnsRecordType.Ptr);

    /// <summary>Build an mDNS query for an arbitrary name + qtype.</summary>
    public static byte[] Build(string name, ushort qType)
    {
        if (name is null)
        {
            throw new ArgumentNullException(nameof(name));
        }

        var packet = new List<byte>(32);

        // Header: id=0, flags=0, qd=1, an=0, ns=0, ar=0.
        AppendUInt16(packet, 0);
        AppendUInt16(packet, 0);
        AppendUInt16(packet, 1);
        AppendUInt16(packet, 0);
        AppendUInt16(packet, 0);
        AppendUInt16(packet, 0);

        AppendName(packet, name);
        AppendUInt16(packet, qType);
        AppendUInt16(packet, 1); // QCLASS = IN (QU bit left clear → standard query)

        return packet.ToArray();
    }

    private static void AppendName(List<byte> packet, string name)
    {
        foreach (var label in name.TrimEnd('.').Split('.'))
        {
            if (label.Length == 0)
            {
                continue;
            }

            var bytes = Encoding.UTF8.GetBytes(label);
            if (bytes.Length > 63)
            {
                throw new ArgumentException($"DNS label too long: {label}", nameof(name));
            }

            packet.Add((byte)bytes.Length);
            packet.AddRange(bytes);
        }

        packet.Add(0); // root label terminator
    }

    private static void AppendUInt16(List<byte> packet, ushort value)
    {
        packet.Add((byte)(value >> 8));
        packet.Add((byte)(value & 0xFF));
    }
}
