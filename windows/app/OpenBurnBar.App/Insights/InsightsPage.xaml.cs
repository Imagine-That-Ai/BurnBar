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

        // Wire real-or-empty KPI data from the SQLCipher DB path; non-KPI template samples remain
        // visibly labeled by the SampleChip until the Engine analysis source is configured.
        InsightsBuiltInTemplates.RealDataResolver = (kind, seed) =>
            kind == InsightWidgetKind.KpiTile ? CloudSyncInsightSource.ResolveKpi(kind, seed) : null;
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
