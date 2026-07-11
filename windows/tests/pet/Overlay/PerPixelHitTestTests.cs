using OpenBurnBar.Pal.Overlay;
using Xunit;

namespace OpenBurnBar.App.Pet.Tests.Overlay;

public sealed class PerPixelHitTestTests
{
    // Build a width*height BGRA buffer (top-down) whose alpha is set per pixel by
    // <paramref name="alphaAt"/>.
    private static byte[] MakeBuffer(int width, int height, System.Func<int, int, byte> alphaAt)
    {
        var stride = width * 4;
        var buf = new byte[stride * height];
        for (var y = 0; y < height; y++)
        {
            for (var x = 0; x < width; x++)
            {
                buf[(y * stride) + (x * 4) + 3] = alphaAt(x, y);
            }
        }
        return buf;
    }

    [Fact]
    public void OpaquePixel_IsHit_TransparentPixel_PassesThrough()
    {
        // Left half opaque (255), right half transparent (0).
        var buf = MakeBuffer(4, 2, (x, _) => (byte)(x < 2 ? 255 : 0));
        Assert.True(PerPixelHitTest.IsHit(buf, 4, 2, 16, 0, 0, topDown: true));
        Assert.True(PerPixelHitTest.IsHit(buf, 4, 2, 16, 1, 1, topDown: true));
        Assert.False(PerPixelHitTest.IsHit(buf, 4, 2, 16, 2, 0, topDown: true));
        Assert.False(PerPixelHitTest.IsHit(buf, 4, 2, 16, 3, 1, topDown: true));
    }

    [Fact]
    public void ThresholdControlsNearTransparentFringe()
    {
        var buf = MakeBuffer(2, 1, (_, _) => 20); // alpha 20 everywhere
        // default threshold 25 -> pass-through
        Assert.False(PerPixelHitTest.IsHit(buf, 2, 1, 8, 0, 0, topDown: true));
        // lower the threshold to 10 -> hit
        Assert.True(PerPixelHitTest.IsHit(buf, 2, 1, 8, 0, 0, alphaThreshold: 10, topDown: true));
    }

    [Fact]
    public void OutOfBounds_IsMiss()
    {
        var buf = MakeBuffer(2, 2, (_, _) => 255);
        Assert.False(PerPixelHitTest.IsHit(buf, 2, 2, 8, -1, 0, topDown: true));
        Assert.False(PerPixelHitTest.IsHit(buf, 2, 2, 8, 0, -1, topDown: true));
        Assert.False(PerPixelHitTest.IsHit(buf, 2, 2, 8, 2, 0, topDown: true));
        Assert.False(PerPixelHitTest.IsHit(buf, 2, 2, 8, 0, 2, topDown: true));
    }

    [Fact]
    public void BottomUpRowOrder_IsRespected()
    {
        // Row 0 (top-down) opaque; row 1 transparent.
        var buf = MakeBuffer(1, 2, (_, y) => (byte)(y == 0 ? 255 : 0));
        // top-down: (0,0) reads row 0 -> opaque
        Assert.True(PerPixelHitTest.IsHit(buf, 1, 2, 4, 0, 0, topDown: true));
        // bottom-up: (0,0) reads the LAST row (row height-1-0 = 1) -> transparent
        Assert.False(PerPixelHitTest.IsHit(buf, 1, 2, 4, 0, 0, topDown: false));
        // bottom-up: (0,1) reads row 0 -> opaque
        Assert.True(PerPixelHitTest.IsHit(buf, 1, 2, 4, 0, 1, topDown: false));
    }

    [Fact]
    public void AlphaAt_ReturnsExactValue()
    {
        var buf = MakeBuffer(3, 1, (x, _) => (byte)(x * 40));
        Assert.Equal(0, PerPixelHitTest.AlphaAt(buf, 3, 1, 12, 0, 0, topDown: true));
        Assert.Equal(40, PerPixelHitTest.AlphaAt(buf, 3, 1, 12, 1, 0, topDown: true));
        Assert.Equal(80, PerPixelHitTest.AlphaAt(buf, 3, 1, 12, 2, 0, topDown: true));
    }
}
