// The navigation parameter passed to every Settings leaf page + the search results
// page. It carries the shared SettingsRouter (so a page can consume a pending anchor
// on Loaded, mirroring how the macOS destination view inspects router.pendingAnchor),
// the tab a placeholder should describe, and the callback the results list invokes
// when a match is chosen.

using OpenBurnBar.App.Settings;

namespace OpenBurnBar.App.Settings.Winui;

/// <summary>Navigation payload shared by the Settings shell and its hosted pages.</summary>
public sealed class SettingsPageContext
{
    public SettingsPageContext(SettingsRouter router, SettingsTab tab, Action<SettingsItem>? onResultChosen = null)
    {
        Router = router;
        Tab = tab;
        OnResultChosen = onResultChosen;
    }

    /// <summary>The shell's single router — source of the pending anchor/focus a page consumes.</summary>
    public SettingsRouter Router { get; }

    /// <summary>The tab whose landing/placeholder is being shown.</summary>
    public SettingsTab Tab { get; }

    /// <summary>Invoked by the results list when the user picks a match.</summary>
    public Action<SettingsItem>? OnResultChosen { get; }
}
