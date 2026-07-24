using System;
using System.Linq;
using OpenBurnBar.App.Presentation.Calendar;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests.Calendar;

/// <summary>
/// Pins the local-tz day bucketing contract (parity: macOS <c>ChartBucketing</c>
/// day/hour arms as consumed by <c>CalendarDataService</c>): gap-filled buckets,
/// attribution by local start-of-day (never UTC-truncated), DST 23/25-hour days,
/// month boundaries, and the 7×24 hour×weekday matrix.
/// </summary>
public sealed class CalendarBucketingTests
{
    private static readonly TimeZoneInfo NewYork =
        TimeZoneInfo.FindSystemTimeZoneById("America/New_York");

    [Fact]
    public void Buckets_are_gap_filled_across_silent_days()
    {
        var events = new[]
        {
            (Instant("2026-07-06T15:00:00Z"), 2.0),
            (Instant("2026-07-08T15:00:00Z"), 3.0),
        };

        var buckets = CalendarBucketing.DayBuckets(
            events,
            new DateOnly(2026, 7, 6),
            new DateOnly(2026, 7, 9),
            TimeZoneInfo.Utc);

        Assert.Equal(4, buckets.Count);
        Assert.Equal(new DateOnly(2026, 7, 6), buckets[0].Day);
        Assert.Equal(2.0, buckets[0].Value);
        Assert.Equal(0, buckets[1].Value); // silent Jul 7 materialized
        Assert.Equal(3.0, buckets[2].Value);
        Assert.Equal(0, buckets[3].Value);
    }

    [Fact]
    public void Events_outside_the_range_are_ignored()
    {
        var events = new[]
        {
            (Instant("2026-07-05T23:59:59Z"), 9.0),
            (Instant("2026-07-06T00:00:00Z"), 1.0),
            (Instant("2026-07-07T00:00:00Z"), 2.0),
        };

        var buckets = CalendarBucketing.DayBuckets(
            events,
            new DateOnly(2026, 7, 6),
            new DateOnly(2026, 7, 6),
            TimeZoneInfo.Utc);

        Assert.Single(buckets);
        Assert.Equal(1.0, buckets[0].Value);
    }

    [Fact]
    public void Empty_range_returns_no_buckets()
    {
        var buckets = CalendarBucketing.DayBuckets(
            Array.Empty<(DateTimeOffset, double)>(),
            new DateOnly(2026, 7, 8),
            new DateOnly(2026, 7, 6),
            TimeZoneInfo.Utc);

        Assert.Empty(buckets);
    }

    [Fact]
    public void Local_day_attribution_is_never_utc_truncated()
    {
        // 2026-07-08T01:30:00Z is still Jul 7 in New York (21:30 EDT) — the row
        // belongs to Jul 7 locally even though UTC calls it Jul 8.
        var events = new[] { (Instant("2026-07-08T01:30:00Z"), 5.0) };

        var buckets = CalendarBucketing.DayBuckets(
            events,
            new DateOnly(2026, 7, 7),
            new DateOnly(2026, 7, 8),
            NewYork);

        Assert.Equal(5.0, buckets[0].Value);
        Assert.Equal(0, buckets[1].Value);
    }

    [Fact]
    public void Spring_forward_day_stays_aligned()
    {
        // America/New_York springs forward 2026-03-08 (23-hour day).
        // Mar 7 23:00 EST = Mar 8 04:00Z; Mar 8 23:00 EDT = Mar 9 03:00Z.
        var events = new[]
        {
            (Instant("2026-03-08T04:00:00Z"), 1.0), // Mar 7 local
            (Instant("2026-03-09T03:00:00Z"), 2.0), // Mar 8 local
        };

        var buckets = CalendarBucketing.DayBuckets(
            events,
            new DateOnly(2026, 3, 7),
            new DateOnly(2026, 3, 9),
            NewYork);

        Assert.Equal(3, buckets.Count);
        Assert.Equal(1.0, buckets[0].Value);
        Assert.Equal(2.0, buckets[1].Value);
        Assert.Equal(0, buckets[2].Value);
    }

    [Fact]
    public void Fall_back_day_stays_aligned()
    {
        // America/New_York falls back 2026-11-01 (25-hour day): both 05:30Z
        // (01:30 EDT) and 06:30Z (01:30 EST) are Nov 1 local.
        var events = new[]
        {
            (Instant("2026-11-01T05:30:00Z"), 1.0),
            (Instant("2026-11-01T06:30:00Z"), 2.0),
        };

        var buckets = CalendarBucketing.DayBuckets(
            events,
            new DateOnly(2026, 10, 31),
            new DateOnly(2026, 11, 2),
            NewYork);

        Assert.Equal(0, buckets[0].Value);
        Assert.Equal(3.0, buckets[1].Value);
        Assert.Equal(0, buckets[2].Value);
    }

    [Fact]
    public void DayStartUtc_tracks_the_local_offset_at_midnight()
    {
        // Midnight Mar 8 2026 is still EST (UTC-5) → 05:00Z; midnight Nov 1 is EDT (UTC-4) → 04:00Z.
        Assert.Equal(
            Instant("2026-03-08T05:00:00Z"),
            CalendarLocalTime.DayStartUtc(new DateOnly(2026, 3, 8), NewYork));
        Assert.Equal(
            Instant("2026-11-01T04:00:00Z"),
            CalendarLocalTime.DayStartUtc(new DateOnly(2026, 11, 1), NewYork));
    }

    [Fact]
    public void Hour_matrix_uses_local_weekday_and_hour_with_sunday_first()
    {
        // 2026-07-15T13:00:00Z = Wednesday 09:00 EDT → row 3, hour 9.
        var events = new[]
        {
            (Instant("2026-07-15T13:00:00Z"), 2.0),
            (Instant("2026-07-15T13:30:00Z"), 1.0), // same cell
            (Instant("2026-07-19T04:30:00Z"), 4.0), // Jul 19 00:30 EDT = Sunday → row 0, hour 0
        };

        double[][] matrix = CalendarBucketing.HourWeekdayMatrix(events, NewYork);

        Assert.Equal(7, matrix.Length);
        Assert.Equal(24, matrix[0].Length);
        Assert.Equal(3.0, matrix[3][9]);
        Assert.Equal(4.0, matrix[0][0]);
        Assert.Equal(3.0 + 4.0, matrix.SelectMany(row => row).Sum());
    }

    private static DateTimeOffset Instant(string iso) =>
        DateTimeOffset.Parse(iso, System.Globalization.CultureInfo.InvariantCulture);
}
