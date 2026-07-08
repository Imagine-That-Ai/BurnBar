using System;
using OpenBurnBar.Integrations.Mercury.Wire;
using Xunit;

namespace OpenBurnBar.Integrations.Mercury.Tests;

public sealed class RfbProtocolTests
{
    [Fact]
    public void BuildClientProtocolVersion_IsTwelveByteRfb889()
    {
        var bytes = RfbProtocol.BuildClientProtocolVersion();
        Assert.Equal(12, bytes.Length);
        Assert.Equal("RFB 003.889\n", System.Text.Encoding.ASCII.GetString(bytes));
    }

    [Fact]
    public void ParseProtocolBanner_ExtractsMajorMinor()
    {
        var banner = System.Text.Encoding.ASCII.GetBytes("RFB 003.008\n");
        var version = RfbProtocol.ParseProtocolBanner(banner);
        Assert.Equal(3, version.Major);
        Assert.Equal(8, version.Minor);
    }

    [Fact]
    public void ParseProtocolBanner_MissingPrefix_Throws()
    {
        var banner = System.Text.Encoding.ASCII.GetBytes("XXX 003.008\n");
        var ex = Assert.Throws<RfbProtocolException>(() => RfbProtocol.ParseProtocolBanner(banner));
        Assert.Equal("missing_rfb_banner", ex.Message);
    }

    [Fact]
    public void ParseProtocolBanner_WrongLength_Throws()
    {
        Assert.Throws<RfbProtocolException>(() => RfbProtocol.ParseProtocolBanner(new byte[] { 1, 2, 3 }));
    }

    [Fact]
    public void SelectSecurityType_PicksAppleArdWhenOffered()
    {
        var offered = new byte[] { 1, 2, RfbProtocol.SecurityTypeAppleArd };
        Assert.True(RfbProtocol.OffersAppleArd(offered));
        Assert.Equal(RfbProtocol.SecurityTypeAppleArd, RfbProtocol.SelectSecurityType(offered, RfbProtocol.SecurityTypeAppleArd));
    }

    [Fact]
    public void SelectSecurityType_NotOffered_Throws()
    {
        var offered = new byte[] { 1, 2 };
        Assert.False(RfbProtocol.OffersAppleArd(offered));
        Assert.Throws<RfbProtocolException>(() => RfbProtocol.SelectSecurityType(offered, RfbProtocol.SecurityTypeAppleArd));
    }

    [Fact]
    public void SelectSecurityType_EmptyList_Throws()
    {
        var ex = Assert.Throws<RfbProtocolException>(() => RfbProtocol.SelectSecurityType(Array.Empty<byte>(), 30));
        Assert.Equal("empty_security_type_list", ex.Message);
    }

    [Fact]
    public void ParseServerInit_ReadsWidthHeightNameLength()
    {
        var header = new byte[24];
        header[0] = 0x07; header[1] = 0x80; // width 1920
        header[2] = 0x04; header[3] = 0x38; // height 1080
        header[20] = 0; header[21] = 0; header[22] = 0; header[23] = 5; // nameLength 5

        var init = RfbProtocol.ParseServerInit(header);
        Assert.Equal(1920, init.Width);
        Assert.Equal(1080, init.Height);
        Assert.Equal(5u, init.NameLength);
    }

    [Fact]
    public void ParseServerInit_Truncated_Throws()
    {
        Assert.Throws<RfbProtocolException>(() => RfbProtocol.ParseServerInit(new byte[10]));
    }

    [Fact]
    public void BuildKeyEvent_IsByteExact()
    {
        // Parity: makeKeyEventMessage(keysym: 0xff0d, down: true).
        var down = RfbProtocol.BuildKeyEvent(RfbProtocol.Keysym.Return, down: true);
        Assert.Equal(new byte[] { 4, 1, 0, 0, 0x00, 0x00, 0xff, 0x0d }, down);

        var up = RfbProtocol.BuildKeyEvent(RfbProtocol.Keysym.Return, down: false);
        Assert.Equal(new byte[] { 4, 0, 0, 0, 0x00, 0x00, 0xff, 0x0d }, up);
    }

    [Fact]
    public void BuildKeyEvent_AsciiSpace_EncodesLowByte()
    {
        var msg = RfbProtocol.BuildKeyEvent(RfbProtocol.Keysym.Space, down: true);
        Assert.Equal(new byte[] { 4, 1, 0, 0, 0x00, 0x00, 0x00, 0x20 }, msg);
    }

    [Fact]
    public void BuildPointerEvent_IsByteExact()
    {
        // Parity: makePointerEventMessage(buttonMask: 1, x: 100, y: 200).
        var msg = RfbProtocol.BuildPointerEvent(buttonMask: 1, x: 100, y: 200);
        Assert.Equal(new byte[] { 5, 1, 0x00, 0x64, 0x00, 0xC8 }, msg);
    }

    [Fact]
    public void BuildClientInit_SharedFlag()
    {
        Assert.Equal(new byte[] { 1 }, RfbProtocol.BuildClientInit(shared: true));
        Assert.Equal(new byte[] { 0 }, RfbProtocol.BuildClientInit(shared: false));
    }

    [Fact]
    public void BuildFramebufferUpdateRequest_IsByteExact()
    {
        var msg = RfbProtocol.BuildFramebufferUpdateRequest(incremental: true, x: 0, y: 0, width: 1920, height: 1080);
        Assert.Equal(new byte[] { 3, 1, 0x00, 0x00, 0x00, 0x00, 0x07, 0x80, 0x04, 0x38 }, msg);
    }

    [Fact]
    public void ParseFramebufferUpdateHeader_ReadsRectangleCount()
    {
        var message = new byte[] { 0, 0, 0x00, 0x03 };
        var header = RfbProtocol.ParseFramebufferUpdateHeader(message);
        Assert.Equal(3, header.NumberOfRectangles);
        Assert.Equal(4, header.HeaderBytes);
    }

    [Fact]
    public void ParseFramebufferUpdateHeader_WrongMessageType_Throws()
    {
        var message = new byte[] { 9, 0, 0x00, 0x01 };
        Assert.Throws<RfbProtocolException>(() => RfbProtocol.ParseFramebufferUpdateHeader(message));
    }

    [Fact]
    public void ParseRectangleHeader_ReadsGeometryAndEncoding()
    {
        var header = new byte[]
        {
            0x00, 0x0A, // x = 10
            0x00, 0x14, // y = 20
            0x00, 0x50, // width = 80
            0x00, 0x3C, // height = 60
            0x00, 0x00, 0x00, 0x01, // encoding = 1 (CopyRect)
        };
        var rect = RfbProtocol.ParseRectangleHeader(header);
        Assert.Equal(10, rect.X);
        Assert.Equal(20, rect.Y);
        Assert.Equal(80, rect.Width);
        Assert.Equal(60, rect.Height);
        Assert.Equal((int)RfbEncoding.CopyRect, rect.Encoding);
    }

    [Fact]
    public void ParseRawFramebufferUpdate_ParsesRectanglesAndConsumesPixels()
    {
        // One 2x1 RAW rectangle, 4 bytes-per-pixel → 8 pixel bytes.
        const int bpp = 4;
        var message = new byte[]
        {
            0, 0, 0x00, 0x01, // header: 1 rectangle
            0x00, 0x05, 0x00, 0x06, // x=5, y=6
            0x00, 0x02, 0x00, 0x01, // w=2, h=1
            0x00, 0x00, 0x00, 0x00, // encoding = 0 (RAW)
            0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03, 0x04, // 2 pixels * 4 bytes
        };

        var update = RfbProtocol.ParseRawFramebufferUpdate(message, bpp);
        Assert.Single(update.Rectangles);
        var rect = update.Rectangles[0];
        Assert.Equal(5, rect.X);
        Assert.Equal(6, rect.Y);
        Assert.Equal(2, rect.Width);
        Assert.Equal(1, rect.Height);
        Assert.Equal((int)RfbEncoding.Raw, rect.Encoding);
        Assert.Equal(message.Length, update.ConsumedBytes);
    }

    [Fact]
    public void ParseRawFramebufferUpdate_TruncatedPixels_Throws()
    {
        var message = new byte[]
        {
            0, 0, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x02, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x00,
            0xDE, 0xAD, // only 2 of the 8 pixel bytes
        };
        Assert.Throws<RfbProtocolException>(() => RfbProtocol.ParseRawFramebufferUpdate(message, 4));
    }

    [Fact]
    public void ParseRawFramebufferUpdate_NonRawEncoding_Throws()
    {
        var message = new byte[]
        {
            0, 0, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x01, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x05, // Hextile — not RAW
        };
        Assert.Throws<RfbProtocolException>(() => RfbProtocol.ParseRawFramebufferUpdate(message, 4));
    }
}
