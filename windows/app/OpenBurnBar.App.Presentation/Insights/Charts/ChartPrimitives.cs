using System;
using System.Collections.Generic;

namespace OpenBurnBar.App.Presentation.Insights.Charts;

/// <summary>
/// A rectangle in device-independent pixels (top-left origin, y grows down — the Win2D /
/// WinUI convention). The chart geometry engines lay out inside a caller-supplied plot rect
/// so the same math is exercised in tests (with a synthetic rect) and by the Win2D renderer
/// (with the control's actual bounds).
/// </summary>
public readonly record struct PlotRect(double X, double Y, double Width, double Height)
{
    public double Right => X + Width;

    public double Bottom => Y + Height;

    public double CenterX => X + (Width / 2);

    public double CenterY => Y + (Height / 2);
}

/// <summary>A 2-D point in the same pixel space as <see cref="PlotRect"/>.</summary>
public readonly record struct ChartPoint(double X, double Y);

/// <summary>One laid-out horizontal bar (Top-N ranking).</summary>
public readonly record struct BarRect(
    string Id,
    string Label,
    double X,
    double Y,
    double Width,
    double Height,
    double Value,
    InsightRgb Color);

/// <summary>A closed polygon (one radar series) plus its resolved color.</summary>
public sealed record RadarPolygon(string Id, string Name, IReadOnlyList<ChartPoint> Vertices, InsightRgb Color);

/// <summary>The full radar layout: concentric grid rings, axis endpoints, and series polygons.</summary>
public sealed record RadarGeometryResult(
    ChartPoint Center,
    double Radius,
    IReadOnlyList<ChartPoint> AxisEndpoints,
    IReadOnlyList<IReadOnlyList<ChartPoint>> GridRings,
    IReadOnlyList<RadarPolygon> Series);

/// <summary>One laid-out heatmap cell with its normalized intensity + fill alpha.</summary>
public readonly record struct HeatmapCellGeometry(
    int Row,
    int Col,
    double Value,
    double Intensity,
    double Alpha,
    double X,
    double Y,
    double Width,
    double Height);

/// <summary>One node in a sankey column, with both a normalized (0…1) and a pixel height.</summary>
public readonly record struct SankeyColumnNode(
    string Id,
    string Label,
    double Weight,
    double NormalizedHeight,
    double X,
    double Y,
    double Width,
    double Height,
    InsightRgb Color);

/// <summary>One sankey column (sources on the left, targets on the right).</summary>
public sealed record SankeyColumn(string Id, double Total, IReadOnlyList<SankeyColumnNode> Nodes);

/// <summary>The full sankey layout (two columns for this compact renderer).</summary>
public sealed record SankeyGeometryResult(IReadOnlyList<SankeyColumn> Columns);

/// <summary>One polyline (a time-series line) mapped into pixel space.</summary>
public sealed record LinePolyline(string Id, string Name, IReadOnlyList<ChartPoint> Points, InsightRgb Color);

/// <summary>The full line/area layout: the resolved domains plus the mapped polylines.</summary>
public sealed record LineChartGeometryResult(
    double YMin,
    double YMax,
    DateTimeOffset XMin,
    DateTimeOffset XMax,
    IReadOnlyList<LinePolyline> Lines);

/// <summary>One donut/pie sector, in degrees (0° = top, sweeping clockwise).</summary>
public readonly record struct DonutSliceGeometry(
    string Id,
    string Label,
    double StartAngleDeg,
    double SweepAngleDeg,
    double Value,
    InsightRgb Color);

/// <summary>One centered funnel bar with its fraction of the widest step.</summary>
public readonly record struct FunnelBarGeometry(
    string Id,
    string Label,
    double Fraction,
    double Count,
    double X,
    double Y,
    double Width,
    double Height,
    InsightRgb Color);
