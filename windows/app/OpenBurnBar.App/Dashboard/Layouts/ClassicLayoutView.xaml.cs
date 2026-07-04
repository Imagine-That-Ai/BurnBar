using Microsoft.UI.Xaml.Controls;

namespace OpenBurnBar.App.Dashboard.Layouts;

/// <summary>The information-dense scroll overview (fallback). Swift: <c>DashboardOverviewView.swift</c>.</summary>
public sealed partial class ClassicLayoutView : UserControl
{
    public ClassicLayoutView()
    {
        InitializeComponent();
        Loaded += OnLoaded;
    }

    private void OnLoaded(object sender, Microsoft.UI.Xaml.RoutedEventArgs e)
    {
        Loaded -= OnLoaded;
        ApplyUsageSummary(OpenBurnBar.App.Storage.WindowsStorageDevHost.LoadDashboardUsageSummary());
    }

    internal void ApplyUsageSummary(OpenBurnBar.App.Presentation.Dashboard.DashboardUsageSummary summary)
    {
        if (!summary.HasData)
        {
            SpendTile.Value = "—";
            TokensTile.Value = "—";
            SessionsTile.Value = "—";
            return;
        }

        SpendTile.Value = $"${summary.SpendThisMonthUsd:0.##}";
        TokensTile.Value = FormatTokenCount(summary.TotalTokens);
        SessionsTile.Value = summary.SessionCount.ToString(System.Globalization.CultureInfo.InvariantCulture);
    }

    private static string FormatTokenCount(long tokens)
    {
        if (tokens >= 1_000_000)
        {
            return $"{tokens / 1_000_000.0:0.#}M";
        }

        if (tokens >= 1_000)
        {
            return $"{tokens / 1_000.0:0.#}K";
        }

        return tokens.ToString(System.Globalization.CultureInfo.InvariantCulture);
    }
}
