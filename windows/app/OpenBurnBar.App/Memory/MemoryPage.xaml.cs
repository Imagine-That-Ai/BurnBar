using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OpenBurnBar.App.Presentation.Memories;

namespace OpenBurnBar.App.Memory;

/// <summary>
/// Nav-frame host for <see cref="MemoryReviewInboxView"/>. Registered as the "memory"
/// destination in <see cref="OpenBurnBar.App.Shell.SurfacePageResolver"/>.
/// </summary>
public sealed partial class MemoryPage : Page
{

    public MemoryPage()
    {
        InitializeComponent();
        Loaded += OnLoaded;
    }

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        Loaded -= OnLoaded;

        var model = DevHostMemoryInboxModel.Create();
        InboxView.SetModel(model);
        await InboxView.LoadAsync();
    }
}

/// <summary>In-memory inbox delegates for dev-host nav (empty corpus until storage wires in).</summary>
file static class DevHostMemoryInboxModel
{
    private static readonly MemoryScope DevScope = new(UserId: "dev", AgentId: "openburnbar");

    public static MemoryReviewInboxModel Create() =>
        new(DevScope, LoadPageAsync, OpenBodyAsync, SetStatusAsync);

    private static Task<Presentation.Memories.MemoryPage> LoadPageAsync(MemoryPageRequest request)
    {
        IReadOnlyList<Memory> items = Array.Empty<Memory>();
        return Task.FromResult(new Presentation.Memories.MemoryPage(items, request.Page, request.PageSize, 0));
    }

    private static Task<string?> OpenBodyAsync(string id) => Task.FromResult<string?>(null);

    private static Task<bool> SetStatusAsync(string id, MemoryReviewStatus status) =>
        Task.FromResult(true);
}