using Microsoft.UI.Xaml.Controls;

namespace OpenBurnBar.App.Dashboard.Layouts;

/// <summary>Centered command column concept. Swift: <c>ConstellationLayoutView.swift</c>.</summary>
public sealed partial class ConstellationLayoutView : UserControl
{
    public ConstellationLayoutView()
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
        ProviderStatusText.Text = DashboardUsageSummaryFormatter.Detail(summary, "SQLCipher usage database");
    }
}
