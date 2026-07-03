// Row view-model bound by SettingsSearchResultsPage — the WinUI peer of the Swift
// SettingsDrillRow rendered inside SettingsSearchResultsView. It projects one ranked
// SettingsItem into display-ready fields (glyph + accent from SettingsTabVisuals,
// breadcrumb from the portable SettingsRouteDisplay) so the XAML stays declarative.

using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using OpenBurnBar.App.Settings;

namespace OpenBurnBar.App.Settings.Winui;

/// <summary>Display projection of a ranked <see cref="SettingsItem"/> for the results list.</summary>
public sealed class SettingsSearchResultViewModel
{
    public SettingsSearchResultViewModel(SettingsItem item)
    {
        Item = item;
        Glyph = SettingsTabVisuals.Glyph(item.Tab);
        AccentBrush = SettingsTabVisuals.AccentBrush(item.Tab);
        Breadcrumb = SettingsRouteDisplay.Breadcrumb(item);
    }

    /// <summary>The underlying manifest row the router navigates to when this is chosen.</summary>
    public SettingsItem Item { get; }

    public string Title => Item.Title;

    public string Subtitle => Item.Subtitle ?? string.Empty;

    public bool HasSubtitle => !string.IsNullOrEmpty(Item.Subtitle);

    /// <summary>Collapses the subtitle line when the row has none.</summary>
    public Visibility SubtitleVisibility => HasSubtitle ? Visibility.Visible : Visibility.Collapsed;

    /// <summary>"Tab › Page" trail shown as the row's value/breadcrumb.</summary>
    public string Breadcrumb { get; }

    /// <summary>Segoe Fluent glyph for the owning tab.</summary>
    public string Glyph { get; }

    /// <summary>Owning-tab accent used to tint the row glyph.</summary>
    public Brush AccentBrush { get; }
}
