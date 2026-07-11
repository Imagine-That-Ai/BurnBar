using System;
using System.Collections.Generic;

namespace OpenBurnBar.Integrations.SmartHub.Discovery;

// DNS message assemble + parse (RFC 1035 §4).
//
// A 12-byte header (id, flags, and the four section counts) followed by the
// question section and the answer / authority / additional resource-record
// sections. Building emits uncompressed names for determinism; parsing follows
// compression pointers so real mDNS responses round-trip.

public sealed record DnsQuestion(string Name, ushort Type, ushort Class);

public sealed record DnsSrvData(ushort Priority, ushort Weight, ushort Port, string Target);

public sealed class DnsResourceRecord
{
    public string Name { get; }
    public ushort Type { get; }
    public ushort Class { get; }
    public uint Ttl { get; }
    public byte[] RData { get; }

    // Typed payloads, resolved during Parse where the message context is
    // available for compressed SRV/PTR target names. Null for other types.
    public string? ATarget { get; init; }
    public string? PtrTarget { get; init; }
    public DnsSrvData? Srv { get; init; }
    public IReadOnlyList<string>? TxtEntries { get; init; }

    public DnsResourceRecord(string name, ushort type, ushort @class, uint ttl, byte[] rdata)
    {
        Name = name;
        Type = type;
        Class = @class;
        Ttl = ttl;
        RData = rdata;
    }
}

public sealed class DnsMessage
{
    public ushort Id { get; set; }
    public ushort Flags { get; set; }
    public List<DnsQuestion> Questions { get; } = new();
    public List<DnsResourceRecord> Answers { get; } = new();
    public List<DnsResourceRecord> Authorities { get; } = new();
    public List<DnsResourceRecord> Additionals { get; } = new();

    /// mDNS standard query flags (QR=0, opcode=0).
    public const ushort QueryFlags = 0x0000;

    /// mDNS authoritative response flags (QR=1, AA=1).
    public const ushort ResponseFlags = 0x8400;

    public byte[] Build()
    {
        var buffer = new List<byte>(64);
        DnsRecords.WriteUInt16(buffer, Id);
        DnsRecords.WriteUInt16(buffer, Flags);
        DnsRecords.WriteUInt16(buffer, (ushort)Questions.Count);
        DnsRecords.WriteUInt16(buffer, (ushort)Answers.Count);
        DnsRecords.WriteUInt16(buffer, (ushort)Authorities.Count);
        DnsRecords.WriteUInt16(buffer, (ushort)Additionals.Count);

        foreach (var question in Questions)
        {
            DnsName.EncodeInto(buffer, question.Name);
            DnsRecords.WriteUInt16(buffer, question.Type);
            DnsRecords.WriteUInt16(buffer, question.Class);
        }

        AppendRecords(buffer, Answers);
        AppendRecords(buffer, Authorities);
        AppendRecords(buffer, Additionals);
        return buffer.ToArray();
    }

    private static void AppendRecords(List<byte> buffer, List<DnsResourceRecord> records)
    {
        foreach (var record in records)
        {
            DnsName.EncodeInto(buffer, record.Name);
            DnsRecords.WriteUInt16(buffer, record.Type);
            DnsRecords.WriteUInt16(buffer, record.Class);
            DnsRecords.WriteUInt32(buffer, record.Ttl);
            DnsRecords.WriteUInt16(buffer, (ushort)record.RData.Length);
            buffer.AddRange(record.RData);
        }
    }

    public static DnsMessage Parse(byte[] message)
    {
        if (message.Length < 12)
        {
            throw new FormatException("DNS message shorter than the 12-byte header");
        }

        var result = new DnsMessage
        {
            Id = DnsRecords.ReadUInt16(message, 0),
            Flags = DnsRecords.ReadUInt16(message, 2),
        };
        int qd = DnsRecords.ReadUInt16(message, 4);
        int an = DnsRecords.ReadUInt16(message, 6);
        int ns = DnsRecords.ReadUInt16(message, 8);
        int ar = DnsRecords.ReadUInt16(message, 10);

        var offset = 12;
        for (var i = 0; i < qd; i++)
        {
            var (name, next) = DnsName.Decode(message, offset);
            offset = next;
            var type = DnsRecords.ReadUInt16(message, offset);
            var cls = DnsRecords.ReadUInt16(message, offset + 2);
            offset += 4;
            result.Questions.Add(new DnsQuestion(name, type, cls));
        }

        offset = ReadRecords(message, offset, an, result.Answers);
        offset = ReadRecords(message, offset, ns, result.Authorities);
        ReadRecords(message, offset, ar, result.Additionals);
        return result;
    }

    private static int ReadRecords(byte[] message, int offset, int count, List<DnsResourceRecord> into)
    {
        for (var i = 0; i < count; i++)
        {
            var (name, next) = DnsName.Decode(message, offset);
            offset = next;
            var type = DnsRecords.ReadUInt16(message, offset);
            var cls = DnsRecords.ReadUInt16(message, offset + 2);
            var ttl = DnsRecords.ReadUInt32(message, offset + 4);
            int rdlength = DnsRecords.ReadUInt16(message, offset + 8);
            var rdataOffset = offset + 10;
            if (rdataOffset + rdlength > message.Length)
            {
                throw new FormatException("Resource-record rdata runs past the message end");
            }
            var rdata = new byte[rdlength];
            Array.Copy(message, rdataOffset, rdata, 0, rdlength);

            into.Add(BuildTyped(message, rdataOffset, name, type, cls, ttl, rdata));
            offset = rdataOffset + rdlength;
        }
        return offset;
    }

    private static DnsResourceRecord BuildTyped(
        byte[] message,
        int rdataOffset,
        string name,
        ushort type,
        ushort cls,
        uint ttl,
        byte[] rdata)
    {
        // Ignore the mDNS cache-flush bit when classifying the payload type.
        switch ((DnsRecordType)type)
        {
            case DnsRecordType.A:
                return new DnsResourceRecord(name, type, cls, ttl, rdata)
                {
                    ATarget = DnsRecords.ParseARData(rdata),
                };
            case DnsRecordType.Ptr:
                return new DnsResourceRecord(name, type, cls, ttl, rdata)
                {
                    PtrTarget = DnsName.Decode(message, rdataOffset).Name,
                };
            case DnsRecordType.Srv:
                var priority = DnsRecords.ReadUInt16(message, rdataOffset);
                var weight = DnsRecords.ReadUInt16(message, rdataOffset + 2);
                var port = DnsRecords.ReadUInt16(message, rdataOffset + 4);
                var target = DnsName.Decode(message, rdataOffset + 6).Name;
                return new DnsResourceRecord(name, type, cls, ttl, rdata)
                {
                    Srv = new DnsSrvData(priority, weight, port, target),
                };
            case DnsRecordType.Txt:
                return new DnsResourceRecord(name, type, cls, ttl, rdata)
                {
                    TxtEntries = DnsTxt.ParseRData(rdata),
                };
            default:
                return new DnsResourceRecord(name, type, cls, ttl, rdata);
        }
    }
}
