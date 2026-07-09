using System.ComponentModel;
using System.Linq;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Navigation;
using OpenBurnBar.App.Theme;
using Windows.UI;

namespace OpenBurnBar.App.Onboarding;

/// <summary>Scanning step. Windows peer of <c>OnboardingScanView.swift</c>: a per-provider
/// parser-health readout plus a busy indicator while the aggregator refreshes. The live
/// parser-health source is wired when the Windows usage aggregator lands; this step
/// reflects <see cref="OnboardingWizardModel.IsScanning"/>.</summary>
public sealed partial class ScanStepPage : Page
{
    private OnboardingContext? _context;

    public ScanStepPage()
    {
        InitializeComponent();
        Unloaded += OnUnloaded;
    }

    private OnboardingWizardModel? Model => _context?.Model;

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        _context = e.Parameter as OnboardingContext;
        if (_context is null || Model is null)
        {
            return;
        }

        BuildRows();
        Model.PropertyChanged += OnModelChanged;
        SyncBusy();
    }

    private void BuildRows()
    {
        if (_context is null || Model is null)
        {
            return;
        }

        ProviderRows.Children.Clear();
        foreach (AgentProviderBrand provider in Model.SelectedProviders.OrderBy(_context.DisplayName, System.StringComparer.Ordinal))
        {
            var row = new Grid { Padding = new Thickness(8, 6, 8, 6) };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.Background = (Brush)Application.Current.Resources["PensieveColorGlassBgBrush"];
            row.CornerRadius = new CornerRadius(8);

            var badge = new Border
            {
                Width = 16,
                Height = 16,
                CornerRadius = new CornerRadius(4),
                VerticalAlignment = VerticalAlignment.Center,
                Background = new SolidColorBrush(ProviderBrand.Primary(provider)),
            };
            Grid.SetColumn(badge, 0);
            row.Children.Add(badge);

            var name = new TextBlock
            {
                Text = _context.DisplayName(provider),
                FontSize = 12.5,
                Margin = new Thickness(8, 0, 0, 0),
                VerticalAlignment = VerticalAlignment.Center,
                TextTrimming = TextTrimming.CharacterEllipsis,
            };
            Grid.SetColumn(name, 1);
            row.Children.Add(name);

            var status = new TextBlock
            {
                Text = "Scanning…",
                FontSize = 11,
                Opacity = 0.55,
                VerticalAlignment = VerticalAlignment.Center,
            };
            Grid.SetColumn(status, 2);
            row.Children.Add(status);

            ProviderRows.Children.Add(row);
        }
    }

    private void OnModelChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(OnboardingWizardModel.IsScanning))
        {
            SyncBusy();
        }
    }

    private void SyncBusy()
    {
        bool scanning = Model?.IsScanning ?? false;
        BusyRow.Visibility = scanning ? Visibility.Visible : Visibility.Collapsed;
        BusyRing.IsActive = scanning;
    }

    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        if (Model is not null)
        {
            Model.PropertyChanged -= OnModelChanged;
        }
    }
}
