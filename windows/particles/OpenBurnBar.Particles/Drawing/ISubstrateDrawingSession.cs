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
    /// A cached radial sprite drawn centered at (cx, cy) with the given outer
    /// radius and global <paramref name="opacity"/>. Mirrors the Swift
    /// <c>SpriteCache.whiteGlow</c> / <c>tintedGlow</c> / <c>radial(stops:)</c> path
    /// (bake once, draw many). <paramref name="profile"/> selects the baked stop
    /// ramp — a soft glow, a hollow glass sphere (Film Bubble), or a hot spark
    /// (caustic sparks / catchlights). On Win2D this is a cached <c>CanvasBitmap</c>
    /// (baked from a <c>CanvasRadialGradientBrush</c>) drawn with the current blend.
    /// </summary>
    void DrawGlowSprite(double cx, double cy, double radius, in Rgba tint, double opacity,
        GlowProfile profile = GlowProfile.Glow);

    /// <summary>
    /// A stroked (unfilled) circle — SwiftUI <c>ctx.stroke(Path(ellipseIn:), lineWidth:)</c> /
    /// Win2D <c>DrawCircle</c>. The soap-film rim rings of the Moiré "Film Bubble".
    /// </summary>
    void StrokeCircle(double cx, double cy, double radius, in Rgba color, double strokeWidth);

    /// <summary>
    /// A filled convex polygon — SwiftUI <c>ctx.fill(trianglePath)</c> / Win2D
    /// <c>FillGeometry(CanvasGeometry.CreatePolygon)</c>. The Mesh/Moiré faceted
    /// crystal lattices (triangular gem facets, gem tables, specular glints).
    /// </summary>
    void FillPolygon(ReadOnlySpan<PointD> points, in Rgba color);

    /// <summary>
    /// A rotated, rounded-rect lozenge filled with a 3-stop linear gradient — the
    /// Mesh "Gradient Patch" stained-glass panes. SwiftUI
    /// <c>ctx.fill(Path(roundedRect:).applying(rotate), .linearGradient(...))</c>;
    /// on Win2D a <c>CanvasGeometry.CreateRoundedRectangle</c> transformed by
    /// <paramref name="rotation"/> about the center, filled with a
    /// <c>CanvasLinearGradientBrush</c> from <paramref name="gradStart"/> to
    /// <paramref name="gradEnd"/> (stops at 0.0 / 0.5 / 1.0). <paramref name="opacity"/>
    /// is the SwiftUI <c>ctx.opacity</c> multiplier folded in once.
    /// </summary>
    void FillRoundedRectGradient(double cx, double cy, double halfW, double halfH,
        double cornerRadius, double rotation, in Rgba c0, in Rgba c1, in Rgba c2,
        in PointD gradStart, in PointD gradEnd, double opacity);

    /// <summary>
    /// The hairline iridescent seam stroke around a "Gradient Patch" pane — the
    /// stroked twin of <see cref="FillRoundedRectGradient"/> (same rotated rounded
    /// rect, single color). Win2D <c>DrawGeometry(roundedRect)</c>.
    /// </summary>
    void StrokeRoundedRect(double cx, double cy, double halfW, double halfH,
        double cornerRadius, double rotation, in Rgba color, double strokeWidth, double opacity);

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
    /// <paramref name="blurRadius"/>, and composited back with <paramref name="blend"/>
    /// at <paramref name="layerOpacity"/> (the SwiftUI <c>layer.opacity</c> — a whole-
    /// layer multiply applied once on composite, e.g. Living Grain's 0.55 light haze).
    /// On Win2D: render into a <c>CanvasCommandList</c>, wrap it in a
    /// <c>GaussianBlurEffect</c> (and an <c>OpacityEffect</c> when &lt; 1), then
    /// <c>DrawImage</c> onto the parent. Dispose to flush.
    /// </summary>
    IDisposable PushBlurLayer(double blurRadius, SubstrateBlend blend, double layerOpacity = 1.0);

    /// <summary>
    /// Push a radial alpha-mask sub-layer — the C# analog of SwiftUI
    /// <c>ctx.drawLayer { … ; layer.blendMode = .destinationIn; layer.fill(rect, .radialGradient(...)) }</c>.
    /// All draws issued while the returned scope is alive are captured and then
    /// composited back MASKED by a radial gradient that is fully opaque within
    /// <paramref name="whiteRadius"/> and feathers to clear at
    /// <paramref name="clearRadius"/> (centered at cx, cy) — so a full-canvas
    /// interference field (Moiré "Ruling Grating") dissolves softly into the swarm
    /// instead of ending on a hard rectangle. On Win2D: draw into a
    /// <c>CanvasCommandList</c>, then <c>AlphaMaskEffect</c> it with a rendered
    /// radial gradient and <c>DrawImage</c> onto the parent. Dispose to flush.
    /// </summary>
    IDisposable PushRadialMaskLayer(double cx, double cy, double whiteRadius, double clearRadius);
}
