using System.Collections.Generic;
using Microsoft.UI.Xaml.Controls;

namespace OpenBurnBar.App.Theme;

/// <summary>One selectable appearance option (mode + its glyph/label) for the picker.</summary>
public sealed class AppearanceModeOption
{
    public AppearanceModeOption(AppearanceMode mode, string label, string glyph)
    {
        Mode = mode;
        Label = label;
        Glyph = glyph;
    }

    public AppearanceMode Mode { get; }

    public string Label { get; }

    /// <summary>Segoe MDL2 Assets glyph shown beside the label.</summary>
    public string Glyph { get; }
}

/// <summary>
/// The appearance picker. Bind it to the shell's <see cref="ThemeService"/> via
/// <see cref="Bind"/>; user selections drive the service, and external changes
/// (e.g. a hotkey toggling mode) reflect back into the control.
/// </summary>
public sealed partial class AppearanceModeControl : UserControl
{
    private static readonly IReadOnlyList<AppearanceModeOption> Options = new List<AppearanceModeOption>
    {
        // Segoe MDL2 Assets glyphs (approximate; final icon parity is a Bucket A design pass).
        new(AppearanceMode.System, "System", "\uE771"),         // adaptive / follow OS
        new(AppearanceMode.Light, "Light", "\uE706"),           // Brightness (sun)
        new(AppearanceMode.Dark, "Dark", "\uE708"),             // QuietHours (moon)
        new(AppearanceMode.HighContrast, "High contrast", "\uE7B3"), // contrast dial
    };

    private ThemeService? _theme;
    private bool _syncing;

    public AppearanceModeControl()
    {
        InitializeComponent();
        ModeButtons.ItemsSource = Options;
    }

    /// <summary>Attach the picker to the shell theme service and sync the initial UI state.</summary>
    public void Bind(ThemeService theme)
    {
        _theme = theme;
        theme.Changed += (_, _) => SyncFromService();
        SyncFromService();
    }

    private void SyncFromService()
    {
        if (_theme is null)
        {
            return;
        }

        _syncing = true;
        try
        {
            var index = IndexOf(_theme.Mode);
            if (ModeButtons.SelectedIndex != index)
            {
                ModeButtons.SelectedIndex = index;
            }

            ReduceTransparencyToggle.IsOn = _theme.EffectiveReduceTransparency;
            // High-contrast forces reduced transparency, so the toggle is not independently editable there.
            ReduceTransparencyToggle.IsEnabled = _theme.Mode != AppearanceMode.HighContrast;
        }
        finally
        {
            _syncing = false;
        }
    }

    private static int IndexOf(AppearanceMode mode)
    {
        for (var i = 0; i < Options.Count; i++)
        {
            if (Options[i].Mode == mode)
            {
                return i;
            }
        }

        return 0;
    }

    private void ModeButtons_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_syncing || _theme is null)
        {
            return;
        }

        if (ModeButtons.SelectedItem is AppearanceModeOption option)
        {
            _theme.Mode = option.Mode;
        }
    }

    private void ReduceTransparencyToggle_Toggled(object sender, Microsoft.UI.Xaml.RoutedEventArgs e)
    {
        if (_syncing || _theme is null)
        {
            return;
        }

        _theme.ReduceTransparencyOverride = ReduceTransparencyToggle.IsOn;
    }
}
