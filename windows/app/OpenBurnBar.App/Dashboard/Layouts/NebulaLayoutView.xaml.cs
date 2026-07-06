using Microsoft.UI.Xaml.Controls;

namespace OpenBurnBar.App.Dashboard.Layouts;

/// <summary>Bento grid concept. Swift: <c>NebulaLayoutView.swift</c>.</summary>
public sealed partial class NebulaLayoutView : UserControl
{
    public NebulaLayoutView()
    {
        InitializeComponent();
        Loaded += OnLoaded;
    }

    private void OnLoaded(object sender, Microsoft.UI.Xaml.RoutedEventArgs e)
    {
        Loaded -= OnLoaded;
        var summary = OpenBurnBar.App.Storage.WindowsStorageDevHost.LoadDashboardUsageSummary();
        BurnTile.Text = DashboardUsageSummaryFormatter.BurnPerDay(summary);
        BurnDetailText.Text = DashboardUsageSummaryFormatter.Detail(summary, "SQLCipher usage database");
        TokensTile.Value = DashboardUsageSummaryFormatter.Tokens(summary);
        SessionsTile.Value = DashboardUsageSummaryFormatter.Sessions(summary);
        SpendTile.Value = DashboardUsageSummaryFormatter.Spend(summary);
        ProviderStatusText.Text = DashboardUsageSummaryFormatter.Detail(summary, "SQLCipher usage database");
    }
}
