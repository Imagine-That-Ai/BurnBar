// PORTED (faithful, parity-with-Swift) from the pure pacing math the macOS quota
// surfaces share across Mac / iOS / Android:
//   OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/ProviderQuotaPacing.swift
//     — PaceSeverity, IdealPace, PacingMath.windowDuration / .pace / .humanLabel
//
// This is the pure, platform-agnostic ideal-pace derivation that the twin-ring
// QuotaArcDial (Quota/QuotaArcDial) draws a "where usage *should* be" marker from.
// It targets `System` only (no WinUI), so it compiles + runs on macOS and is asserted
// by windows/tests/components/QuotaPacingTests.cs against the same golden values pinned
// by OpenBurnBarCoreTests/ProviderQuotaPacingTests.swift. The WinUI dial turns the
// marker fraction into a ring-edge dot; this file owns none of that.
//
// The window-kind vocabulary reuses the existing QuotaWindowKind enum from QuotaModels.cs.

using System;
using System.Globalization;

namespace OpenBurnBar.App.Components;

/// <summary>Bucketed pace signal for UI tinting. Swift: <c>PaceSeverity</c>.</summary>
public enum PaceSeverity
{
    /// <summary><c>|delta| &lt; onPaceThreshold</c> — usage tracks elapsed time.</summary>
    OnPace,

    /// <summary><c>delta &gt; 0</c> — used more of the quota than time elapsed (burning fast).</summary>
    AheadOfBudget,

    /// <summary><c>delta &lt; 0</c> — used less of the quota than time elapsed (headroom).</summary>
    BehindBudget,
}

/// <summary>
/// A snapshot of where a bucket's usage <i>should</i> be if it is to last the full window.
/// Pure derivation — never persisted, never networked. Swift: <c>IdealPace</c>.
/// </summary>
public readonly record struct IdealPace(
    DateTimeOffset WindowStart,
    DateTimeOffset WindowEnd,
    double ElapsedFraction,
    double UsedFraction,
    double Delta,
    PaceSeverity Severity,
    string HumanLabel);

/// <summary>Pure pacing math. Swift: <c>PacingMath</c>.</summary>
public static class PacingMath
{
    /// <summary>Below this absolute delta the bucket is "on pace" and the UI suppresses the
    /// badge to avoid noise. Swift: <c>PacingMath.onPaceThreshold</c>.</summary>
    public const double OnPaceThreshold = 0.03;

    /// <summary>
    /// Duration of the active window ending at <paramref name="resetsAt"/> for the given kind.
    /// Returns <c>null</c> for kinds without a finite repeating window (lifetime / custom).
    /// Swift: <c>PacingMath.windowDuration(for:resetsAt:calendar:)</c>.
    /// </summary>
    public static TimeSpan? WindowDuration(QuotaWindowKind kind, DateTimeOffset resetsAt)
    {
        switch (kind)
        {
            case QuotaWindowKind.RollingHours:
                return TimeSpan.FromHours(5);
            case QuotaWindowKind.Daily:
                return TimeSpan.FromHours(24);
            case QuotaWindowKind.Weekly:
            case QuotaWindowKind.RollingDays:
                return TimeSpan.FromDays(7);
            case QuotaWindowKind.Monthly:
                // True calendar arithmetic so February (28/29d) and March (31d) report
                // different durations. Falls back to 30d if the subtraction underflows.
                // Swift uses `calendar.date(byAdding: .month, value: -1, to: resetsAt)`.
                DateTimeOffset start = resetsAt.AddMonths(-1);
                TimeSpan interval = resetsAt - start;
                return interval > TimeSpan.Zero ? interval : TimeSpan.FromDays(30);
            default:
                return null;
        }
    }

    /// <summary>
    /// Compute the ideal pace for a bucket. Returns <c>null</c> when there is no meaningful window
    /// (lifetime, custom, or missing <paramref name="resetsAt"/>). Swift: <c>PacingMath.pace(...)</c>.
    /// </summary>
    /// <param name="windowKind">Window kind of the bucket.</param>
    /// <param name="resetsAt">When the current window ends.</param>
    /// <param name="progressFraction">How much of the quota is used (0…1).</param>
    /// <param name="now">Reference time.</param>
    public static IdealPace? Pace(
        QuotaWindowKind windowKind,
        DateTimeOffset? resetsAt,
        double progressFraction,
        DateTimeOffset now)
    {
        if (resetsAt is not { } end0)
        {
            return null;
        }

        if (WindowDuration(windowKind, end0) is not { } duration || duration <= TimeSpan.Zero)
        {
            return null;
        }

        DateTimeOffset windowEnd;
        DateTimeOffset windowStart;
        double elapsedFraction;

        if (now > end0)
        {
            // Snapshot is stale (resetsAt in the past). Assume the next window just began at
            // resetsAt; the user is at the very start of the new period.
            windowEnd = end0 + duration;
            windowStart = end0;
            elapsedFraction = 0;
        }
        else
        {
            windowEnd = end0;
            windowStart = end0 - duration;
            double raw = (now - windowStart) / duration;
            elapsedFraction = Math.Clamp(raw, 0, 1);
        }

        double used = Math.Clamp(progressFraction, 0, 1);
        double delta = used - elapsedFraction;
        PaceSeverity severity = Math.Abs(delta) < OnPaceThreshold
            ? PaceSeverity.OnPace
            : (delta > 0 ? PaceSeverity.AheadOfBudget : PaceSeverity.BehindBudget);

        return new IdealPace(
            windowStart,
            windowEnd,
            elapsedFraction,
            used,
            delta,
            severity,
            HumanLabel(delta, severity));
    }

    /// <summary>Short badge label: <c>"on pace"</c>, <c>"+12% pace"</c>, <c>"-8% pace"</c>.
    /// Rounded to the nearest whole percent. Swift: <c>PacingMath.humanLabel(for:severity:)</c>.</summary>
    public static string HumanLabel(double delta, PaceSeverity severity)
    {
        int pct = (int)Math.Round(delta * 100, MidpointRounding.AwayFromZero);
        return severity switch
        {
            PaceSeverity.OnPace => "on pace",
            PaceSeverity.AheadOfBudget => string.Format(CultureInfo.InvariantCulture, "+{0}% pace", pct),
            _ => string.Format(CultureInfo.InvariantCulture, "{0}% pace", pct),
        };
    }
}
