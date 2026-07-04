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
/// One canvas-space vertex for a filled polygon (facets, glass quads, silk
/// ribbons, tessellated petals) or a stroked polyline (glowing wires, frost rims,
/// dispersion rails). The C# analog of a SwiftUI <c>Path</c> point.
/// </summary>
public readonly struct Vec2
{
    public readonly double X, Y;

    public Vec2(double x, double y)
    {
        X = x;
        Y = y;
    }
}

/// <summary>
/// One stop of a linear gradient — the C# analog of a SwiftUI
/// <c>Gradient.Stop</c> / Win2D <c>CanvasGradientStop</c>. <see cref="Location"/>
/// is in <c>0…1</c> along the gradient axis.
/// </summary>
public readonly struct GradientStop
{
    public readonly double Location;
    public readonly Rgba Color;

    public GradientStop(double location, in Rgba color)
    {
        Location = location;
        Color = color;
    }
}

/// <summary>
/// A dash pattern for a stroked polyline (the aurora-filament "charge" crawl):
/// <c>On</c> px painted, <c>Off</c> px skipped, offset by <c>Phase</c> px —
/// mirrors SwiftUI <c>StrokeStyle(dash:dashPhase:)</c> and Win2D
/// <c>CanvasStrokeStyle.CustomDashStyle</c>.
/// </summary>
public readonly struct DashPattern
{
    public readonly double On, Off, Phase;

    public DashPattern(double on, double off, double phase)
    {
        On = on;
        Off = off;
        Phase = phase;
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

    /// <summary>
    /// Fill a simple (single-contour) polygon with a solid color — the C# analog of
    /// SwiftUI <c>ctx.fill(Path)</c> for a closed poly (glacier facets, glass quads,
    /// tessellated petals, shadow/specular wedges). The contour is implicitly closed
    /// from the last vertex back to the first. On Win2D: <c>CanvasGeometry.CreatePolygon</c>
    /// + <c>FillGeometry</c> with the current blend.
    /// </summary>
    void FillPolygon(ReadOnlySpan<Vec2> points, in Rgba color);

    /// <summary>
    /// Fill a simple polygon with a linear gradient — the C# analog of
    /// SwiftUI <c>ctx.fill(Path, with: .linearGradient(Gradient(stops:), startPoint:, endPoint:))</c>
    /// (glass-ribbon cross-band gradient, silk-streamline arc-length ink/glow). The
    /// gradient axis runs from <c>(x0,y0)</c> to <c>(x1,y1)</c>. On Win2D:
    /// <c>CanvasLinearGradientBrush</c> + <c>FillGeometry</c> with the current blend.
    /// </summary>
    void FillPolygonGradient(ReadOnlySpan<Vec2> points, ReadOnlySpan<GradientStop> stops,
        double x0, double y0, double x1, double y1);

    /// <summary>
    /// Stroke one polyline (open by default, or closed) with a solid color — the C#
    /// analog of SwiftUI <c>ctx.stroke(Path, with: .color, style:)</c> (frost rims,
    /// silk creases, glass edges/rails, the aurora-filament hot core). Round caps +
    /// joins. When <paramref name="dash"/> is set, the stroke crawls a dash pattern
    /// (the filament "charge"). <paramref name="breakBefore"/>, when non-empty, marks
    /// vertices that begin a NEW sub-path (a <c>path.move(to:)</c>) so one call can
    /// carry a broken polyline. On Win2D: <c>CanvasPathBuilder</c> → <c>DrawGeometry</c>
    /// with a round <c>CanvasStrokeStyle</c> (+ <c>CustomDashStyle</c> when dashed).
    /// </summary>
    void StrokePolyline(ReadOnlySpan<Vec2> points, in Rgba color, double strokeWidth,
        bool closed = false, DashPattern? dash = null, ReadOnlySpan<bool> breakBefore = default);

    /// <summary>
    /// Stroke one polyline with a linear gradient — the C# analog of
    /// SwiftUI <c>ctx.stroke(Path, with: .linearGradient(...), style:)</c> (the
    /// aurora-filament wire, whose hue shifts amber→teal→violet down a vertical
    /// gradient axis). Supports the same broken-polyline + dash idioms as
    /// <see cref="StrokePolyline"/>. On Win2D: <c>CanvasPathBuilder</c> →
    /// <c>DrawGeometry</c> with a <c>CanvasLinearGradientBrush</c>.
    /// </summary>
    void StrokePolylineGradient(ReadOnlySpan<Vec2> points, ReadOnlySpan<GradientStop> stops,
        double x0, double y0, double x1, double y1, double strokeWidth,
        bool closed = false, DashPattern? dash = null, ReadOnlySpan<bool> breakBefore = default);
}
