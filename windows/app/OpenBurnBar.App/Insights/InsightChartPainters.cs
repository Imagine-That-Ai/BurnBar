// =============================================================================
//  Win2D painters for the Insights chart widget set (Phase 3 / W7 — Insights lane).
//
//  WINDOWS-ONLY / CI-DEFERRED. These are the GPU-bound draw passes that turn the
//  platform-agnostic chart GEOMETRY (OpenBurnBar.App.Presentation.Insights.Charts,
//  already unit-tested green on macOS) into pixels on a real Win2D CanvasDrawingSession.
//
//  Every painter is a thin forward: it calls the parity-tested geometry engine to get
//  rectangles / polygons / arc angles, then issues the matching Win2D fill/stroke/text
//  calls. No layout math lives here — that is exactly what keeps the math testable off
//  a GPU. The live-render check (actual pixels @ a Windows dev host) runs per
//  windows/app/DEV_HOST_RUNBOOK.md; on macOS this file syntax-parses + reaches the
//  Windows-only XamlCompiler/Win2D gate with the rest of the app.
// =============================================================================

using System;
using System.Numerics;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Geometry;
using Microsoft.Graphics.Canvas.Text;
using OpenBurnBar.App.Presentation.Insights;
using OpenBurnBar.App.Presentation.Insights.Charts;
using WinColor = Windows.UI.Color;

namespace OpenBurnBar.App.Insights;

/// <summary>
/// Static Win2D draw passes for each Insights chart kind. Dispatched from
/// <see cref="InsightChartCanvas"/>; each pass consumes the portable geometry engines and
/// draws the resulting primitives.
/// </summary>
internal static class InsightChartPainters
{
    private static readonly WinColor GridLine = WinColor.FromArgb(0x33, 0xC7, 0xCF, 0xDD);
    private static readonly WinColor LabelColor = WinColor.FromArgb(0xCC, 0xC7, 0xCF, 0xDD);
    private static readonly WinColor MutedColor = WinColor.FromArgb(0x88, 0xC7, 0xCF, 0xDD);

    /// <summary>Dispatch to the painter matching the widget data variant.</summary>
    public static void Paint(CanvasDrawingSession ds, ICanvasResourceCreator device, InsightWidgetData data, PlotRect rect, InsightTheme theme)
    {
        switch (data)
        {
            case RankingData d: Bar(ds, device, d, rect); break;
            case TimeSeriesData d: Line(ds, device, d, rect, theme); break;
            case RadarData d: Radar(ds, device, d, rect); break;
            case HeatmapData d: Heatmap(ds, d, rect, theme); break;
            case SankeyData d: Sankey(ds, device, d, rect); break;
            case DistributionData d: Donut(ds, device, d, rect); break;
            case FunnelData d: Funnel(ds, d, rect); break;
            case ScatterData d: Scatter(ds, d, rect); break;
            case QuotaData d: Quota(ds, d, rect, theme); break;
            default: break;
        }
    }

    private static WinColor ToColor(InsightRgb rgb, double alpha = 1.0)
        => WinColor.FromArgb((byte)Math.Clamp(alpha * 255, 0, 255), rgb.R, rgb.G, rgb.B);

    private static WinColor Accent(InsightTheme theme) => theme switch
    {
        InsightTheme.Ember => WinColor.FromArgb(0xFF, 0xFA, 0x50, 0x53),
        InsightTheme.Mercury => WinColor.FromArgb(0xFF, 0x8F, 0xB6, 0xFF),
        InsightTheme.Whimsy => WinColor.FromArgb(0xFF, 0xB9, 0x8F, 0xFF),
        _ => WinColor.FromArgb(0xFF, 0x62, 0xD0, 0xC4),
    };

    private static CanvasTextFormat Text(float size, CanvasHorizontalAlignment h = CanvasHorizontalAlignment.Left)
        => new()
        {
            FontSize = size,
            HorizontalAlignment = h,
            VerticalAlignment = CanvasVerticalAlignment.Center,
            WordWrapping = CanvasWordWrapping.NoWrap,
        };

    // ── Bar (Top-N ranking) ──────────────────────────────────────────────────────

    private static void Bar(CanvasDrawingSession ds, ICanvasResourceCreator device, RankingData data, PlotRect rect)
    {
        var labelRect = new PlotRect(rect.X, rect.Y, rect.Width, rect.Height);
        foreach (BarRect bar in BarChartGeometry.Layout(data.Rows, labelRect, rowGap: 6))
        {
            ds.FillRoundedRectangle((float)bar.X, (float)bar.Y, (float)Math.Max(2, bar.Width), (float)bar.Height, 3, 3, ToColor(bar.Color, 0.9));
            using CanvasTextFormat valueFormat = Text(10);
            ds.DrawText(
                InsightFormatting.Format(bar.Value, data.ValueFormat),
                (float)(bar.X + bar.Width + 4),
                (float)(bar.Y + (bar.Height / 2)),
                LabelColor,
                valueFormat);
            using CanvasTextFormat nameFormat = Text(10);
            ds.DrawText(bar.Label, (float)(bar.X + 4), (float)(bar.Y + (bar.Height / 2)), MutedColor, nameFormat);
        }
    }

    // ── Line / area (time series) ────────────────────────────────────────────────

    private static void Line(CanvasDrawingSession ds, ICanvasResourceCreator device, TimeSeriesData data, PlotRect rect, InsightTheme theme)
    {
        // Baseline.
        ds.DrawLine((float)rect.X, (float)rect.Bottom, (float)rect.Right, (float)rect.Bottom, GridLine, 1);

        LineChartGeometryResult result = LineChartGeometry.Layout(data, rect);
        foreach (LinePolyline line in result.Lines)
        {
            if (line.Points.Count < 2)
            {
                continue;
            }

            using var pb = new CanvasPathBuilder(device);
            pb.BeginFigure((float)line.Points[0].X, (float)line.Points[0].Y);
            for (int i = 1; i < line.Points.Count; i++)
            {
                pb.AddLine((float)line.Points[i].X, (float)line.Points[i].Y);
            }

            pb.EndFigure(CanvasFigureLoop.Open);
            using CanvasGeometry geo = CanvasGeometry.CreatePath(pb);
            using var stroke = new CanvasStrokeStyle { LineJoin = CanvasLineJoin.Round };
            ds.DrawGeometry(geo, ToColor(line.Color), 2, stroke);
        }
    }

    // ── Radar ────────────────────────────────────────────────────────────────────

    private static void Radar(CanvasDrawingSession ds, ICanvasResourceCreator device, RadarData data, PlotRect rect)
    {
        RadarGeometryResult result = RadarGeometry.Layout(data, rect);
        var center = new Vector2((float)result.Center.X, (float)result.Center.Y);

        foreach (var ring in result.GridRings)
        {
            DrawPolygon(ds, device, ring, GridLine, filled: false, strokeWidth: 0.5f);
        }

        foreach (ChartPoint endpoint in result.AxisEndpoints)
        {
            ds.DrawLine(center, new Vector2((float)endpoint.X, (float)endpoint.Y), GridLine, 0.5f);
        }

        foreach (RadarPolygon series in result.Series)
        {
            DrawPolygon(ds, device, series.Vertices, ToColor(series.Color, 0.18), filled: true, strokeWidth: 0);
            DrawPolygon(ds, device, series.Vertices, ToColor(series.Color), filled: false, strokeWidth: 1.5f);
        }
    }

    private static void DrawPolygon(
        CanvasDrawingSession ds,
        ICanvasResourceCreator device,
        System.Collections.Generic.IReadOnlyList<ChartPoint> vertices,
        WinColor color,
        bool filled,
        float strokeWidth)
    {
        if (vertices.Count < 2)
        {
            return;
        }

        var points = new Vector2[vertices.Count];
        for (int i = 0; i < vertices.Count; i++)
        {
            points[i] = new Vector2((float)vertices[i].X, (float)vertices[i].Y);
        }

        using CanvasGeometry geo = CanvasGeometry.CreatePolygon(device, points);
        if (filled)
        {
            ds.FillGeometry(geo, color);
        }
        else
        {
            ds.DrawGeometry(geo, color, strokeWidth);
        }
    }

    // ── Heatmap ──────────────────────────────────────────────────────────────────

    private static void Heatmap(CanvasDrawingSession ds, HeatmapData data, PlotRect rect, InsightTheme theme)
    {
        InsightRgb accent = new(Accent(theme).R, Accent(theme).G, Accent(theme).B);
        foreach (HeatmapCellGeometry cell in HeatmapGeometry.Layout(data.Cells, rect, cellGap: 1))
        {
            ds.FillRoundedRectangle(
                (float)cell.X,
                (float)cell.Y,
                (float)cell.Width,
                (float)cell.Height,
                2,
                2,
                ToColor(accent, cell.Alpha));
        }
    }

    // ── Sankey ───────────────────────────────────────────────────────────────────

    private static void Sankey(CanvasDrawingSession ds, ICanvasResourceCreator device, SankeyData data, PlotRect rect)
    {
        SankeyGeometryResult result = SankeyGeometry.OrderColumns(data, rect);
        foreach (SankeyColumn column in result.Columns)
        {
            foreach (SankeyColumnNode node in column.Nodes)
            {
                ds.FillRoundedRectangle((float)node.X, (float)node.Y, (float)node.Width, (float)node.Height, 3, 3, ToColor(node.Color, 0.9));
                using CanvasTextFormat format = Text(9, column.Id == "source" ? CanvasHorizontalAlignment.Right : CanvasHorizontalAlignment.Left);
                float labelX = column.Id == "source" ? (float)(node.X - 64) : (float)(node.X + node.Width + 4);
                var labelRect = new Windows.Foundation.Rect(labelX, node.Y, 60, Math.Max(10, node.Height));
                ds.DrawText(node.Label, labelRect, MutedColor, format);
            }
        }
    }

    // ── Donut ────────────────────────────────────────────────────────────────────

    private static void Donut(CanvasDrawingSession ds, ICanvasResourceCreator device, DistributionData data, PlotRect rect)
    {
        double side = Math.Min(rect.Width, rect.Height);
        double outer = (side / 2) - 6;
        double inner = outer * 0.55;
        double mid = (outer + inner) / 2;
        float thickness = (float)(outer - inner);
        var center = new ChartPoint(rect.CenterX, rect.CenterY);
        var centerVec = new Vector2((float)center.X, (float)center.Y);

        foreach (DonutSliceGeometry slice in DonutGeometry.Layout(data.Slices))
        {
            ChartPoint start = DonutGeometry.PointOnArc(center, mid, slice.StartAngleDeg);
            using var pb = new CanvasPathBuilder(device);
            pb.BeginFigure((float)start.X, (float)start.Y);
            pb.AddArc(centerVec, (float)mid, (float)mid, DegToRad(slice.StartAngleDeg), DegToRad(slice.SweepAngleDeg));
            pb.EndFigure(CanvasFigureLoop.Open);
            using CanvasGeometry geo = CanvasGeometry.CreatePath(pb);
            using var stroke = new CanvasStrokeStyle { StartCap = CanvasCapStyle.Flat, EndCap = CanvasCapStyle.Flat };
            ds.DrawGeometry(geo, ToColor(slice.Color, 0.92), thickness, stroke);
        }
    }

    private static float DegToRad(double deg) => (float)(deg * Math.PI / 180.0);

    // ── Funnel ───────────────────────────────────────────────────────────────────

    private static void Funnel(CanvasDrawingSession ds, FunnelData data, PlotRect rect)
    {
        foreach (FunnelBarGeometry bar in FunnelGeometry.Layout(data.Steps, rect, rowGap: 8))
        {
            ds.FillRoundedRectangle((float)bar.X, (float)bar.Y, (float)Math.Max(2, bar.Width), (float)bar.Height, 4, 4, ToColor(bar.Color, 0.85));
            using CanvasTextFormat format = Text(10, CanvasHorizontalAlignment.Center);
            var labelRect = new Windows.Foundation.Rect(rect.X, bar.Y, rect.Width, Math.Max(10, bar.Height));
            ds.DrawText(bar.Label, labelRect, LabelColor, format);
        }
    }

    // ── Scatter ──────────────────────────────────────────────────────────────────

    private static void Scatter(CanvasDrawingSession ds, ScatterData data, PlotRect rect)
    {
        ds.DrawLine((float)rect.X, (float)rect.Bottom, (float)rect.Right, (float)rect.Bottom, GridLine, 1);
        ds.DrawLine((float)rect.X, (float)rect.Y, (float)rect.X, (float)rect.Bottom, GridLine, 1);
        foreach (ScatterBubble bubble in ScatterGeometry.Layout(data.Points, rect))
        {
            var c = new Vector2((float)bubble.CenterX, (float)bubble.CenterY);
            ds.FillCircle(c, (float)bubble.Radius, ToColor(bubble.Color, 0.8));
        }
    }

    // ── Quota pulse ──────────────────────────────────────────────────────────────

    private static void Quota(CanvasDrawingSession ds, QuotaData data, PlotRect rect, InsightTheme theme)
    {
        if (data.Buckets.Count == 0)
        {
            return;
        }

        double slot = rect.Height / data.Buckets.Count;
        double trackHeight = Math.Max(6, slot - 14);
        for (int i = 0; i < data.Buckets.Count; i++)
        {
            QuotaBucket bucket = data.Buckets[i];
            double y = rect.Y + (i * slot) + 14;
            ds.FillRoundedRectangle((float)rect.X, (float)y, (float)rect.Width, (float)trackHeight, 4, 4, WinColor.FromArgb(0x22, 0xC7, 0xCF, 0xDD));
            double fillWidth = rect.Width * bucket.Fraction;
            WinColor color = bucket.Fraction > 0.85 ? WinColor.FromArgb(0xFF, 0xFA, 0x50, 0x53) : Accent(theme);
            ds.FillRoundedRectangle((float)rect.X, (float)y, (float)Math.Max(2, fillWidth), (float)trackHeight, 4, 4, color);
            using CanvasTextFormat format = Text(9);
            ds.DrawText($"{bucket.ProviderLabel} · {bucket.BucketName}", (float)rect.X, (float)(y - 7), MutedColor, format);
        }
    }
}
