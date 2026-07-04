using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using OpenBurnBar.App.Presentation.Memories;

namespace OpenBurnBar.App.Memory;

public sealed partial class MemoryPage : Page
{
    private readonly MemoryStore _store = new();
    private MemoryReviewInboxModel? _model;

    public MemoryPage()
    {
        InitializeComponent();
        Loaded += OnLoaded;
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        // Scope is filled by the signed-in account when cloud sync lands; empty store
        // until then. Read-only: approve/reject stays Mac-owned (G4).
        var scope = new MemoryScope(AppId: "openburnbar");
        _model = new MemoryReviewInboxModel(
            scope,
            request => _store.LoadPageAsync(request),
            id => _store.OpenBodyAsync(id),
            (id, status) => _store.SetStatusAsync(id, status),
            readOnly: true);
        InboxView.SetModel(_model);
    }

    private async void OnLoaded(object sender, Microsoft.UI.Xaml.RoutedEventArgs e)
    {
        if (_model is not null)
        {
            await InboxView.LoadAsync();
        }
    }
}
