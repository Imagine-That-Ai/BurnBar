using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;

namespace OpenBurnBar.App.Shell;

/// <summary>
/// Fallback placeholder when <see cref="SurfacePageResolver"/> has no registered Page for a key,
/// and the explicit deferred-disclosure host for IA-1 <c>database</c> / <c>projects</c> routes
/// until depth pages land. Shows the destination title/subtitle honestly — never a fake Real surface.
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
    }
}