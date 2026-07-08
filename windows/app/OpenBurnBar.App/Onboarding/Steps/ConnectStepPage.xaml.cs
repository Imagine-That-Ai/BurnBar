using System.Collections.Generic;
using System.Linq;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Navigation;
using Microsoft.UI.Text;
using OpenBurnBar.App.Theme;
using Windows.UI;

namespace OpenBurnBar.App.Onboarding;

/// <summary>Connection-status step. Windows peer of <c>OnboardingConnectView.swift</c>:
/// the selected providers split into "Ready" (detected) and "Needs attention" sections.
/// Real per-provider log-path detection is a Windows detection-service follow-up; this
/// step reflects the detected flag the model already carries.</summary>
public sealed partial class ConnectStepPage : Page
{
    private static readonly Color ReadyColor = Color.FromArgb(0xFF, 0x22, 0xC5, 0x5E);
    private static readonly Color WarnColor = Color.FromArgb(0xFF, 0xF5, 0x9E, 0x0B);

    private OnboardingContext? _context;

    public ConnectStepPage()
    {
        InitializeComponent();
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        _context = e.Parameter as OnboardingContext;
        if (_context is null)
        {
            return;
        }

        OnboardingWizardModel model = _context.Model;
        List<AgentProviderBrand> selected = model.SelectedProviders
            .OrderBy(_context.DisplayName, System.StringComparer.Ordinal)
            .ToList();
        List<AgentProviderBrand> ready = selected.Where(model.IsProviderDetected).ToList();
        List<AgentProviderBrand> attention = selected.Where(p => !model.IsProviderDetected(p)).ToList();

        SectionHost.Children.Clear();
        if (ready.Count > 0)
        {
            SectionHost.Children.Add(BuildSection("Ready", ready, isReady: true));
        }

        if (attention.Count > 0)
        {
            SectionHost.Children.Add(BuildSection("Needs attention", attention, isReady: false));
        }

        FootNote.Text = attention.Count == 0
            ? "All selected agents look ready on this PC."
            : "Missing agents may store logs elsewhere, or you haven't used them on this PC yet. You can configure paths later in Settings.";
    }

    private StackPanel BuildSection(string title, IReadOnlyList<AgentProviderBrand> providers, bool isReady)
    {
        var section = new StackPanel { Spacing = 8 };
        section.Children.Add(new TextBlock
        {
            Text = title,
            FontSize = 12.5,
            FontWeight = FontWeights.SemiBold,
            Opacity = 0.7,
        });

        Color accent = isReady ? ReadyColor : WarnColor;
        foreach (AgentProviderBrand provider in providers)
        {
            var row = new Grid { Padding = new Thickness(8, 6, 8, 6) };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.Background = new SolidColorBrush(Color.FromArgb(0x10, accent.R, accent.G, accent.B));
            row.CornerRadius = new CornerRadius(8);

            var dot = new Border
            {
                Width = 8,
                Height = 8,
                CornerRadius = new CornerRadius(4),
                VerticalAlignment = VerticalAlignment.Center,
                Background = new SolidColorBrush(accent),
            };
            Grid.SetColumn(dot, 0);
            row.Children.Add(dot);

            var badge = new Border
            {
                Width = 16,
                Height = 16,
                CornerRadius = new CornerRadius(4),
                Margin = new Thickness(8, 0, 8, 0),
                VerticalAlignment = VerticalAlignment.Center,
                Background = new SolidColorBrush(ProviderBrand.Primary(provider)),
            };
            Grid.SetColumn(badge, 1);
            row.Children.Add(badge);

            var name = new TextBlock
            {
                Text = _context!.DisplayName(provider),
                FontSize = 12.5,
                VerticalAlignment = VerticalAlignment.Center,
                TextTrimming = TextTrimming.CharacterEllipsis,
            };
            Grid.SetColumn(name, 2);
            row.Children.Add(name);

            section.Children.Add(row);
        }

        return section;
    }
}
