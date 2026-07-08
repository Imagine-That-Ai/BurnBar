using System.ComponentModel;
using System.Linq;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OpenBurnBar.App.Presentation.MissionControl;

namespace OpenBurnBar.App.MissionControl;

/// <summary>
/// Code-behind for the situation room. Refreshes its x:Binds on snapshot change and routes
/// Approve / Reject taps back through <see cref="MissionConsoleViewModel.RespondAsync"/>.
/// </summary>
public sealed partial class MissionSituationRoomView : UserControl
{
    private MissionConsoleViewModel? _viewModel;

    public MissionSituationRoomView()
    {
        InitializeComponent();
    }

    /// <summary>The console view-model whose live snapshot this room renders.</summary>
    public MissionConsoleViewModel? ViewModel
    {
        get => _viewModel;
        set
        {
            if (ReferenceEquals(_viewModel, value))
            {
                return;
            }

            if (_viewModel is not null)
            {
                _viewModel.PropertyChanged -= OnViewModelChanged;
            }

            _viewModel = value;
            if (_viewModel is not null)
            {
                _viewModel.PropertyChanged += OnViewModelChanged;
            }

            Bindings.Update();
        }
    }

    private void OnViewModelChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(MissionConsoleViewModel.ActiveTiles)
            or nameof(MissionConsoleViewModel.ApprovalAsks)
            or nameof(MissionConsoleViewModel.RecentTicker)
            or nameof(MissionConsoleViewModel.HasActiveTiles)
            or nameof(MissionConsoleViewModel.HasApprovals)
            or nameof(MissionConsoleViewModel.HasTicker)
            or null)
        {
            Bindings.Update();
        }
    }

    private async void Approve_Click(object sender, RoutedEventArgs e) => await RespondAsync(sender, approve: true);

    private async void Reject_Click(object sender, RoutedEventArgs e) => await RespondAsync(sender, approve: false);

    private async System.Threading.Tasks.Task RespondAsync(object sender, bool approve)
    {
        if (_viewModel is null || sender is not FrameworkElement { Tag: string askId })
        {
            return;
        }

        MissionApprovalAsk? ask = _viewModel.ApprovalAsks.FirstOrDefault(a => a.Id == askId);
        if (ask is not null)
        {
            await _viewModel.RespondAsync(ask, approve);
        }
    }
}
