using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using OpenBurnBar.App.Cli;
using OpenBurnBar.App.Views;

namespace OpenBurnBar.App.Shell;

/// <summary>
/// The placeholder page every stubbed NavigationView destination navigates to. It renders the
/// destination's glyph/title/subtitle and, for Session Logs, hosts the live CLI stream so the
/// frame is proven to host real controls. Real surfaces replace this per-key over Phase 3.
/// </summary>
public sealed partial class SurfaceStubPage : Page
{
    private LiveCliStreamView? _liveView;

    public SurfaceStubPage()
    {
        InitializeComponent();
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);

        var destination = e.Parameter as NavDestination ?? NavCatalog.Default;

        Glyph.Glyph = destination.Glyph;
        TitleText.Text = destination.Title;
        SubtitleText.Text = destination.Subtitle;

        // Session Logs previews the live stream (the spike's original demo content).
        if (destination.Key == "sessionLogs")
        {
            PlaceholderCard.Visibility = Visibility.Collapsed;
            LiveHost.Visibility = Visibility.Visible;

            _liveView = new LiveCliStreamView();
            LiveHost.Child = _liveView;
            _liveView.Attach(CliStreamFactory.CreateDefault(), autoStart: true);
        }
    }

    protected override void OnNavigatedFrom(NavigationEventArgs e)
    {
        base.OnNavigatedFrom(e);

        // Stop the stream and release the host when navigating away.
        _liveView?.Detach();
        _liveView = null;
        LiveHost.Child = null;
    }
}
