using System;
using Microsoft.UI.Xaml.Controls;
using OpenBurnBar.App.Presentation.Insights;

namespace OpenBurnBar.App.Insights;

/// <summary>
/// The Insights template gallery. Lists the eight built-in templates and raises
/// <see cref="TemplateSelected"/> when the user picks one. The Windows analog of
/// <c>InsightsTemplateGalleryView</c>.
/// </summary>
public sealed partial class TemplateGalleryView : UserControl
{
    public TemplateGalleryView()
    {
        InitializeComponent();
        ReloadTemplates();
    }

    /// <summary>Raised with the chosen template when a gallery card is clicked.</summary>
    public event EventHandler<InsightCanvasTemplate>? TemplateSelected;

    /// <summary>
    /// Rebind the gallery to the current <see cref="InsightsBuiltInTemplates.All"/> snapshot
    /// (call after production composition reinstall so cards match live usage mode).
    /// </summary>
    public void ReloadTemplates()
    {
        Gallery.ItemsSource = null;
        Gallery.ItemsSource = InsightsBuiltInTemplates.All;
    }

    private void OnTemplateClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is InsightCanvasTemplate template)
        {
            TemplateSelected?.Invoke(this, template);
        }
    }
}
