// PORTED 1:1 from AgentLens/Views/Settings/Search/SettingsItem.swift (struct SettingsItem).
//
// A single indexable control inside the Settings hierarchy. Hand-authored entries
// live in SettingsManifest. Each item points to a Tab (which sidebar selection owns
// it), a PageRoute (which detail screen drills to it), an AnchorId (a stable string
// keyed on a FrameworkElement so the destination page can scroll it into view), and
// an optional FocusId (used by detail pages to focus a TextBox/stepper on appear).
//
// Keywords are the synonym net — what users type when they don't know the exact
// label. HelpText is opt-in long-form context indexed at the lowest weight. Title
// carries the most weight; see SettingsSearchEngine.

using System.Collections.Generic;
using System.Linq;

namespace OpenBurnBar.App.Settings;

/// <summary>A single indexable control inside the Settings hierarchy (Swift <c>SettingsItem</c>).</summary>
public sealed class SettingsItem : IEquatable<SettingsItem>
{
    /// <summary>Stable, unique id — typed-string form (e.g. <c>general.appearance.theme</c>).</summary>
    public string Id { get; }

    /// <summary>Sidebar tab that owns this item.</summary>
    public SettingsTab Tab { get; }

    /// <summary>Page-level route the destination inspects to decide whether to scroll.</summary>
    public SettingsPageRoute PageRoute { get; }

    /// <summary>Anchor target used by the destination page's scroller.</summary>
    public string AnchorId { get; }

    /// <summary>Optional focus target for text fields, steppers, secure fields, etc.</summary>
    public string? FocusId { get; }

    /// <summary>Primary label as seen in the UI.</summary>
    public string Title { get; }

    /// <summary>Optional descriptive line shown under <see cref="Title"/>.</summary>
    public string? Subtitle { get; }

    /// <summary>Synonyms / alternates users might type.</summary>
    public IReadOnlyList<string> Keywords { get; }

    /// <summary>Long-form help indexed at the lowest weight.</summary>
    public string? HelpText { get; }

    /// <summary>Provider logos that should visually identify this row in results.</summary>
    public IReadOnlyList<AgentProvider> LogoProviders { get; }

    public SettingsItem(
        string id,
        SettingsTab tab,
        SettingsPageRoute pageRoute,
        string anchorId,
        string title,
        string? focusId = null,
        string? subtitle = null,
        IReadOnlyList<string>? keywords = null,
        string? helpText = null,
        IReadOnlyList<AgentProvider>? logoProviders = null)
    {
        Id = id;
        Tab = tab;
        PageRoute = pageRoute;
        AnchorId = anchorId;
        FocusId = focusId;
        Title = title;
        Subtitle = subtitle;
        Keywords = keywords ?? Array.Empty<string>();
        HelpText = helpText;
        LogoProviders = logoProviders ?? Array.Empty<AgentProvider>();
    }

    // Swift `SettingsItem` is Identifiable + Hashable; identity is the stable `id`.
    public bool Equals(SettingsItem? other) => other is not null && Id == other.Id;

    public override bool Equals(object? obj) => obj is SettingsItem other && Equals(other);

    public override int GetHashCode() => Id.GetHashCode();

    public override string ToString() => $"SettingsItem({Id})";
}
