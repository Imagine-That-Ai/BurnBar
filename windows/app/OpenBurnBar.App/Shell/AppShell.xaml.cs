using System;
using Microsoft.UI.Xaml.Controls;
using OpenBurnBar.App.Diagnostics;
using OpenBurnBar.App.Theme;

namespace OpenBurnBar.App.Shell;

/// <summary>
/// Code-behind for the NavigationView app frame. Populates the sidebar from
/// <see cref="NavCatalog"/>, drives the content <see cref="Frame"/> per selection, exposes
/// programmatic <see cref="Navigate(string)"/> for the Command Palette, and raises
/// <see cref="CommandPaletteRequested"/> for the header button + the global hotkey.
/// </summary>
public sealed partial class AppShell : UserControl
{
    private string? _currentKey;
    private ThemeService? _theme;
    private bool _appearanceBound;

    public AppShell()
    {
        InitializeComponent();
        BuildDestinations();
        SelectDefault();
    }

    /// <summary>Raised when the user asks for the Command Palette (header button or Ctrl+K).</summary>
    public event EventHandler? CommandPaletteRequested;

    /// <summary>
    /// Provide the shell theme service. The Appearance picker binds lazily on first flyout open
    /// (the flyout's content is realized then), which avoids any construction-order surprises.
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

        // Reflect the selection in the sidebar; SelectionChanged performs the frame navigation.
        var item = FindItem(key);
        if (item is not null)
        {
            if (ReferenceEquals(Nav.SelectedItem, item))
            {
                // Already selected (SelectionChanged won't re-fire): drive the frame directly.
                NavigateFrame(destination);
            }
            else
            {
                Nav.SelectedItem = item;
            }
        }
        else
        {
            // Auxiliary (non-sidebar) destination — e.g. Elder Wand. Clear any stale sidebar
            // highlight so the next sidebar click always re-navigates, then drive the frame.
            Nav.SelectedItem = null;
            NavigateFrame(destination);
        }
    }

    private void BuildDestinations()
    {
        foreach (var destination in NavCatalog.Menu)
        {
            Nav.MenuItems.Add(CreateItem(destination));
        }

        foreach (var destination in NavCatalog.Footer)
        {
            Nav.FooterMenuItems.Add(CreateItem(destination));
        }
    }

    private static NavigationViewItem CreateItem(NavDestination destination) => new()
    {
        Content = destination.Title,
        Tag = destination.Key,
        Icon = new FontIcon
        {
            FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Segoe MDL2 Assets"),
            Glyph = destination.Glyph,
        },
    };

    private void SelectDefault()
    {
        var first = FindItem(NavCatalog.Default.Key);
        if (first is not null)
        {
            Nav.SelectedItem = first;
        }

        // Guarantee initial content even if SelectionChanged is deferred until load.
        NavigateFrame(NavCatalog.Default);
    }

    private NavigationViewItem? FindItem(string key)
    {
        foreach (var item in Nav.MenuItems)
        {
            if (item is NavigationViewItem nvi && (string?)nvi.Tag == key)
            {
                return nvi;
            }
        }

        foreach (var item in Nav.FooterMenuItems)
        {
            if (item is NavigationViewItem nvi && (string?)nvi.Tag == key)
            {
                return nvi;
            }
        }

        return null;
    }

    private void Nav_SelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (args.SelectedItem is NavigationViewItem { Tag: string key })
        {
            var destination = NavCatalog.Find(key);
            if (destination is not null)
            {
                NavigateFrame(destination);
            }
        }
    }

    private void NavigateFrame(NavDestination destination)
    {
        // Dedupe: selection-in-constructor + SelectionChanged-on-load can both fire.
        if (_currentKey == destination.Key)
        {
            return;
        }

        Type pageType = SurfacePageResolver.Resolve(destination.Key);
        AppDiagnostics.RouteBegin(destination.Key, pageType);
        try
        {
            _currentKey = destination.Key;
            HeaderTitle.Text = destination.Title;
            ContentFrame.Navigate(pageType, destination);
            AppDiagnostics.RouteSuccess(destination.Key, pageType);
        }
        catch (Exception ex)
        {
            AppDiagnostics.RouteFailure(destination.Key, pageType, ex);
            throw;
        }
    }

    private void Palette_Click(object sender, Microsoft.UI.Xaml.RoutedEventArgs e)
        => CommandPaletteRequested?.Invoke(this, EventArgs.Empty);
}
