using System.Threading.Tasks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using OpenBurnBar.App.Configuration;
using OpenBurnBar.App.Data;
using OpenBurnBar.App.Presentation.Dashboard;
using OpenBurnBar.App.Settings.Winui;
using OpenBurnBar.App.Theme;
using Windows.UI;

namespace OpenBurnBar.App.Dashboard.Layouts;

/// <summary>The kernel-forward "keeper" concept. Swift: <c>AtelierLayoutView.swift</c>.</summary>
public sealed partial class AtelierLayoutView : UserControl
{
    public AtelierLayoutView()
    {
        InitializeComponent();
        this.BindUsageRefresh(RefreshAsync);
    }

    private async Task RefreshAsync()
    {
        var summary = await DashboardUsageProvider.LoadAsync();
        SpendTile.Value = DashboardUsageSummaryFormatter.Spend(summary);
        TokensTile.Value = DashboardUsageSummaryFormatter.Tokens(summary);
        ProvidersTile.Value = DashboardUsageSummaryFormatter.Providers(summary);

        if (summary.HasData)
        {
            HeadlineText.Text = "A living substrate,\ntuned to your spend.";
            SubheadText.Text = $"{DashboardUsageSummaryFormatter.Spend(summary)} across {summary.SessionCount} sessions. Provider logos emerge from the kernel and dissolve back into it.";
        }
        else
        {
            HeadlineText.Text = "A living substrate,\nwaiting for its first session.";
            SubheadText.Text = "Provider logos will emerge from the kernel as sessions land. Connect a data source to begin.";
        }

        PopulateProviderRail();
    }

    private void OnSizeChanged(object sender, SizeChangedEventArgs e)
    {
        // macOS wide threshold ≈ 900 — collapse rail column when the concept
        // pane is narrow so the hero still reads.
        bool wide = e.NewSize.Width >= 820;
        if (WideRoot.ColumnDefinitions.Count >= 1)
        {
            WideRoot.ColumnDefinitions[0].Width = wide
                ? new GridLength(300)
                : new GridLength(0);
            ProviderRail.Visibility = wide ? Visibility.Visible : Visibility.Collapsed;
        }
    }

    private void PopulateProviderRail()
    {
        ProviderList.Children.Clear();
        DashboardCommandSnapshot snapshot = RuntimeDataMode.SampleModeEnabled
            ? DashboardCommandSampleData.Snapshot()
            : App.Current.UsageRuntime is { } usageRuntime
                ? UsageRuntimePresentationMapper.ToDashboardCommandSnapshot(
                    usageRuntime.State,
                    WindowsGeneralSettingsComposition.Load())
                : DashboardCommandSnapshot.Empty;

        if (snapshot.Providers.Count == 0)
        {
            ProviderList.Children.Add(new TextBlock
            {
                Text = "No providers in this window",
                FontSize = 12,
                Opacity = 0.55,
                Margin = new Thickness(4, 8, 4, 0),
            });
            return;
        }

        foreach (DashboardProviderSidebarRow row in snapshot.Providers)
        {
            ProviderList.Children.Add(BuildProviderChip(row));
        }
    }

    private static Border BuildProviderChip(DashboardProviderSidebarRow row)
    {
        Color accent = BrandFor(row.Id);
        var root = new Border
        {
            CornerRadius = new CornerRadius(10),
            Padding = new Thickness(10, 8, 10, 8),
            BorderThickness = new Thickness(1),
            BorderBrush = new SolidColorBrush(Color.FromArgb(0x33, 0xFF, 0xFF, 0xFF)),
            Background = new SolidColorBrush(Color.FromArgb(0x18, 0xFF, 0xFF, 0xFF)),
        };

        var grid = new Grid { ColumnSpacing = 10 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var disc = new Border
        {
            Width = 32,
            Height = 32,
            CornerRadius = new CornerRadius(16),
            Background = new SolidColorBrush(Color.FromArgb(0x2E, accent.R, accent.G, accent.B)),
            Child = new TextBlock
            {
                Text = row.DisplayName.Length > 0 ? row.DisplayName[..1] : "?",
                FontSize = 13,
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
                Foreground = new SolidColorBrush(accent),
            },
        };
        Grid.SetColumn(disc, 0);

        var labels = new StackPanel { Spacing = 1, VerticalAlignment = VerticalAlignment.Center };
        labels.Children.Add(new TextBlock
        {
            Text = row.DisplayName,
            FontSize = 13,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        });
        labels.Children.Add(new TextBlock
        {
            Text = $"{row.SessionCount} sessions",
            FontSize = 11,
            Opacity = 0.55,
        });
        Grid.SetColumn(labels, 1);

        var metric = new TextBlock
        {
            Text = row.MetricLabel,
            FontSize = 12,
            FontFamily = BrandFonts.Mono,
            VerticalAlignment = VerticalAlignment.Center,
            Foreground = new SolidColorBrush(accent),
        };
        Grid.SetColumn(metric, 2);

        grid.Children.Add(disc);
        grid.Children.Add(labels);
        grid.Children.Add(metric);
        root.Child = grid;
        return root;
    }

    private static Color BrandFor(string providerId) =>
        providerId.Trim().ToLowerInvariant() switch
        {
            "openai" => ProviderBrand.Primary(AgentProviderBrand.OpenAI),
            "anthropic" => ProviderBrand.Primary(AgentProviderBrand.ClaudeCode),
            "cursor" => ProviderBrand.Primary(AgentProviderBrand.Cursor),
            "grok" or "xai" => ProviderBrand.Primary(AgentProviderBrand.XAI),
            "gemini" => ProviderBrand.Primary(AgentProviderBrand.GeminiCLI),
            _ => Color.FromArgb(0xFF, 0xC9, 0xA2, 0x4A),
        };
}
