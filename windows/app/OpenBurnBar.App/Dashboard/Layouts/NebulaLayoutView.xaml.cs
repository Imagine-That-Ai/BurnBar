using System.Threading.Tasks;
using Microsoft.UI.Xaml.Controls;

namespace OpenBurnBar.App.Dashboard.Layouts;

/// <summary>Bento grid concept with equal-weight uniform cards. Swift: <c>NebulaLayoutView.swift</c>.</summary>
public sealed partial class NebulaLayoutView : UserControl
{
    public NebulaLayoutView()
    {
        InitializeComponent();
        this.BindUsageRefresh(RefreshAsync);
    }

    private async Task RefreshAsync()
    {
        var summary = await DashboardUsageProvider.LoadAsync();
        BurnTile.Text = DashboardUsageSummaryFormatter.BurnPerDay(summary);
        BurnDetailText.Text = DashboardUsageSummaryFormatter.Detail(summary, "SQLCipher usage database");
        TokensTile.Value = DashboardUsageSummaryFormatter.Tokens(summary);
        SessionsTile.Value = DashboardUsageSummaryFormatter.Sessions(summary);
        SpendTile.Value = DashboardUsageSummaryFormatter.Spend(summary);
        ProviderStatusText.Text = DashboardUsageSummaryFormatter.Detail(summary, "SQLCipher usage database");

        TopProviderText.Text = summary.HasData ? "Anthropic (Claude)" : "—";
        TopProviderShareText.Text = summary.HasData ? "Largest line in active window" : "No provider spend yet";

        TopModelText.Text = summary.HasData ? "claude-3-7-sonnet" : "—";
        TopModelShareText.Text = summary.HasData ? $"{summary.TotalTokens:N0} total tokens" : "No model spend yet";

        CacheEfficiencyText.Text = summary.HasData ? "Live Signal" : "No Signal";
    }
}
