using System.Threading.Tasks;
using Microsoft.UI.Xaml.Controls;

namespace OpenBurnBar.App.Dashboard.Layouts;

/// <summary>Mission-control grid concept with instruments and alarms. Swift: <c>CockpitLayoutView.swift</c>.</summary>
public sealed partial class CockpitLayoutView : UserControl
{
    public CockpitLayoutView()
    {
        InitializeComponent();
        this.BindUsageRefresh(RefreshAsync);
    }

    private async Task RefreshAsync()
    {
        var summary = await DashboardUsageProvider.LoadAsync();
        BurnTile.Value = DashboardUsageSummaryFormatter.BurnPerDay(summary);
        TokensTile.Value = DashboardUsageSummaryFormatter.Tokens(summary);
        SessionsTile.Value = DashboardUsageSummaryFormatter.Sessions(summary);
        CacheTile.Value = DashboardUsageSummaryFormatter.CacheHit(summary);
        string detail = DashboardUsageSummaryFormatter.Detail(summary, "SQLCipher usage database");
        ProviderStatusText.Text = detail;
        ActiveProvidersBadge.Text = summary.HasData ? "All active providers live" : "0 providers active";
        RoutingStatusText.Text = summary.HasData ? "Live routing active across agent sessions" : "Routing idle until live sessions are connected";
        CostCurveText.Text = detail;

        AlarmUrgentText.Text = summary.HasData ? "• Urgent queue: Nominal (0 open P1s)" : "• Urgent queue: Nominal";
        AlarmTodayText.Text = summary.HasData ? $"• Today queue: {summary.SessionCount} sessions tracked" : "• Today queue: Nominal";
        AlarmCacheText.Text = summary.HasData ? "• Cache efficiency: Signal active" : "• Cache efficiency: No signal";
    }
}
