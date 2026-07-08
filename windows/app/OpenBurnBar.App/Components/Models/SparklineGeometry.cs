// PORTED (hand-authored) from:
//   AgentLens/Views/Components/MiniSparkline.swift
//     — the Swift Charts LineMark/AreaMark with .interpolationMethod(.catmullRom)
//
// SwiftUI Charts renders the smoothing internally; on Windows there is no Charts
// equivalent, so this computes the SAME Catmull-Rom curve explicitly as cubic Béziers the
// MiniSparkline UserControl feeds into a WinUI PathGeometry. Pure `System` math so it
// compiles + runs on macOS and is asserted by windows/tests/components/SparklineGeometryTests.cs.

using System;
using System.Collections.Generic;

namespace OpenBurnBar.App.Components;

/// <summary>A 2-D point in the sparkline's view coordinate space (origin top-left, y down).</summary>
public readonly record struct SparkPoint(double X, double Y);

/// <summary>A cubic Bézier segment: <c>Start</c> → (<c>Control1</c>, <c>Control2</c>) → <c>End</c>.</summary>
public readonly record struct SparkBezier(SparkPoint Start, SparkPoint Control1, SparkPoint Control2, SparkPoint End);

/// <summary>Sparkline layout + Catmull-Rom smoothing math.</summary>
public static class SparklineGeometry
{
    /// <summary>
    /// Normalize <paramref name="data"/> into view points across <paramref name="width"/> ×
    /// <paramref name="height"/>. X is spread evenly (i/(n-1)·W); Y is flipped so a larger value
    /// sits higher (smaller y). A flat series pins to the vertical middle (matching how Charts
    /// centers a zero-range domain).
    /// </summary>
    public static IReadOnlyList<SparkPoint> NormalizedPoints(IReadOnlyList<double> data, double width, double height)
    {
        var points = new List<SparkPoint>();
        if (data is null || data.Count == 0)
        {
            return points;
        }

        double min = double.PositiveInfinity;
        double max = double.NegativeInfinity;
        foreach (double v in data)
        {
            if (v < min) min = v;
            if (v > max) max = v;
        }

        double range = max - min;
        int n = data.Count;

        for (int i = 0; i < n; i++)
        {
            double x = n == 1 ? width : (double)i / (n - 1) * width;
            double norm = range > 0 ? (data[i] - min) / range : 0.5; // 0..1, higher = taller
            double y = height - norm * height; // flip so bigger value = smaller y
            points.Add(new SparkPoint(x, y));
        }

        return points;
    }

    /// <summary>
    /// Convert a polyline into Catmull-Rom cubic Béziers (uniform, tension 1/6 — the standard
    /// Catmull-Rom-to-Bézier conversion Charts' <c>.catmullRom</c> uses). Endpoints are
    /// duplicated so the first/last segments stay anchored. Returns n-1 segments for n points.
    /// </summary>
    public static IReadOnlyList<SparkBezier> CatmullRomBeziers(IReadOnlyList<SparkPoint> pts)
    {
        var segments = new List<SparkBezier>();
        if (pts is null || pts.Count < 2)
        {
            return segments;
        }

        int count = pts.Count;
        for (int i = 0; i < count - 1; i++)
        {
            SparkPoint p0 = pts[i == 0 ? 0 : i - 1];
            SparkPoint p1 = pts[i];
            SparkPoint p2 = pts[i + 1];
            SparkPoint p3 = pts[i + 2 < count ? i + 2 : count - 1];

            var c1 = new SparkPoint(
                p1.X + (p2.X - p0.X) / 6.0,
                p1.Y + (p2.Y - p0.Y) / 6.0);
            var c2 = new SparkPoint(
                p2.X - (p3.X - p1.X) / 6.0,
                p2.Y - (p3.Y - p1.Y) / 6.0);

            segments.Add(new SparkBezier(p1, c1, c2, p2));
        }

        return segments;
    }
}
