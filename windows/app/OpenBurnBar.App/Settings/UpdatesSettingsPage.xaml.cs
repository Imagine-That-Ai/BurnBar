// Code-behind for Updates. Registers the three anchored rows and consumes the router's
// pending anchor on Loaded (search deep-link → scroll + pulse).

using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using OpenBurnBar.App.Diagnostics;
using OpenBurnBar.App.Settings;

namespace OpenBurnBar.App.Settings.Winui;

public sealed partial class UpdatesSettingsPage : Page, ISettingsAnchorTarget
{
    private readonly SettingsAnchorScroller _scroller = new();
    private readonly WindowsSettingsPersistence _persistence = WindowsSettingsComposition.SharedPersistence;
    private SettingsPageContext? _context;
    private bool _refreshing;

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
        _scroller.RegisterAnchor("updates.status", UpdaterStatusCard);
        _scroller.RegisterAnchor("updates.startup", StartupCard);
        RefreshUpdateStatus();
        _ = RefreshStartupStatusAsync();
        SettingsLeafPageSupport.ConsumePending(_context?.Router, _scroller);
    }

    public void ScrollToAnchor(string anchorId, string? focusId) => _scroller.ScrollTo(anchorId, focusId);

    private void RefreshUpdateStatus(string? overrideMessage = null)
    {
        _refreshing = true;
        try
        {
            WindowsUpdateStatus status = WindowsUpdateService.GetStatus(_persistence);
            VersionText.Text = status.Version;
            ChannelText.Text = status.Channel;
            AutomaticChecksToggle.IsOn = status.AutomaticChecksEnabled;
            AutomaticChecksToggle.IsEnabled = status.AutomaticChecksAvailable;
            UpdaterStatusText.Text = overrideMessage ?? status.Message;
            AppcastText.Text = status.ManagedByStore
                ? "Updates are delivered and signed by Microsoft Store."
                : $"{status.AppcastUrl} | pin={(status.ProductionPinInjected ? "production" : "development")} | native={(status.NativeHostAvailable ? "available" : "unavailable")}";
            CheckNowButton.Content = status.ManagedByStore ? "Open Store Updates" : "Check Now";
            CheckNowButton.IsEnabled = status.CheckActionAvailable;
        }
        finally
        {
            _refreshing = false;
        }
    }

    private async System.Threading.Tasks.Task RefreshStartupStatusAsync()
    {
        WindowsStartupStatus status = await WindowsStartupService.GetStatusAsync();
        _refreshing = true;
        try
        {
            StartupToggle.IsOn = status.IsEnabled;
            StartupToggle.IsEnabled = status.CanChange;
            StartupStatusText.Text = status.Message;
        }
        finally
        {
            _refreshing = false;
        }
    }

    private void AutomaticChecksToggle_Toggled(object sender, RoutedEventArgs e)
    {
        if (_refreshing) return;
        WindowsUpdateService.SetAutomaticChecks(_persistence, AutomaticChecksToggle.IsOn);
        WindowsUpdateStatus status = WindowsUpdateService.Configure(_persistence);
        RefreshUpdateStatus(status.Message);
    }

    private async void CheckNowButton_Click(object sender, RoutedEventArgs e)
    {
        CheckNowButton.IsEnabled = false;
        try
        {
            string message = await WindowsUpdateService.CheckWithUiAsync(_persistence);
            RefreshUpdateStatus(message);
        }
        catch (System.Exception ex)
        {
            AppDiagnostics.LogException("settings.updates.check", ex);
            RefreshUpdateStatus(ex.Message);
        }
    }

    private void ReleaseNotesButton_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            WindowsUpdateService.OpenReleaseNotes();
        }
        catch (System.Exception ex)
        {
            AppDiagnostics.LogException("settings.updates.release-notes", ex);
            RefreshUpdateStatus(ex.Message);
        }
    }

    private async void StartupToggle_Toggled(object sender, RoutedEventArgs e)
    {
        if (_refreshing) return;
        StartupToggle.IsEnabled = false;
        WindowsStartupStatus status = await WindowsStartupService.SetEnabledAsync(StartupToggle.IsOn);
        _refreshing = true;
        try
        {
            StartupToggle.IsOn = status.IsEnabled;
            StartupToggle.IsEnabled = status.CanChange;
            StartupStatusText.Text = status.Message;
        }
        finally
        {
            _refreshing = false;
        }
    }
}
