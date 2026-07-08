using System;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Data;
using Microsoft.UI.Xaml.Media;
using OpenBurnBar.App.Presentation.MissionControl;
using OpenBurnBar.App.Theme;
using Windows.UI;

namespace OpenBurnBar.App.MissionControl;

// Windows-only value converters the Mission Control XAML binds to. They touch
// Microsoft.UI.Xaml, so they compile on Windows CI; on the macOS authoring host they are
// Roslyn syntax-checked and the app build reaches the XamlCompiler gate (the documented
// WinUI verification ceiling). Color roles resolve to the dark-shell Pensieve palette,
// and the runtime accent reuses the landed ProviderBrand table for byte-parity with macOS.

/// <summary>Shared dark-shell color resolutions for the mission surfaces. Mirrors the
/// macOS DesignSystem semantic colors (ember / amber / aureate / success / muted).</summary>
internal static class MissionPalette
{
    public static readonly Color Amber = Color.FromArgb(0xFF, 0xFD, 0xC4, 0x2C);   // BrassBright
    public static readonly Color Ember = Color.FromArgb(0xFF, 0xFA, 0x6B, 0x06);   // BrassCore / accent
    public static readonly Color Aureate = Color.FromArgb(0xFF, 0xE8, 0xA9, 0x3C); // hermesAureate (soft brass)
    public static readonly Color Success = Color.FromArgb(0xFF, 0x3F, 0xB7, 0x68); // green
    public static readonly Color Warning = Color.FromArgb(0xFF, 0xFD, 0xC4, 0x2C); // amber warning
    public static readonly Color Error = Color.FromArgb(0xFF, 0xFF, 0x8A, 0x7A);   // OBBStderr / crimson-lite
    public static readonly Color Muted = Color.FromArgb(0xFF, 0x8B, 0x94, 0xA8);   // textMuted

    public static SolidColorBrush Brush(Color c) => new(c);

    public static Color ForRole(MissionGaugeColorRole role) => role switch
    {
        MissionGaugeColorRole.Amber => Amber,
        MissionGaugeColorRole.Ember => Ember,
        MissionGaugeColorRole.Aureate => Aureate,
        MissionGaugeColorRole.Success => Success,
        MissionGaugeColorRole.Muted => Muted,
        _ => Muted,
    };
}

/// <summary>Maps a runtime's <see cref="MissionRuntime.ProviderKey"/> to its provider brand
/// brush via the landed <see cref="ProviderBrand"/> table. AUTO ("factory") resolves ember.</summary>
public sealed partial class MissionProviderBrushConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        string key = value as string ?? "factory";
        if (string.Equals(key, "factory", StringComparison.OrdinalIgnoreCase))
        {
            return MissionPalette.Brush(MissionPalette.Ember);
        }

        AgentProviderBrand brand = Enum.TryParse(key, ignoreCase: true, out AgentProviderBrand parsed)
            ? parsed
            : AgentProviderBrand.Factory;
        return new SolidColorBrush(ProviderBrand.Primary(brand));
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        throw new NotSupportedException();
}

/// <summary>Maps a <see cref="MissionGaugeColorRole"/> to its dark-shell brush.</summary>
public sealed partial class MissionGaugeRoleBrushConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        var role = value is MissionGaugeColorRole r ? r : MissionGaugeColorRole.Muted;
        return MissionPalette.Brush(MissionPalette.ForRole(role));
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        throw new NotSupportedException();
}

/// <summary>Maps a runtime <see cref="RuntimeAvailability"/> to the status-dot brush
/// (online = success, offline = error, unknown = muted).</summary>
public sealed partial class MissionAvailabilityBrushConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        var availability = value is RuntimeAvailability a ? a : RuntimeAvailability.Unknown;
        Color color = availability switch
        {
            RuntimeAvailability.Online => MissionPalette.Success,
            RuntimeAvailability.Offline => MissionPalette.Error,
            _ => MissionPalette.Muted,
        };
        return MissionPalette.Brush(color);
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        throw new NotSupportedException();
}

/// <summary>Bool → the elevated-cost tint (ember when true, text-primary token when false).
/// Used by the forecast COST cell. Mirrors the Swift <c>costHigh &gt; 1 ? ember : textPrimary</c>.</summary>
public sealed partial class MissionCostElevatedBrushConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        bool elevated = value is bool b && b;
        return elevated
            ? MissionPalette.Brush(MissionPalette.Ember)
            : (Application.Current.Resources["PensieveColorTextBrightBrush"] as Brush)
                ?? MissionPalette.Brush(MissionPalette.Muted);
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        throw new NotSupportedException();
}

/// <summary>Maps a phase-problem flag to a brush (ember for problems, mercury otherwise) so
/// the situation-room tiles flag wedged runs. Mirrors the tile's <c>isProblem</c> tint.</summary>
public sealed partial class MissionProblemBrushConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        bool problem = value is bool b && b;
        return problem
            ? MissionPalette.Brush(MissionPalette.Ember)
            : (Application.Current.Resources["PensieveColorMercuryCoreBrush"] as Brush)
                ?? MissionPalette.Brush(MissionPalette.Muted);
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        throw new NotSupportedException();
}
