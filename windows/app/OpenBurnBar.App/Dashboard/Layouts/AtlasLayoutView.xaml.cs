using System.Threading.Tasks;
using Microsoft.UI.Xaml.Controls;

namespace OpenBurnBar.App.Dashboard.Layouts;

/// <summary>
/// Comparison ladders split across the window. Swift: <c>AtlasLayoutView.swift</c>.
/// </summary>
public sealed partial class AtlasLayoutView : UserControl
{
    public AtlasLayoutView()
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
        WholeWindowText.Text = formattedSpend;

        // The summary carries window totals only — no half-window split and no
        // provider/model rankings — so the split readout and ladders keep their
        // honest empty defaults rather than fabricating a delta.
    }
}
