using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using OpenBurnBar.App.CloudSync;

namespace OpenBurnBar.App.DataControlCenter;

/// <summary>
/// The AppShell content page hosting the <see cref="DataControlCenterView"/> governance workbench.
/// The view self-loads its registry-seeded inventory; a real Firebase-backed view-model (with the
/// export window-handle provider) is injected on the dev host per the callable-hub seam.
/// </summary>
public sealed partial class DataControlCenterPage : Page
{
    public DataControlCenterPage()
    {
        InitializeComponent();
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        Workbench.SetViewModel(WinAppCloudSyncHost.CreateDataControlViewModel());
    }

    /// <summary>The hosted workbench, exposed so a host can inject a real hub-backed view-model.</summary>
    public DataControlCenterView Surface => Workbench;
}
