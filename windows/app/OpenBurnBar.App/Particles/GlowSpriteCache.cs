// WINDOWS-ONLY / CI-DEFERRED (Win2D). See Win2DSubstrateDrawingSession.cs header.

using System.Collections.Generic;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Brushes;
using OpenBurnBar.Particles.Model;
using WinColor = Windows.UI.Color;

namespace OpenBurnBar.App.Particles;

/// <summary>
/// Win2D analog of the Swift <c>SpriteCache</c> (<c>Views/Substrate/SubstrateKit.swift</c>):
/// bakes a soft radial-gradient glow sprite ONCE per tint into a
/// <see cref="CanvasRenderTarget"/>, then hands it back for many additive draws
/// per frame. Keyed by the tint's 8-bit bucket key so micro-jitter in the color
/// driver never thrashes the cache.
/// </summary>
public sealed class GlowSpriteCache
{
    private const float Diameter = 64f;
    private readonly Dictionary<uint, CanvasBitmap> _cache = new();

    /// <summary>
    /// The canonical additive white glow (matches the Swift starfire 64px sprite
    /// stop ramp: 1.0 → 0.55 → 0.14 → 0.0). For a tinted glow, the same stop
    /// shape is applied to the tint color.
    /// </summary>
    public CanvasBitmap Resolve(ICanvasResourceCreator device, in Rgba tint)
    {
        uint key = tint.BucketKey;
        if (_cache.TryGetValue(key, out CanvasBitmap? cached)) return cached;

        var rt = new CanvasRenderTarget(device, Diameter, Diameter, 96f);
        using (CanvasDrawingSession ds = rt.CreateDrawingSession())
        {
            ds.Clear(WinColor.FromArgb(0, 0, 0, 0));
            var stops = new[]
            {
                new CanvasGradientStop { Position = 0.0f, Color = Tint(tint, 1.00) },
                new CanvasGradientStop { Position = 0.22f, Color = Tint(tint, 0.55) },
                new CanvasGradientStop { Position = 0.50f, Color = Tint(tint, 0.14) },
                new CanvasGradientStop { Position = 1.0f, Color = Tint(tint, 0.0) },
            };
            using var brush = new CanvasRadialGradientBrush(device, stops)
            {
                Center = new System.Numerics.Vector2(Diameter / 2f, Diameter / 2f),
                RadiusX = Diameter / 2f,
                RadiusY = Diameter / 2f,
            };
            ds.FillRectangle(0, 0, Diameter, Diameter, brush);
        }

        _cache[key] = rt;
        return rt;
    }

    private static WinColor Tint(in Rgba c, double alpha) => WinColor.FromArgb(
        (byte)System.Math.Round(System.Math.Clamp(c.A * alpha, 0, 1) * 255.0),
        (byte)System.Math.Round(System.Math.Clamp(c.R, 0, 1) * 255.0),
        (byte)System.Math.Round(System.Math.Clamp(c.G, 0, 1) * 255.0),
        (byte)System.Math.Round(System.Math.Clamp(c.B, 0, 1) * 255.0));
}
