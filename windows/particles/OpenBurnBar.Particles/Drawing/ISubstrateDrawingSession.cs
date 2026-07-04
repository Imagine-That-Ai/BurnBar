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

    // ── Geometry + gradient + oriented-sprite primitives (added for the Volumetric
    //    family + the richer Constellation substrates: cut-gem facets, glass chips,
    //    god-ray shafts, star-chart rings + dashed guide edges). Each maps 1:1 onto a
    //    Win2D CanvasDrawingSession call — CanvasGeometry fill/stroke, FillRectangle,
    //    a rotated rounded rect, a CanvasLinearGradientBrush, and a transformed
    //    DrawImage of a cached anisotropic mask. The headless RecordingDrawingSession
    //    tallies + hashes them exactly like the original four so the CPU perf budget
    //    and the parity golden still measure the full painter cost. ──

    /// <summary>
    /// Axis-aligned filled rectangle (SwiftUI <c>ctx.fill(Path(rect))</c> / Win2D
    /// <c>FillRectangle</c>). Used for full-canvas presence washes (smoked-glass floor).
    /// </summary>
    void FillRect(double x, double y, double width, double height, in Rgba color);

    /// <summary>
    /// A rotated rounded square centered at (cx, cy) — a glass CHIP. <paramref name="halfExtent"/>
    /// is half the side; <paramref name="cornerRadius"/> the corner round; the quad is
    /// rotated by the pre-computed (<paramref name="rotCos"/>, <paramref name="rotSin"/>).
    /// SwiftUI <c>Path(roundedRect:).applying(transform)</c> / Win2D
    /// <c>FillRoundedRectangle</c> under a rotation <c>Transform</c>.
    /// </summary>
    void FillRoundedQuad(double cx, double cy, double halfExtent, double cornerRadius,
        double rotCos, double rotSin, in Rgba color);

    /// <summary>
    /// A filled closed polygon over the given vertices (SwiftUI <c>ctx.fill(Path)</c> of
    /// a closed subpath / Win2D <c>FillGeometry</c> of a filled <c>CanvasGeometry</c>).
    /// Used for the cut-gem lambert wedges + highlight triangles. The caller
    /// <c>stackalloc</c>s the small vertex span, so this never heap-allocates.
    /// </summary>
    void FillPolygon(ReadOnlySpan<Vec2> points, in Rgba color);

    /// <summary>
    /// A stroked poly-line over the given vertices (SwiftUI <c>ctx.stroke(Path)</c> /
    /// Win2D <c>DrawGeometry</c> of a path). When <paramref name="closed"/> the last
    /// vertex links back to the first (the crystal hex edge). Round cap + join.
    /// </summary>
    void StrokePolyline(ReadOnlySpan<Vec2> points, in Rgba color, double strokeWidth, bool closed);

    /// <summary>
    /// A stroked circle outline — an open star RING (SwiftUI
    /// <c>ctx.stroke(Path(ellipseIn:))</c> / Win2D <c>DrawCircle</c>). Distinct from a
    /// filled disc so the star-chart nodes read as rings, not dots.
    /// </summary>
    void StrokeCircle(double cx, double cy, double radius, in Rgba color, double strokeWidth);

    /// <summary>
    /// A rectangle filled with a linear gradient laid from (<paramref name="startX"/>,
    /// <paramref name="startY"/>) to (<paramref name="endX"/>, <paramref name="endY"/>).
    /// SwiftUI <c>ctx.fill(Path(rect), with: .linearGradient(...))</c> / Win2D
    /// <c>FillRectangle</c> with a <c>CanvasLinearGradientBrush</c>. The volumetric
    /// god-ray band. Stops are copied by the recorder / adapter (span not retained).
    /// </summary>
    void FillLinearGradientRect(double x, double y, double width, double height,
        ReadOnlySpan<GradientStop> stops, double startX, double startY, double endX, double endY);

    /// <summary>
    /// A cached anisotropic (tall) tinted luminance mask — the crepuscular SHAFT —
    /// anchored at its FOOT (<paramref name="footX"/>, <paramref name="footY"/>),
    /// extending up by <paramref name="height"/> along a <paramref name="rotation"/>
    /// (radians) light vector, <paramref name="width"/> wide, tinted by
    /// <paramref name="tint"/> at global <paramref name="opacity"/>. SwiftUI
    /// <c>g.translateBy; g.rotate; g.draw(shaftSprite, in: rect(-w/2,-h,w,h))</c> / Win2D
    /// a transformed <c>DrawImage</c> of a cached shaft bitmap. The isotropic radial
    /// glows still go through <see cref="DrawGlowSprite"/>.
    /// </summary>
    void DrawShaftSprite(double footX, double footY, double width, double height,
        double rotation, in Rgba tint, double opacity);

    /// <summary>
    /// One batched dashed poly-line stroke (SwiftUI <c>ctx.stroke(Path, style:
    /// StrokeStyle(dash:dashPhase:))</c> / Win2D <c>DrawGeometry</c> with a dashed
    /// <c>CanvasStrokeStyle</c>). Used for the crawling engraved guide ticks in the
    /// drawn-constellation chart; <paramref name="dashPhase"/> animates the crawl.
    /// </summary>
    void DrawDashedLineBatch(ReadOnlySpan<LineSegment> segments, in Rgba color,
        double strokeWidth, double dashOn, double dashOff, double dashPhase);
}
