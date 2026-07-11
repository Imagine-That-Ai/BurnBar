using System;
using System.Globalization;

namespace OpenBurnBar.App.Presentation.MissionControl;

// PORTED (faithful) from MissionConsoleFormatting in
// OpenBurnBarCore/.../Views/MissionControl/MissionConsoleTypes.swift. Pure number/time
// formatting shared across the console surfaces. Culture-invariant so tests lock the
// exact strings the mono readouts render (the Swift used C-format specifiers).

/// <summary>Shared cost / token / duration / relative-time formatting.</summary>
public static class MissionFormatting
{
    /// <summary>Format a USD amount. Mirrors <c>MissionConsoleFormatting.cost</c>:
    /// >= $100 rounds to whole dollars (unless precise), &lt; $1 or precise shows 4dp,
    /// otherwise 2dp.</summary>
    public static string Cost(double usd, bool precise = false)
    {
        if (!precise && usd >= 100)
        {
            return string.Format(CultureInfo.InvariantCulture, "${0:0}", usd);
        }

        if (precise || usd < 1)
        {
            return string.Format(CultureInfo.InvariantCulture, "${0:0.0000}", usd);
        }

        return string.Format(CultureInfo.InvariantCulture, "${0:0.00}", usd);
    }

    /// <summary>An en-dash cost band. Mirrors <c>costRange</c>.</summary>
    public static string CostRange(double low, double high) => $"{Cost(low)}–{Cost(high)}";

    /// <summary>Format a token count with k/M suffixes. Mirrors <c>tokens</c>.</summary>
    public static string Tokens(int count)
    {
        if (count >= 1_000_000)
        {
            return string.Format(CultureInfo.InvariantCulture, "{0:0.0}M", count / 1_000_000.0);
        }

        if (count >= 1_000)
        {
            return string.Format(CultureInfo.InvariantCulture, "{0:0.0}k", count / 1_000.0);
        }

        return count.ToString(CultureInfo.InvariantCulture);
    }

    /// <summary>An en-dash token band. Mirrors <c>tokenRange</c>.</summary>
    public static string TokenRange(int low, int high) => $"{Tokens(low)}–{Tokens(high)}";

    /// <summary>Format a duration as h:mm:ss or mm:ss. Mirrors <c>duration</c>.</summary>
    public static string Duration(double seconds)
    {
        int total = (int)Math.Round(seconds, MidpointRounding.AwayFromZero);
        if (total < 0)
        {
            total = 0;
        }

        int h = total / 3600;
        int m = (total % 3600) / 60;
        int s = total % 60;
        if (h > 0)
        {
            return string.Format(CultureInfo.InvariantCulture, "{0}:{1:00}:{2:00}", h, m, s);
        }

        return string.Format(CultureInfo.InvariantCulture, "{0:00}:{1:00}", m, s);
    }

    /// <summary>An en-dash duration band. Mirrors <c>durationRange</c>.</summary>
    public static string DurationRange(double low, double high) => $"{Duration(low)}–{Duration(high)}";

    /// <summary>Human-friendly "x ago" relative label. Mirrors <c>relativeTime</c>.</summary>
    public static string RelativeTime(DateTimeOffset value, DateTimeOffset reference)
    {
        double delta = (reference - value).TotalSeconds;
        if (delta < 5)
        {
            return "just now";
        }

        if (delta < 60)
        {
            return $"{(int)delta}s ago";
        }

        if (delta < 3_600)
        {
            return $"{(int)(delta / 60)}m ago";
        }

        if (delta < 86_400)
        {
            return $"{(int)(delta / 3_600)}h ago";
        }

        return $"{(int)(delta / 86_400)}d ago";
    }
}
