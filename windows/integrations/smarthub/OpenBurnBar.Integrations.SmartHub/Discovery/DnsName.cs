using System;
using System.Collections.Generic;
using System.Text;

namespace OpenBurnBar.Integrations.SmartHub.Discovery;

// DNS name wire encoding (RFC 1035 §3.1 + §4.1.4 compression).
//
// macOS advertises + browses services through NetService/Bonjour, which hides
// the on-wire DNS-SD bytes entirely. On Windows there is no such shim for a
// custom advertiser, so the wire format is authored + proven here: a name is a
// sequence of length-prefixed labels terminated by a zero-length label; the
// reader additionally follows 0xC0 compression pointers so real mDNS responses
// (e.g. an AWTRIX clock's _http._tcp answer) parse.

public static class DnsName
{
    public const int MaxLabelLength = 63;

    /// Encodes a dotted name to length-prefixed labels + terminating 0x00.
    /// A trailing dot (FQDN form "local.") is ignored; the root name "" or "."
    /// encodes to a single 0x00.
    public static byte[] Encode(string name)
    {
        var bytes = new List<byte>();
        EncodeInto(bytes, name);
        return bytes.ToArray();
    }

    public static void EncodeInto(List<byte> buffer, string name)
    {
        var normalized = name;
        if (normalized.EndsWith(".", StringComparison.Ordinal))
        {
            normalized = normalized.Substring(0, normalized.Length - 1);
        }

        if (normalized.Length > 0)
        {
            foreach (var label in normalized.Split('.'))
            {
                var labelBytes = Encoding.UTF8.GetBytes(label);
                if (labelBytes.Length == 0 || labelBytes.Length > MaxLabelLength)
                {
                    throw new ArgumentException($"DNS label must be 1..{MaxLabelLength} bytes: '{label}'", nameof(name));
                }
                buffer.Add((byte)labelBytes.Length);
                buffer.AddRange(labelBytes);
            }
        }
        buffer.Add(0x00);
    }

    /// Decodes a name at `offset`, following compression pointers. Returns the
    /// dotted name (no trailing dot) and the offset immediately after the name
    /// in the ORIGINAL stream (i.e. after the first pointer, if any).
    public static (string Name, int NextOffset) Decode(byte[] message, int offset)
    {
        var labels = new List<string>();
        var pos = offset;
        var jumped = false;
        var nextOffset = -1;
        var guard = 0;

        while (true)
        {
            if (guard++ > message.Length)
            {
                throw new FormatException("DNS name decode exceeded message length (pointer loop?)");
            }
            if (pos >= message.Length)
            {
                throw new FormatException("DNS name decode ran off the end of the message");
            }

            var len = message[pos];
            if (len == 0)
            {
                pos++;
                if (!jumped)
                {
                    nextOffset = pos;
                }
                break;
            }

            if ((len & 0xC0) == 0xC0)
            {
                if (pos + 1 >= message.Length)
                {
                    throw new FormatException("DNS compression pointer truncated");
                }
                var pointer = ((len & 0x3F) << 8) | message[pos + 1];
                if (!jumped)
                {
                    nextOffset = pos + 2;
                }
                jumped = true;
                pos = pointer;
                continue;
            }

            if ((len & 0xC0) != 0)
            {
                throw new FormatException($"DNS label has reserved length bits set: 0x{len:X2}");
            }

            pos++;
            if (pos + len > message.Length)
            {
                throw new FormatException("DNS label runs past the message end");
            }
            labels.Add(Encoding.UTF8.GetString(message, pos, len));
            pos += len;
        }

        return (string.Join(".", labels), nextOffset);
    }
}
