using System.ComponentModel;
using Microsoft.UI.Xaml.Controls;
using OpenBurnBar.App.Presentation.MissionControl;

namespace OpenBurnBar.App.MissionControl;

/// <summary>
/// Code-behind for the burn forecast strip. Refreshes its x:Binds whenever the view-model's
/// forecast, resolved runtime, or accent changes (kind / runtime / depth edits).
/// </summary>
public sealed partial class MissionBurnForecastView : UserControl
{
    private MissionConsoleViewModel? _viewModel;

    public MissionBurnForecastView()
    {
        InitializeComponent();
    }

    /// <summary>The console view-model whose forecast this strip renders.</summary>
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
        if (e.PropertyName is nameof(MissionConsoleViewModel.Forecast)
            or nameof(MissionConsoleViewModel.ResolvedRuntime)
            or nameof(MissionConsoleViewModel.RuntimeAccentKey)
            or null)
        {
            Bindings.Update();
        }
    }
}
