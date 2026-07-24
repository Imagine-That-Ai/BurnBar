using System;
using System.Collections.Generic;

namespace OpenBurnBar.App.Presentation.Calendar;

/// <summary>One day bucket: the local day and the summed value inside it.</summary>
public sealed record CalendarDateBucket(DateOnly Day, double Value)
{
    /// <summary>Alias for chart consumers that read "start of bucket".</summary>
    public DateOnly Start => Day;
}

/// <summary>
/// Pure, deterministic bucketing math for the Calendar surface — the port of the
/// day/hour arms of macOS <c>AgentLens/Models/Charts/ChartBucketing.swift</c>
/// (<c>dateBuckets(component: .day)</c> + <c>hourWeekdayMatrix</c>). Buckets are
/// aligned to local calendar days, so DST transitions produce 23- and 25-hour
/// days rather than drifting edges; empty days are materialized with value 0 so
/// series keep a stable, gap-free shape.
/// </summary>
public static class CalendarBucketing
{
    /// <summary>
    /// Sums <paramref name="events"/> into contiguous local-day buckets covering
    /// <paramref name="firstDay"/>…<paramref name="lastDay"/> inclusive. Events
    /// outside the range are ignored; days with no events materialize as 0.
    /// </summary>
    public static IReadOnlyList<CalendarDateBucket> DayBuckets(
        IEnumerable<(DateTimeOffset InstantUtc, double Value)> events,
        DateOnly firstDay,
        DateOnly lastDay,
        TimeZoneInfo timeZone)
    {
        ArgumentNullException.ThrowIfNull(events);
        ArgumentNullException.ThrowIfNull(timeZone);
        if (lastDay < firstDay)
        {
            return Array.Empty<CalendarDateBucket>();
        }

        // Hard ceiling keeps a malformed range from allocating unbounded buckets
        // (macOS: 6_200 day buckets).
        var starts = new List<DateOnly>();
        DateOnly cursor = firstDay;
        while (cursor <= lastDay && starts.Count < 6_200)
        {
            starts.Add(cursor);
            cursor = cursor.AddDays(1);
        }

        if (starts.Count == 0)
        {
            return Array.Empty<CalendarDateBucket>();
        }

        var totals = new double[starts.Count];
        foreach ((DateTimeOffset instantUtc, double value) in events)
        {
            DateOnly day = CalendarLocalTime.LocalDay(instantUtc, timeZone);
            if (day < firstDay || day > lastDay)
            {
                continue;
            }

            // Binary search for the owning bucket (starts is ascending).
            int low = 0;
            int high = starts.Count - 1;
            while (low < high)
            {
                int mid = (low + high + 1) / 2;
                if (starts[mid] <= day)
                {
                    low = mid;
                }
                else
                {
                    high = mid - 1;
                }
            }

            totals[low] += value;
        }

        var buckets = new CalendarDateBucket[starts.Count];
        for (int i = 0; i < starts.Count; i++)
        {
            buckets[i] = new CalendarDateBucket(starts[i], totals[i]);
        }

        return buckets;
    }

    /// <summary>
    /// Sums <paramref name="events"/> into a 7×24 matrix — <c>matrix[weekday][hour]</c> —
    /// where weekday is 0-based from Sunday (Gregorian weekday order, matching the
    /// macOS <c>Calendar.component(.weekday)</c> numbering). Rendered as the
    /// time-of-day heatmap.
    /// </summary>
    public static double[][] HourWeekdayMatrix(
        IEnumerable<(DateTimeOffset InstantUtc, double Value)> events,
        TimeZoneInfo timeZone)
    {
        ArgumentNullException.ThrowIfNull(events);
        ArgumentNullException.ThrowIfNull(timeZone);

        var matrix = new double[7][];
        for (int i = 0; i < matrix.Length; i++)
        {
            matrix[i] = new double[24];
        }

        foreach ((DateTimeOffset instantUtc, double value) in events)
        {
            (DayOfWeek weekday, int hour) = CalendarLocalTime.LocalWeekdayAndHour(instantUtc, timeZone);
            matrix[(int)weekday][hour] += value;
        }

        return matrix;
    }
}
