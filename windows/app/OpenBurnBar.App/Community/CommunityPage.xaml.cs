using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OpenBurnBar.App.Community;

namespace OpenBurnBar.App.Community;

public sealed partial class CommunityPage : Page
{
    private readonly CommunityViewModel _viewModel = new();

    public CommunityPage()
    {
        InitializeComponent();
        Loaded += (_, _) => Render();
        _viewModel.PropertyChanged += (_, _) => Render();
    }

    private void OnWindowClick(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: string tag })
        {
            return;
        }

        if (Enum.TryParse<CommunityTimeWindow>(tag, out var window))
        {
            _viewModel.Window = window;
        }
    }

    private void OnL1Click(object sender, RoutedEventArgs e) => _viewModel.CycleL1();

    private void OnL2Click(object sender, RoutedEventArgs e) => _viewModel.CycleL2Rankings();

    private void OnL3Click(object sender, RoutedEventArgs e) => _viewModel.CycleL3();

    private void OnLocationClick(object sender, RoutedEventArgs e) => _viewModel.CycleLocation();

    private void OnCityTierClick(object sender, RoutedEventArgs e) => _viewModel.CycleTier(GeographyTier.City);

    private void OnRegionTierClick(object sender, RoutedEventArgs e) => _viewModel.CycleTier(GeographyTier.Region);

    private void OnCountryTierClick(object sender, RoutedEventArgs e) => _viewModel.CycleTier(GeographyTier.Country);

    private void OnWorldTierClick(object sender, RoutedEventArgs e) => _viewModel.CycleTier(GeographyTier.World);

    private void OnRevokeClick(object sender, RoutedEventArgs e) => _viewModel.RevokeAllParticipation();

    private void Render()
    {
        HeroTokensText.Text = $"{_viewModel.HeroTokens:N0} tokens";
        HeroCostText.Text = $"${_viewModel.HeroCostUsd:N2} estimated cost";
        HeroTrendText.Text = _viewModel.TrendDeltaPct == 0
            ? "Trend delta —"
            : $"Trend Δ {_viewModel.TrendDeltaPct:+#.#;-#.#;0}% vs prior window";
        HeroMixText.Text = _viewModel.ModelMixSummary;
        InviteText.Visibility = _viewModel.ShowInviteEmptyState ? Visibility.Visible : Visibility.Collapsed;
        InviteText.Text = "Share anonymized usage to see where you stand — no pressure, every tier is opt-in.";

        PercentileText.Text =
            $"p50 {_viewModel.PercentileStrip.P50:N0} · p75 {_viewModel.PercentileStrip.P75:N0} · p90 {_viewModel.PercentileStrip.P90:N0} · p99 {_viewModel.PercentileStrip.P99:N0}";

        PeerText.Text = _viewModel.PeerCohortTokens.Count == 0
            ? "Cohort chart unlocks once a leaderboard tier clears the anonymity threshold."
            : $"Cohort token spread: {string.Join(", ", _viewModel.PeerCohortTokens.Select(v => v.ToString("N0")))}";

        PurposeText.Text = _viewModel.PurposeBreakdown.Count == 0
            ? "Purpose mix appears after you opt into community sharing."
            : string.Join(" · ", _viewModel.PurposeBreakdown.Select(p => $"{p.Category} {p.Share:P0}"));

        ConsentPreviewText.Text = _viewModel.ConsentPreviewSummary;
        CityConfidenceText.Text = _viewModel.CityConfidenceCopy;
        StatusText.Text = _viewModel.StatusMessage;

        LeaderboardHost.Children.Clear();
        foreach (var card in _viewModel.Leaderboards)
        {
            LeaderboardHost.Children.Add(BuildLeaderboardCard(card));
        }
    }

    private static UIElement BuildLeaderboardCard(CommunityLeaderboardCard card)
    {
        var panel = new StackPanel { Spacing = 6 };
        panel.Children.Add(new TextBlock
        {
            Text = $"{card.Tier.DisplayName()} — {card.GeoLabel}",
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        });

        if (card.BelowThreshold)
        {
            panel.Children.Add(new TextBlock
            {
                Text = $"Needs {card.KThreshold} more burners in {card.GeoLabel}. No individual data is shown below k={card.KThreshold}.",
                TextWrapping = TextWrapping.WrapWholeWords,
                Foreground = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["PensieveColorTextMuteBrush"],
            });
            return WrapCard(panel);
        }

        foreach (var entry in card.Entries)
        {
            var handle = string.IsNullOrWhiteSpace(entry.Handle) ? entry.AnonId : entry.Handle;
            panel.Children.Add(new TextBlock
            {
                Text = $"#{entry.Rank} {handle} · {entry.TotalTokens:N0} tok · ${entry.CostUsd:N2} · {entry.Movement}",
            });
        }

        if (card.YourRank is int rank)
        {
            panel.Children.Add(new TextBlock
            {
                Text = $"You · rank {rank} · {card.YourMovement}",
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            });
        }

        return WrapCard(panel);
    }

    private static Border WrapCard(UIElement child) => new()
    {
        Child = child,
        Padding = new Thickness(16),
        CornerRadius = (CornerRadius)Application.Current.Resources["PensieveRadiusMdCorner"],
        Background = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["PensieveColorInkElevatedBrush"],
        BorderBrush = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["PensieveColorGlassLineBrush"],
        BorderThickness = new Thickness(1),
    };
}