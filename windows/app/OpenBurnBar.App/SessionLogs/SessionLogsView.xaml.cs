using System.Threading.Tasks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OpenBurnBar.App.Presentation.SessionLogs;

namespace OpenBurnBar.App.SessionLogs;

/// <summary>
/// The session-logs list-detail surface (Windows). Hosts a grouped command-center list
/// and the <see cref="SessionLogDetailPane"/>, bound to the portable
/// <see cref="SessionLogsViewModel"/> (unit-tested on macOS). Designed to be shown as a
/// destination inside the AppShell NavigationView. Callers assign <see cref="ViewModel"/>
/// via <see cref="SetModel"/> then <see cref="LoadAsync"/> (analog of the SwiftUI
/// <c>.task { await initializeSessionLogs() }</c>).
/// </summary>
public sealed partial class SessionLogsView : UserControl
{
    public SessionLogsView()
    {
        InitializeComponent();
    }

    public SessionLogsViewModel? ViewModel { get; private set; }

    /// <summary>Bind a view-model, wire the grouped collection source, and refresh bindings.</summary>
    public void SetModel(SessionLogsViewModel viewModel)
    {
        ViewModel = viewModel;
        GroupedLogs.Source = viewModel.Groups;
        LogsList.ItemsSource = GroupedLogs.View;
        Bindings.Update();
    }

    /// <summary>Load the local log set. No-op until a model is bound.</summary>
    public Task LoadAsync() => ViewModel?.LoadAsync() ?? Task.CompletedTask;

    private async void OnSearchTextChanged(object sender, TextChangedEventArgs e)
    {
        if (ViewModel is not null && sender is TextBox box)
        {
            await ViewModel.UpdateSearchAsync(box.Text);
        }
    }

    private void OnSourceFilterClick(object sender, Microsoft.UI.Xaml.RoutedEventArgs e)
    {
        if (ViewModel is null || sender is not FrameworkElement element || element.Tag is not string tag)
        {
            return;
        }

        ViewModel.SourceFilter = tag switch
        {
            "Provider" => SessionLogSourceFilter.Provider,
            "Assistant" => SessionLogSourceFilter.Assistant,
            _ => SessionLogSourceFilter.All,
        };
    }

    private void OnGroupModeClick(object sender, Microsoft.UI.Xaml.RoutedEventArgs e)
    {
        if (ViewModel is null || sender is not FrameworkElement element || element.Tag is not string tag)
        {
            return;
        }

        ViewModel.GroupMode = tag switch
        {
            "Provider" => SessionLogGroupMode.Provider,
            "Project" => SessionLogGroupMode.Project,
            _ => SessionLogGroupMode.Time,
        };
    }

    private void OnLogSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (ViewModel is null)
        {
            return;
        }

        var record = LogsList.SelectedItem as SessionLogRecord;
        ViewModel.SelectedId = record?.Id;
        DetailPane.Record = record;
    }
}
