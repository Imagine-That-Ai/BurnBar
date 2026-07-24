using System.Globalization;

namespace OpenBurnBar.App.Presentation.Calendar;

/// <summary>
/// Display formatting for the Calendar surface — same conventions as
/// <c>UsageRuntimePresentationProjection</c> (en-US currency, K/M/B token
/// compaction) so the shell reads consistently across surfaces.
/// </summary>
public static class CalendarFormatting
{
    public static string Cost(double cost) =>
        cost.ToString("C2", CultureInfo.GetCultureInfo("en-US"));

    public static string Tokens(long tokens)
    {
        if (tokens >= 1_000_000_000) return $"{tokens / 1_000_000_000.0:0.##}B";
        if (tokens >= 1_000_000) return $"{tokens / 1_000_000.0:0.##}M";
        if (tokens >= 1_000) return $"{tokens / 1_000.0:0.#}K";
        return tokens.ToString(CultureInfo.InvariantCulture);
    }

    /// <summary>A 0…1 share as a whole/one-decimal percent ("42%", "7.5%").</summary>
    public static string Percent(double share)
    {
        double pct = share * 100;
        return pct >= 10 || pct == System.Math.Floor(pct)
            ? $"{pct:0}%"
            : $"{pct:0.0}%";
    }
}
