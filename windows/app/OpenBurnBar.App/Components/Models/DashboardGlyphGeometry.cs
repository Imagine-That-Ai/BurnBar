// PORTED (hand-authored, coordinate-exact) from:
//   AgentLens/Views/Components/DashboardActionGlyphs.swift
//     — the hand-authored 24×24 stroked vector art (Import-from-logs + Sweep-recount)
//
// The Swift art draws SwiftUI Shapes onto a 24-unit grid mapped into the target rect. On
// Windows the DashboardActionGlyph UserControl builds a WinUI PathGeometry from these same
// grid-space figures, applying the identical grid→rect mapping (GlyphTransform). Pure
// `System` math so it compiles + runs on macOS and is asserted by
// windows/tests/components/DashboardGlyphGeometryTests.cs.

using System;
using System.Collections.Generic;

namespace OpenBurnBar.App.Components;

/// <summary>A point on the 24×24 authoring grid. Swift: coordinates passed to <c>Transform.p</c>.</summary>
public readonly record struct GlyphPoint(double X, double Y);

/// <summary>A single drawing step within a figure.</summary>
public enum GlyphSegmentKind
{
    Line,
    Quad,
}

/// <summary>One segment of a figure: a line to <see cref="End"/>, or a quadratic curve through
/// <see cref="Control"/> to <see cref="End"/>.</summary>
public readonly record struct GlyphSegment(GlyphSegmentKind Kind, GlyphPoint Control, GlyphPoint End);

/// <summary>Which of the two dashboard toolbar glyphs. Swift: <c>DashboardActionGlyphKind</c>.</summary>
public enum DashboardActionGlyphKind
{
    /// <summary>Pull in / refresh from log files on disk. Swift: <c>.importFromLogs</c>.</summary>
    ImportFromLogs,
    /// <summary>Rebuild usage from stored sessions. Swift: <c>.sweepRecount</c>.</summary>
    SweepRecount,
}

/// <summary>
/// A stroked figure in 24-grid space: either an open/closed path (Start + Segments) or an
/// ellipse (IsEllipse, Center, Radius). <see cref="StrokeScale"/> is the per-figure line-weight
/// multiplier the control turns into a pixel stroke width (max(floor, scale·(s/24))).
/// </summary>
public sealed class GlyphFigure
{
    public bool IsEllipse { get; init; }
    public GlyphPoint Center { get; init; }
    public double Radius { get; init; }
    public GlyphPoint Start { get; init; }
    public IReadOnlyList<GlyphSegment> Segments { get; init; } = Array.Empty<GlyphSegment>();
    public bool IsClosed { get; init; }
    public double StrokeScale { get; init; } = 1.0;

    public static GlyphFigure Ellipse(GlyphPoint center, double radius, double strokeScale) =>
        new() { IsEllipse = true, Center = center, Radius = radius, StrokeScale = strokeScale };

    public static GlyphFigure Line(GlyphPoint from, GlyphPoint to, double strokeScale) =>
        new()
        {
            Start = from,
            Segments = new[] { new GlyphSegment(GlyphSegmentKind.Line, default, to) },
            StrokeScale = strokeScale,
        };
}

/// <summary>Maps a 24-grid point into a target rect exactly as Swift's <c>Transform</c> does:
/// <c>s = min(w,h)</c>, origin centered, then <c>ox + x/24·s</c>, <c>oy + y/24·s</c>.</summary>
public readonly struct GlyphTransform
{
    private readonly double _s;
    private readonly double _ox;
    private readonly double _oy;

    public GlyphTransform(double rectX, double rectY, double rectWidth, double rectHeight)
    {
        _s = Math.Min(rectWidth, rectHeight);
        _ox = rectX + rectWidth / 2 - _s / 2;
        _oy = rectY + rectHeight / 2 - _s / 2;
    }

    /// <summary>Swift: <c>Transform.p(x, y)</c>.</summary>
    public (double X, double Y) Map(GlyphPoint p) => (_ox + p.X / 24.0 * _s, _oy + p.Y / 24.0 * _s);

    /// <summary>A grid-unit length scaled into the rect (e.g. the magnifier radius).</summary>
    public double Scale(double gridLength) => gridLength / 24.0 * _s;
}

/// <summary>The exact figure tables for the two dashboard action glyphs.</summary>
public static class DashboardGlyphGeometry
{
    public static IReadOnlyList<GlyphFigure> Figures(DashboardActionGlyphKind kind) =>
        kind == DashboardActionGlyphKind.ImportFromLogs ? ImportFromLogs() : SweepRecount();

    // MARK: Import from logs (magnifier + log lines + eureka sparkle)

    private static IReadOnlyList<GlyphFigure> ImportFromLogs()
    {
        const double linesScale = 1.35;
        const double lensScale = 1.45;
        const double sparkScale = 1.05;
        var o = new GlyphPoint(4.1, 5.4);
        const double a = 1.15;

        return new List<GlyphFigure>
        {
            // LogLinesUnderLens — three log lines.
            GlyphFigure.Line(new GlyphPoint(2.8, 7.2), new GlyphPoint(11.2, 7.2), linesScale),
            GlyphFigure.Line(new GlyphPoint(2.8, 10.0), new GlyphPoint(13.4, 10.0), linesScale),
            GlyphFigure.Line(new GlyphPoint(2.8, 12.6), new GlyphPoint(10.5, 12.6), linesScale),

            // MagnifierWithHandle — lens circle + handle.
            GlyphFigure.Ellipse(new GlyphPoint(15.4, 8.9), 5.1, lensScale),
            GlyphFigure.Line(new GlyphPoint(19.05, 12.15), new GlyphPoint(22.7, 16.35), lensScale),

            // EurekaSparkle — a tiny plus.
            GlyphFigure.Line(new GlyphPoint(o.X, o.Y - a), new GlyphPoint(o.X, o.Y + a), sparkScale),
            GlyphFigure.Line(new GlyphPoint(o.X - a, o.Y), new GlyphPoint(o.X + a, o.Y), sparkScale),
        };
    }

    // MARK: Recount (broom sweeping tally sticks)

    private static IReadOnlyList<GlyphFigure> SweepRecount()
    {
        const double tallyScale = 1.25;
        const double headScale = 1.35;
        const double handleScale = 1.2;
        const double bristleScale = 0.95;
        const double whimsyScale = 0.9;

        var figures = new List<GlyphFigure>();

        // TallySticks — four vertical marks.
        foreach (double x in new[] { 3.4, 5.1, 6.8, 8.5 })
        {
            figures.Add(GlyphFigure.Line(new GlyphPoint(x, 16.4), new GlyphPoint(x, 19.6), tallyScale));
        }

        // BroomHead — a closed quad-bounded quad.
        figures.Add(new GlyphFigure
        {
            Start = new GlyphPoint(11.8, 7.8),
            Segments = new[]
            {
                new GlyphSegment(GlyphSegmentKind.Quad, new GlyphPoint(14.8, 6.9), new GlyphPoint(17.6, 8.6)),
                new GlyphSegment(GlyphSegmentKind.Line, default, new GlyphPoint(16.9, 11.8)),
                new GlyphSegment(GlyphSegmentKind.Quad, new GlyphPoint(14.5, 12.1), new GlyphPoint(12.2, 10.8)),
            },
            IsClosed = true,
            StrokeScale = headScale,
        });

        // BroomHandle — one quadratic curve.
        figures.Add(new GlyphFigure
        {
            Start = new GlyphPoint(14.8, 11.2),
            Segments = new[]
            {
                new GlyphSegment(GlyphSegmentKind.Quad, new GlyphPoint(18.5, 14.2), new GlyphPoint(21.2, 18.6)),
            },
            StrokeScale = handleScale,
        });

        // BroomBristleTexture — three short strokes.
        figures.Add(GlyphFigure.Line(new GlyphPoint(13.2, 9.4), new GlyphPoint(13.8, 10.9), bristleScale));
        figures.Add(GlyphFigure.Line(new GlyphPoint(15.1, 9.1), new GlyphPoint(15.6, 10.8), bristleScale));
        figures.Add(GlyphFigure.Line(new GlyphPoint(16.8, 9.5), new GlyphPoint(17.1, 11.0), bristleScale));

        // WhimsySpeedLine — a small trailing curve.
        figures.Add(new GlyphFigure
        {
            Start = new GlyphPoint(10.4, 13.6),
            Segments = new[]
            {
                new GlyphSegment(GlyphSegmentKind.Quad, new GlyphPoint(9.1, 12.7), new GlyphPoint(7.6, 12.2)),
            },
            StrokeScale = whimsyScale,
        });

        return figures;
    }
}
