using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace OpenBurnBar.App.Chat;

/// <summary>
/// Picks the user vs assistant bubble template for the messages ItemsRepeater —
/// the Windows analog of the macOS ChatMessagesStream branching on message role.
/// </summary>
public sealed partial class ChatMessageTemplateSelector : DataTemplateSelector
{
    public DataTemplate? User { get; set; }

    public DataTemplate? Assistant { get; set; }

    protected override DataTemplate? SelectTemplateCore(object item) =>
        item is ChatMessageViewModel { IsUser: true } ? User : Assistant;

    protected override DataTemplate? SelectTemplateCore(object item, DependencyObject container) =>
        SelectTemplateCore(item);
}

/// <summary>
/// Picks the prose (Pretext-measured bubble) vs tool-group (accordion) template
/// for a message's rows — the atom-router's per-row template dispatch, the
/// Windows analog of the macOS TranscriptGroup rendering switch.
/// </summary>
public sealed partial class ChatRowTemplateSelector : DataTemplateSelector
{
    public DataTemplate? Prose { get; set; }

    public DataTemplate? Tool { get; set; }

    protected override DataTemplate? SelectTemplateCore(object item) =>
        item is ChatToolRow ? Tool : Prose;

    protected override DataTemplate? SelectTemplateCore(object item, DependencyObject container) =>
        SelectTemplateCore(item);
}
