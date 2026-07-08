using System.ComponentModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OpenBurnBar.App.Presentation.MissionControl;

namespace OpenBurnBar.App.MissionControl;

/// <summary>
/// Code-behind for the runtime constellation. Binds the card rows from
/// <see cref="MissionConsoleViewModel.ConstellationItems"/> and, on card tap, sets the draft
/// runtime — which recomputes the constellation selection + the forecast in the view-model.
/// </summary>
public sealed partial class MissionRuntimeConstellationView : UserControl
{
    private MissionConsoleViewModel? _viewModel;

    public MissionRuntimeConstellationView()
    {
        InitializeComponent();
    }

    /// <summary>The console view-model driving the constellation.</summary>
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
        if (e.PropertyName is nameof(MissionConsoleViewModel.ConstellationItems) or null)
        {
            Bindings.Update();
        }
    }

    private void Card_Click(object sender, RoutedEventArgs e)
    {
        if (_viewModel is not null && sender is FrameworkElement { Tag: string runtimeId })
        {
            _viewModel.RuntimeId = runtimeId;
        }
    }
}
