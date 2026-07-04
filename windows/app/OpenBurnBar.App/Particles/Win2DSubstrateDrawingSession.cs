// =============================================================================
//  Win2D binding for the particle-engine renderer (Phase 3 / W6-DS-SWARM).
//
//  WINDOWS-ONLY / CI-DEFERRED. This is the ONLY GPU-bound piece of the substrate
//  renderer. It implements OpenBurnBar.Particles.Drawing.ISubstrateDrawingSession
//  against a real Win2D CanvasDrawingSession, so the platform-agnostic painters
//  (PlainDots + Constellation/Starfire + the Mesh & Moiré families, in the
//  OpenBurnBar.Particles lib, already built + perf-measured green on macOS) light
//  up on a real device with additive bloom (CanvasBlend.Add), cached radial-gradient
//  sprites (glow / glass-sphere / spark profiles), batched geometry strokes,
//  triangular facet fills, rotated linear-gradient panes, radial alpha masks, and
//  Gaussian-blurred under-glow layers.
//
//  It cannot be compiled on macOS (Win2D + WinUI targets are Windows-only), so it
//  lives in the WinUI app project, which is itself Windows-gated. The live-render
//  check (the actual ARM64 @60fps GPU pass) runs on the dev host / Windows CI per
//  windows/app/DEV_HOST_RUNBOOK.md — see Particles/README.md.
// =============================================================================

using System;
using System.Collections.Generic;
using System.Numerics;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Brushes;
using Microsoft.Graphics.Canvas.Effects;
using Microsoft.Graphics.Canvas.Geometry;
using OpenBurnBar.Particles.Drawing;
using OpenBurnBar.Particles.Model;
using WinColor = Windows.UI.Color;

namespace OpenBurnBar.App.Particles;

/// <summary>
/// Adapts a Win2D <see cref="CanvasDrawingSession"/> to the engine-agnostic
/// <see cref="ISubstrateDrawingSession"/>. A near-1:1 forward — the abstraction was
/// shaped after the <c>CanvasDrawingSession</c> subset the painters use.
/// </summary>
/// <remarks>
/// One instance per frame (cheap); the glow-sprite cache is owned by the host and
/// injected so sprites are baked once and reused across frames.
/// </remarks>
public sealed class Win2DSubstrateDrawingSession : ISubstrateDrawingSession
{
    private readonly CanvasDrawingSession _root;
    private readonly ICanvasResourceCreator _device;
    private readonly GlowSpriteCache _sprites;

    // Off-screen layer stack (blur + radial-mask). Each entry owns a command-list
    // and its drawing session; the "current" target is the top of the stack, or the
    // root session when empty.
    private readonly Stack<ILayer> _layers = new();

    private SubstrateBlend _blend = SubstrateBlend.Normal;

    public Win2DSubstrateDrawingSession(CanvasDrawingSession root, GlowSpriteCache sprites)
    {
        _root = root;
        _device = root.Device;
        _sprites = sprites;
        Current.Blend = CanvasBlend.SourceOver;
    }

    private CanvasDrawingSession Current => _layers.Count > 0 ? _layers.Peek().Session : _root;

    public SubstrateBlend Blend
    {
        get => _blend;
        set
        {
            _blend = value;
            Current.Blend = value == SubstrateBlend.Add ? CanvasBlend.Add : CanvasBlend.SourceOver;
        }
    }

    public void FillCircle(double cx, double cy, double radius, in Rgba color)
        => Current.FillCircle((float)cx, (float)cy, (float)radius, ToColor(color));

    public void StrokeCircle(double cx, double cy, double radius, in Rgba color, double strokeWidth)
        => Current.DrawCircle((float)cx, (float)cy, (float)radius, ToColor(color), (float)strokeWidth, RoundStroke);

    public void FillPolygon(ReadOnlySpan<PointD> points, in Rgba color)
    {
        if (points.Length < 3) return;
        var verts = new Vector2[points.Length];
        for (int i = 0; i < points.Length; i++) verts[i] = new Vector2((float)points[i].X, (float)points[i].Y);
        using CanvasGeometry geometry = CanvasGeometry.CreatePolygon(_device, verts);
        Current.FillGeometry(geometry, ToColor(color));
    }

    public void FillRoundedRectGradient(double cx, double cy, double halfW, double halfH,
        double cornerRadius, double rotation, in Rgba c0, in Rgba c1, in Rgba c2,
        in PointD gradStart, in PointD gradEnd, double opacity)
    {
        using CanvasGeometry geo = RoundedRect(cx, cy, halfW, halfH, cornerRadius, rotation);
        var stops = new[]
        {
            new CanvasGradientStop { Position = 0.0f, Color = ToColor(c0) },
            new CanvasGradientStop { Position = 0.5f, Color = ToColor(c1) },
            new CanvasGradientStop { Position = 1.0f, Color = ToColor(c2) },
        };
        using var brush = new CanvasLinearGradientBrush(_device, stops)
        {
            StartPoint = new Vector2((float)gradStart.X, (float)gradStart.Y),
            EndPoint = new Vector2((float)gradEnd.X, (float)gradEnd.Y),
            Opacity = (float)Math.Clamp(opacity, 0.0, 1.0),
        };
        Current.FillGeometry(geo, brush);
    }

    public void StrokeRoundedRect(double cx, double cy, double halfW, double halfH,
        double cornerRadius, double rotation, in Rgba color, double strokeWidth, double opacity)
    {
        using CanvasGeometry geo = RoundedRect(cx, cy, halfW, halfH, cornerRadius, rotation);
        WinColor c = ToColor(color.WithOpacity(Math.Clamp(color.A * opacity, 0.0, 1.0)));
        Current.DrawGeometry(geo, c, (float)strokeWidth, RoundStroke);
    }

    private CanvasGeometry RoundedRect(double cx, double cy, double halfW, double halfH,
        double cornerRadius, double rotation)
    {
        CanvasGeometry geo = CanvasGeometry.CreateRoundedRectangle(
            _device, (float)(cx - halfW), (float)(cy - halfH),
            (float)(halfW * 2), (float)(halfH * 2), (float)cornerRadius, (float)cornerRadius);
        if (rotation != 0.0)
        {
            Matrix3x2 m = Matrix3x2.CreateRotation((float)rotation, new Vector2((float)cx, (float)cy));
            CanvasGeometry rotated = geo.Transform(m);
            geo.Dispose();
            return rotated;
        }
        return geo;
    }

    public void DrawGlowSprite(double cx, double cy, double radius, in Rgba tint, double opacity,
        GlowProfile profile = GlowProfile.Glow)
    {
        CanvasBitmap sprite = _sprites.Resolve(_device, tint, profile);
        float r = (float)radius;
        var dest = new Windows.Foundation.Rect(cx - r, cy - r, r * 2, r * 2);
        Current.DrawImage(sprite, dest, sprite.Bounds, (float)Math.Clamp(opacity, 0.0, 1.0));
    }

    public void DrawLineBatch(ReadOnlySpan<LineSegment> segments, in Rgba color, double strokeWidth)
    {
        if (segments.Length == 0) return;
        using var pb = new CanvasPathBuilder(_device);
        foreach (LineSegment s in segments)
        {
            pb.BeginFigure((float)s.X0, (float)s.Y0);
            pb.AddLine((float)s.X1, (float)s.Y1);
            pb.EndFigure(CanvasFigureLoop.Open);
        }
        using CanvasGeometry geometry = CanvasGeometry.CreatePath(pb);
        Current.DrawGeometry(geometry, ToColor(color), (float)strokeWidth, RoundStroke);
    }

    public IDisposable PushBlurLayer(double blurRadius, SubstrateBlend blend, double layerOpacity = 1.0)
    {
        var cl = new CanvasCommandList(_device);
        CanvasDrawingSession session = cl.CreateDrawingSession();
        session.Blend = _blend == SubstrateBlend.Add ? CanvasBlend.Add : CanvasBlend.SourceOver;
        var layer = new BlurLayer(this, cl, session, (float)blurRadius, blend, (float)Math.Clamp(layerOpacity, 0.0, 1.0));
        _layers.Push(layer);
        return layer;
    }

    public IDisposable PushRadialMaskLayer(double cx, double cy, double whiteRadius, double clearRadius)
    {
        var cl = new CanvasCommandList(_device);
        CanvasDrawingSession session = cl.CreateDrawingSession();
        session.Blend = _blend == SubstrateBlend.Add ? CanvasBlend.Add : CanvasBlend.SourceOver;
        var layer = new MaskLayer(this, cl, session, cx, cy, whiteRadius, clearRadius);
        _layers.Push(layer);
        return layer;
    }

    private void PopBlurLayer(BlurLayer layer)
    {
        if (_layers.Count == 0 || !ReferenceEquals(_layers.Peek(), layer)) return;
        _layers.Pop();

        layer.Session.Dispose();
        using var blur = new GaussianBlurEffect
        {
            Source = layer.CommandList,
            BlurAmount = layer.BlurRadius,
            BorderMode = EffectBorderMode.Soft,
        };

        CanvasDrawingSession target = Current;
        CanvasBlend saved = target.Blend;
        target.Blend = layer.Blend == SubstrateBlend.Add ? CanvasBlend.Add : CanvasBlend.SourceOver;
        if (layer.LayerOpacity < 0.999f)
        {
            using var faded = new OpacityEffect { Source = blur, Opacity = layer.LayerOpacity };
            target.DrawImage(faded);
        }
        else
        {
            target.DrawImage(blur);
        }
        target.Blend = saved;

        layer.CommandList.Dispose();
        target.Blend = _blend == SubstrateBlend.Add ? CanvasBlend.Add : CanvasBlend.SourceOver;
    }

    private void PopMaskLayer(MaskLayer layer)
    {
        if (_layers.Count == 0 || !ReferenceEquals(_layers.Peek(), layer)) return;
        _layers.Pop();

        layer.Session.Dispose();

        // Radial alpha mask: opaque within whiteRadius, feathering to clear at
        // clearRadius. Baked into a small command list, then AlphaMask-composited so
        // the captured full-field interference dissolves softly (never a hard edge).
        using var maskCl = new CanvasCommandList(_device);
        using (CanvasDrawingSession maskDs = maskCl.CreateDrawingSession())
        {
            var stops = new[]
            {
                new CanvasGradientStop { Position = 0.0f, Color = WinColor.FromArgb(255, 255, 255, 255) },
                new CanvasGradientStop
                {
                    Position = (float)Math.Clamp(layer.WhiteRadius / Math.Max(1e-3, layer.ClearRadius), 0.0, 1.0),
                    Color = WinColor.FromArgb(255, 255, 255, 255),
                },
                new CanvasGradientStop { Position = 1.0f, Color = WinColor.FromArgb(0, 255, 255, 255) },
            };
            using var maskBrush = new CanvasRadialGradientBrush(_device, stops)
            {
                Center = new Vector2((float)layer.Cx, (float)layer.Cy),
                RadiusX = (float)layer.ClearRadius,
                RadiusY = (float)layer.ClearRadius,
            };
            float ext = (float)layer.ClearRadius;
            maskDs.FillRectangle((float)(layer.Cx - ext), (float)(layer.Cy - ext), ext * 2, ext * 2, maskBrush);
        }

        using var masked = new AlphaMaskEffect
        {
            Source = layer.CommandList,
            AlphaMask = maskCl,
        };

        CanvasDrawingSession target = Current;
        CanvasBlend saved = target.Blend;
        target.Blend = _blend == SubstrateBlend.Add ? CanvasBlend.Add : CanvasBlend.SourceOver;
        target.DrawImage(masked);
        target.Blend = saved;

        layer.CommandList.Dispose();
        target.Blend = _blend == SubstrateBlend.Add ? CanvasBlend.Add : CanvasBlend.SourceOver;
    }

    private static readonly CanvasStrokeStyle RoundStroke = new()
    {
        StartCap = CanvasCapStyle.Round,
        EndCap = CanvasCapStyle.Round,
        LineJoin = CanvasLineJoin.Round,
    };

    private static WinColor ToColor(in Rgba c) => WinColor.FromArgb(
        (byte)Math.Round(Math.Clamp(c.A, 0, 1) * 255.0),
        (byte)Math.Round(Math.Clamp(c.R, 0, 1) * 255.0),
        (byte)Math.Round(Math.Clamp(c.G, 0, 1) * 255.0),
        (byte)Math.Round(Math.Clamp(c.B, 0, 1) * 255.0));

    private interface ILayer : IDisposable
    {
        CanvasDrawingSession Session { get; }
    }

    private sealed class BlurLayer : ILayer
    {
        private readonly Win2DSubstrateDrawingSession _owner;
        public CanvasCommandList CommandList { get; }
        public CanvasDrawingSession Session { get; }
        public float BlurRadius { get; }
        public SubstrateBlend Blend { get; }
        public float LayerOpacity { get; }
        private bool _disposed;

        public BlurLayer(Win2DSubstrateDrawingSession owner, CanvasCommandList cl,
            CanvasDrawingSession session, float blurRadius, SubstrateBlend blend, float layerOpacity)
        {
            _owner = owner;
            CommandList = cl;
            Session = session;
            BlurRadius = blurRadius;
            Blend = blend;
            LayerOpacity = layerOpacity;
        }

        public void Dispose()
        {
            if (_disposed) return;
            _disposed = true;
            _owner.PopBlurLayer(this);
        }
    }

    private sealed class MaskLayer : ILayer
    {
        private readonly Win2DSubstrateDrawingSession _owner;
        public CanvasCommandList CommandList { get; }
        public CanvasDrawingSession Session { get; }
        public double Cx { get; }
        public double Cy { get; }
        public double WhiteRadius { get; }
        public double ClearRadius { get; }
        private bool _disposed;

        public MaskLayer(Win2DSubstrateDrawingSession owner, CanvasCommandList cl,
            CanvasDrawingSession session, double cx, double cy, double whiteRadius, double clearRadius)
        {
            _owner = owner;
            CommandList = cl;
            Session = session;
            Cx = cx;
            Cy = cy;
            WhiteRadius = whiteRadius;
            ClearRadius = clearRadius;
        }

        public void Dispose()
        {
            if (_disposed) return;
            _disposed = true;
            _owner.PopMaskLayer(this);
        }
    }
}
