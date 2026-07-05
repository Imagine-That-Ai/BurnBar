using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OpenBurnBar.App.Presentation.SessionLogs;
using OpenBurnBar.App.Storage;

namespace OpenBurnBar.App.SessionLogs;

/// <summary>
/// Nav-frame host for <see cref="SessionLogsView"/>. Registered as the "sessionLogs"
/// destination in <see cref="OpenBurnBar.App.Shell.SurfacePageResolver"/>.
/// </summary>
public sealed partial class SessionLogsPage : Page
{
    public SessionLogsPage()
    {
        InitializeComponent();
        Loaded += OnLoaded;
    }

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        Loaded -= OnLoaded;

        var viewModel = new SessionLogsViewModel(WindowsStorageDevHost.CreateSessionLogReadSource());
        LogsView.SetModel(viewModel);
        await LogsView.LoadAsync();
    }

}