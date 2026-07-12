using Microsoft.UI.Xaml.Controls;

namespace OpenBurnBar.App.Dashboard.Layouts;

/// <summary>Mission-control grid concept. Swift: <c>CockpitLayoutView.swift</c>.</summary>
public sealed partial class CockpitLayoutView : UserControl
{
    public CockpitLayoutView()
    {
        InitializeComponent();
        Loaded += OnLoaded;
    }

    private async void OnLoaded(object sender, Microsoft.UI.Xaml.RoutedEventArgs e)
    {
        Loaded -= OnLoaded;
        var summary = await DashboardUsageProvider.LoadAsync();
        BurnTile.Value = DashboardUsageSummaryFormatter.BurnPerDay(summary);
        TokensTile.Value = DashboardUsageSummaryFormatter.Tokens(summary);
        SessionsTile.Value = DashboardUsageSummaryFormatter.Sessions(summary);
        CacheTile.Value = DashboardUsageSummaryFormatter.CacheHit(summary);
        string detail = DashboardUsageSummaryFormatter.Detail(summary, "SQLCipher usage database");
        ProviderStatusText.Text = detail;
        RoutingStatusText.Text = summary.HasData ? "Routing telemetry connected" : "Routing idle until live sessions are connected";
        CostCurveText.Text = detail;
    }
}
