// PORTED (faithful, parity-with-Swift) from the twin-ring quota dial + its bucket math:
//   AgentLens/Views/Dashboard/Quota/QuotaArcDial.swift
//     — dominantBucket, remainingFraction(for:), outerLabel/innerLabel, centerText/centerSubtitle,
//       the pressure BANDS (which reuse QuotaFill.Band), and the PaceArcMarker fuel-gauge angle
//   AgentLens/Services/ProviderQuota/ProviderQuotaTypes.swift
//     — ProviderQuotaBucket.remainingPercent + .progressFraction (the percent-first semantics
//       the dial reads; a DIFFERENT shape from Components/QuotaModels.QuotaBucket, which is the
//       core Meta-based model — the dial mirrors the AgentLens typed bucket exactly)
//
// This is the pure, platform-agnostic dial model the WinUI Quota/QuotaArcDial renders: two rings
// (outer = longer horizon, inner = shorter horizon), each either FILLED to its remaining fraction
// or DASHED-muted when its bucket is unavailable, plus the ideal-pace marker angle. It targets
// `System` only (no WinUI), so it compiles + runs on macOS and is asserted by
// windows/tests/components/QuotaArcDialModelTests.cs against hand-computed Swift golden values.

using System;

namespace OpenBurnBar.App.Components;

/// <summary>
/// The percent-first quota bucket the twin-ring dial reads. Faithful port of the AgentLens
/// <c>ProviderQuotaBucket</c> fields <see cref="RemainingPercent"/> / <see cref="ProgressFraction"/>
/// / <see cref="RemainingFraction"/> derive from. (Distinct from <see cref="QuotaBucket"/>, which is
/// the core Meta-based model the strip/battery read.)
/// </summary>
public sealed class QuotaDialBucket
{
    public QuotaDialBucket(
        QuotaWindowKind windowKind,
        double? usedPercent = null,
        double? remainingValue = null,
        double? limitValue = null,
        double? usedValue = null,
        bool isPercentUnit = false,
        DateTimeOffset? resetsAt = null,
        string? label = null)
    {
        WindowKind = windowKind;
        UsedPercent = usedPercent;
        RemainingValue = remainingValue;
        LimitValue = limitValue;
        UsedValue = usedValue;
        IsPercentUnit = isPercentUnit;
        ResetsAt = resetsAt;
        Label = label;
    }

    public QuotaWindowKind WindowKind { get; }
    public double? UsedPercent { get; }
    public double? RemainingValue { get; }
    public double? LimitValue { get; }
    public double? UsedValue { get; }
    public bool IsPercentUnit { get; }
    public DateTimeOffset? ResetsAt { get; }
    public string? Label { get; }

    /// <summary>Swift: <c>ProviderQuotaBucket.remainingPercent</c> (0…100, or null).</summary>
    public double? RemainingPercent
    {
        get
        {
            if (UsedPercent is { } used)
            {
                return Math.Clamp(100 - used, 0, 100);
            }

            if (RemainingValue is { } remaining && IsPercentUnit)
            {
                return Math.Clamp(remaining, 0, 100);
            }

            if (RemainingValue is { } rem && LimitValue is { } limit && limit > 0)
            {
                return Math.Clamp(rem / limit * 100, 0, 100);
            }

            return null;
        }
    }

    /// <summary>Swift: <c>ProviderQuotaBucket.progressFraction</c> (0…1, defaults to 0).</summary>
    public double ProgressFraction
    {
        get
        {
            if (UsedPercent is { } used)
            {
                return Math.Clamp(used / 100, 0, 1);
            }

            if (UsedValue is { } uv && LimitValue is { } limit && limit > 0)
            {
                return Math.Clamp(uv / limit, 0, 1);
            }

            if (RemainingPercent is { } pct)
            {
                return Math.Clamp((100 - pct) / 100, 0, 1);
            }

            return 0;
        }
    }

    /// <summary>The ring fill fraction. Swift: <c>QuotaArcDial.remainingFraction(for:)</c>.</summary>
    public double RemainingFraction =>
        RemainingPercent is { } pct
            ? Math.Clamp(pct / 100, 0, 1)
            : Math.Clamp(1 - ProgressFraction, 0, 1);

    /// <summary>Short window label ("5h" / "24h" / "7d" / "30d" / "Lifetime" / label / "—").
    /// Swift: <c>QuotaArcDial.outerLabel</c> / <c>.innerLabel</c> (identical per kind).</summary>
    public string WindowLabel => WindowKind switch
    {
        QuotaWindowKind.RollingHours => "5h",
        QuotaWindowKind.Daily => "24h",
        QuotaWindowKind.Weekly => "7d",
        QuotaWindowKind.RollingDays => "7d",
        QuotaWindowKind.Monthly => "30d",
        QuotaWindowKind.Lifetime => "Lifetime",
        _ => string.IsNullOrEmpty(Label) ? "—" : Label!, // em dash
    };
}

/// <summary>
/// Pure ring-arc geometry the WinUI dial turns into an <c>ArcSegment</c> path. Rings fill clockwise
/// from the top (12 o'clock = -90°), matching SwiftUI's <c>Circle().trim(from:0,to:).rotationEffect(-90°)</c>.
/// System-only so it is unit-tested on macOS; the WinUI control only maps the returned coordinates
/// onto XAML <c>Point</c>s.
/// </summary>
public static class QuotaArcGeometry
{
    /// <summary>Angle (degrees) of a sweep fraction's fill edge — starts at top, sweeps clockwise.</summary>
    public static double AngleDegrees(double fraction) => -90 + 360 * Math.Clamp(fraction, 0, 1);

    /// <summary>The point on a ring of <paramref name="radius"/> centered at
    /// (<paramref name="cx"/>, <paramref name="cy"/>) for a sweep fraction (0…1).</summary>
    public static (double X, double Y) PointOnRing(double cx, double cy, double radius, double fraction)
    {
        double radians = AngleDegrees(fraction) * Math.PI / 180.0;
        return (cx + radius * Math.Cos(radians), cy + radius * Math.Sin(radians));
    }

    /// <summary>Whether the swept arc is the major (&gt; 180°) arc — the <c>ArcSegment.IsLargeArc</c> flag.</summary>
    public static bool IsLargeArc(double fraction) => Math.Clamp(fraction, 0, 1) > 0.5;
}

/// <summary>One concentric ring of the dial. When <see cref="IsAvailable"/> is false the WinUI
/// control renders it DASHED-muted instead of a flat zero fill (a missing bucket must not read as
/// "fully exhausted"). Swift: the outer/inner fill + pace-marker branches of QuotaArcDial.</summary>
public sealed class QuotaRingModel
{
    private QuotaRingModel(
        bool isAvailable,
        double remainingFraction,
        QuotaFillBand band,
        string windowLabel,
        IdealPace? pace)
    {
        IsAvailable = isAvailable;
        RemainingFraction = remainingFraction;
        Band = band;
        WindowLabel = windowLabel;
        Pace = pace;
    }

    /// <summary>False when the bucket is missing — the control draws a dashed muted ring.</summary>
    public bool IsAvailable { get; }

    /// <summary>Sweep fraction (0…1) the fill arc trims to. Zero when unavailable.</summary>
    public double RemainingFraction { get; }

    /// <summary>Pressure band for the fill tint. Swift: the <c>switch remaining</c> in pressureColor.</summary>
    public QuotaFillBand Band { get; }

    /// <summary>Short window label the center subtitle references.</summary>
    public string WindowLabel { get; }

    /// <summary>Ideal pace for this window, or null (lifetime/custom/missing reset).</summary>
    public IdealPace? Pace { get; }

    /// <summary>Marker fill-edge fraction (fuel gauge = <c>1 - elapsed</c>), or null when no pace.
    /// Swift: <c>PaceArcMarker</c> with <c>fuelGauge: true</c>.</summary>
    public double? MarkerFraction => Pace is { } p ? Math.Clamp(1 - p.ElapsedFraction, 0, 1) : null;

    /// <summary>Marker angle in degrees on the ring (rings rotate -90° so 0 starts at the top).
    /// Swift: <c>-90 + 360 * fraction</c>. Null when there is no pace marker.</summary>
    public double? MarkerAngleDegrees => MarkerFraction is { } f ? -90 + 360 * f : null;

    /// <summary>Build a ring from an optional bucket. Swift: outerFill / innerFill + marker branches.</summary>
    public static QuotaRingModel From(QuotaDialBucket? bucket, DateTimeOffset now)
    {
        if (bucket is null)
        {
            return new QuotaRingModel(false, 0, QuotaFillBand.Edge, "—", null);
        }

        double fraction = bucket.RemainingFraction;
        return new QuotaRingModel(
            isAvailable: true,
            remainingFraction: fraction,
            band: QuotaFill.Band(fraction),
            windowLabel: bucket.WindowLabel,
            pace: PacingMath.Pace(bucket.WindowKind, bucket.ResetsAt, bucket.ProgressFraction, now));
    }
}

/// <summary>
/// The full twin-ring dial state. Outer ring tracks the longer-horizon bucket (7d/30d/weekly);
/// inner ring the shorter one (5h/24h). The center reads the dominant window's remaining percent.
/// Swift: <c>QuotaArcDial</c>.
/// </summary>
public sealed class QuotaArcDialModel
{
    private QuotaArcDialModel(
        QuotaRingModel outer,
        QuotaRingModel inner,
        bool hasSignal,
        double dominantRemainingFraction,
        string centerText,
        string centerSubtitle)
    {
        Outer = outer;
        Inner = inner;
        HasSignal = hasSignal;
        DominantRemainingFraction = dominantRemainingFraction;
        CenterText = centerText;
        CenterSubtitle = centerSubtitle;
    }

    public QuotaRingModel Outer { get; }
    public QuotaRingModel Inner { get; }

    /// <summary>True when at least one ring has a bucket (Swift: <c>dominantBucket != nil</c>).</summary>
    public bool HasSignal { get; }

    /// <summary>Remaining fraction of the dominant (outer-preferred) bucket. Swift:
    /// <c>dominantRemainingFraction</c>.</summary>
    public double DominantRemainingFraction { get; }

    /// <summary>Center readout — "NN%" or the em-dash. Swift: <c>centerText</c>.</summary>
    public string CenterText { get; }

    /// <summary>Center caption — "left in 7d" / "no signal". Swift: <c>centerSubtitle</c>.</summary>
    public string CenterSubtitle { get; }

    /// <summary>Compose the dial from outer + inner buckets (either may be null). Dominant selection
    /// is by PRESENCE — <c>outer ?? inner</c> — matching the Swift <c>dominantBucket</c>.</summary>
    public static QuotaArcDialModel Build(QuotaDialBucket? outer, QuotaDialBucket? inner, DateTimeOffset now)
    {
        QuotaDialBucket? dominant = outer ?? inner;
        double dominantFraction = dominant?.RemainingFraction ?? 0;

        string centerText = dominant is null
            ? "—" // em dash
            : $"{(int)Math.Round(dominantFraction * 100, MidpointRounding.AwayFromZero)}%";

        // Swift: "left in \(outerLabel == "—" ? innerLabel : outerLabel)". outerLabel resolves to the
        // em-dash only when the outer bucket is missing, so the window is outer-when-present else inner.
        string outerLabel = outer?.WindowLabel ?? "—";
        string innerLabel = inner?.WindowLabel ?? "—";
        string window = outerLabel == "—" ? innerLabel : outerLabel;
        string centerSubtitle = dominant is null ? "no signal" : $"left in {window}";

        return new QuotaArcDialModel(
            outer: QuotaRingModel.From(outer, now),
            inner: QuotaRingModel.From(inner, now),
            hasSignal: dominant is not null,
            dominantRemainingFraction: dominantFraction,
            centerText: centerText,
            centerSubtitle: centerSubtitle);
    }
}
