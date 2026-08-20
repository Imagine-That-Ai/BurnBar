using System;
using System.Globalization;
using Microsoft.UI;
using Microsoft.UI.Xaml.Data;
using Microsoft.UI.Xaml.Media;
using Windows.UI;
using OpenBurnBar.App.Presentation.Switcher;
using OpenBurnBar.App.Theme;

namespace OpenBurnBar.App.Switcher;

/// <summary>
/// View-layer glue for the WinUI account-switcher surface: a hex-string → brush converter
/// (the provider brand colors travel as "RRGGBB" strings out of the portable
/// <see cref="ProfileGroup"/>), and the CLI-type → <see cref="AgentProviderBrand"/> map so
/// the shared <c>ProviderLogoView</c> renders the right emblem. No logic — pure presentation.
/// </summary>
public static class SwitcherViewSupport
{
    /// <summary>Map a switcher CLI type to the shared brand-logo enum (for ProviderLogoView).</summary>
    public static AgentProviderBrand Brand(SwitcherCLIProfileType? type) => type switch
    {
        SwitcherCLIProfileType.Codex => AgentProviderBrand.Codex,
        SwitcherCLIProfileType.Claude => AgentProviderBrand.ClaudeCode,
        SwitcherCLIProfileType.OpenCode => AgentProviderBrand.OpenCode,
        SwitcherCLIProfileType.Droid => AgentProviderBrand.Factory,
        SwitcherCLIProfileType.Forge => AgentProviderBrand.ForgeDev,
        SwitcherCLIProfileType.Antigravity => AgentProviderBrand.Antigravity,
        SwitcherCLIProfileType.Grok => AgentProviderBrand.XAI,
        SwitcherCLIProfileType.CursorAgent => AgentProviderBrand.CursorAgent,
        SwitcherCLIProfileType.Omp => AgentProviderBrand.Omp,
        SwitcherCLIProfileType.Gemini => AgentProviderBrand.GeminiCLI,
        SwitcherCLIProfileType.Kimi => AgentProviderBrand.Kimi,
        SwitcherCLIProfileType.Pi => AgentProviderBrand.PiAgent,
        _ => AgentProviderBrand.OpenBurnBar,
    };

    /// <summary>Parse a "RRGGBB" / "#RRGGBB" hex string into a <see cref="Color"/> (opaque).</summary>
    public static Color ParseHex(string? hex)
    {
        if (!string.IsNullOrWhiteSpace(hex))
        {
            var span = hex.AsSpan().Trim();
            if (span.Length > 0 && span[0] == '#')
            {
                span = span.Slice(1);
            }

            if (span.Length == 6 &&
                byte.TryParse(span.Slice(0, 2), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var r) &&
                byte.TryParse(span.Slice(2, 2), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var g) &&
                byte.TryParse(span.Slice(4, 2), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var b))
            {
                return Color.FromArgb(0xFF, r, g, b);
            }
        }

        return Colors.Transparent;
    }
}

/// <summary>"RRGGBB" hex string → <see cref="SolidColorBrush"/>. Optional ConverterParameter
/// is an alpha byte (0-255) applied to the parsed color, e.g. a translucent accent fill.</summary>
public sealed class HexToBrushConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        var color = SwitcherViewSupport.ParseHex(value as string);

        if (parameter is string alphaText &&
            byte.TryParse(alphaText, NumberStyles.Integer, CultureInfo.InvariantCulture, out var alpha))
        {
            color = Windows.UI.Color.FromArgb(alpha, color.R, color.G, color.B);
        }

        return new SolidColorBrush(color);
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        throw new NotSupportedException();
}
