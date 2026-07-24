using System;

namespace OpenBurnBar.App.Presentation.Calendar;

/// <summary>
/// Local-timezone day math for the Calendar surface. Days are keyed by
/// <see cref="DateOnly"/> in the host's local timezone — the .NET peer of macOS
/// <c>Calendar.current.startOfDay(for:)</c> keys — so DST 23/25-hour days stay
/// aligned by construction and never depend on the time-of-day an event carried.
/// The timezone is injected everywhere so tests pin non-UTC zones on any host.
/// </summary>
public static class CalendarLocalTime
{
    /// <summary>The local calendar day <paramref name="instantUtc"/> lands on in <paramref name="timeZone"/>.</summary>
    public static DateOnly LocalDay(DateTimeOffset instantUtc, TimeZoneInfo timeZone)
    {
        ArgumentNullException.ThrowIfNull(timeZone);
        DateTimeOffset local = TimeZoneInfo.ConvertTime(instantUtc, timeZone);
        return DateOnly.FromDateTime(local.DateTime);
    }

    /// <summary>The local wall-clock components (weekday, hour) of an instant.</summary>
    public static (DayOfWeek Weekday, int Hour) LocalWeekdayAndHour(DateTimeOffset instantUtc, TimeZoneInfo timeZone)
    {
        ArgumentNullException.ThrowIfNull(timeZone);
        DateTimeOffset local = TimeZoneInfo.ConvertTime(instantUtc, timeZone);
        return (local.DayOfWeek, local.Hour);
    }

    /// <summary>
    /// The UTC instant of local midnight starting <paramref name="day"/>. Used only
    /// for fetch-window bounds; bucket keys are <see cref="DateOnly"/> and never
    /// depend on this conversion.
    /// </summary>
    public static DateTimeOffset DayStartUtc(DateOnly day, TimeZoneInfo timeZone)
    {
        ArgumentNullException.ThrowIfNull(timeZone);
        var localMidnight = new DateTime(day.Year, day.Month, day.Day, 0, 0, 0, DateTimeKind.Unspecified);
        return new DateTimeOffset(TimeZoneInfo.ConvertTimeToUtc(localMidnight, timeZone));
    }

    /// <summary>Today's local date in <paramref name="timeZone"/>.</summary>
    public static DateOnly Today(TimeZoneInfo timeZone, DateTimeOffset? nowUtc = null) =>
        LocalDay(nowUtc ?? DateTimeOffset.UtcNow, timeZone);
}
