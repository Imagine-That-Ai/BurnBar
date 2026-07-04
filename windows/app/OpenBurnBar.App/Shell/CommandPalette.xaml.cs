using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
using Microsoft.UI.Xaml.Controls;
using Windows.System;

namespace OpenBurnBar.App.Shell;

/// <summary>
/// The Ctrl+K Command Palette. Ports the behavior of <c>CommandDeckPalette.swift</c>: a search
/// box unifying section navigation ("Go to") with session jumps, keyboard-first (Up/Down/Enter,
/// Esc to dismiss), and case-insensitive substring + subsequence matching.
///
/// Sessions are stub data here; wiring the real search results is deferred to the storage read
/// seam (#1198). The chosen destination is exposed via <see cref="ChosenDestinationKey"/> so the
/// caller can drive <c>AppShell.Navigate</c> after <c>ShowAsync</c> completes.
/// </summary>
public sealed partial class CommandPalette : ContentDialog
{
    private readonly ObservableCollection<CommandPaletteItem> _results = new();
    private readonly IReadOnlyList<CommandPaletteItem> _sections;
    private readonly IReadOnlyList<CommandPaletteItem> _recentSessions;

    public CommandPalette()
    {
        InitializeComponent();

        _sections = BuildSections();
        _recentSessions = BuildRecentSessionsStub();

        ResultsList.ItemsSource = _results;
        Rebuild(string.Empty);

        Opened += (_, _) => QueryBox.Focus(Microsoft.UI.Xaml.FocusState.Programmatic);
    }

    /// <summary>The destination key the user activated, or <c>null</c> if the palette was dismissed.</summary>
    public string? ChosenDestinationKey { get; private set; }

    private static IReadOnlyList<CommandPaletteItem> BuildSections()
    {
        var items = new List<CommandPaletteItem>();
        var shortcutIndex = 1;
        foreach (var destination in NavCatalog.All)
        {
            // Mirror the macOS Cmd-1..9 primary shortcuts (here Ctrl 1..9 for the menu items).
            string? shortcut = null;
            if (!destination.IsFooter && shortcutIndex <= 9)
            {
                shortcut = $"Ctrl {shortcutIndex}";
                shortcutIndex++;
            }

            items.Add(new CommandPaletteItem(
                PaletteItemKind.Section,
                destination.Glyph,
                destination.Title,
                destination.Subtitle,
                destination.Key,
                shortcut));
        }

        // Auxiliary (non-sidebar) surfaces — e.g. Elder Wand / "Analysis Models". They carry no
        // Ctrl 1..9 shortcut (those mirror the 12 sidebar rows) but stay reachable via search, the
        // Windows interim for the macOS gated Settings-leaf / chat-header entry.
        foreach (var destination in NavCatalog.Auxiliary)
        {
            items.Add(new CommandPaletteItem(
                PaletteItemKind.Section,
                destination.Glyph,
                destination.Title,
                destination.Subtitle,
                destination.Key,
                shortcut: null));
        }

        return items;
    }

    private static IReadOnlyList<CommandPaletteItem> BuildRecentSessionsStub()
    {
        // Stub recents until the search/storage read seam (#1198) is consumed. Activating one
        // jumps to Session Logs — the real target once session records are wired.
        const string sessionGlyph = "\uE8BD"; // Message
        return new List<CommandPaletteItem>
        {
            new(PaletteItemKind.Session, sessionGlyph, "Windows port — W6 shell", "Claude Code · windows-port", "sessionLogs"),
            new(PaletteItemKind.Session, sessionGlyph, "Refactor auth flow", "Codex · burnbar", "sessionLogs"),
            new(PaletteItemKind.Session, sessionGlyph, "Quota sync repair", "Claude Code · burnbar", "sessionLogs"),
        };
    }

    private void QueryBox_TextChanged(object sender, TextChangedEventArgs e) => Rebuild(QueryBox.Text);

    private void Rebuild(string rawQuery)
    {
        var query = rawQuery.Trim();
        _results.Clear();

        foreach (var item in FilterSections(query))
        {
            _results.Add(item);
        }

        foreach (var item in FilterSessions(query))
        {
            _results.Add(item);
        }

        if (_results.Count > 0)
        {
            ResultsList.SelectedIndex = 0;
        }
    }

    private IEnumerable<CommandPaletteItem> FilterSections(string query)
    {
        if (string.IsNullOrEmpty(query))
        {
            return _sections;
        }

        var q = query.ToLowerInvariant();
        return _sections.Where(item =>
        {
            var title = item.Title.ToLowerInvariant();
            var subtitle = item.Subtitle.ToLowerInvariant();
            return title.Contains(q) || subtitle.Contains(q) || MatchesSubsequence(q, title);
        });
    }

    private IEnumerable<CommandPaletteItem> FilterSessions(string query)
    {
        if (string.IsNullOrEmpty(query))
        {
            return _recentSessions;
        }

        var q = query.ToLowerInvariant();
        return _recentSessions.Where(item =>
            item.Title.ToLowerInvariant().Contains(q) ||
            item.Subtitle.ToLowerInvariant().Contains(q));
    }

    private void QueryBox_KeyDown(object sender, Microsoft.UI.Xaml.Input.KeyRoutedEventArgs e)
    {
        switch (e.Key)
        {
            case VirtualKey.Down:
                MoveSelection(1);
                e.Handled = true;
                break;
            case VirtualKey.Up:
                MoveSelection(-1);
                e.Handled = true;
                break;
            case VirtualKey.Enter:
                ActivateSelected();
                e.Handled = true;
                break;
        }
    }

    private void MoveSelection(int delta)
    {
        var count = _results.Count;
        if (count == 0)
        {
            return;
        }

        var next = ResultsList.SelectedIndex + delta;
        next = System.Math.Max(0, System.Math.Min(count - 1, next));
        ResultsList.SelectedIndex = next;
        ResultsList.ScrollIntoView(_results[next]);
    }

    private void ActivateSelected()
    {
        if (ResultsList.SelectedItem is CommandPaletteItem item)
        {
            Activate(item);
        }
    }

    private void ResultsList_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is CommandPaletteItem item)
        {
            Activate(item);
        }
    }

    private void Activate(CommandPaletteItem item)
    {
        ChosenDestinationKey = item.DestinationKey;
        Hide();
    }

    /// <summary>Case-insensitive fuzzy subsequence match (ports the macOS palette helper).</summary>
    private static bool MatchesSubsequence(string pattern, string text)
    {
        var pi = 0;
        var ti = 0;
        while (pi < pattern.Length && ti < text.Length)
        {
            if (pattern[pi] == text[ti])
            {
                pi++;
            }

            ti++;
        }

        return pi == pattern.Length;
    }
}
