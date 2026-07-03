// =============================================================================
//  Win2D binding for the particle-engine renderer (Phase 3 / W6-DS-SWARM).
//
//  WINDOWS-ONLY / CI-DEFERRED. This is the ONLY GPU-bound piece of the substrate
//  renderer. It implements OpenBurnBar.Particles.Drawing.ISubstrateDrawingSession
//  against a real Win2D CanvasDrawingSession, so the platform-agnostic painters
//  (PlainDots + StarfireSubstrate, in the OpenBurnBar.Particles lib, already built
//  + perf-measured green on macOS) light up on a real device with additive bloom
//  (CanvasBlend.Add), cached radial-gradient glow sprites, batched geometry
//  strokes, and Gaussian-blurred under-glow layers.
//
//  It cannot be compiled on macOS (Win2D + WinUI targets are Windows-only), so it
//  lives in the WinUI app project, which is itself Windows-gated. The live-render
//  check (the actual ARM64 @60fps GPU pass) runs on the dev host / Windows CI per
//  windows/app/DEV_HOST_RUNBOOK.md — see Particles/README.md.
// =============================================================================

using System;
using System.Collections.Generic;
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

    // Blur-layer stack: each entry is (command-list, its drawing session, blur
    // radius, composite blend, saved parent session). The "current" target is the
    // top of the stack, or the root session when empty.
    private readonly Stack<BlurLayer> _layers = new();

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

    public void DrawGlowSprite(double cx, double cy, double radius, in Rgba tint, double opacity)
    {
        CanvasBitmap sprite = _sprites.Resolve(_device, tint);
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

    public IDisposable PushBlurLayer(double blurRadius, SubstrateBlend blend)
    {
        var cl = new CanvasCommandList(_device);
        CanvasDrawingSession session = cl.CreateDrawingSession();
        session.Blend = _blend == SubstrateBlend.Add ? CanvasBlend.Add : CanvasBlend.SourceOver;
        var layer = new BlurLayer(this, cl, session, (float)blurRadius, blend);
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
        target.DrawImage(blur);
        target.Blend = saved;

        layer.CommandList.Dispose();
        // Restore the painter-visible blend onto the now-current target.
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

    private sealed class BlurLayer : IDisposable
    {
        private readonly Win2DSubstrateDrawingSession _owner;
        public CanvasCommandList CommandList { get; }
        public CanvasDrawingSession Session { get; }
        public float BlurRadius { get; }
        public SubstrateBlend Blend { get; }
        private bool _disposed;

        public BlurLayer(Win2DSubstrateDrawingSession owner, CanvasCommandList cl,
            CanvasDrawingSession session, float blurRadius, SubstrateBlend blend)
        {
            _owner = owner;
            CommandList = cl;
            Session = session;
            BlurRadius = blurRadius;
            Blend = blend;
        }

        public void Dispose()
        {
            if (_disposed) return;
            _disposed = true;
            _owner.PopBlurLayer(this);
        }
    }
}
