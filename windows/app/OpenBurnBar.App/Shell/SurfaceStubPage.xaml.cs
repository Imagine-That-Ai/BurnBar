using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;

namespace OpenBurnBar.App.Shell;

/// <summary>
/// Fallback when <see cref="SurfacePageResolver"/> has no product page for a key,
/// and the intentional deferred-disclosure host for IA-1 <c>database</c> / <c>projects</c>
/// until depth pages land. Never pretends to be a Real parity surface.
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

        bool ia1 = SurfaceRouteMap.IsIa1DeferredDisclosure(destination.Key);
        if (ia1)
        {
            StatusPillText.Text = "Coming soon · depth deferred (IA-1)";
            NextStepText.Text = destination.Key switch
            {
                "database" =>
                    "Session browsing will live here. Until then use Session Logs for indexed conversations, and keep this route as a honest macOS primary-section peer.",
                "projects" =>
                    "Project grouping will live here. Until then track work by provider and model on Dashboard — full project-code depth needs a later phase (WPD-0003).",
                _ =>
                    "This macOS primary route is registered but not depth-ported yet. Nothing is fabricated on this page.",
            };
        }
        else
        {
            StatusPillText.Text = "Unknown destination";
            NextStepText.Text =
                "This key is not a registered product surface. Use the sidebar or Command Palette to open a known destination.";
        }

        PlaceholderCard.Visibility = Visibility.Visible;
    }
}
