// DNS / mDNS (RFC 1035 + RFC 6763 DNS-SD) wire parser. This is the portable
// core behind the live browser: on macOS the OS surfaces resolved records via
// NWBrowser/NetService; on Windows via Dnssd. Both ultimately carry the same
// DNS-SD records, and this parser decodes a captured _googlecast._tcp
// advertisement byte-for-byte so the logic is provable off-Windows.

using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;

namespace OpenBurnBar.Integrations.Cast.Discovery;

/// <summary>DNS resource-record / question type codes we handle.</summary>
public static class DnsRecordType
{
    /// <summary>IPv4 host address.</summary>
    public const ushort A = 1;

    /// <summary>Domain-name pointer (DNS-SD service instance enumeration).</summary>
    public const ushort Ptr = 12;

    /// <summary>Text strings (DNS-SD key/value attributes).</summary>
    public const ushort Txt = 16;

    /// <summary>IPv6 host address.</summary>
    public const ushort Aaaa = 28;

    /// <summary>Service location (host + port).</summary>
    public const ushort Srv = 33;

    /// <summary>Request-any wildcard.</summary>
    public const ushort Any = 255;
}

/// <summary>A parsed DNS resource record with type-specific convenience fields.</summary>
public sealed record DnsResourceRecord
{
    /// <summary>Owner name (fully decompressed).</summary>
    public required string Name { get; init; }

    /// <summary>Record type (see <see cref="DnsRecordType"/>).</summary>
    public required ushort Type { get; init; }

    /// <summary>Record class with the mDNS cache-flush / QU bit masked off.</summary>
    public required ushort Class { get; init; }

    /// <summary>Time-to-live in seconds.</summary>
    public required uint Ttl { get; init; }

    /// <summary>PTR target name (for <see cref="DnsRecordType.Ptr"/>).</summary>
    public string? PtrTarget { get; init; }

    /// <summary>SRV port (for <see cref="DnsRecordType.Srv"/>).</summary>
    public int? SrvPort { get; init; }

    /// <summary>SRV target host name (for <see cref="DnsRecordType.Srv"/>).</summary>
    public string? SrvTarget { get; init; }

    /// <summary>Decoded TXT key=value strings (for <see cref="DnsRecordType.Txt"/>).</summary>
    public IReadOnlyList<string>? TxtStrings { get; init; }

    /// <summary>Dotted-quad IPv4 address (for <see cref="DnsRecordType.A"/>).</summary>
    public string? AAddress { get; init; }
}

/// <summary>A parsed DNS-SD question (name + qtype + qclass).</summary>
public sealed record DnsQuestion
{
    /// <summary>The queried name.</summary>
    public required string Name { get; init; }

    /// <summary>Query type.</summary>
    public required ushort Type { get; init; }

    /// <summary>Query class with the mDNS QU bit masked off.</summary>
    public required ushort Class { get; init; }
}

/// <summary>A fully-parsed DNS/mDNS message.</summary>
public sealed record DnsMessage
{
    /// <summary>Transaction id (0 for mDNS).</summary>
    public required ushort Id { get; init; }

    /// <summary>Raw 16-bit flags word.</summary>
    public required ushort Flags { get; init; }

    /// <summary>Whether the QR bit marks this as a response.</summary>
    public bool IsResponse => (Flags & 0x8000) != 0;

    /// <summary>Question section.</summary>
    public required IReadOnlyList<DnsQuestion> Questions { get; init; }

    /// <summary>Answer section.</summary>
    public required IReadOnlyList<DnsResourceRecord> Answers { get; init; }

    /// <summary>Authority section.</summary>
    public required IReadOnlyList<DnsResourceRecord> Authorities { get; init; }

    /// <summary>Additional section.</summary>
    public required IReadOnlyList<DnsResourceRecord> Additionals { get; init; }

    /// <summary>All resource records across answer/authority/additional sections.</summary>
    public IEnumerable<DnsResourceRecord> AllRecords()
    {
        foreach (var record in Answers)
        {
            yield return record;
        }

        foreach (var record in Authorities)
        {
            yield return record;
        }

        foreach (var record in Additionals)
        {
            yield return record;
        }
    }

    /// <summary>Parse a DNS/mDNS message from raw bytes. Throws on truncation / malformation.</summary>
    public static DnsMessage Parse(byte[] packet)
    {
        if (packet is null)
        {
            throw new ArgumentNullException(nameof(packet));
        }

        var reader = new DnsReader(packet);
        var id = reader.ReadUInt16();
        var flags = reader.ReadUInt16();
        var qdCount = reader.ReadUInt16();
        var anCount = reader.ReadUInt16();
        var nsCount = reader.ReadUInt16();
        var arCount = reader.ReadUInt16();

        var questions = new List<DnsQuestion>(qdCount);
        for (var i = 0; i < qdCount; i++)
        {
            var name = reader.ReadName();
            var type = reader.ReadUInt16();
            var klass = reader.ReadUInt16();
            questions.Add(new DnsQuestion { Name = name, Type = type, Class = (ushort)(klass & 0x7FFF) });
        }

        var answers = ReadRecords(reader, anCount);
        var authorities = ReadRecords(reader, nsCount);
        var additionals = ReadRecords(reader, arCount);

        return new DnsMessage
        {
            Id = id,
            Flags = flags,
            Questions = questions,
            Answers = answers,
            Authorities = authorities,
            Additionals = additionals,
        };
    }

    private static IReadOnlyList<DnsResourceRecord> ReadRecords(DnsReader reader, int count)
    {
        var records = new List<DnsResourceRecord>(count);
        for (var i = 0; i < count; i++)
        {
            records.Add(reader.ReadResourceRecord());
        }

        return records;
    }
}

/// <summary>Forward-only reader over a DNS message with name-compression support.</summary>
public sealed class DnsReader
{
    private readonly byte[] _data;
    private int _position;

    /// <summary>Create a reader positioned at the start of <paramref name="data"/>.</summary>
    public DnsReader(byte[] data)
    {
        _data = data ?? throw new ArgumentNullException(nameof(data));
    }

    /// <summary>Read a big-endian 16-bit value.</summary>
    public ushort ReadUInt16()
    {
        Require(2);
        var value = (ushort)((_data[_position] << 8) | _data[_position + 1]);
        _position += 2;
        return value;
    }

    /// <summary>Read a big-endian 32-bit value.</summary>
    public uint ReadUInt32()
    {
        Require(4);
        var value = ((uint)_data[_position] << 24)
                    | ((uint)_data[_position + 1] << 16)
                    | ((uint)_data[_position + 2] << 8)
                    | _data[_position + 3];
        _position += 4;
        return value;
    }

    /// <summary>
    /// Read a domain name at the current position, following compression
    /// pointers (RFC 1035 §4.1.4) and advancing the position past the name in
    /// the record stream (not past the pointer target).
    /// </summary>
    public string ReadName()
    {
        var labels = new List<string>();
        var jumped = false;
        var cursor = _position;
        var safety = 0;

        while (true)
        {
            if (cursor >= _data.Length)
            {
                throw new FormatException("DNS name overran the packet.");
            }

            var length = _data[cursor];
            if ((length & 0xC0) == 0xC0)
            {
                // Compression pointer: 14-bit offset from the next two bytes.
                if (cursor + 1 >= _data.Length)
                {
                    throw new FormatException("DNS compression pointer overran the packet.");
                }

                var pointer = ((length & 0x3F) << 8) | _data[cursor + 1];
                if (!jumped)
                {
                    _position = cursor + 2;
                    jumped = true;
                }

                cursor = pointer;
                if (++safety > _data.Length)
                {
                    throw new FormatException("DNS compression pointer loop.");
                }

                continue;
            }

            if (length == 0)
            {
                cursor += 1;
                if (!jumped)
                {
                    _position = cursor;
                }

                break;
            }

            cursor += 1;
            if (cursor + length > _data.Length)
            {
                throw new FormatException("DNS label overran the packet.");
            }

            labels.Add(Encoding.UTF8.GetString(_data, cursor, length));
            cursor += length;
        }

        return string.Join(".", labels);
    }

    /// <summary>Read one resource record (header + typed rdata).</summary>
    public DnsResourceRecord ReadResourceRecord()
    {
        var name = ReadName();
        var type = ReadUInt16();
        var klass = ReadUInt16();
        var ttl = ReadUInt32();
        var rdLength = ReadUInt16();
        Require(rdLength);
        var rdataStart = _position;
        var rdataEnd = _position + rdLength;

        string? ptrTarget = null;
        int? srvPort = null;
        string? srvTarget = null;
        IReadOnlyList<string>? txtStrings = null;
        string? aAddress = null;

        switch (type)
        {
            case DnsRecordType.Ptr:
                ptrTarget = ReadName();
                break;
            case DnsRecordType.Srv:
                _ = ReadUInt16(); // priority
                _ = ReadUInt16(); // weight
                srvPort = ReadUInt16();
                srvTarget = ReadName();
                break;
            case DnsRecordType.Txt:
                txtStrings = ReadTxtStrings(rdataStart, rdLength);
                break;
            case DnsRecordType.A:
                if (rdLength == 4)
                {
                    aAddress = string.Join(
                        ".",
                        _data[rdataStart].ToString(CultureInfo.InvariantCulture),
                        _data[rdataStart + 1].ToString(CultureInfo.InvariantCulture),
                        _data[rdataStart + 2].ToString(CultureInfo.InvariantCulture),
                        _data[rdataStart + 3].ToString(CultureInfo.InvariantCulture));
                }

                break;
            default:
                break;
        }

        // Always resume exactly at the end of this record's rdata, regardless of
        // how far a compressed name inside the rdata jumped.
        _position = rdataEnd;

        return new DnsResourceRecord
        {
            Name = name,
            Type = type,
            Class = (ushort)(klass & 0x7FFF),
            Ttl = ttl,
            PtrTarget = ptrTarget,
            SrvPort = srvPort,
            SrvTarget = srvTarget,
            TxtStrings = txtStrings,
            AAddress = aAddress,
        };
    }

    private IReadOnlyList<string> ReadTxtStrings(int start, int rdLength)
    {
        var strings = new List<string>();
        var cursor = start;
        var end = start + rdLength;
        while (cursor < end)
        {
            var length = _data[cursor];
            cursor += 1;
            if (length == 0 || cursor + length > end)
            {
                if (length == 0)
                {
                    continue;
                }

                break;
            }

            strings.Add(Encoding.UTF8.GetString(_data, cursor, length));
            cursor += length;
        }

        return strings;
    }

    private void Require(int count)
    {
        if (_position + count > _data.Length || _position + count < _position)
        {
            throw new FormatException("DNS message truncated.");
        }
    }
}
