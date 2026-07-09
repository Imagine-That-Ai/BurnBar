using System;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OpenBurnBar.App.Configuration;
using OpenBurnBar.App.Presentation.Insights;
using OpenBurnBar.App.Presentation.Dashboard;

namespace OpenBurnBar.App.Insights;

/// <summary>
/// The Insights nav destination. Hosts the template gallery and, once a template is stamped,
/// the resulting canvas of widget tiles laid out on the 12-column <see cref="InsightsCanvasPanel"/>.
/// The Windows analog of the macOS <c>InsightsWorkspaceView</c> gallery → canvas flow.
/// </summary>
public sealed partial class InsightsPage : Page
{
    private readonly Lazy<DashboardUsageSummary> _dashboardSummary;

    public InsightsPage()
    {
        // Install before InitializeComponent(): the XAML tree constructs TemplateGalleryView,
        // and its constructor materializes InsightsBuiltInTemplates.All immediately.
        // Production default is honest empty data; sample series only when opt-in and no live data.
        InsightsBuiltInTemplates.SampleFallbackEnabled = RuntimeDataMode.SampleModeEnabled;
        _dashboardSummary = new Lazy<DashboardUsageSummary>(
            OpenBurnBar.App.Dashboard.DashboardUsageProvider.Load);
        InsightsBuiltInTemplates.RealDataResolver = (kind, seed) =>
            CloudSyncInsightSource.Resolve(kind, seed, _dashboardSummary.Value);

        InitializeComponent();
        GalleryView.TemplateSelected += OnTemplateSelected;
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
        // Sample chip only when sample payloads were actually installed — not when sample
        // mode is on but hybrid withheld fiction because live usage is present.
        SampleChip.Visibility = CloudSyncInsightSource.ShowsSamplePreviewChip(_dashboardSummary.Value)
            ? Visibility.Visible
            : Visibility.Collapsed;
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
