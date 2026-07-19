// WINDOWS-ONLY / CI-DEFERRED (Win2D). See Win2DSubstrateDrawingSession.cs header.

using System.Collections.Generic;
using Microsoft.Graphics.Canvas;
using OpenBurnBar.Particles.Model;
using Windows.Graphics.DirectX;

namespace OpenBurnBar.App.Particles;

/// <summary>
/// Win2D analog of the Swift Sunshaft <c>bakeShaft</c> (a 48×256 pre-tinted luminance
/// mask): a tall god-ray sprite whose vertical envelope blooms from a bright foot up to
/// a soft crown, crossed by a horizontal filament (a tight bright center-x with a soft
/// skirt), pre-tinted to the ramp color and premultiplied. Baked ONCE per tint into a
/// <see cref="CanvasBitmap"/> and drawn many times per frame (foot-anchored, oriented
/// along the light vector) by <see cref="Win2DSubstrateDrawingSession.DrawShaftSprite"/>.
/// Keyed by the tint's 8-bit bucket key so palette micro-jitter never thrashes the cache.
/// The vStops / hStops envelopes are byte-identical to the Swift bake.
/// </summary>
public sealed class ShaftSpriteCache
{
    private const int Width = 48;
    private const int Height = 256;
    private readonly Dictionary<uint, CanvasBitmap> _cache = new();

    // vertical envelope keyed on `up` (0 foot → 1 crown); horizontal filament on `hx`.
    private static readonly double[] VLoc = { 0.0, 0.4, 0.78, 1.0 };
    private static readonly double[] VVal = { 0.96, 0.46, 0.14, 0.0 };
    private static readonly double[] HLoc = { 0.0, 0.36, 0.5, 0.64, 1.0 };
    private static readonly double[] HVal = { 0.0, 0.14, 1.0, 0.14, 0.0 };

    public CanvasBitmap Resolve(ICanvasResourceCreator device, in Rgba col)
    {
        uint key = col.BucketKey;
        if (_cache.TryGetValue(key, out CanvasBitmap? cached)) return cached;

        var bytes = new byte[Width * Height * 4]; // BGRA, premultiplied
        double r = col.R, g = col.G, b = col.B;
        for (int row = 0; row < Height; row++)
        {
            double up = (Height - 1 - row) / (double)(Height - 1); // row 0 = crown (top)
            double vA = Pw(VLoc, VVal, up);
            int baseIdx = row * Width * 4;
            for (int c = 0; c < Width; c++)
            {
                double hx = c / (double)(Width - 1);
                double a = vA * Pw(HLoc, HVal, hx);
                int o = baseIdx + c * 4;
                bytes[o + 0] = Clamp255(b * a); // B
                bytes[o + 1] = Clamp255(g * a); // G
                bytes[o + 2] = Clamp255(r * a); // R
                bytes[o + 3] = Clamp255(a);     // A
            }
        }

        var bmp = CanvasBitmap.CreateFromBytes(
            device, bytes, Width, Height,
            DirectXPixelFormat.B8G8R8A8UIntNormalized,
            96f, Microsoft.Graphics.Canvas.CanvasAlphaMode.Premultiplied);
        _cache[key] = bmp;
        return bmp;
    }

    public void Clear()
    {
        foreach (CanvasBitmap bitmap in _cache.Values)
        {
            bitmap.Dispose();
        }

        _cache.Clear();
    }

    private static byte Clamp255(double v)
    {
        double s = v * 255.0;
        if (s < 0) s = 0; else if (s > 255) s = 255;
        return (byte)(s + 0.5);
    }

    /// <summary>Piecewise-linear lookup over sorted (location, value) stops in 0…1.</summary>
    private static double Pw(double[] locs, double[] vals, double x)
    {
        if (x <= locs[0]) return vals[0];
        for (int j = 1; j < locs.Length; j++)
        {
            double lx = locs[j - 1], rx = locs[j];
            if (x <= rx)
            {
                double f = rx - lx <= 0 ? 0 : (x - lx) / (rx - lx);
                return vals[j - 1] + (vals[j] - vals[j - 1]) * f;
            }
        }
        return vals[vals.Length - 1];
    }
}
