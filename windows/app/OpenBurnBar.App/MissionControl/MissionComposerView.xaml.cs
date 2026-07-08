using System.ComponentModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OpenBurnBar.App.Presentation.MissionControl;

namespace OpenBurnBar.App.MissionControl;

/// <summary>
/// Code-behind for the console composer column. Fans the view-model out to the embedded
/// constellation + forecast, routes chip / depth / approval / dispatch interactions back into
/// the draft, and keeps the depth/approval radio groups + captions in sync with the model.
/// </summary>
public sealed partial class MissionComposerView : UserControl
{
    private MissionConsoleViewModel? _viewModel;
    private bool _syncingChoice;

    public MissionComposerView()
    {
        InitializeComponent();
    }

    /// <summary>The console view-model this composer edits.</summary>
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

            Constellation.ViewModel = value;
            Forecast.ViewModel = value;
            Bindings.Update();
            SyncChoicesFromModel();
        }
    }

    private void OnViewModelChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(MissionConsoleViewModel.KindChips)
            or nameof(MissionConsoleViewModel.KindTagline)
            or null)
        {
            Bindings.Update();
        }

        if (e.PropertyName is nameof(MissionConsoleViewModel.Depth)
            or nameof(MissionConsoleViewModel.ApprovalMode)
            or null)
        {
            SyncChoicesFromModel();
        }
    }

    /// <summary>Reflect the model's depth + approval into the radio groups + captions without
    /// re-entrant selection events.</summary>
    private void SyncChoicesFromModel()
    {
        if (_viewModel is null)
        {
            return;
        }

        _syncingChoice = true;
        DepthChoice.SelectedIndex = MissionDepthInfo.Ordinal(_viewModel.Depth);
        ApprovalChoice.SelectedIndex = _viewModel.ApprovalMode == MissionApprovalMode.RequireApproval ? 1 : 0;
        _syncingChoice = false;

        DepthSubtitle.Text = MissionDepthInfo.Subtitle(_viewModel.Depth);
        ApprovalCaption.Text = MissionApprovalModeInfo.Caption(_viewModel.ApprovalMode);
    }

    private void Kind_Click(object sender, Microsoft.UI.Xaml.RoutedEventArgs e)
    {
        if (_viewModel is not null && sender is FrameworkElement { Tag: string tag })
        {
            _viewModel.Kind = MissionKindChipItem.KindForTag(tag);
        }
    }

    private void Depth_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_syncingChoice || _viewModel is null || DepthChoice.SelectedIndex < 0)
        {
            return;
        }

        _viewModel.Depth = DepthChoice.SelectedIndex switch
        {
            0 => MissionDepth.Light,
            2 => MissionDepth.Deep,
            _ => MissionDepth.Standard,
        };
        DepthSubtitle.Text = MissionDepthInfo.Subtitle(_viewModel.Depth);
    }

    private void Approval_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_syncingChoice || _viewModel is null || ApprovalChoice.SelectedIndex < 0)
        {
            return;
        }

        _viewModel.ApprovalMode = ApprovalChoice.SelectedIndex == 1
            ? MissionApprovalMode.RequireApproval
            : MissionApprovalMode.ExistingPolicy;
        ApprovalCaption.Text = MissionApprovalModeInfo.Caption(_viewModel.ApprovalMode);
    }

    private void ClearError_Click(object sender, Microsoft.UI.Xaml.RoutedEventArgs e) =>
        _viewModel?.ClearInlineError();

    private async void Dispatch_Click(object sender, Microsoft.UI.Xaml.RoutedEventArgs e)
    {
        if (_viewModel is not null)
        {
            await _viewModel.DispatchAsync();
        }
    }
}
