namespace OpenBurnBar.App.Shell;

/// <summary>What a Command Palette row represents.</summary>
public enum PaletteItemKind
{
    /// <summary>"Go to" a top-level surface (a <see cref="NavDestination"/>).</summary>
    Section,

    /// <summary>Jump to a tracked session.</summary>
    Session,
}

/// <summary>
/// One row in the Command Palette — the Windows analog of a <c>CommandDeckPalette</c> result
/// (<c>AgentLens/Views/Dashboard/Components/CommandDeckPalette.swift</c>). Sections navigate the
/// shell frame; sessions navigate through the encrypted local session-log index.
/// </summary>
public sealed class CommandPaletteItem
{
    public CommandPaletteItem(
        PaletteItemKind kind,
        string glyph,
        string title,
        string subtitle,
        string destinationKey,
        string? shortcut = null)
    {
        Kind = kind;
        Glyph = glyph;
        Title = title;
        Subtitle = subtitle;
        DestinationKey = destinationKey;
        Shortcut = shortcut;
    }

    public PaletteItemKind Kind { get; }

    /// <summary>Segoe MDL2 Assets glyph.</summary>
    public string Glyph { get; }

    public string Title { get; }

    public string Subtitle { get; }

    /// <summary>The <see cref="NavDestination.Key"/> to navigate to when activated.</summary>
    public string DestinationKey { get; }

    /// <summary>Optional keyboard-shortcut hint (e.g. "Ctrl 1"); shown right-aligned.</summary>
    public string? Shortcut { get; }

    /// <summary>Whether the shortcut hint should render.</summary>
    public bool HasShortcut => !string.IsNullOrEmpty(Shortcut);

    /// <summary>Visibility of the shortcut hint (x:Bind has no implicit bool→Visibility coercion).</summary>
    public Microsoft.UI.Xaml.Visibility ShortcutVisibility =>
        HasShortcut ? Microsoft.UI.Xaml.Visibility.Visible : Microsoft.UI.Xaml.Visibility.Collapsed;
}
