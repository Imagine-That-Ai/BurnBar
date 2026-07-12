using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using OpenBurnBar.App.Presentation.Database;
using OpenBurnBar.App.Presentation.SessionLogs;
using OpenBurnBar.App.Storage;

namespace OpenBurnBar.App.Database;

/// <summary>
/// Database nav destination (IA-2 System mode). Lists tracked sessions from the
/// SQLCipher session-log seam; empty when unconfigured.
/// </summary>
public sealed partial class DatabasePage : Page
{
    public DatabasePage()
    {
        InitializeComponent();
    }

    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);

        ISessionLogReadSource source = WindowsStorageDevHost.CreateSessionLogReadSource();
        var viewModel = new DatabaseBrowseViewModel(source);
        await viewModel.LoadAsync();
        StatusText.Text = viewModel.Status;
        SessionList.ItemsSource = viewModel.Sessions;
    }
}
