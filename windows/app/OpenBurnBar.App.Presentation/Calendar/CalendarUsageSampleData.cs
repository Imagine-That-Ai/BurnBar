using System;
using System.Collections.Generic;
using OpenBurnBar.App.Presentation.Dashboard;

namespace OpenBurnBar.App.Presentation.Calendar;

/// <summary>
/// Deterministic, clearly-labeled demo rows surfaced only when
/// <c>OPENBURNBAR_SAMPLE_MODE</c> is enabled. Production routes never fabricate
/// data; the <see cref="DashboardUsageOrigin.Sample"/> marker lets the UI say so
/// out loud. Rows cover the requested month grid (including overflow days) so
/// the heatmap, dots, and every card exercise real shapes on any visible month.
/// </summary>
public static class CalendarUsageSampleData
{
    private static readonly string[] Providers = { "Claude Code", "Codex", "Cursor" };
    private static readonly string[] Models = { "claude-opus-4-1", "gpt-5-codex", "composer-1" };
    private static readonly string[] Projects = { "burnbar", "openburnbar-windows", "sidequest" };

    /// <summary>
    /// Builds the deterministic sample for the month grid containing
    /// <paramref name="visibleMonth"/> (any day inside the month), suppressing
    /// days after <paramref name="nowUtc"/>'s local today so the demo never
    /// claims future spend. Costs follow a fixed formula — no RNG — so tests
    /// and screenshots are stable.
    /// </summary>
    public static CalendarUsageData Rows(DateOnly visibleMonth, DateTimeOffset nowUtc, TimeZoneInfo timeZone)
    {
        ArgumentNullException.ThrowIfNull(timeZone);
        DateOnly today = CalendarLocalTime.Today(timeZone, nowUtc);
        CalendarMonthGridModel grid = CalendarMonthGridModel.Create(visibleMonth);

        var rows = new List<CalendarUsageRow>();
        foreach (DateOnly day in grid.AllDays)
        {
            // Fixed rhythm: busy on most days, quiet every 5th, silent on future days.
            if (day > today || day.Day % 5 == 0)
            {
                continue;
            }

            int sessionCount = 1 + (day.Day % 3);
            for (int session = 0; session < sessionCount; session++)
            {
                string provider = Providers[(day.Day + session) % Providers.Length];
                string model = Models[(day.Day + session) % Models.Length];
                string project = Projects[(day.Day + session) % Projects.Length];
                long input = 12_000 + (day.Day * 913L % 7_000);
                long output = 3_400 + (day.Day * 517L % 2_600);
                long cacheRead = 40_000 + (day.Day * 2_711L % 60_000);
                long reasoning = session == 0 ? 1_200 + (day.Day * 131L % 900) : 0;
                long total = input + output + cacheRead + reasoning;
                double cost = Math.Round(total / 1_000_000.0 * (2.4 + ((day.Day + session) % 4)), 4);

                // Local 09:00/13:30/18:00-ish starts, converted to UTC instants.
                int hour = 9 + (session * 4) + (day.Day % 2);
                var localStart = new DateTime(day.Year, day.Month, day.Day, hour, session == 1 ? 30 : 0, 0, DateTimeKind.Unspecified);
                DateTimeOffset startUtc = new(TimeZoneInfo.ConvertTimeToUtc(localStart, timeZone));

                rows.Add(new CalendarUsageRow(
                    $"sample-{day:yyyy-MM-dd}-{session}",
                    provider,
                    $"sample-sess-{day:yyyy-MM-dd}-{session}",
                    project,
                    model,
                    input,
                    output,
                    CacheCreationTokens: 2_000,
                    cacheRead,
                    reasoning,
                    total,
                    cost,
                    startUtc));
            }
        }

        return new CalendarUsageData(rows, DashboardUsageOrigin.Sample);
    }
}
