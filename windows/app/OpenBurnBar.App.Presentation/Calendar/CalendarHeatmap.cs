using System;

namespace OpenBurnBar.App.Presentation.Calendar;

/// <summary>
/// Heatmap fill math for calendar day cells — the port of macOS
/// <c>CalendarDayCell.fillColor</c> (which shares the
/// <c>ChartKitHeatmap.fill(for:peak:)</c> recipe). The square root keeps
/// mid-range days visible instead of letting one monster day wash the rest out.
/// Kept pure so the month-peak scaling contract is pinned by tests.
/// </summary>
public static class CalendarHeatmap
{
    /// <summary>Sqrt-scaled intensity of a day's cost against the visible month's peak day cost, 0…1.</summary>
    public static double Intensity(double cost, double peak)
    {
        if (cost <= 0 || peak <= 0)
        {
            return 0;
        }

        return Math.Sqrt(cost / peak);
    }

    /// <summary>
    /// Accent-fill opacity for a day cell: <c>0.10 + 0.55 × intensity</c>, the exact
    /// macOS ramp (peak day → 0.65; zero/unknown peak → 0, i.e. the plain surface fill).
    /// </summary>
    public static double FillOpacity(double cost, double peak)
    {
        if (cost <= 0 || peak <= 0)
        {
            return 0;
        }

        return 0.10 + (0.55 * Intensity(cost, peak));
    }

    /// <summary>Selected-cell accent opacity (macOS: 0.34 dark / 0.24 light).</summary>
    public static double SelectedFillOpacity(bool isDark) => isDark ? 0.34 : 0.24;

    /// <summary>Selected-ring accent opacity (macOS: 0.85).</summary>
    public const double SelectedRingOpacity = 0.85;

    /// <summary>Today-ring accent opacity (macOS: 0.55).</summary>
    public const double TodayRingOpacity = 0.55;

    /// <summary>Resting-ring border opacity (macOS: border 0.28).</summary>
    public const double RestingRingOpacity = 0.28;

    /// <summary>Out-of-month cell opacity (macOS: 0.45).</summary>
    public const double OutOfMonthOpacity = 0.45;
}
