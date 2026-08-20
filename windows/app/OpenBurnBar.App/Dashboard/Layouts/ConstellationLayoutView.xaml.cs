using System.Threading.Tasks;
using Microsoft.UI.Xaml.Controls;

namespace OpenBurnBar.App.Dashboard.Layouts;

/// <summary>Centered Ask command column concept. Swift: <c>ConstellationLayoutView.swift</c>.</summary>
public sealed partial class ConstellationLayoutView : UserControl
{
    public ConstellationLayoutView()
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
        ProviderStatusText.Text = DashboardUsageSummaryFormatter.Detail(summary, "SQLCipher usage database");

        if (summary.HasData)
        {
            AskBox.PlaceholderText = $"Ask Hermes about {DashboardUsageSummaryFormatter.Spend(summary)} spend, models, or {summary.SessionCount} sessions…";
            ActiveContextDetail.Text = $"Hermes is grounded in {summary.SessionCount} local sessions across {summary.TotalTokens:N0} tokens.";
        }
        else
        {
            AskBox.PlaceholderText = "Ask Hermes or search everything…";
            ActiveContextDetail.Text = "Hermes is grounded in your local session ledger.";
        }
    }
}
