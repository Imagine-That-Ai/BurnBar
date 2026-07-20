// Code-behind for the Settings shell. Builds the sidebar from the portable
// SettingsTabMetadata (labels + section order in lock-step with the manifest), drives
// search through the shared SettingsRouter, and — on a chosen result or an incoming
// deep link — selects the owning tab, navigates the content Frame to the leaf page,
// and lets that page consume the router's pending anchor (the WinUI realization of
// SettingsView.swift's sidebar + detail NavigationStack + `.searchable`).

using System;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using OpenBurnBar.App.Settings;

namespace OpenBurnBar.App.Settings.Winui;

public sealed partial class SettingsPage : Page
{
    private readonly SettingsRouter _router = new();
    private bool _suppressNavSelection;
    private NavigationViewItem? _homeItem;

    /// <summary>
    /// Injected HWND resolver (the <c>Func&lt;IntPtr&gt;</c> pattern from
    /// <c>DataControlCenterView.WindowHandleProvider</c>). The host window sets this so
    /// it can be threaded into <see cref="SettingsPageContext"/> for leaf pages that
    /// open file pickers (e.g. <see cref="DataSourceSettingsPage"/>).
    /// </summary>
    public Func<IntPtr>? WindowHandleProvider { get; set; }

    public SettingsPage()
    {
        InitializeComponent();
        BuildNavItems();
        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        SettingsDeepLink.OpenSettingsItemRequested += OnOpenSettingsItem;
        if (Nav.SelectedItem is null && _homeItem is not null)
        {
            Nav.SelectedItem = _homeItem; // fires SelectionChanged → lands on Home
        }
    }

    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        SettingsDeepLink.OpenSettingsItemRequested -= OnOpenSettingsItem;
    }

    // ── Sidebar construction ──────────────────────────────────────────────────

    private void BuildNavItems()
    {
        _homeItem = MakeNavItem(SettingsTab.Home);
        Nav.MenuItems.Add(_homeItem);

        foreach (var section in SettingsSectionMetadata.VisibleSections)
        {
            Nav.MenuItems.Add(new NavigationViewItemHeader { Content = SettingsSectionMetadata.Title(section) });
            foreach (var tab in SettingsSectionMetadata.Tabs(section))
            {
                Nav.MenuItems.Add(MakeNavItem(tab));
            }
        }
    }

    private static NavigationViewItem MakeNavItem(SettingsTab tab) => new()
    {
        Content = SettingsTabMetadata.Title(tab),
        Tag = tab,
        Icon = new FontIcon
        {
            Glyph = SettingsTabVisuals.Glyph(tab),
            Foreground = SettingsTabVisuals.AccentBrush(tab),
        },
    };

    // ── Sidebar selection ─────────────────────────────────────────────────────

    private void Nav_SelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (_suppressNavSelection)
        {
            _suppressNavSelection = false;
            return;
        }

        if (args.SelectedItem is NavigationViewItem { Tag: SettingsTab tab })
        {
            NavigateToTab(tab);
        }
    }

    private void NavigateToTab(SettingsTab tab)
    {
        _router.SelectedTab = tab;
        ContentFrame.Navigate(PageTypeForTab(tab), new SettingsPageContext(_router, tab, windowHandleProvider: WindowHandleProvider));
    }

    private void SelectNavItem(SettingsTab tab)
    {
        foreach (var entry in Nav.MenuItems)
        {
            if (entry is NavigationViewItem { Tag: SettingsTab candidate } item && candidate == tab)
            {
                _suppressNavSelection = true;
                Nav.SelectedItem = item;
                return;
            }
        }
    }

    // ── Search ────────────────────────────────────────────────────────────────

    private void SearchBox_TextChanged(AutoSuggestBox sender, AutoSuggestBoxTextChangedEventArgs args)
    {
        if (args.Reason != AutoSuggestionBoxTextChangeReason.UserInput)
        {
            return; // ignore programmatic clears (e.g. after a result is chosen)
        }

        _router.Query = sender.Text;

        if (_router.IsSearching)
        {
            if (ContentFrame.CurrentSourcePageType != typeof(SettingsSearchResultsPage))
            {
                ContentFrame.Navigate(
                    typeof(SettingsSearchResultsPage),
                    new SettingsPageContext(_router, _router.SelectedTab ?? SettingsTab.Home, NavigateForItem, windowHandleProvider: WindowHandleProvider));
            }
        }
        else
        {
            NavigateToTab(_router.SelectedTab ?? SettingsTab.Home);
        }
    }

    // ── Routing to a specific item (chosen result or deep link) ────────────────

    private void NavigateForItem(SettingsItem item)
    {
        _router.Navigate(item);      // primes SelectedTab / PendingAnchor / PendingFocus / Path
        SearchBox.Text = string.Empty; // reflect the cleared query (ignored by TextChanged guard)
        SelectNavItem(item.Tab);
        ContentFrame.Navigate(
            PageTypeForRoute(item.PageRoute, item.Tab),
            new SettingsPageContext(_router, item.Tab, windowHandleProvider: WindowHandleProvider));
    }

    private void OnOpenSettingsItem(string itemId)
    {
        if (SettingsDeepLink.Item(itemId) is { } item)
        {
            NavigateForItem(item);
        }
    }

    // ── Page selection ────────────────────────────────────────────────────────

    private static Type PageTypeForTab(SettingsTab tab) => tab switch
    {
        SettingsTab.General => typeof(GeneralSettingsPage),
        SettingsTab.Updates => typeof(UpdatesSettingsPage),
        SettingsTab.DataPrivacy => typeof(DataSourceSettingsPage),
        // Every catalog ViewModel tab gets a real host page (no empty-leaf fallthrough).
        SettingsTab.Daemon or SettingsTab.Agents or SettingsTab.ModelProxy or SettingsTab.Alerts
            or SettingsTab.Notifications or SettingsTab.TextExpansion or SettingsTab.ComputerUse
            or SettingsTab.Pets or SettingsTab.Account or SettingsTab.Cloud
            or SettingsTab.DevicesAndSync or SettingsTab.Media
            => typeof(SettingsViewModelHostPage),
        SettingsTab.Home => typeof(GeneralSettingsPage),
        _ => typeof(SettingsViewModelHostPage),
    };

    private static Type PageTypeForRoute(SettingsPageRoute route, SettingsTab tab) => route switch
    {
        SettingsPageRoute.Appearance => typeof(AppearanceSettingsPage),
        SettingsPageRoute.UpdatesRoot => typeof(UpdatesSettingsPage),
        SettingsPageRoute.GeneralRoot or SettingsPageRoute.OperatorModel or SettingsPageRoute.DefaultView
            or SettingsPageRoute.DataRefresh or SettingsPageRoute.Indexing
            or SettingsPageRoute.SessionSummaries => typeof(GeneralSettingsPage),
        _ => PageTypeForTab(tab),
    };
}
