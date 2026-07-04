using System;
using OpenBurnBar.Particles.Model;

namespace OpenBurnBar.Particles.Drawing;

/// <summary>
/// Compositing mode — the C# analog of SwiftUI <c>GraphicsContext.BlendMode</c>
/// and Win2D <c>CanvasBlend</c>. Additive bloom (<see cref="Add"/>) is what makes
/// stacked glows read as luminous plasma on a dark canvas.
/// </summary>
public enum SubstrateBlend
{
    /// <summary>Source-over alpha (SwiftUI <c>.normal</c> / Win2D <c>CanvasBlend.SourceOver</c>).</summary>
    Normal,

    /// <summary>Additive (SwiftUI <c>.plusLighter</c> / Win2D <c>CanvasBlend.Add</c>).</summary>
    Add,
}

/// <summary>
/// One line segment for a batched stroke (diffraction crosses, lattice edges).
/// </summary>
public readonly struct LineSegment
{
    public readonly double X0, Y0, X1, Y1;

    public LineSegment(double x0, double y0, double x1, double y1)
    {
        X0 = x0;
        Y0 = y0;
        X1 = x1;
        Y1 = y1;
    }
}

/// <summary>
/// Abstract per-frame drawing surface the substrate painters draw into. This is
/// the seam that keeps the parity-critical painter logic platform-agnostic:
/// <list type="bullet">
///   <item>On Windows, <c>Win2DSubstrateDrawingSession</c> forwards each call to a
///   Win2D <c>CanvasDrawingSession</c> (<c>FillCircle</c>, <c>CanvasBlend.Add</c>,
///   <c>CanvasRadialGradientBrush</c>, <c>GaussianBlurEffect</c>).</item>
///   <item>Headless (macOS CI / perf harness), <c>RecordingDrawingSession</c>
///   counts commands and hashes geometry, so the painter's CPU cost and its
///   draw-command output are measurable and golden-testable without a GPU.</item>
/// </list>
/// The method surface deliberately mirrors the subset of <c>CanvasDrawingSession</c>
/// that the Swift <c>GraphicsContext</c> painters use, so the Win2D adapter is a
/// nearly 1:1 forward.
/// </summary>
public interface ISubstrateDrawingSession
{
    /// <summary>Active compositing mode. Painters flip this to <see cref="SubstrateBlend.Add"/> for bloom passes.</summary>
    SubstrateBlend Blend { get; set; }

    /// <summary>Filled circle (SwiftUI <c>ctx.fill(Path(ellipseIn:))</c> / Win2D <c>FillCircle</c>).</summary>
    void FillCircle(double cx, double cy, double radius, in Rgba color);

    /// <summary>
    /// A cached radial-glow sprite drawn centered at (cx, cy) with the given
    /// outer radius and global <paramref name="opacity"/>. Mirrors the Swift
    /// <c>SpriteCache.whiteGlow</c> / <c>tintedGlow</c> path (bake once, draw many).
    /// On Win2D this is a cached <c>CanvasBitmap</c> (or <c>CanvasRadialGradientBrush</c>)
    /// drawn with the current blend.
    /// </summary>
    void DrawGlowSprite(double cx, double cy, double radius, in Rgba tint, double opacity);

    /// <summary>
    /// One batched poly-line stroke — mirrors the Swift "one <c>ctx.stroke(Path)</c>
    /// per alpha tier" batching (cheap on the GPU, one geometry per color/width).
    /// On Win2D this builds a single <c>CanvasGeometry</c> and strokes it once.
    /// </summary>
    void DrawLineBatch(ReadOnlySpan<LineSegment> segments, in Rgba color, double strokeWidth);

    /// <summary>
    /// Push a blurred, blended sub-layer — the C# analog of SwiftUI
    /// <c>ctx.drawLayer { layer in layer.addFilter(.blur(radius:)); … }</c>. All
    /// draw calls issued while the returned scope is alive are captured, blurred by
    /// <paramref name="blurRadius"/>, and composited back with <paramref name="blend"/>.
    /// On Win2D: render into a <c>CanvasCommandList</c>, wrap it in a
    /// <c>GaussianBlurEffect</c>, then <c>DrawImage</c> onto the parent. Dispose to flush.
    /// </summary>
    IDisposable PushBlurLayer(double blurRadius, SubstrateBlend blend);
}
