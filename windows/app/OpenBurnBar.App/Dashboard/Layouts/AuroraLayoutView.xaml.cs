using System.Threading.Tasks;
using Microsoft.UI.Xaml.Controls;

namespace OpenBurnBar.App.Dashboard.Layouts;

/// <summary>Focus layout: exactly one number above the fold. Swift: <c>AuroraLayoutView.swift</c>.</summary>
public sealed partial class AuroraLayoutView : UserControl
{
    public AuroraLayoutView()
    {
        InitializeComponent();
        this.BindUsageRefresh(RefreshAsync);
    }

    private async Task RefreshAsync()
    {
        var summary = await DashboardUsageProvider.LoadAsync();
        string formattedSpend = DashboardUsageSummaryFormatter.Spend(summary);
        SpendTile.Value = formattedSpend;
        TokensTile.Value = DashboardUsageSummaryFormatter.Tokens(summary);
        SessionsTile.Value = DashboardUsageSummaryFormatter.Sessions(summary);
        HeroBurnText.Text = formattedSpend;
        ActiveProvidersCountText.Text = summary.HasData ? "Live" : "0";
        ProviderStatusText.Text = DashboardUsageSummaryFormatter.Detail(summary, "SQLCipher usage database");

        if (summary.HasData)
        {
            FocusSentenceText.Text = $"Across {summary.SessionCount} sessions and {summary.TotalTokens:N0} tokens.";
        }
        else
        {
            FocusSentenceText.Text = "No spend recorded in this window yet. Connect a data source to begin.";
        }
    }
}
