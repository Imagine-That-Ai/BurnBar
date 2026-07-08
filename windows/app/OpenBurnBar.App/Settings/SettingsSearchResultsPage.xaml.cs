// Code-behind for the search results detail. Rebinds ranked matches live as the
// shared router's Query changes (the shell owns the search box), and forwards a chosen
// row to the shell's routing callback. Mirrors SettingsSearchResultsView.swift, which
// re-runs SettingsSearchEngine.search on every query change and calls
// SettingsRouter.navigate(to:) on tap.

using System.Collections.ObjectModel;
using System.ComponentModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using OpenBurnBar.App.Settings;

namespace OpenBurnBar.App.Settings.Winui;

public sealed partial class SettingsSearchResultsPage : Page
{
    private SettingsPageContext? _context;

    public SettingsSearchResultsPage()
    {
        InitializeComponent();
    }

    /// <summary>Ranked matches for the current query, bound by the results ListView.</summary>
    public ObservableCollection<SettingsSearchResultViewModel> Results { get; } = new();

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        _context = e.Parameter as SettingsPageContext;
        if (_context is not null)
        {
            _context.Router.PropertyChanged += Router_PropertyChanged;
        }
        Rebuild();
    }

    protected override void OnNavigatedFrom(NavigationEventArgs e)
    {
        base.OnNavigatedFrom(e);
        if (_context is not null)
        {
            _context.Router.PropertyChanged -= Router_PropertyChanged;
        }
    }

    private void Router_PropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(SettingsRouter.Query))
        {
            Rebuild();
        }
    }

    private void Rebuild()
    {
        Results.Clear();

        var router = _context?.Router;
        var query = router?.Query ?? string.Empty;
        var matches = SettingsSearchEngine.Search(query, SettingsManifest.All);
        foreach (var item in matches)
        {
            Results.Add(new SettingsSearchResultViewModel(item));
        }

        var empty = matches.Count == 0;
        EmptyState.Visibility = empty ? Visibility.Visible : Visibility.Collapsed;
        ResultsList.Visibility = empty ? Visibility.Collapsed : Visibility.Visible;
        CountLabel.Text = matches.Count == 1 ? "1 result" : $"{matches.Count} results";
        EmptyLabel.Text = $"No settings match “{query}”";
    }

    private void ResultsList_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is SettingsSearchResultViewModel vm)
        {
            _context?.OnResultChosen?.Invoke(vm.Item);
        }
    }

    private void BrowseAll_Click(object sender, RoutedEventArgs e)
    {
        // "Browse all" clears the search and lands on the Settings Home overview.
        if (SettingsDeepLink.Item("home.overview") is { } home)
        {
            _context?.OnResultChosen?.Invoke(home);
        }
    }
}
