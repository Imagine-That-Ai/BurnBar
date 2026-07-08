using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OpenBurnBar.App.Presentation.SessionLogs;

namespace OpenBurnBar.App.SessionLogs;

/// <summary>
/// Picks the transcript row template by <see cref="TranscriptBlockKind"/> — the Windows
/// analog of the Swift detail pane's per-kind block views (user bubble, assistant prose,
/// code block, tool-use chip, separator). Templates are supplied by the detail pane XAML.
/// </summary>
public sealed partial class TranscriptBlockTemplateSelector : DataTemplateSelector
{
    public DataTemplate? UserTemplate { get; set; }

    public DataTemplate? AssistantTemplate { get; set; }

    public DataTemplate? CodeTemplate { get; set; }

    public DataTemplate? ToolTemplate { get; set; }

    public DataTemplate? SeparatorTemplate { get; set; }

    protected override DataTemplate? SelectTemplateCore(object item)
    {
        return item is TranscriptBlock block
            ? block.Kind switch
            {
                TranscriptBlockKind.UserMessage => UserTemplate,
                TranscriptBlockKind.AssistantMessage => AssistantTemplate,
                TranscriptBlockKind.CodeBlock => CodeTemplate,
                TranscriptBlockKind.ToolUse => ToolTemplate,
                TranscriptBlockKind.Separator => SeparatorTemplate,
                _ => AssistantTemplate,
            }
            : AssistantTemplate;
    }

    protected override DataTemplate? SelectTemplateCore(object item, DependencyObject container) =>
        SelectTemplateCore(item);
}
