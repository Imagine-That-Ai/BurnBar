using System;
using System.Globalization;

namespace OpenBurnBar.App.Presentation.Insights;

/// <summary>
/// Format hint used by renderers when displaying numeric values. Direct port of the
/// macOS <c>ValueFormat</c> (<c>OpenBurnBarCore/.../Insights/InsightWidgetData.swift</c>).
/// </summary>
public enum ValueFormat
{
    Currency,
    Tokens,
    Percent,
    Duration,
    Count,
    Raw,
}

/// <summary>
/// A platform-agnostic 8-bit RGB triple. The portable geometry + formatting layer never
/// references <c>Windows.UI.Color</c> (Windows-only); the Win2D render layer converts this
/// into a <c>Windows.UI.Color</c> at draw time.
/// </summary>
public readonly record struct InsightRgb(byte R, byte G, byte B)
{
    /// <summary>Pack into 0xAARRGGBB with the supplied alpha (default fully opaque).</summary>
    public uint ToArgb(byte alpha = 0xFF) =>
        ((uint)alpha << 24) | ((uint)R << 16) | ((uint)G << 8) | B;
}

/// <summary>
/// Tiny, deterministic formatting + color helpers used by every chart renderer — a direct
/// port of the macOS <c>InsightFormatting</c> enum
/// (<c>OpenBurnBarCore/.../Views/Insights/InsightFormatting.swift</c>).
///
/// Everything here is a pure function over its inputs, so the whole file is unit-tested on
/// the macOS authoring host (<c>windows/tests/presentation/Insights</c>) — the same assembly
/// that ships on Windows. Numeric formatting is pinned to the invariant culture so a German
/// or Japanese dev host produces byte-identical strings.
/// </summary>
public static class InsightFormatting
{
    private static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

    /// <summary>Format a scalar for display per <paramref name="format"/> (parity with Swift).</summary>
    public static string Format(double value, ValueFormat format)
    {
        switch (format)
        {
            case ValueFormat.Currency:
                if (Math.Abs(value) >= 1000)
                {
                    return "$" + value.ToString("F0", Inv);
                }

                if (Math.Abs(value) >= 100)
                {
                    return "$" + value.ToString("F1", Inv);
                }

                return "$" + value.ToString("F2", Inv);
            case ValueFormat.Tokens:
                return TokensFormatter(value);
            case ValueFormat.Percent:
                return (value * 100).ToString("F0", Inv) + "%";
            case ValueFormat.Duration:
                if (value < 60)
                {
                    return value.ToString("F1", Inv) + "s";
                }

                if (value < 3600)
                {
                    return (value / 60).ToString("F0", Inv) + "m";
                }

                return (value / 3600).ToString("F1", Inv) + "h";
            case ValueFormat.Count:
                return value.ToString("F0", Inv);
            case ValueFormat.Raw:
            default:
                return value.ToString(Inv);
        }
    }

    /// <summary>Signed delta (e.g. <c>+12%</c> / <c>-3.40</c>), parity with Swift.</summary>
    public static string FormatDelta(double delta, bool asPercent)
    {
        string prefix = delta >= 0 ? "+" : string.Empty;
        if (asPercent)
        {
            return prefix + (delta * 100).ToString("F0", Inv) + "%";
        }

        return prefix + delta.ToString("F2", Inv);
    }

    /// <summary>Abbreviate a token count (k / M / B), parity with Swift.</summary>
    public static string TokensFormatter(double value)
    {
        if (Math.Abs(value) >= 1_000_000_000)
        {
            return (value / 1_000_000_000).ToString("F1", Inv) + "B";
        }

        if (Math.Abs(value) >= 1_000_000)
        {
            return (value / 1_000_000).ToString("F1", Inv) + "M";
        }

        if (Math.Abs(value) >= 1_000)
        {
            return (value / 1_000).ToString("F1", Inv) + "k";
        }

        return value.ToString("F0", Inv);
    }

    /// <summary>
    /// Parse a <c>#RRGGBB</c> / <c>RRGGBB</c> / <c>#RRGGBBAA</c> hex string into an
    /// <see cref="InsightRgb"/> (alpha is dropped, matching the Swift renderer which always
    /// draws series fills at full opacity and layers opacity separately). Returns
    /// <c>null</c> for malformed input — the caller falls back to the series-id color.
    /// </summary>
    public static InsightRgb? ColorFromHex(string? hex)
    {
        if (hex is null)
        {
            return null;
        }

        string trimmed = hex.Trim();
        if (trimmed.StartsWith("#", StringComparison.Ordinal))
        {
            trimmed = trimmed.Substring(1);
        }

        if (trimmed.Length != 6 && trimmed.Length != 8)
        {
            return null;
        }

        if (!uint.TryParse(trimmed, NumberStyles.HexNumber, Inv, out uint value))
        {
            return null;
        }

        byte r = (byte)((value >> 16) & 0xff);
        byte g = (byte)((value >> 8) & 0xff);
        byte b = (byte)(value & 0xff);
        return new InsightRgb(r, g, b);
    }

    /// <summary>
    /// A stable color derived from a series id so the same series gets the same color across
    /// renders. Direct port of the Swift djb2 hash → HSB(hue, 0.55, 0.85). The HSB→RGB
    /// conversion matches SwiftUI's <c>Color(hue:saturation:brightness:)</c>.
    /// </summary>
    public static InsightRgb SeriesColor(string id)
    {
        ulong hash = 5381;
        foreach (byte b in System.Text.Encoding.UTF8.GetBytes(id))
        {
            // Swift uses wrapping (&*, &+); C# ulong arithmetic is unchecked (wraps).
            hash = (hash * 33) + b;
        }

        double hue = (hash % 360) / 360.0;
        return HsbToRgb(hue, 0.55, 0.85);
    }

    /// <summary>Resolve a series color: explicit hex wins, else the id-derived color.</summary>
    public static InsightRgb ResolveColor(string? hex, string seriesId)
        => ColorFromHex(hex) ?? SeriesColor(seriesId);

    /// <summary>
    /// HSB/HSV → RGB, matching SwiftUI <c>Color(hue:saturation:brightness:)</c>. Hue,
    /// saturation and brightness are all in <c>[0, 1]</c>. Pure + unit-tested against
    /// hand-computed values.
    /// </summary>
    public static InsightRgb HsbToRgb(double hue, double saturation, double brightness)
    {
        double h = ((hue % 1.0) + 1.0) % 1.0; // normalize into [0,1)
        double s = Math.Clamp(saturation, 0, 1);
        double v = Math.Clamp(brightness, 0, 1);

        double r, g, b;
        if (s <= 0)
        {
            r = g = b = v;
        }
        else
        {
            double h6 = h * 6.0;
            int i = (int)Math.Floor(h6) % 6;
            if (i < 0)
            {
                i += 6;
            }

            double f = h6 - Math.Floor(h6);
            double p = v * (1 - s);
            double q = v * (1 - (f * s));
            double t = v * (1 - ((1 - f) * s));
            switch (i)
            {
                case 0: r = v; g = t; b = p; break;
                case 1: r = q; g = v; b = p; break;
                case 2: r = p; g = v; b = t; break;
                case 3: r = p; g = q; b = v; break;
                case 4: r = t; g = p; b = v; break;
                default: r = v; g = p; b = q; break;
            }
        }

        return new InsightRgb(ToByte(r), ToByte(g), ToByte(b));
    }

    private static byte ToByte(double channel)
        => (byte)Math.Clamp((int)Math.Round(channel * 255.0, MidpointRounding.AwayFromZero), 0, 255);
}
