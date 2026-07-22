using System;
using System.Collections.Generic;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using OpenBurnBar.App.Diagnostics;
using OpenBurnBar.App.SessionLogs;
using OpenBurnBar.App.Theme;
using OpenBurnBar.App.UsageRuntime;

namespace OpenBurnBar.App.Shell;

/// <summary>
/// App frame chrome matching the Linux TopChrome (apps/linux-desktop/src/components/TopChrome.tsx):
/// command deck (brand + omnibar + kernel + hero + appearance + overflow) over the 7-tab
/// glass pill strip (chat/providers/database/projects/missions/activity/memory), content below.
/// Dashboard owns the Command sidebar (not a permanent destination rail).
/// </summary>
public sealed partial class AppShell : UserControl
{
    /// <summary>The Linux TopTabbar tab set (labels mirror src/topTabMeta.ts), mapped to NavCatalog keys.</summary>
    private static readonly (string Key, string Label)[] TopTabs =
    {
        ("chat", "Chat"),
        ("dashboard", "Providers"),
        ("database", "Database"),
        ("projects", "Projects"),
        ("missionControl", "Missions"),
        ("sessionLogs", "Activity"),
        ("memory", "Memory"),
    };

    private readonly List<Button> _tabButtons = new();
    private readonly List<TextBlock> _tabLabels = new();
    private string? _currentKey;
    private ThemeService? _theme;
    private bool _appearanceBound;

    public AppShell()
    {
        InitializeComponent();
        BuildTopTabs();
        BuildOverflowMenu();
        NavigateFrame(NavCatalog.Default);
        ApplyResponsiveLayout(ShellResponsiveLayout.ForWidth(ActualWidth));
    }

    /// <summary>Raised when the user asks for the Command Palette (header button or Ctrl+K).</summary>
    public event EventHandler? CommandPaletteRequested;

    /// <summary>
    /// Provide the shell theme service. The Appearance picker binds lazily on first flyout open.
    /// </summary>
    public void BindTheme(ThemeService theme) => _theme = theme;

    /// <summary>Connects the header telemetry capsule to the live usage runtime.</summary>
    public void BindUsageRuntime(IUsageRuntime? runtime) => BurnHero.Bind(runtime);

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
    public void Navigate(string key, string? sessionId = null)
    {
        var destination = NavCatalog.Find(key);
        if (destination is null)
        {
            return;
        }

        NavigateFrame(destination, sessionId);
    }

    private void BuildTopTabs()
    {
        Style normal = (Style)Application.Current.Resources["AuroraGlassTabStyle"];
        TopTabsHost.ColumnDefinitions.Clear();
        TopTabsHost.Children.Clear();
        _tabButtons.Clear();
        _tabLabels.Clear();

        for (int i = 0; i < TopTabs.Length; i++)
        {
            (string key, string label) = TopTabs[i];
            TopTabsHost.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

            var destination = NavCatalog.Find(key);
            var tabLabel = new TextBlock
            {
                Text = label,
                FontSize = 12,
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            };
            var button = new Button
            {
                Tag = key,
                Style = normal,
                HorizontalAlignment = HorizontalAlignment.Stretch,
                HorizontalContentAlignment = HorizontalAlignment.Center,
                Content = new StackPanel
                {
                    Orientation = Orientation.Horizontal,
                    Spacing = 6,
                    Children =
                    {
                        new FontIcon
                        {
                            FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Segoe MDL2 Assets"),
                            Glyph = destination?.Glyph ?? "\uE80F",
                            FontSize = 12,
                        },
                        tabLabel,
                    },
                },
            };
            AutomationProperties.SetAutomationId(button, $"Shell.Tab.{key}");
            AutomationProperties.SetName(button, label);
            ToolTipService.SetToolTip(button, destination is null ? label : $"{label} — {destination.Subtitle}");
            button.Click += (_, _) => Navigate(key);
            Grid.SetColumn(button, i);
            TopTabsHost.Children.Add(button);
            _tabButtons.Add(button);
            _tabLabels.Add(tabLabel);
        }

        ApplyTabSelection(NavCatalog.Default.Key);
    }

    private void OnShellSizeChanged(object sender, SizeChangedEventArgs e) =>
        ApplyResponsiveLayout(ShellResponsiveLayout.ForWidth(e.NewSize.Width));

    private void ApplyResponsiveLayout(ShellResponsiveLayout layout)
    {
        BrandWordmark.Visibility = layout.ShowBrandWordmark ? Visibility.Visible : Visibility.Collapsed;
        PaletteLabel.Visibility = layout.ShowPaletteLabel ? Visibility.Visible : Visibility.Collapsed;
        PaletteShortcut.Visibility = layout.ShowPaletteShortcut ? Visibility.Visible : Visibility.Collapsed;
        PaletteButton.MinWidth = layout.ShowPaletteLabel ? 220 : 38;
        PaletteButton.MaxWidth = layout.ShowPaletteLabel ? 400 : 38;
        PaletteButton.Width = layout.ShowPaletteLabel ? double.NaN : 38;

        foreach (TextBlock label in _tabLabels)
        {
            label.Visibility = layout.ShowTabLabels ? Visibility.Visible : Visibility.Collapsed;
        }
    }

    private void ApplyTabSelection(string activeKey)
    {
        Style normal = (Style)Application.Current.Resources["AuroraGlassTabStyle"];
        Style selected = (Style)Application.Current.Resources["AuroraGlassTabSelectedStyle"];
        foreach (Button tab in _tabButtons)
        {
            tab.Style = (string?)tab.Tag == activeKey ? selected : normal;
        }
    }

    private void BuildOverflowMenu()
    {
        OverflowMenu.Items.Clear();

        // The tab strip owns the 7 primary destinations; everything else lives here:
        // remaining catalog entries (insights/quota/budget/dataControlCenter/switcher/
        // onboarding), footer (settings), and palette-only auxiliaries (elderWand).
        var tabKeys = new System.Collections.Generic.HashSet<string>(
            System.Linq.Enumerable.Select(TopTabs, t => t.Key));
        foreach (var destination in NavCatalog.Menu)
        {
            if (!tabKeys.Contains(destination.Key))
            {
                OverflowMenu.Items.Add(CreateMenuItem(destination));
            }
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

    private void NavigateFrame(NavDestination destination, string? sessionId = null)
    {
        // Dedupe: selection-in-constructor + palette re-entry can both fire.
        if (_currentKey == destination.Key && string.IsNullOrWhiteSpace(sessionId))
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
            object parameter = destination;
            if (destination.Key == "sessionLogs" && !string.IsNullOrWhiteSpace(sessionId))
            {
                parameter = new SessionLogsNavigationRequest(sessionId);
            }

            ContentFrame.Navigate(pageType, parameter);
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
        // Linux TopTabbar: selected tab follows the active destination; destinations
        // outside the tab set (overflow/palette) leave all tabs unselected.
        ApplyTabSelection(destination.Key);
    }

    private void Palette_Click(object sender, RoutedEventArgs e)
        => CommandPaletteRequested?.Invoke(this, EventArgs.Empty);

    private void Brand_Click(object sender, RoutedEventArgs e) => Navigate(NavCatalog.Default.Key);
}
