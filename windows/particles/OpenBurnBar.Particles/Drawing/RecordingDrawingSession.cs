using System;
using OpenBurnBar.Particles.Model;

namespace OpenBurnBar.Particles.Drawing;

/// <summary>
/// Headless <see cref="ISubstrateDrawingSession"/> that records draw commands
/// instead of rasterizing them. Two jobs:
/// <list type="number">
///   <item><b>Perf harness</b>: it does the minimum bookkeeping per call, so a
///   frame's measured wall-time is the painter's CPU cost — particle iteration +
///   draw-command emission (the parity-critical, ARM64-sensitive work) — not GPU
///   rasterization (which is Windows-only and measured separately in CI).</item>
///   <item><b>Parity golden</b>: with <see cref="HashGeometry"/> on it folds every
///   command into an order-sensitive FNV-1a checksum, so a Mac↔Windows render of
///   the same <see cref="SwarmSubstrateFrame"/> can be compared command-for-command
///   without pixels.</item>
/// </list>
/// </summary>
public sealed class RecordingDrawingSession : ISubstrateDrawingSession
{
    private const ulong FnvOffset = 1469598103934665603UL;
    private const ulong FnvPrime = 1099511628211UL;

    public SubstrateBlend Blend { get; set; } = SubstrateBlend.Normal;

    /// <summary>When true, accumulate the geometry checksum. Off in the hot perf path.</summary>
    public bool HashGeometry { get; set; }

    // Command tallies (the draw-call budget matters for the 60fps GPU pass).
    public long FillCircleCount { get; private set; }
    public long StrokeCircleCount { get; private set; }
    public long FillPolygonCount { get; private set; }
    public long PolygonVertexCount { get; private set; }
    public long GradientQuadCount { get; private set; }
    public long StrokeRectCount { get; private set; }
    public long GlowSpriteCount { get; private set; }
    public long LineBatchCount { get; private set; }
    public long LineSegmentCount { get; private set; }
    public long BlurLayerCount { get; private set; }
    public long MaskLayerCount { get; private set; }
    public int MaxBlurNesting { get; private set; }

    private int _blurNesting;
    private ulong _checksum = FnvOffset;

    /// <summary>Order-sensitive FNV-1a checksum of all recorded geometry (valid when <see cref="HashGeometry"/> was on).</summary>
    public ulong Checksum => _checksum;

    /// <summary>Total draw commands emitted (all fills/strokes/glows/batches/layer pushes).</summary>
    public long TotalCommands => FillCircleCount + StrokeCircleCount + FillPolygonCount
        + GradientQuadCount + StrokeRectCount + GlowSpriteCount + LineBatchCount
        + BlurLayerCount + MaskLayerCount;

    /// <summary>Reset all tallies + checksum for a fresh frame.</summary>
    public void Reset()
    {
        Blend = SubstrateBlend.Normal;
        FillCircleCount = 0;
        StrokeCircleCount = 0;
        FillPolygonCount = 0;
        PolygonVertexCount = 0;
        GradientQuadCount = 0;
        StrokeRectCount = 0;
        GlowSpriteCount = 0;
        LineBatchCount = 0;
        LineSegmentCount = 0;
        BlurLayerCount = 0;
        MaskLayerCount = 0;
        MaxBlurNesting = 0;
        _blurNesting = 0;
        _checksum = FnvOffset;
    }

    public void FillCircle(double cx, double cy, double radius, in Rgba color)
    {
        FillCircleCount++;
        if (HashGeometry)
        {
            MixD(cx);
            MixD(cy);
            MixD(radius);
            MixColor(color);
            MixU((ulong)Blend);
        }
    }

    public void DrawGlowSprite(double cx, double cy, double radius, in Rgba tint, double opacity,
        GlowProfile profile = GlowProfile.Glow)
    {
        GlowSpriteCount++;
        if (HashGeometry)
        {
            MixD(cx);
            MixD(cy);
            MixD(radius);
            MixColor(tint);
            MixD(opacity);
            MixU((ulong)profile);
            MixU((ulong)Blend);
        }
    }

    public void StrokeCircle(double cx, double cy, double radius, in Rgba color, double strokeWidth)
    {
        StrokeCircleCount++;
        if (HashGeometry)
        {
            MixD(cx);
            MixD(cy);
            MixD(radius);
            MixColor(color);
            MixD(strokeWidth);
            MixU((ulong)Blend);
        }
    }

    public void FillPolygon(ReadOnlySpan<PointD> points, in Rgba color)
    {
        FillPolygonCount++;
        PolygonVertexCount += points.Length;
        if (HashGeometry)
        {
            MixColor(color);
            MixU((ulong)Blend);
            foreach (PointD p in points)
            {
                MixD(p.X);
                MixD(p.Y);
            }
        }
    }

    public void FillRoundedRectGradient(double cx, double cy, double halfW, double halfH,
        double cornerRadius, double rotation, in Rgba c0, in Rgba c1, in Rgba c2,
        in PointD gradStart, in PointD gradEnd, double opacity)
    {
        GradientQuadCount++;
        if (HashGeometry)
        {
            MixD(cx);
            MixD(cy);
            MixD(halfW);
            MixD(halfH);
            MixD(cornerRadius);
            MixD(rotation);
            MixColor(c0);
            MixColor(c1);
            MixColor(c2);
            MixD(gradStart.X);
            MixD(gradStart.Y);
            MixD(gradEnd.X);
            MixD(gradEnd.Y);
            MixD(opacity);
            MixU((ulong)Blend);
        }
    }

    public void StrokeRoundedRect(double cx, double cy, double halfW, double halfH,
        double cornerRadius, double rotation, in Rgba color, double strokeWidth, double opacity)
    {
        StrokeRectCount++;
        if (HashGeometry)
        {
            MixD(cx);
            MixD(cy);
            MixD(halfW);
            MixD(halfH);
            MixD(cornerRadius);
            MixD(rotation);
            MixColor(color);
            MixD(strokeWidth);
            MixD(opacity);
            MixU((ulong)Blend);
        }
    }

    public void DrawLineBatch(ReadOnlySpan<LineSegment> segments, in Rgba color, double strokeWidth)
    {
        LineBatchCount++;
        LineSegmentCount += segments.Length;
        if (HashGeometry)
        {
            MixColor(color);
            MixD(strokeWidth);
            foreach (LineSegment s in segments)
            {
                MixD(s.X0);
                MixD(s.Y0);
                MixD(s.X1);
                MixD(s.Y1);
            }
        }
    }

    public IDisposable PushBlurLayer(double blurRadius, SubstrateBlend blend, double layerOpacity = 1.0)
    {
        BlurLayerCount++;
        _blurNesting++;
        if (_blurNesting > MaxBlurNesting) MaxBlurNesting = _blurNesting;
        if (HashGeometry)
        {
            MixD(blurRadius);
            MixU((ulong)blend);
            MixD(layerOpacity);
        }
        return new BlurScope(this);
    }

    public IDisposable PushRadialMaskLayer(double cx, double cy, double whiteRadius, double clearRadius)
    {
        MaskLayerCount++;
        _blurNesting++;
        if (_blurNesting > MaxBlurNesting) MaxBlurNesting = _blurNesting;
        if (HashGeometry)
        {
            MixD(cx);
            MixD(cy);
            MixD(whiteRadius);
            MixD(clearRadius);
        }
        return new BlurScope(this);
    }

    private void PopBlurLayer() => _blurNesting--;

    // Quantize to 1e-3 before hashing so float micro-jitter across platforms
    // (x87 vs SSE vs NEON rounding) doesn't spuriously fail parity goldens.
    private void MixD(double v)
    {
        long q = (long)System.Math.Round(v * 1000.0);
        MixU(unchecked((ulong)q));
    }

    private void MixColor(in Rgba c) => MixU(c.BucketKey);

    private void MixU(ulong v)
    {
        _checksum = (_checksum ^ v) * FnvPrime;
    }

    private sealed class BlurScope : IDisposable
    {
        private RecordingDrawingSession? _owner;

        public BlurScope(RecordingDrawingSession owner) => _owner = owner;

        public void Dispose()
        {
            _owner?.PopBlurLayer();
            _owner = null;
        }
    }
}
