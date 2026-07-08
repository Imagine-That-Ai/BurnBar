using System.Collections.Generic;
using System.Linq;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Navigation;
using OpenBurnBar.App.Theme;

namespace OpenBurnBar.App.Onboarding;

/// <summary>Chat-engine step. Windows peer of <c>OnboardingChatEngineView.swift</c>:
/// a per-backend toggle list, a default-engine picker that appears once two-plus backends
/// are enabled, a Hermes "Setup wizard" launcher, and a gateway-health readout.</summary>
public sealed partial class ChatEngineStepPage : Page
{
    private OnboardingContext? _context;
    private bool _suppressComboEvent;

    public ChatEngineStepPage()
    {
        InitializeComponent();
    }

    private OnboardingWizardModel? Model => _context?.Model;

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        _context = e.Parameter as OnboardingContext;
        if (Model is null)
        {
            return;
        }

        BuildBackendRows();
        RefreshDefaultEngine();
    }

    private void BuildBackendRows()
    {
        if (Model is null)
        {
            return;
        }

        BackendRows.Children.Clear();
        foreach (ChatBackendId backend in ChatBackendMetadata.AllCases)
        {
            var row = new Grid();
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

            var badge = new Border
            {
                Width = 20,
                Height = 20,
                CornerRadius = new CornerRadius(5),
                VerticalAlignment = VerticalAlignment.Center,
                Background = new SolidColorBrush(ProviderBrand.Primary(backend.AgentProvider())),
            };
            Grid.SetColumn(badge, 0);
            row.Children.Add(badge);

            var toggle = new ToggleSwitch
            {
                Header = backend.DisplayName(),
                IsOn = Model.IsBackendEnabled(backend),
                Margin = new Thickness(10, 0, 0, 0),
            };
            ChatBackendId captured = backend;
            toggle.Toggled += (_, _) =>
            {
                Model.SetBackendEnabled(captured, toggle.IsOn);
                RefreshDefaultEngine();
            };
            Grid.SetColumn(toggle, 1);
            row.Children.Add(toggle);

            if (backend == ChatBackendId.Hermes)
            {
                var setup = new Button
                {
                    Content = "Setup wizard",
                    Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
                    BorderThickness = new Thickness(0),
                    FontSize = 11,
                    VerticalAlignment = VerticalAlignment.Center,
                };
                setup.Click += (_, _) => _context?.ShowHermesSetup?.Invoke();
                Grid.SetColumn(setup, 2);
                row.Children.Add(setup);
            }

            BackendRows.Children.Add(row);
        }
    }

    private void RefreshDefaultEngine()
    {
        if (Model is null)
        {
            return;
        }

        IReadOnlyList<ChatBackendId> ordered = Model.OrderedEnabledBackends;
        DefaultEngineRow.Visibility = ordered.Count >= 2 ? Visibility.Visible : Visibility.Collapsed;
        if (ordered.Count < 2)
        {
            return;
        }

        _suppressComboEvent = true;
        DefaultEngineCombo.Items.Clear();
        foreach (ChatBackendId backend in ordered)
        {
            DefaultEngineCombo.Items.Add(new ComboBoxItem
            {
                Content = backend.DisplayName(),
                Tag = backend,
            });
        }

        int selectedIndex = ordered.ToList().IndexOf(Model.DefaultEngine);
        DefaultEngineCombo.SelectedIndex = selectedIndex >= 0 ? selectedIndex : 0;
        _suppressComboEvent = false;
    }

    private void OnDefaultEngineChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_suppressComboEvent || Model is null)
        {
            return;
        }

        if (DefaultEngineCombo.SelectedItem is ComboBoxItem { Tag: ChatBackendId backend })
        {
            Model.DefaultEngine = backend;
        }
    }

    private void OnCheckGatewayHealth(object sender, RoutedEventArgs e)
    {
        // Live probe wires in with the Windows Hermes runtime; this reflects the placeholder
        // "unknown" state (neutral dots) until then.
    }
}
