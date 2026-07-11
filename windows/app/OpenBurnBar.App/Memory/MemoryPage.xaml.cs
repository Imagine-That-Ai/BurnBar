using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using OpenBurnBar.App.CloudSync;
using OpenBurnBar.App.Presentation.Memories;

namespace OpenBurnBar.App.Memory;

/// <summary>
/// Nav destination for memory review. Injects <see cref="CloudSyncMemoryStore"/> when
/// <see cref="WinAppCloudSyncHost"/> is configured; otherwise shows an empty inbox shell.
/// </summary>
public sealed partial class MemoryPage : Page
{
    public MemoryPage()
    {
        InitializeComponent();
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        MemoryReviewInboxModel? model = WinAppCloudSyncHost.CreateMemoryInboxModel();
        if (model is not null)
        {
            Inbox.SetModel(model);
            _ = Inbox.LoadAsync();
        }
    }
}