// Code-behind for the not-yet-ported tab placeholder. Fills the title/subtitle from the
// portable SettingsTabMetadata for whichever tab the shell navigated to.

using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using OpenBurnBar.App.Settings;

namespace OpenBurnBar.App.Settings.Winui;

public sealed partial class SettingsPlaceholderPage : Page
{
    public SettingsPlaceholderPage()
    {
        InitializeComponent();
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        var tab = (e.Parameter as SettingsPageContext)?.Tab ?? SettingsTab.Home;
        TitleLabel.Text = SettingsTabMetadata.Title(tab);
        SubtitleLabel.Text = SettingsTabMetadata.Subtitle(tab);
    }
}
