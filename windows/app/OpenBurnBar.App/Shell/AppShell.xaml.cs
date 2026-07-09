using System;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OpenBurnBar.App.Diagnostics;
using OpenBurnBar.App.Theme;

namespace OpenBurnBar.App.Shell;

/// <summary>
/// App frame chrome matching macOS <c>DashboardView</c> Command Deck:
/// section switcher menu + palette + appearance, full-width content frame.
/// The permanent left destination rail is intentionally gone — Dashboard owns
/// the Command sidebar (<c>DashboardSidebarView</c> parity).
/// </summary>
public sealed partial class AppShell : UserControl
{
    private string? _currentKey;
    private ThemeService? _theme;
    private bool _appearanceBound;

    public AppShell()
    {
        InitializeComponent();
        BuildSectionMenus();
        NavigateFrame(NavCatalog.Default);
    }

    /// <summary>Raised when the user asks for the Command Palette (header button or Ctrl+K).</summary>
    public event EventHandler? CommandPaletteRequested;

    /// <summary>
    /// Provide the shell theme service. The Appearance picker binds lazily on first flyout open.
    /// </summary>
    public void BindTheme(ThemeService theme) => _theme = theme;

    private void AppearanceFlyout_Opening(object sender, object e)
    {
        if (_appearanceBound || _theme is null)
        {
            return;
        }

        AppearanceControl.Bind(_theme);
        _appearanceBound = true;
    }

    /// <summary>Navigate the content frame to a destination by key (used by the palette).</summary>
    public void Navigate(string key)
    {
        var destination = NavCatalog.Find(key);
        if (destination is null)
        {
            return;
        }

        NavigateFrame(destination);
    }

    private void BuildSectionMenus()
    {
        SectionMenu.Items.Clear();
        OverflowMenu.Items.Clear();

        // Primary sections in the switcher — macOS DashboardSectionSwitcher lists
        // chat/quota/database/projects/missions/sessionLogs/memory; Windows NavCatalog
        // is the ordered 12-destination catalog. Dashboard stays first (overview home).
        foreach (var destination in NavCatalog.Menu)
        {
            SectionMenu.Items.Add(CreateMenuItem(destination));
        }

        foreach (var destination in NavCatalog.Footer)
        {
            OverflowMenu.Items.Add(CreateMenuItem(destination));
        }

        // Palette-only auxiliaries stay reachable from overflow too.
        if (NavCatalog.Auxiliary.Count > 0)
        {
            OverflowMenu.Items.Add(new MenuFlyoutSeparator());
            foreach (var destination in NavCatalog.Auxiliary)
            {
                OverflowMenu.Items.Add(CreateMenuItem(destination));
            }
        }
    }

    private MenuFlyoutItem CreateMenuItem(NavDestination destination)
    {
        var item = new MenuFlyoutItem
        {
            Text = destination.Title,
            Tag = destination.Key,
            Icon = new FontIcon
            {
                FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Segoe MDL2 Assets"),
                Glyph = destination.Glyph,
            },
        };
        item.Click += (_, _) => Navigate(destination.Key);
        return item;
    }

    private void NavigateFrame(NavDestination destination)
    {
        // Dedupe: selection-in-constructor + palette re-entry can both fire.
        if (_currentKey == destination.Key)
        {
            ApplySectionChrome(destination);
            return;
        }

        Type pageType = SurfacePageResolver.Resolve(destination.Key);
        AppDiagnostics.RouteBegin(destination.Key, pageType);
        try
        {
            _currentKey = destination.Key;
            ApplySectionChrome(destination);
            ContentFrame.Navigate(pageType, destination);
            AppDiagnostics.RouteSuccess(destination.Key, pageType);
        }
        catch (Exception ex)
        {
            AppDiagnostics.RouteFailure(destination.Key, pageType, ex);
            throw;
        }
    }

    private void ApplySectionChrome(NavDestination destination)
    {
        SectionTitle.Text = destination.Title;
        SectionGlyph.Glyph = destination.Glyph;

        // Tick mark on the active section menu row.
        foreach (object raw in SectionMenu.Items)
        {
            if (raw is MenuFlyoutItem item)
            {
                bool active = (string?)item.Tag == destination.Key;
                item.Icon = new FontIcon
                {
                    FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Segoe MDL2 Assets"),
                    Glyph = active ? "\uE73E" : (NavCatalog.Find((string?)item.Tag)?.Glyph ?? "\uE80F"),
                };
            }
        }
    }

    private void Palette_Click(object sender, RoutedEventArgs e)
        => CommandPaletteRequested?.Invoke(this, EventArgs.Empty);
}
