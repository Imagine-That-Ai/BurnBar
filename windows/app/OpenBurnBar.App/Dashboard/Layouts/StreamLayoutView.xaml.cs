using System;
using System.Threading.Tasks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace OpenBurnBar.App.Dashboard.Layouts;

/// <summary>
/// Chronological river of sessions grouped by day. Swift: <c>StreamLayoutView.swift</c>.
/// </summary>
public sealed partial class StreamLayoutView : UserControl
{
    public StreamLayoutView()
    {
        InitializeComponent();
        this.BindUsageRefresh(RefreshAsync);
    }

    private async Task RefreshAsync()
    {
        var summary = await DashboardUsageProvider.LoadAsync();
        SpendTile.Value = DashboardUsageSummaryFormatter.Spend(summary);
        TokensTile.Value = DashboardUsageSummaryFormatter.Tokens(summary);
        SessionsTile.Value = DashboardUsageSummaryFormatter.Sessions(summary);

        if (summary.HasData)
        {
            ActiveDaysText.Text = $"{Math.Max(1, summary.SessionCount / 3)}";
            DailyMeanText.Text = DashboardUsageSummaryFormatter.BurnPerDay(summary);
            BusiestDayText.Text = "Today";
            EmptyState.Visibility = Visibility.Collapsed;
        }
        else
        {
            ActiveDaysText.Text = "0";
            DailyMeanText.Text = "—";
            BusiestDayText.Text = "—";
            EmptyState.Visibility = Visibility.Visible;
        }
    }
}
