using System.Threading.Tasks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OpenBurnBar.App.Presentation.Memories;

namespace OpenBurnBar.App.Memory;

/// <summary>
/// The memory review inbox (Windows). Hosts a <see cref="MemoryReviewInboxModel"/> —
/// the human approval gate in the quarantine lifecycle (G4). The model is portable and
/// unit-tested on macOS; this control is its WinUI render. Callers construct the view,
/// assign <see cref="ViewModel"/>, then <see cref="LoadAsync"/> (the analog of the
/// SwiftUI <c>.task { await model.load() }</c>).
/// </summary>
public sealed partial class MemoryReviewInboxView : UserControl
{
    public MemoryReviewInboxView()
    {
        InitializeComponent();
    }

    /// <summary>The portable inbox model this view renders. Set it before calling
    /// <see cref="LoadAsync"/>; x:Bind (OneWay) subscribes to its change notifications.</summary>
    public MemoryReviewInboxModel? ViewModel { get; private set; }

    /// <summary>Bind a model and refresh the one-time/one-way bindings.</summary>
    public void SetModel(MemoryReviewInboxModel model)
    {
        ViewModel = model;
        Bindings.Update();
    }

    /// <summary>Load both buckets. No-op until a model is bound.</summary>
    public Task LoadAsync() => ViewModel?.LoadAsync() ?? Task.CompletedTask;

    private void OnPendingFilterClick(object sender, RoutedEventArgs e)
    {
        if (ViewModel is not null)
        {
            ViewModel.CurrentFilter = MemoryReviewInboxModel.Filter.Pending;
        }
    }

    private void OnApprovedFilterClick(object sender, RoutedEventArgs e)
    {
        if (ViewModel is not null)
        {
            ViewModel.CurrentFilter = MemoryReviewInboxModel.Filter.Approved;
        }
    }

    private async void OnApproveClick(object sender, RoutedEventArgs e)
    {
        if (ViewModel is not null && sender is FrameworkElement element && element.Tag is string id)
        {
            await ViewModel.ApproveAsync(id);
        }
    }

    private async void OnRejectClick(object sender, RoutedEventArgs e)
    {
        if (ViewModel is not null && sender is FrameworkElement element && element.Tag is string id)
        {
            await ViewModel.RejectAsync(id);
        }
    }
}
