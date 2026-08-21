using System.Threading.Tasks;
using Microsoft.UI.Xaml.Controls;

namespace OpenBurnBar.App.Dashboard.Layouts;

/// <summary>The information-dense scroll overview (fallback). Swift: <c>DashboardOverviewView.swift</c>.</summary>
public sealed partial class ClassicLayoutView : UserControl
{
    public ClassicLayoutView()
    {
        InitializeComponent();
        this.BindUsageRefresh(RefreshAsync);
    }

    private async Task RefreshAsync()
    {
        ApplyUsageSummary(await DashboardUsageProvider.LoadAsync());
    }

    internal void ApplyUsageSummary(OpenBurnBar.App.Presentation.Dashboard.DashboardUsageSummary summary)
    {
        SpendTile.Value = DashboardUsageSummaryFormatter.Spend(summary);
        TokensTile.Value = DashboardUsageSummaryFormatter.Tokens(summary);
        SessionsTile.Value = DashboardUsageSummaryFormatter.Sessions(summary);
        string detail = DashboardUsageSummaryFormatter.Detail(summary, "SQLCipher usage database");
        CostCurveText.Text = detail;
        ProviderStatusText.Text = detail;
        ModelsStatusText.Text = summary.HasData ? "Live SQLCipher model rankings." : detail;
    }

}
