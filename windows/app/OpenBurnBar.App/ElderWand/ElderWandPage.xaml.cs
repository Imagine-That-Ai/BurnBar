using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OpenBurnBar.App.Presentation.ElderWand;
using OpenBurnBar.App.Storage;

namespace OpenBurnBar.App.ElderWand;

/// <summary>
/// Nav-frame host for <see cref="ElderWandConfiguratorView"/>. Registered as the "elderWand"
/// destination in <see cref="OpenBurnBar.App.Shell.SurfacePageResolver"/> and reachable via the
/// Command Palette (NavCatalog.Auxiliary) — deliberately NOT a sidebar row, matching the macOS
/// gated Settings-leaf / chat-header reachability. Seeds the configurator from the portable,
/// unit-tested <see cref="ElderWandSampleData"/> (preset store + grouped live-model catalog) so the
/// surface shows its full live form before the real advertised-model stream + settings store wire in.
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
            ElderWandSampleData.DevHostGroups());
    }
}
