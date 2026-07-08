// Code-behind for General. Registers the General-tab anchored rows, consumes the
// router's pending anchor on Loaded, and drills into the Appearance subpage when its
// card is clicked (the same content Frame, carrying the shared context).

using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using OpenBurnBar.App.Settings;

namespace OpenBurnBar.App.Settings.Winui;

public sealed partial class GeneralSettingsPage : Page, ISettingsAnchorTarget
{
    private readonly SettingsAnchorScroller _scroller = new();
    private SettingsPageContext? _context;

    public GeneralSettingsPage()
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
        _scroller.RegisterAnchor(SettingsAnchor.OperatorWizard, OperatorCard);
        _scroller.RegisterAnchor(SettingsAnchor.DefaultsTimeRange, TimeRangeCard);
        _scroller.RegisterAnchor(SettingsAnchor.DefaultsUsageMode, UsageModeCard);
        _scroller.RegisterAnchor(SettingsAnchor.RefreshInterval, RefreshCard);
        _scroller.RegisterAnchor(SettingsAnchor.IndexingToggle, IndexingCard);
        _scroller.RegisterAnchor(SettingsAnchor.SummariesAuto, SummariesCard);
        SettingsLeafPageSupport.ConsumePending(_context?.Router, _scroller);
    }

    public void ScrollToAnchor(string anchorId, string? focusId) => _scroller.ScrollTo(anchorId, focusId);

    private void Appearance_Click(object sender, RoutedEventArgs e)
    {
        // Drill into the Appearance subpage in the same content Frame.
        Frame?.Navigate(typeof(AppearanceSettingsPage), _context);
    }
}
