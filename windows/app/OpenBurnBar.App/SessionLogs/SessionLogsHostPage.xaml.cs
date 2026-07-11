using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using OpenBurnBar.App.Presentation.SessionLogs;
using OpenBurnBar.App.Storage;

namespace OpenBurnBar.App.SessionLogs;

/// <summary>
/// Session Logs destination: SQLCipher-backed list-detail when credentials are set;
/// otherwise an empty list. Live CLI assistant stream remains on B1 ConPTY (was stub on SurfaceStubPage).
/// </summary>
public sealed partial class SessionLogsHostPage : Page
{
    public SessionLogsHostPage()
    {
        InitializeComponent();
    }

    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);

        ISessionLogReadSource source = WindowsStorageDevHost.CreateSessionLogReadSource();
        var viewModel = new SessionLogsViewModel(source);
        LogsView.SetModel(viewModel);
        await LogsView.LoadAsync();
    }
}