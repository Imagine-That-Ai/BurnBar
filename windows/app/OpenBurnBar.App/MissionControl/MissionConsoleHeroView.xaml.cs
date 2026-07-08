using System;
using System.ComponentModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OpenBurnBar.App.Presentation.MissionControl;

namespace OpenBurnBar.App.MissionControl;

/// <summary>
/// Code-behind for the console hero strip. Binds the editorial copy via x:Bind and pushes the
/// hero <see cref="MissionGaugeConfiguration"/> into the <see cref="MissionFabGaugeView"/> on
/// every view-model change. Raises <see cref="CloseRequested"/> for the optional close button.
/// </summary>
public sealed partial class MissionConsoleHeroView : UserControl
{
    private MissionConsoleViewModel? _viewModel;

    public MissionConsoleHeroView()
    {
        InitializeComponent();
        Loaded += (_, _) => PushGauge();
    }

    /// <summary>Raised when the optional close affordance is invoked.</summary>
    public event EventHandler? CloseRequested;

    /// <summary>The console view-model this hero renders.</summary>
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
            PushGauge();
        }
    }

    /// <summary>Show/hide the close affordance (shown when hosted as a modal console window).</summary>
    public bool ShowCloseButton
    {
        get => CloseButton.Visibility == Visibility.Visible;
        set => CloseButton.Visibility = value ? Visibility.Visible : Visibility.Collapsed;
    }

    private void OnViewModelChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(MissionConsoleViewModel.HeroGauge) or null)
        {
            PushGauge();
        }
    }

    private void PushGauge()
    {
        if (_viewModel is not null && IsLoaded)
        {
            Gauge.Configuration = _viewModel.HeroGauge;
        }
    }

    private void CloseButton_Click(object sender, RoutedEventArgs e) =>
        CloseRequested?.Invoke(this, EventArgs.Empty);
}
