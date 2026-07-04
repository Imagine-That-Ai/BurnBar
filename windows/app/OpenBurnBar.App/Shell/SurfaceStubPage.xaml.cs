using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;

namespace OpenBurnBar.App.Shell;

/// <summary>
/// Fallback placeholder when <see cref="SurfacePageResolver"/> has no registered Page for a key.
/// All <see cref="NavCatalog"/> sidebar destinations and <see cref="NavCatalog.Auxiliary"/> palette
/// surfaces are registered; this page is not used for in-scope nav today.
/// </summary>
public sealed partial class SurfaceStubPage : Page
{
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

        PlaceholderCard.Visibility = Visibility.Visible;
        LiveHost.Visibility = Visibility.Collapsed;
    }
}