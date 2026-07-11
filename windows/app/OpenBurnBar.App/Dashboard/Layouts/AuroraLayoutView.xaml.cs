using Microsoft.UI.Xaml.Controls;

namespace OpenBurnBar.App.Dashboard.Layouts;

/// <summary>Provider list + open hero swarm + data band. Swift: <c>AuroraLayoutView.swift</c>.</summary>
public sealed partial class AuroraLayoutView : UserControl
{
    public AuroraLayoutView()
    {
        InitializeComponent();
        Loaded += OnLoaded;
    }

    private async void OnLoaded(object sender, Microsoft.UI.Xaml.RoutedEventArgs e)
    {
        Loaded -= OnLoaded;
        var summary = await DashboardUsageProvider.LoadAsync();
        SpendTile.Value = DashboardUsageSummaryFormatter.Spend(summary);
        TokensTile.Value = DashboardUsageSummaryFormatter.Tokens(summary);
        SessionsTile.Value = DashboardUsageSummaryFormatter.Sessions(summary);
        ProviderStatusText.Text = DashboardUsageSummaryFormatter.Detail(summary, "SQLCipher usage database");
    }
}
