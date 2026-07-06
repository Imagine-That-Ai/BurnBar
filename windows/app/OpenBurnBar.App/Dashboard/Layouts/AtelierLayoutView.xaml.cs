using Microsoft.UI.Xaml.Controls;

namespace OpenBurnBar.App.Dashboard.Layouts;

/// <summary>The kernel-forward "keeper" concept. Swift: <c>AtelierLayoutView.swift</c>.</summary>
public sealed partial class AtelierLayoutView : UserControl
{
    public AtelierLayoutView()
    {
        InitializeComponent();
        Loaded += OnLoaded;
    }

    private void OnLoaded(object sender, Microsoft.UI.Xaml.RoutedEventArgs e)
    {
        Loaded -= OnLoaded;
        var summary = OpenBurnBar.App.Storage.WindowsStorageDevHost.LoadDashboardUsageSummary();
        SpendTile.Value = DashboardUsageSummaryFormatter.Spend(summary);
        TokensTile.Value = DashboardUsageSummaryFormatter.Tokens(summary);
        ProvidersTile.Value = DashboardUsageSummaryFormatter.Providers(summary);
    }
}
