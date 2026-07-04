using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OpenBurnBar.App.Presentation.Insights;

namespace OpenBurnBar.App.Insights;

/// <summary>
/// The Insights nav destination. Hosts the template gallery and, once a template is stamped,
/// the resulting canvas of widget tiles laid out on the 12-column <see cref="InsightsCanvasPanel"/>.
/// The Windows analog of the macOS <c>InsightsWorkspaceView</c> gallery → canvas flow.
/// </summary>
public sealed partial class InsightsPage : Page
{
    public InsightsPage()
    {
        InitializeComponent();
        GalleryView.TemplateSelected += OnTemplateSelected;

        // Wire real KPI data from the SQLCipher DB when configured.
        // Complex widgets (narratives, recommendations, forecasts) still use
        // InsightSampleData — they need the Engine's LLM analysis (C-ABI follow-up).
        InsightsBuiltInTemplates.RealDataResolver = (kind, seed) =>
        {
            if (kind != InsightWidgetKind.KpiTile)
                return null; // Only KPI tiles have real data from the DB.

            var summary = OpenBurnBar.App.Storage.WindowsStorageDevHost.LoadDashboardUsageSummary();
            if (!summary.HasData)
                return null; // No DB configured — use sample data.

            return seed switch
            {
                1 => InsightWidgetData.Kpi(
                    value: summary.TotalSpend.ToString("F2"),
                    label: "Cost (this month)",
                    subtext: $"${summary.TotalSpend:F2} spent",
                    trend: null),
                2 => InsightWidgetData.Kpi(
                    value: summary.SessionCount.ToString(),
                    label: "Sessions",
                    subtext: $"{summary.SessionCount} sessions",
                    trend: null),
                4 => InsightWidgetData.Kpi(
                    value: summary.TotalTokens.ToString("N0"),
                    label: "Tokens",
                    subtext: $"{summary.TotalTokens:N0} tokens",
                    trend: null),
                _ => null,
            };
        };
    }

    private void OnTemplateSelected(object? sender, InsightCanvasTemplate template)
        => ShowCanvas(template.Instantiate());

    private void ShowCanvas(InsightCanvas canvas)
    {
        HeaderTitle.Text = canvas.Title;
        CanvasPanel.Children.Clear();
        CanvasPanel.ColumnCount = canvas.Layout.ColumnCount;
        CanvasPanel.RowHeight = canvas.Layout.RowHeight;
        CanvasPanel.Gap = canvas.Layout.Gap;

        foreach (InsightWidget widget in canvas.Widgets)
        {
            if (!canvas.Layout.Placements.TryGetValue(widget.Id, out CellPlacement? placement))
            {
                continue;
            }

            var tile = new InsightWidgetTile();
            tile.SetWidget(widget, canvas.Theme);
            InsightsCanvasPanel.SetColumn(tile, placement.Column);
            InsightsCanvasPanel.SetRow(tile, placement.Row);
            InsightsCanvasPanel.SetColSpan(tile, placement.ColSpan);
            InsightsCanvasPanel.SetRowSpan(tile, placement.RowSpan);
            CanvasPanel.Children.Add(tile);
        }

        GalleryView.Visibility = Visibility.Collapsed;
        CanvasScroller.Visibility = Visibility.Visible;
        BackButton.Visibility = Visibility.Visible;
        SampleChip.Visibility = Visibility.Visible;
    }

    private void OnBackClick(object sender, RoutedEventArgs e)
    {
        CanvasPanel.Children.Clear();
        HeaderTitle.Text = "Insights";
        GalleryView.Visibility = Visibility.Visible;
        CanvasScroller.Visibility = Visibility.Collapsed;
        BackButton.Visibility = Visibility.Collapsed;
        SampleChip.Visibility = Visibility.Collapsed;
    }
}
