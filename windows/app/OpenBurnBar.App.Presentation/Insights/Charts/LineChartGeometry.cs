using System;
using System.Collections.Generic;
using System.Linq;

namespace OpenBurnBar.App.Presentation.Insights.Charts;

/// <summary>
/// Pure domain resolution + point mapping for the time-series line/area chart — a port of the
/// domain math in the macOS <c>InsightTimeSeriesView</c>.
///
/// Y-domain: <c>[min(0, minValue) … max(maxValue·1.15, maxValue+ε)]</c>; when there is no
/// positive value it collapses to <c>0…1</c>. X-domain spans the min→max timestamp. Points
/// map into the plot rect with y inverted (larger value = higher on screen). The unit tests
/// pin the domains + the mapped pixel coordinates for a known series.
/// </summary>
public static class LineChartGeometry
{
    /// <summary>Compute the padded y-domain over every point in every series (parity with Swift).</summary>
    public static (double Min, double Max) YDomain(IReadOnlyList<TimeSeriesSeries> series)
    {
        List<double> values = series.SelectMany(s => s.Points.Select(p => p.Value)).ToList();
        if (values.Count == 0)
        {
            return (0, 1);
        }

        double maxValue = values.Max();
        if (maxValue <= 0)
        {
            return (0, 1);
        }

        double minValue = Math.Min(0, values.Min());
        double padded = maxValue * 1.15;
        return (minValue, Math.Max(padded, maxValue + 0.001));
    }

    /// <summary>Compute the x-domain (min→max timestamp), padding a degenerate single-instant span.</summary>
    public static (DateTimeOffset Min, DateTimeOffset Max) XDomain(IReadOnlyList<TimeSeriesSeries> series)
    {
        List<DateTimeOffset> dates = series.SelectMany(s => s.Points.Select(p => p.Date)).ToList();
        if (dates.Count == 0)
        {
            DateTimeOffset now = DateTimeOffset.UnixEpoch;
            return (now.AddHours(-1), now.AddHours(1));
        }

        DateTimeOffset min = dates.Min();
        DateTimeOffset max = dates.Max();
        if (min == max)
        {
            return (min.AddHours(-3), max.AddHours(3));
        }

        return (min, max);
    }

    /// <summary>Map every series into pixel polylines inside <paramref name="rect"/>.</summary>
    public static LineChartGeometryResult Layout(TimeSeriesData data, PlotRect rect)
    {
        (double yMin, double yMax) = YDomain(data.Series);
        (DateTimeOffset xMin, DateTimeOffset xMax) = XDomain(data.Series);

        double ySpan = yMax - yMin;
        if (ySpan <= 0)
        {
            ySpan = 1;
        }

        double xSpanTicks = (xMax - xMin).Ticks;
        if (xSpanTicks <= 0)
        {
            xSpanTicks = 1;
        }

        var lines = new List<LinePolyline>(data.Series.Count);
        foreach (TimeSeriesSeries s in data.Series)
        {
            var points = new List<ChartPoint>(s.Points.Count);
            foreach (TimeSeriesPoint p in s.Points)
            {
                double tx = (p.Date - xMin).Ticks / xSpanTicks;
                double ty = (p.Value - yMin) / ySpan;
                double x = rect.X + (tx * rect.Width);
                double y = rect.Bottom - (ty * rect.Height);
                points.Add(new ChartPoint(x, y));
            }

            InsightRgb color = InsightFormatting.ResolveColor(s.ColorHex, s.Id);
            lines.Add(new LinePolyline(s.Id, s.Name, points, color));
        }

        return new LineChartGeometryResult(yMin, yMax, xMin, xMax, lines);
    }
}
