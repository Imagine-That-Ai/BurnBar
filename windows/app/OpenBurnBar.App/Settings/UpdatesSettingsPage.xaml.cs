// Code-behind for Updates. Registers the three anchored rows and consumes the router's
// pending anchor on Loaded (search deep-link → scroll + pulse).

using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using OpenBurnBar.App.Settings;

namespace OpenBurnBar.App.Settings.Winui;

public sealed partial class UpdatesSettingsPage : Page, ISettingsAnchorTarget
{
    private readonly SettingsAnchorScroller _scroller = new();
    private SettingsPageContext? _context;

    public UpdatesSettingsPage()
    {
        InitializeComponent();
        Loaded += OnLoaded;
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        _context = e.Parameter as SettingsPageContext;
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        _scroller.RegisterAnchor(SettingsAnchor.UpdatesOverview, OverviewCard);
        _scroller.RegisterAnchor(SettingsAnchor.UpdatesAutomaticChecks, AutomaticChecksCard);
        _scroller.RegisterAnchor(SettingsAnchor.UpdatesReleaseNotes, ReleaseNotesCard);
        SettingsLeafPageSupport.ConsumePending(_context?.Router, _scroller);
    }

    public void ScrollToAnchor(string anchorId, string? focusId) => _scroller.ScrollTo(anchorId, focusId);
}
