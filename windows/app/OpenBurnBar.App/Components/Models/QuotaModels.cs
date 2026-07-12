// PORTED (hand-authored, parity-with-Swift) from the macOS quota model + views:
//   OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/ProviderQuotaTypes.swift
//     — ProviderQuotaBucket + displayRemainingFraction / displayRemainingPercent,
//       ProviderQuotaWindowKind
//   OpenBurnBarCore/Sources/OpenBurnBarCore/Views/UnifiedQuotaSignalView.swift
//     — BucketUnitKind, remainingText/fullRemainingText/formatValue/
//       remainingPercentText/bucketDisplayName/windowLabel, QuotaSignalStatus.resolve
//   AgentLens/Views/Components/ProviderQuota/ProviderQuotaStripViews.swift
//     — the fillColor / fillGradient BAND thresholds
//
// This is the pure, platform-agnostic model the shared quota controls
// (Components/UnifiedQuotaSignalView, Components/QuotaWindowStrip, Components/QuotaSourceBadge)
// read. It targets `System` only (no WinUI), so it compiles + runs on macOS and is
// asserted by windows/tests/components/QuotaModelTests.cs against hand-computed Swift
// golden values. The WinUI controls turn these numbers into brushes/geometry.

using System;
using System.Collections.Generic;
using System.Globalization;

namespace OpenBurnBar.App.Components;

/// <summary>Quota reset cadence. Swift: <c>ProviderQuotaWindowKind</c>.</summary>
public enum QuotaWindowKind
{
    RollingHours,
    RollingDays,
    Daily,
    Weekly,
    Monthly,
    Lifetime,
    Custom,
}

/// <summary>Provenance of a quota reading. Swift: <c>ProviderQuotaSourceKind</c>.</summary>
public enum QuotaSourceKind
{
    OfficialApi,
    LocalCli,
    LocalSession,
    ManualEstimate,
    Unavailable,
}

/// <summary>Confidence in a quota reading. Swift: <c>ProviderQuotaConfidence</c>.</summary>
public enum QuotaConfidence
{
    Exact,
    Estimated,
    Unavailable,
}

/// <summary>The four remaining-reserve bands the battery/strip fill uses.
/// Swift: the <c>switch fraction</c> arms in UnifiedQuotaSignalView.fillColor /
/// QuotaDualWindowStrip.fillColor.</summary>
public enum QuotaFillBand
{
    /// <summary><c>fraction &gt;= 0.75</c> — full primary tint.</summary>
    Wide,
    /// <summary><c>0.50 &lt;= fraction &lt; 0.75</c> — dimmed primary.</summary>
    Comfortable,
    /// <summary><c>0.25 &lt;= fraction &lt; 0.50</c> — amber.</summary>
    Narrowing,
    /// <summary><c>fraction &lt; 0.25</c> — warning.</summary>
    Edge,
}

/// <summary>The qualitative reserve state shown as the status word + detail line.
/// Swift: <c>QuotaSignalStatus.resolve(fraction:theme:)</c> — the tint is resolved to a
/// <see cref="QuotaTintRole"/> (theme-relative) so this stays platform-agnostic.</summary>
public enum QuotaTintRole
{
    Warning,
    Amber,
    ThemeAccent,
    ThemePrimary,
}

/// <summary>Kind of value a bucket carries. Swift: UnifiedQuotaSignalView.BucketUnitKind.</summary>
public enum QuotaBucketUnitKind
{
    Currency,
    Percent,
    Tokens,
    Unlimited,
    Count,
}

/// <summary>Resolved status word + detail + tint role. Swift: <c>QuotaSignalStatus</c>.</summary>
public readonly record struct QuotaSignalStatus(string Label, string Detail, QuotaTintRole Tint)
{
    /// <summary>Swift: <c>QuotaSignalStatus.resolve(fraction:theme:)</c>.</summary>
    public static QuotaSignalStatus Resolve(double fraction) => fraction switch
    {
        < 0.10 => new QuotaSignalStatus("Near Edge", "Close to the active cap.", QuotaTintRole.Warning),
        < 0.25 => new QuotaSignalStatus("Narrowing", "Reserve is thinning.", QuotaTintRole.Amber),
        < 0.50 => new QuotaSignalStatus("Comfortable", "Healthy reserve remains.", QuotaTintRole.ThemeAccent),
        _ => new QuotaSignalStatus("Wide Open", "Plenty of headroom in this window.", QuotaTintRole.ThemePrimary),
    };
}

/// <summary>
/// Surface-agnostic quota bucket. Mirrors <c>OpenBurnBarCore.ProviderQuotaBucket</c> plus the
/// display-layer helpers the macOS quota views compute. Value-typed and immutable so it can be
/// asserted directly in tests.
/// </summary>
public sealed class QuotaBucket
{
    public string Name { get; }
    public double Used { get; }
    public double Limit { get; }
    public double Remaining { get; }
    public string? Window { get; }
    public IReadOnlyDictionary<string, string>? Meta { get; }
    public DateTimeOffset? ResetsAt { get; }

    public QuotaBucket(
        string name,
        double used,
        double limit,
        double remaining,
        string? window = null,
        IReadOnlyDictionary<string, string>? meta = null,
        DateTimeOffset? resetsAt = null)
    {
        Name = name ?? string.Empty;
        Used = used;
        Limit = limit;
        Remaining = remaining;
        Window = window;
        Meta = meta;
        ResetsAt = resetsAt;
    }

    // MARK: displayRemainingFraction (byte-for-byte port of the Swift extension)

    private static readonly string[] UsedPercentKeys =
    {
        "usedPercent", "used_percent", "used_percentage",
        "usagePercent", "usage_percent", "percentage",
    };

    private static readonly string[] RemainingPercentKeys =
    {
        "remainingPercent", "remaining_percent", "remainingPercentage",
        "remaining_percentage", "percentRemaining", "percent_remaining",
    };

    /// <summary>Swift: <c>ProviderQuotaBucket.displayRemainingFraction</c>.</summary>
    public double? DisplayRemainingFraction
    {
        get
        {
            if (MetaNumber(UsedPercentKeys) is double usedPercent)
            {
                return Clamp((100 - usedPercent) / 100);
            }

            if (MetaNumber(RemainingPercentKeys) is double remainingPercent)
            {
                return Clamp(remainingPercent / 100);
            }

            string? unit = MetaLower("unit");
            string? limitKind = MetaLower("limitKind");
            if (unit == "unlimited" || limitKind == "unlimited")
            {
                return 1;
            }

            if (!IsFinite(Used) || !IsFinite(Limit) || !IsFinite(Remaining))
            {
                return null;
            }

            if (Limit > 0)
            {
                return Clamp(Math.Max(0, Remaining) / Limit);
            }

            if (unit == "percent" || unit == "%")
            {
                if (Remaining >= 0)
                {
                    return Clamp(Remaining / 100);
                }

                if (Used >= 0)
                {
                    return Clamp((100 - Used) / 100);
                }
            }

            if (Limit < 0 && Remaining > 0)
            {
                double syntheticLimit = Remaining + Math.Max(0, Used);
                return syntheticLimit > 0 ? Clamp(Remaining / syntheticLimit) : 1;
            }

            return null;
        }
    }

    /// <summary>Swift: <c>ProviderQuotaBucket.displayRemainingPercent</c>.</summary>
    public double? DisplayRemainingPercent =>
        DisplayRemainingFraction is double f ? f * 100 : (double?)null;

    // MARK: window kind + label

    /// <summary>Parse the free-form <see cref="Window"/> string into a kind.
    /// Mirrors the vocabulary the macOS strip's <c>rowConfig</c> switches on.</summary>
    public QuotaWindowKind WindowKind
    {
        get
        {
            string raw = (Window ?? string.Empty).Trim().ToLowerInvariant();
            return raw switch
            {
                "rollinghours" or "rolling_hours" or "hourly" or "5h" => QuotaWindowKind.RollingHours,
                "daily" or "24h" => QuotaWindowKind.Daily,
                "weekly" or "7d" => QuotaWindowKind.Weekly,
                "rollingdays" or "rolling_days" => QuotaWindowKind.RollingDays,
                "monthly" or "30d" => QuotaWindowKind.Monthly,
                "lifetime" or "alltime" or "all_time" => QuotaWindowKind.Lifetime,
                "" => QuotaWindowKind.Custom,
                _ => QuotaWindowKind.Custom,
            };
        }
    }

    /// <summary>Short pill label for the time window. Swift:
    /// UnifiedQuotaSignalView.windowLabel (the "5h / 24h / 7d / 30d / All" vocabulary).</summary>
    public string? WindowLabel
    {
        get
        {
            string raw = (Window ?? string.Empty).ToLowerInvariant();
            switch (raw)
            {
                case "rollinghours":
                case "rolling_hours":
                case "hourly":
                case "5h":
                    return "5h";
                case "daily":
                case "24h":
                    return "24h";
                case "weekly":
                case "rollingdays":
                case "rolling_days":
                case "7d":
                    return "7d";
                case "monthly":
                case "30d":
                    return "30d";
                case "lifetime":
                case "alltime":
                case "all_time":
                    return "All";
                case "":
                    return null;
                default:
                    if (raw.Length <= 4)
                    {
                        return raw.ToUpperInvariant();
                    }

                    return char.ToUpperInvariant(raw[0]) + raw.Substring(1);
            }
        }
    }

    // MARK: unit + formatted text (Swift: UnifiedQuotaSignalView)

    /// <summary>Swift: UnifiedQuotaSignalView.bucketUnit.</summary>
    public QuotaBucketUnitKind Unit
    {
        get
        {
            string metaValue = (MetaLower("unit") ?? string.Empty);
            return metaValue switch
            {
                "currency" or "usd" or "dollars" or "$" => QuotaBucketUnitKind.Currency,
                "percent" or "%" => QuotaBucketUnitKind.Percent,
                "tokens" or "tok" => QuotaBucketUnitKind.Tokens,
                "unlimited" => QuotaBucketUnitKind.Unlimited,
                _ => QuotaBucketUnitKind.Count,
            };
        }
    }

    /// <summary>The compact "left" string. Swift: UnifiedQuotaSignalView.remainingText.</summary>
    public string RemainingText(string displayMode = "remainingPercent")
    {
        if (Unit == QuotaBucketUnitKind.Unlimited)
        {
            return "Unlimited";
        }

        switch (displayMode)
        {
            case "usedPercent":
                if (Unit == QuotaBucketUnitKind.Percent)
                {
                    double clamped = Math.Min(Math.Max(Used, 0), 100);
                    return $"{(int)Math.Round(clamped)}% used";
                }

                {
                    double usedPct = DisplayRemainingPercent is double p ? 100 - p : 0;
                    return $"{(int)Math.Round(usedPct)}% used";
                }
            case "fractional":
                return string.Format(CultureInfo.InvariantCulture, "{0:0.00} left", DisplayRemainingFraction ?? 0);
            case "absoluteValues":
                return $"{FormatValue(Used)} / {FormatValue(Limit)}";
            default: // remainingPercent
                if (Unit == QuotaBucketUnitKind.Percent)
                {
                    double clamped = Math.Min(Math.Max(Remaining, 0), 100);
                    return $"{(int)Math.Round(clamped)}% left";
                }

                if (DisplayRemainingPercent is double pct)
                {
                    return $"{(int)Math.Round(pct)}% left";
                }

                return $"{FormatValue(Remaining)} left";
        }
    }

    /// <summary>The verbose "remaining" string. Swift: UnifiedQuotaSignalView.fullRemainingText.</summary>
    public string FullRemainingText(string displayMode = "remainingPercent")
    {
        if (Unit == QuotaBucketUnitKind.Unlimited)
        {
            return "Unlimited";
        }

        switch (displayMode)
        {
            case "usedPercent":
                if (Unit == QuotaBucketUnitKind.Percent)
                {
                    double clamped = Math.Min(Math.Max(Used, 0), 100);
                    return $"{(int)Math.Round(clamped)}% used";
                }

                {
                    double usedPct = DisplayRemainingPercent is double p ? 100 - p : 0;
                    return $"{(int)Math.Round(usedPct)}% used";
                }
            case "fractional":
                return string.Format(CultureInfo.InvariantCulture, "{0:0.00} remaining", DisplayRemainingFraction ?? 0);
            case "absoluteValues":
                return $"{FormatValue(Used)} / {FormatValue(Limit)} used";
            default:
                if (Unit == QuotaBucketUnitKind.Percent)
                {
                    double clamped = Math.Min(Math.Max(Remaining, 0), 100);
                    return $"{(int)Math.Round(clamped)}% remaining";
                }

                if (DisplayRemainingPercent is double pct)
                {
                    return $"{(int)Math.Round(pct)}% remaining";
                }

                return $"{FormatValue(Remaining)} remaining";
        }
    }

    /// <summary>Swift: UnifiedQuotaSignalView.usageText.</summary>
    public string UsageText
    {
        get
        {
            if (Unit == QuotaBucketUnitKind.Unlimited)
            {
                return "No fixed cap";
            }

            return $"{FormatValue(Used)} / {FormatValue(Limit)}";
        }
    }

    /// <summary>Swift: UnifiedQuotaSignalView.remainingPercentText.</summary>
    public string RemainingPercentText
    {
        get
        {
            if (Unit == QuotaBucketUnitKind.Unlimited)
            {
                return "∞"; // infinity
            }

            if (DisplayRemainingPercent is not double pct)
            {
                return "—"; // em dash
            }

            if (pct < 1)
            {
                return string.Format(CultureInfo.InvariantCulture, "{0:0.0}%", pct);
            }

            return $"{(int)Math.Round(pct)}%";
        }
    }

    /// <summary>Swift: UnifiedQuotaSignalView.formatValue(_:).</summary>
    public string FormatValue(double value)
    {
        switch (Unit)
        {
            case QuotaBucketUnitKind.Currency:
                return value.ToString("C2", CultureInfo.GetCultureInfo("en-US"));
            case QuotaBucketUnitKind.Percent:
                double clamped = Math.Min(Math.Max(value, 0), 100);
                return $"{(int)Math.Round(clamped)}%";
            case QuotaBucketUnitKind.Tokens:
                if (value >= 1_000_000_000) return string.Format(CultureInfo.InvariantCulture, "{0:0.00}B", value / 1_000_000_000);
                if (value >= 1_000_000) return string.Format(CultureInfo.InvariantCulture, "{0:0.0}M", value / 1_000_000);
                if (value >= 1_000) return string.Format(CultureInfo.InvariantCulture, "{0:0.0}K", value / 1_000);
                return $"{(int)Math.Round(value)}";
            case QuotaBucketUnitKind.Unlimited:
                return "Unlimited";
            default:
                return ((long)Math.Round(value)).ToString("N0", CultureInfo.GetCultureInfo("en-US"));
        }
    }

    /// <summary>Friendly, humanized bucket name. Swift: UnifiedQuotaSignalView.bucketDisplayName.</summary>
    public string DisplayName
    {
        get
        {
            string raw = Name.Trim();
            if (raw.Length == 0)
            {
                return "Quota";
            }

            if (raw.Contains(' '))
            {
                return raw;
            }

            string cleaned = raw.Replace('_', ' ').Replace('-', ' ');
            string[] parts = cleaned.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            for (int i = 0; i < parts.Length; i++)
            {
                parts[i] = char.ToUpperInvariant(parts[i][0]) + parts[i].Substring(1);
            }

            return string.Join(" ", parts);
        }
    }

    // MARK: helpers

    private double? MetaNumber(string[] keys)
    {
        if (Meta is null)
        {
            return null;
        }

        foreach (string key in keys)
        {
            if (!Meta.TryGetValue(key, out string? raw) || raw is null)
            {
                continue;
            }

            string trimmed = raw.Trim();
            if (trimmed.Length == 0)
            {
                continue;
            }

            if (double.TryParse(trimmed.Replace("%", string.Empty), NumberStyles.Float, CultureInfo.InvariantCulture, out double value))
            {
                return value;
            }
        }

        return null;
    }

    private string? MetaLower(string key) =>
        Meta is not null && Meta.TryGetValue(key, out string? v) && v is not null ? v.ToLowerInvariant() : null;

    private static bool IsFinite(double d) => !double.IsNaN(d) && !double.IsInfinity(d);

    private static double Clamp(double value) => Math.Min(Math.Max(value, 0), 1);
}

/// <summary>The fill band + provenance helpers shared by the battery view and window strip.</summary>
public static class QuotaFill
{
    /// <summary>Resolve the reserve fraction into a fill band. Swift: the <c>switch fraction</c>
    /// in UnifiedQuotaSignalView.fillColor / QuotaDualWindowStrip.fillColor.</summary>
    public static QuotaFillBand Band(double fraction) => fraction switch
    {
        >= 0.75 => QuotaFillBand.Wide,
        >= 0.50 => QuotaFillBand.Comfortable,
        >= 0.25 => QuotaFillBand.Narrowing,
        _ => QuotaFillBand.Edge,
    };

    /// <summary>Label for a source badge. Swift: <c>ProviderQuotaSourceKind.label</c>.</summary>
    public static string SourceLabel(QuotaSourceKind source) => source switch
    {
        QuotaSourceKind.OfficialApi => "Official API",
        QuotaSourceKind.LocalCli => "Local CLI",
        QuotaSourceKind.LocalSession => "Local session",
        QuotaSourceKind.ManualEstimate => "Estimated",
        _ => "Unavailable",
    };
}
