using System;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Data;
using Microsoft.UI.Xaml.Media;
using OpenBurnBar.App.Presentation.SessionLogs;
using Windows.UI;

namespace OpenBurnBar.App.Converters;

// Small, dependency-light value converters the SessionLogs + Memory XAML binds to.
// Windows-only (they touch Microsoft.UI.Xaml), so they compile on Windows CI; on the
// macOS authoring host they are Roslyn syntax-checked and the app build reaches the
// XamlCompiler gate, matching the documented WinUI verification ceiling.

/// <summary>Bool → Visibility (true = Visible). Optional <c>ConverterParameter="invert"</c> flips it.</summary>
public sealed partial class BoolToVisibilityConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        bool flag = value is bool b && b;
        if (parameter is string s && string.Equals(s, "invert", StringComparison.OrdinalIgnoreCase))
        {
            flag = !flag;
        }

        return flag ? Visibility.Visible : Visibility.Collapsed;
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        value is Visibility v && v == Visibility.Visible;
}

/// <summary>Negated bool → Visibility (true = Collapsed). Used for empty/absent states.</summary>
public sealed partial class NegatedBoolToVisibilityConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        bool flag = value is bool b && b;
        return flag ? Visibility.Collapsed : Visibility.Visible;
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        value is Visibility v && v == Visibility.Collapsed;
}

/// <summary>
/// Maps the presentation-layer <see cref="SessionLogAccent"/> token to a brand brush,
/// so the portable grouping layer stays color-free while the header still renders the
/// Swift per-group accent. Values are the dark-shell resolutions of the macOS
/// DesignSystem semantic colors (ember/amber/blaze/whimsy/textMuted).
/// </summary>
public sealed partial class SessionLogAccentBrushConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        var accent = value is SessionLogAccent a ? a : SessionLogAccent.Ember;
        Color color = accent switch
        {
            SessionLogAccent.Ember => Color.FromArgb(0xFF, 0xFA, 0x50, 0x53),
            SessionLogAccent.Amber => Color.FromArgb(0xFF, 0xFD, 0xC4, 0x2C),
            SessionLogAccent.Blaze => Color.FromArgb(0xFF, 0xE8, 0x61, 0x00),
            SessionLogAccent.Whimsy => Color.FromArgb(0xFF, 0xA8, 0x55, 0xF7),
            _ => Color.FromArgb(0xFF, 0x8B, 0x94, 0xA8),
        };

        return new SolidColorBrush(color);
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        throw new NotSupportedException();
}
