using System;

namespace OpenBurnBar.Pal.Overlay;

// MARK: - Per-pixel hit test (portable)
//
// Decides, for a point over the layered overlay, whether the pixel there belongs
// to the opaque pet body (a "hit" — the overlay should receive the click) or a
// transparent region (a "pass-through" — the overlay should return HTTRANSPARENT
// from WM_NCHITTEST so the click lands on whatever is behind it).
//
// This is the Windows peer of the shaped-hit-testing the macOS companion gets for
// free from the SpriteKit/SceneKit alpha of `PetDropHostingView` — but here the
// decision is explicit so the WndProc stays trivial. Pure array math, no Win32:
// unit-tested on the macOS authoring host over hand-built alpha buffers.
//
// Layered windows already let FULLY transparent (alpha == 0) pixels fall through at
// the OS compositor level; this adds a configurable THRESHOLD so near-transparent
// antialiased fringe pixels (e.g. alpha < 25) also pass through, matching the
// macOS "only solid body is grabbable" feel.

/// A hit-test over a 32-bpp BGRA alpha buffer.
public static class PerPixelHitTest
{
    /// The default alpha threshold below which a pixel is treated as pass-through
    /// (out of 255). Matches the macOS companion's ~10% opacity floor for grabbable
    /// body pixels.
    public const byte DefaultAlphaThreshold = 25;

    /// True when the pixel at (<paramref name="x"/>, <paramref name="y"/>) is opaque
    /// enough to be a hit; false for out-of-bounds or transparent pixels.
    ///
    /// <paramref name="buffer"/> is a 32-bpp BGRA image; <paramref name="stride"/> is
    /// the byte pitch of one row (>= width*4). <paramref name="topDown"/> selects row
    /// order: true for a top-down bitmap (row 0 at the top), false for a bottom-up
    /// Windows DIB (row 0 at the bottom, the UpdateLayeredWindow default).
    public static bool IsHit(
        ReadOnlySpan<byte> buffer,
        int width,
        int height,
        int stride,
        int x,
        int y,
        byte alphaThreshold = DefaultAlphaThreshold,
        bool topDown = false)
    {
        var alpha = AlphaAt(buffer, width, height, stride, x, y, topDown);
        return alpha >= alphaThreshold;
    }

    /// The alpha (0..255) at (<paramref name="x"/>, <paramref name="y"/>), or 0 when
    /// the point is out of bounds or the buffer is too small to contain it.
    public static byte AlphaAt(
        ReadOnlySpan<byte> buffer,
        int width,
        int height,
        int stride,
        int x,
        int y,
        bool topDown = false)
    {
        if (width <= 0 || height <= 0 || stride < width * 4)
        {
            return 0;
        }
        if (x < 0 || y < 0 || x >= width || y >= height)
        {
            return 0;
        }
        var row = topDown ? y : height - 1 - y;
        // BGRA: byte order is B, G, R, A — alpha is the 4th byte of the pixel.
        var index = (row * stride) + (x * 4) + 3;
        if (index < 0 || index >= buffer.Length)
        {
            return 0;
        }
        return buffer[index];
    }
}
