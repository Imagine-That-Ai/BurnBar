// WINDOWS-ONLY / CI-DEFERRED (Win2D). See Win2DSubstrateDrawingSession.cs header.

using System.Collections.Generic;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Brushes;
using OpenBurnBar.Particles.Drawing;
using OpenBurnBar.Particles.Model;
using WinColor = Windows.UI.Color;

namespace OpenBurnBar.App.Particles;

/// <summary>
/// Win2D analog of the Swift <c>SpriteCache</c> (<c>Views/Substrate/SubstrateKit.swift</c>):
/// bakes a soft radial-gradient sprite ONCE per (profile, tint) into a
/// <see cref="CanvasRenderTarget"/>, then hands it back for many draws per frame.
/// Keyed by the <see cref="GlowProfile"/> and the tint's 8-bit bucket key so
/// micro-jitter in the color driver never thrashes the cache.
/// </summary>
public sealed class GlowSpriteCache
{
    private const float Diameter = 64f;
    private readonly Dictionary<long, CanvasBitmap> _cache = new();

    /// <summary>
    /// Resolve the baked sprite for <paramref name="profile"/> tinted by
    /// <paramref name="tint"/>. <see cref="GlowProfile.Glow"/> matches the Swift
    /// starfire 64px stop ramp (1.0 → 0.55 → 0.14 → 0.0); <see cref="GlowProfile.Sphere"/>
    /// is the Film-Bubble hollow glass (clear core → bright rim at 0.92 → clear);
    /// <see cref="GlowProfile.Spark"/> is a hot specular catchlight.
    /// </summary>
    public CanvasBitmap Resolve(ICanvasResourceCreator device, in Rgba tint, GlowProfile profile = GlowProfile.Glow)
    {
        long key = ((long)profile << 32) | tint.BucketKey;
        if (_cache.TryGetValue(key, out CanvasBitmap? cached)) return cached;

        var rt = new CanvasRenderTarget(device, Diameter, Diameter, 96f);
        using (CanvasDrawingSession ds = rt.CreateDrawingSession())
        {
            ds.Clear(WinColor.FromArgb(0, 0, 0, 0));
            using var brush = new CanvasRadialGradientBrush(device, StopsFor(profile, tint))
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

    public void Clear()
    {
        foreach (CanvasBitmap bitmap in _cache.Values)
        {
            bitmap.Dispose();
        }

        _cache.Clear();
    }

    private static CanvasGradientStop[] StopsFor(GlowProfile profile, in Rgba tint) => profile switch
    {
        GlowProfile.Sphere => new[]
        {
            new CanvasGradientStop { Position = 0.00f, Color = Tint(tint, 0.05) },
            new CanvasGradientStop { Position = 0.42f, Color = Tint(tint, 0.12) },
            new CanvasGradientStop { Position = 0.74f, Color = Tint(tint, 0.42) },
            new CanvasGradientStop { Position = 0.92f, Color = Tint(tint, 0.95) },
            new CanvasGradientStop { Position = 1.00f, Color = Tint(tint, 0.00) },
        },
        GlowProfile.Spark => new[]
        {
            new CanvasGradientStop { Position = 0.00f, Color = Tint(tint, 1.00) },
            new CanvasGradientStop { Position = 0.34f, Color = Tint(tint, 0.78) },
            new CanvasGradientStop { Position = 0.70f, Color = Tint(tint, 0.22) },
            new CanvasGradientStop { Position = 1.00f, Color = Tint(tint, 0.00) },
        },
        _ => new[]
        {
            new CanvasGradientStop { Position = 0.00f, Color = Tint(tint, 1.00) },
            new CanvasGradientStop { Position = 0.22f, Color = Tint(tint, 0.55) },
            new CanvasGradientStop { Position = 0.50f, Color = Tint(tint, 0.14) },
            new CanvasGradientStop { Position = 1.00f, Color = Tint(tint, 0.00) },
        },
    };

    private static WinColor Tint(in Rgba c, double alpha) => WinColor.FromArgb(
        (byte)System.Math.Round(System.Math.Clamp(c.A * alpha, 0, 1) * 255.0),
        (byte)System.Math.Round(System.Math.Clamp(c.R, 0, 1) * 255.0),
        (byte)System.Math.Round(System.Math.Clamp(c.G, 0, 1) * 255.0),
        (byte)System.Math.Round(System.Math.Clamp(c.B, 0, 1) * 255.0));
}
