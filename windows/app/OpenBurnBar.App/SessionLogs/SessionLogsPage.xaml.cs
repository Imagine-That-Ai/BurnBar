using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OpenBurnBar.App.Presentation.SessionLogs;

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

        var viewModel = new SessionLogsViewModel(new EmptySessionLogReadSource());
        LogsView.SetModel(viewModel);
        await LogsView.LoadAsync();
    }

    /// <summary>Dev-host read seam until <c>StorageSessionLogReadSource</c> is referenced from the app.</summary>
    private sealed class EmptySessionLogReadSource : ISessionLogReadSource
    {
        public Task<IReadOnlyList<SessionLogRecord>> ListAsync(int limit = 200, CancellationToken cancellationToken = default) =>
            Task.FromResult<IReadOnlyList<SessionLogRecord>>(Array.Empty<SessionLogRecord>());

        public Task<IReadOnlyList<string>> SearchMatchingIdsAsync(string query, int limit = 200, CancellationToken cancellationToken = default) =>
            Task.FromResult<IReadOnlyList<string>>(Array.Empty<string>());
    }
}