using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.Text;

namespace OpenBurnBar.Integrations.Mercury.Wire;

/// <summary>
/// RFB (Remote Framebuffer, RFC 6143) client wire codec used by the Mercury
/// remote-control lane. Ports the handshake + input-event byte layout of
/// <c>AgentLens/Services/Media/AppleRemoteDesktopRFBClient.swift</c> (the Mac
/// Apple-Screen-Sharing loopback client) and extends it with the standard
/// server→client FramebufferUpdate parse a full Windows VNC viewer needs.
///
/// Pure, transport-free: every method operates on byte spans so the Windows
/// adapter can drive it over a real socket while the parse/build logic stays
/// verifiable on any host.
/// </summary>
public static class RfbProtocol
{
    /// <summary>Fixed 12-byte handshake banner length.</summary>
    public const int ProtocolBannerLength = 12;

    /// <summary>Client-offered protocol version. Parity: "RFB 003.889\n".</summary>
    public const string ClientProtocolVersion = "RFB 003.889";

    /// <summary>Apple Remote Desktop security type (type 30).</summary>
    public const byte SecurityTypeAppleArd = 30;

    /// <summary>Fixed ServerInit header size (before the variable-length name).</summary>
    public const int ServerInitHeaderByteCount = 24;

    // Client → server message-type ids (RFC 6143 §7.5).
    public const byte ClientMessageSetPixelFormat = 0;
    public const byte ClientMessageSetEncodings = 2;
    public const byte ClientMessageFramebufferUpdateRequest = 3;
    public const byte ClientMessageKeyEvent = 4;
    public const byte ClientMessagePointerEvent = 5;

    // Server → client message-type ids (RFC 6143 §7.6).
    public const byte ServerMessageFramebufferUpdate = 0;

    /// <summary>X11 keysyms used by the login-lane focus pass (parity: RFBKeysym).</summary>
    public static class Keysym
    {
        public const uint Backspace = 0xff08;
        public const uint Escape = 0xff1b;
        public const uint Return = 0xff0d;
        public const uint ShiftLeft = 0xffe1;
        public const uint Space = 0x20;
    }

    /// <summary>
    /// Build the client's ProtocolVersion reply ("RFB 003.889\n"), 12 bytes.
    /// </summary>
    public static byte[] BuildClientProtocolVersion()
    {
        var line = ClientProtocolVersion + "\n";
        var bytes = Encoding.ASCII.GetBytes(line);
        if (bytes.Length != ProtocolBannerLength)
        {
            throw new RfbProtocolException("client protocol version must be exactly 12 bytes");
        }

        return bytes;
    }

    /// <summary>
    /// Parse the server's 12-byte ProtocolVersion banner ("RFB mmm.nnn\n").
    /// Throws on a missing "RFB " prefix or a bad length (parity: performHandshake).
    /// </summary>
    public static RfbProtocolVersion ParseProtocolBanner(ReadOnlySpan<byte> banner)
    {
        if (banner.Length != ProtocolBannerLength)
        {
            throw new RfbProtocolException("missing_rfb_banner");
        }

        var text = Encoding.ASCII.GetString(banner);
        if (!text.StartsWith("RFB ", StringComparison.Ordinal))
        {
            throw new RfbProtocolException("missing_rfb_banner");
        }

        // Format: "RFB " + 3-digit major + "." + 3-digit minor + "\n".
        if (!int.TryParse(text.Substring(4, 3), out var major)
            || !int.TryParse(text.Substring(8, 3), out var minor))
        {
            throw new RfbProtocolException("malformed_rfb_banner");
        }

        return new RfbProtocolVersion(major, minor);
    }

    /// <summary>
    /// Given the server's advertised security-type list, confirm the requested
    /// type is offered and return the single byte the client writes back to
    /// select it. Parity: performHandshake's Apple-ARD selection.
    /// </summary>
    public static byte SelectSecurityType(ReadOnlySpan<byte> offered, byte preferred)
    {
        if (offered.Length == 0)
        {
            throw new RfbProtocolException("empty_security_type_list");
        }

        foreach (var type in offered)
        {
            if (type == preferred)
            {
                return preferred;
            }
        }

        throw new RfbProtocolException($"security_type_{preferred}_unavailable");
    }

    /// <summary>Whether the Apple-ARD security type (30) is offered.</summary>
    public static bool OffersAppleArd(ReadOnlySpan<byte> offered)
    {
        foreach (var type in offered)
        {
            if (type == SecurityTypeAppleArd)
            {
                return true;
            }
        }

        return false;
    }

    /// <summary>Build the ClientInit byte (shared-desktop flag). Parity: readServerInit's leading write.</summary>
    public static byte[] BuildClientInit(bool shared) => new[] { (byte)(shared ? 1 : 0) };

    /// <summary>
    /// Parse the fixed 24-byte ServerInit header, returning framebuffer
    /// width/height plus the trailing desktop-name length (name bytes follow).
    /// Parity: readServerInit.
    /// </summary>
    public static RfbServerInit ParseServerInit(ReadOnlySpan<byte> header)
    {
        if (header.Length < ServerInitHeaderByteCount)
        {
            throw new RfbProtocolException("server_init_truncated");
        }

        var width = BinaryPrimitives.ReadUInt16BigEndian(header.Slice(0, 2));
        var height = BinaryPrimitives.ReadUInt16BigEndian(header.Slice(2, 2));
        var nameLength = BinaryPrimitives.ReadUInt32BigEndian(header.Slice(20, 4));
        return new RfbServerInit(width, height, nameLength);
    }

    /// <summary>
    /// Build an 8-byte KeyEvent message. Parity: makeKeyEventMessage —
    /// <c>[4, down, 0, 0, k24, k16, k8, k0]</c>.
    /// </summary>
    public static byte[] BuildKeyEvent(uint keysym, bool down)
    {
        var message = new byte[8];
        message[0] = ClientMessageKeyEvent;
        message[1] = (byte)(down ? 1 : 0);
        message[2] = 0;
        message[3] = 0;
        BinaryPrimitives.WriteUInt32BigEndian(message.AsSpan(4, 4), keysym);
        return message;
    }

    /// <summary>
    /// Build a 6-byte PointerEvent message. Parity: makePointerEventMessage —
    /// <c>[5, buttonMask, x_hi, x_lo, y_hi, y_lo]</c>.
    /// </summary>
    public static byte[] BuildPointerEvent(byte buttonMask, ushort x, ushort y)
    {
        var message = new byte[6];
        message[0] = ClientMessagePointerEvent;
        message[1] = buttonMask;
        BinaryPrimitives.WriteUInt16BigEndian(message.AsSpan(2, 2), x);
        BinaryPrimitives.WriteUInt16BigEndian(message.AsSpan(4, 2), y);
        return message;
    }

    /// <summary>
    /// Build a 10-byte FramebufferUpdateRequest (client message-type 3, RFC 6143
    /// §7.5.3): <c>[3, incremental, x, y, w, h]</c> with u16 BE fields. This is
    /// the request that pairs with the FramebufferUpdate parse below.
    /// </summary>
    public static byte[] BuildFramebufferUpdateRequest(bool incremental, ushort x, ushort y, ushort width, ushort height)
    {
        var message = new byte[10];
        message[0] = ClientMessageFramebufferUpdateRequest;
        message[1] = (byte)(incremental ? 1 : 0);
        BinaryPrimitives.WriteUInt16BigEndian(message.AsSpan(2, 2), x);
        BinaryPrimitives.WriteUInt16BigEndian(message.AsSpan(4, 2), y);
        BinaryPrimitives.WriteUInt16BigEndian(message.AsSpan(6, 2), width);
        BinaryPrimitives.WriteUInt16BigEndian(message.AsSpan(8, 2), height);
        return message;
    }

    /// <summary>
    /// Parse the header of a server→client FramebufferUpdate (message-type 0,
    /// RFC 6143 §7.6.1): <c>[0, padding, numberOfRectangles(u16 BE)]</c>.
    /// Returns the rectangle count and the offset where the first rectangle
    /// header starts (4).
    /// </summary>
    public static RfbFramebufferUpdateHeader ParseFramebufferUpdateHeader(ReadOnlySpan<byte> message)
    {
        if (message.Length < 4)
        {
            throw new RfbProtocolException("framebuffer_update_header_truncated");
        }

        if (message[0] != ServerMessageFramebufferUpdate)
        {
            throw new RfbProtocolException($"unexpected_server_message_type_{message[0]}");
        }

        var count = BinaryPrimitives.ReadUInt16BigEndian(message.Slice(2, 2));
        return new RfbFramebufferUpdateHeader(count, headerBytes: 4);
    }

    /// <summary>
    /// Parse a single 12-byte rectangle header (RFC 6143 §7.6.1):
    /// <c>u16 x, u16 y, u16 width, u16 height, s32 encoding-type</c>. The
    /// encoding-specific pixel bytes that follow are left to the per-encoding
    /// decoder.
    /// </summary>
    public static RfbRectangle ParseRectangleHeader(ReadOnlySpan<byte> header)
    {
        if (header.Length < 12)
        {
            throw new RfbProtocolException("rectangle_header_truncated");
        }

        var x = BinaryPrimitives.ReadUInt16BigEndian(header.Slice(0, 2));
        var y = BinaryPrimitives.ReadUInt16BigEndian(header.Slice(2, 2));
        var width = BinaryPrimitives.ReadUInt16BigEndian(header.Slice(4, 2));
        var height = BinaryPrimitives.ReadUInt16BigEndian(header.Slice(6, 2));
        var encoding = BinaryPrimitives.ReadInt32BigEndian(header.Slice(8, 4));
        return new RfbRectangle(x, y, width, height, encoding);
    }

    /// <summary>
    /// Parse a full RAW-encoded FramebufferUpdate: header + each rectangle
    /// header + its RAW pixel bytes (<c>width * height * bytesPerPixel</c>).
    /// Returns the parsed rectangles and the total bytes consumed so a caller
    /// can advance a back-to-back stream. Throws on truncation or a non-RAW
    /// encoding (the caller dispatches other encodings itself).
    /// </summary>
    public static RfbFramebufferUpdate ParseRawFramebufferUpdate(ReadOnlySpan<byte> message, int bytesPerPixel)
    {
        if (bytesPerPixel <= 0)
        {
            throw new RfbProtocolException("invalid_bytes_per_pixel");
        }

        var header = ParseFramebufferUpdateHeader(message);
        var offset = header.HeaderBytes;
        var rectangles = new List<RfbRectangle>(header.NumberOfRectangles);

        for (var i = 0; i < header.NumberOfRectangles; i++)
        {
            if (offset + 12 > message.Length)
            {
                throw new RfbProtocolException("rectangle_header_truncated");
            }

            var rectangle = ParseRectangleHeader(message.Slice(offset, 12));
            offset += 12;

            if (rectangle.Encoding != (int)RfbEncoding.Raw)
            {
                throw new RfbProtocolException($"unsupported_encoding_{rectangle.Encoding}");
            }

            var pixelBytes = rectangle.Width * rectangle.Height * bytesPerPixel;
            if (offset + pixelBytes > message.Length)
            {
                throw new RfbProtocolException("rectangle_pixels_truncated");
            }

            offset += pixelBytes;
            rectangles.Add(rectangle);
        }

        return new RfbFramebufferUpdate(rectangles, offset);
    }
}

/// <summary>Server ProtocolVersion (parity: "RFB mmm.nnn").</summary>
public readonly struct RfbProtocolVersion : IEquatable<RfbProtocolVersion>
{
    public int Major { get; }

    public int Minor { get; }

    public RfbProtocolVersion(int major, int minor)
    {
        Major = major;
        Minor = minor;
    }

    public bool Equals(RfbProtocolVersion other) => Major == other.Major && Minor == other.Minor;

    public override bool Equals(object? obj) => obj is RfbProtocolVersion other && Equals(other);

    public override int GetHashCode() => HashCode.Combine(Major, Minor);
}

/// <summary>Parsed ServerInit header (parity: RFBServerInit + name length).</summary>
public readonly struct RfbServerInit
{
    public ushort Width { get; }

    public ushort Height { get; }

    public uint NameLength { get; }

    public RfbServerInit(ushort width, ushort height, uint nameLength)
    {
        Width = width;
        Height = height;
        NameLength = nameLength;
    }
}

/// <summary>FramebufferUpdate header: rectangle count + header size.</summary>
public readonly struct RfbFramebufferUpdateHeader
{
    public ushort NumberOfRectangles { get; }

    public int HeaderBytes { get; }

    public RfbFramebufferUpdateHeader(ushort numberOfRectangles, int headerBytes)
    {
        NumberOfRectangles = numberOfRectangles;
        HeaderBytes = headerBytes;
    }
}

/// <summary>A single framebuffer rectangle header (RFC 6143 §7.6.1).</summary>
public readonly struct RfbRectangle : IEquatable<RfbRectangle>
{
    public ushort X { get; }

    public ushort Y { get; }

    public ushort Width { get; }

    public ushort Height { get; }

    public int Encoding { get; }

    public RfbRectangle(ushort x, ushort y, ushort width, ushort height, int encoding)
    {
        X = x;
        Y = y;
        Width = width;
        Height = height;
        Encoding = encoding;
    }

    public bool Equals(RfbRectangle other) =>
        X == other.X && Y == other.Y && Width == other.Width && Height == other.Height && Encoding == other.Encoding;

    public override bool Equals(object? obj) => obj is RfbRectangle other && Equals(other);

    public override int GetHashCode() => HashCode.Combine(X, Y, Width, Height, Encoding);
}

/// <summary>A fully parsed RAW FramebufferUpdate.</summary>
public sealed class RfbFramebufferUpdate
{
    public IReadOnlyList<RfbRectangle> Rectangles { get; }

    public int ConsumedBytes { get; }

    public RfbFramebufferUpdate(IReadOnlyList<RfbRectangle> rectangles, int consumedBytes)
    {
        Rectangles = rectangles;
        ConsumedBytes = consumedBytes;
    }
}

/// <summary>RFB encoding-type ids (RFC 6143 §7.7).</summary>
public enum RfbEncoding
{
    Raw = 0,
    CopyRect = 1,
    Rre = 2,
    Hextile = 5,
    Trle = 15,
    Zrle = 16,
}

public sealed class RfbProtocolException : Exception
{
    public RfbProtocolException(string message)
        : base(message)
    {
    }
}
