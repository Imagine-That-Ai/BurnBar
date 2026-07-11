using System;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OpenBurnBar.App.Configuration;
using OpenBurnBar.App.Presentation.ElderWand;
using OpenBurnBar.App.Storage;

namespace OpenBurnBar.App.ElderWand;

/// <summary>
/// Nav-frame host for <see cref="ElderWandConfiguratorView"/>. Registered as the "elderWand"
/// destination in <see cref="OpenBurnBar.App.Shell.SurfacePageResolver"/> and reachable via the
/// Command Palette (NavCatalog.Auxiliary) — deliberately NOT a sidebar row, matching the macOS
/// gated Settings-leaf / chat-header reachability. Presets persist through the configured store;
/// provider-group demo data is shown only when <c>OPENBURNBAR_SAMPLE_MODE=1</c>.
/// </summary>
public sealed partial class ElderWandPage : Page
{
    public ElderWandPage()
    {
        InitializeComponent();
        Loaded += OnLoaded;
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        Loaded -= OnLoaded;

        ConfiguratorView.Configure(
            new ElderWandSettingsModel(WindowsStorageDevHost.CreateElderWandPersistence()),
            RuntimeDataMode.SampleModeEnabled ? ElderWandSampleData.DevHostGroups() : Array.Empty<ElderWandProviderGroup>());
    }
}
