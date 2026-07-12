using System;
using System.Collections.Generic;
using System.Text;

namespace OpenBurnBar.Integrations.SmartHub.Discovery;

// DNS-SD resource-record rdata build + parse (RFC 1035 / 2782 / 6763).
//
// Parity note: NetService/Bonjour on macOS emits these bytes internally, so
// there is no Swift source to diff against — the wire format is the RFC. We
// author the exact rdata for A / PTR / SRV / TXT and parse them back, which the
// test suite pins byte-for-byte.

public enum DnsRecordType : ushort
{
    A = 1,
    Ptr = 12,
    Txt = 16,
    Aaaa = 28,
    Srv = 33,
    Any = 255,
}

public static class DnsClass
{
    public const ushort Internet = 1;

    /// mDNS "cache-flush" bit OR'd into the record's class for unique records
    /// (RFC 6762 §10.2). Questions may OR the top bit to request unicast replies.
    public const ushort CacheFlush = 0x8000;
}

/// A single TXT key/value pair helper.
public static class DnsTxt
{
    /// Builds RFC 6763 §6 TXT rdata: each entry length-prefixed. An empty list
    /// encodes to a single empty string (one 0x00 byte), per §6.1.
    public static byte[] BuildRData(IReadOnlyList<string> entries)
    {
        if (entries.Count == 0)
        {
            return new byte[] { 0x00 };
        }
        var buffer = new List<byte>();
        foreach (var entry in entries)
        {
            var bytes = Encoding.UTF8.GetBytes(entry);
            if (bytes.Length > 255)
            {
                throw new ArgumentException($"TXT entry exceeds 255 bytes: '{entry}'", nameof(entries));
            }
            buffer.Add((byte)bytes.Length);
            buffer.AddRange(bytes);
        }
        return buffer.ToArray();
    }

    /// Parses TXT rdata back into its length-prefixed strings.
    public static IReadOnlyList<string> ParseRData(byte[] rdata)
    {
        var entries = new List<string>();
        var pos = 0;
        while (pos < rdata.Length)
        {
            int len = rdata[pos];
            pos++;
            if (pos + len > rdata.Length)
            {
                throw new FormatException("TXT entry length runs past the rdata end");
            }
            entries.Add(Encoding.UTF8.GetString(rdata, pos, len));
            pos += len;
        }
        // A single empty string ("") is the canonical empty TXT record; surface
        // it as no entries so callers don't see a phantom "".
        if (entries.Count == 1 && entries[0].Length == 0)
        {
            return Array.Empty<string>();
        }
        return entries;
    }
}

public static class DnsRecords
{
    /// A rdata: 4 raw IPv4 octets. Throws on a non-dotted-quad.
    public static byte[] BuildARData(string ipv4)
    {
        var value = Ipv4Subnet.Ipv4Value(ipv4)
            ?? throw new ArgumentException($"Not a dotted-quad IPv4 address: '{ipv4}'", nameof(ipv4));
        return new[]
        {
            (byte)((value >> 24) & 0xFF),
            (byte)((value >> 16) & 0xFF),
            (byte)((value >> 8) & 0xFF),
            (byte)(value & 0xFF),
        };
    }

    public static string ParseARData(byte[] rdata)
    {
        if (rdata.Length != 4)
        {
            throw new FormatException($"A rdata must be 4 bytes, got {rdata.Length}");
        }
        return $"{rdata[0]}.{rdata[1]}.{rdata[2]}.{rdata[3]}";
    }

    /// PTR rdata: an (uncompressed) encoded target name.
    public static byte[] BuildPtrRData(string targetName) => DnsName.Encode(targetName);

    /// SRV rdata (RFC 2782): priority, weight, port (all big-endian u16) + an
    /// (uncompressed) encoded target name.
    public static byte[] BuildSrvRData(ushort priority, ushort weight, ushort port, string target)
    {
        var buffer = new List<byte>(6 + target.Length + 2);
        WriteUInt16(buffer, priority);
        WriteUInt16(buffer, weight);
        WriteUInt16(buffer, port);
        DnsName.EncodeInto(buffer, target);
        return buffer.ToArray();
    }

    // ── Big-endian primitives ────────────────────────────────────────────────

    public static void WriteUInt16(List<byte> buffer, ushort value)
    {
        buffer.Add((byte)((value >> 8) & 0xFF));
        buffer.Add((byte)(value & 0xFF));
    }

    public static void WriteUInt32(List<byte> buffer, uint value)
    {
        buffer.Add((byte)((value >> 24) & 0xFF));
        buffer.Add((byte)((value >> 16) & 0xFF));
        buffer.Add((byte)((value >> 8) & 0xFF));
        buffer.Add((byte)(value & 0xFF));
    }

    public static ushort ReadUInt16(byte[] data, int offset)
    {
        if (offset + 2 > data.Length)
        {
            throw new FormatException("u16 read past end of message");
        }
        return (ushort)((data[offset] << 8) | data[offset + 1]);
    }

    public static uint ReadUInt32(byte[] data, int offset)
    {
        if (offset + 4 > data.Length)
        {
            throw new FormatException("u32 read past end of message");
        }
        return ((uint)data[offset] << 24)
            | ((uint)data[offset + 1] << 16)
            | ((uint)data[offset + 2] << 8)
            | data[offset + 3];
    }
}
