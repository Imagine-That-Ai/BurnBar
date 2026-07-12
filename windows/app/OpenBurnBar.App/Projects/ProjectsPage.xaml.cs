using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using OpenBurnBar.App.Presentation.Projects;
using OpenBurnBar.App.Presentation.SessionLogs;
using OpenBurnBar.App.Storage;

namespace OpenBurnBar.App.Projects;

/// <summary>
/// Projects nav destination (IA-4 list-level). Groups sessions by project name;
/// discloses WPD-0003 static-parse deferral.
/// </summary>
public sealed partial class ProjectsPage : Page
{
    public ProjectsPage()
    {
        InitializeComponent();
    }

    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);

        ISessionLogReadSource source = WindowsStorageDevHost.CreateSessionLogReadSource();
        var viewModel = new ProjectsListViewModel(source);
        await viewModel.LoadAsync();
        StatusText.Text = viewModel.Status;
        DepthText.Text = viewModel.DepthDisclosure;
        ProjectList.ItemsSource = viewModel.Projects;
    }
}
