using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;

namespace OpenBurnBar.App.Shell;

/// <summary>
/// A reorderable card in the tray flyout — a compact "at a glance" module (Quota, Budget,
/// Missions, Recent Sessions). Content is stubbed until the real surfaces land; the value here
/// is the resizable + user-reorderable flyout shell itself (Phase 3 W6-SHELL item b).
/// </summary>
public sealed class FlyoutModule
{
    public FlyoutModule(string key, string title, string subtitle, string glyph)
    {
        Key = key;
        Title = title;
        Subtitle = subtitle;
        Glyph = glyph;
    }

    public string Key { get; }

    public string Title { get; }

    public string Subtitle { get; }

    /// <summary>Segoe MDL2 Assets glyph.</summary>
    public string Glyph { get; }
}

/// <summary>
/// Backs the flyout's reorderable module list. Seeds a default catalog, applies any saved
/// order from <see cref="AppStatePersistence"/>, and persists the order after a user drag.
/// </summary>
public sealed class FlyoutViewModel
{
    private readonly AppStatePersistence _persistence;

    public FlyoutViewModel(AppStatePersistence persistence)
    {
        _persistence = persistence;
        Modules = new ObservableCollection<FlyoutModule>(OrderedCatalog(persistence.State.FlyoutModuleOrder));
    }

    /// <summary>The modules in their current (possibly user-reordered) order.</summary>
    public ObservableCollection<FlyoutModule> Modules { get; }

    /// <summary>Persist the current module order so the flyout restores it next launch.</summary>
    public void PersistOrder()
    {
        _persistence.State.FlyoutModuleOrder = Modules.Select(m => m.Key).ToList();
        _persistence.Save();
    }

    private static IReadOnlyList<FlyoutModule> Catalog() => new List<FlyoutModule>
    {
        new("quota", "Quota", "Subscriptions near their limit", "\uE9D9"),
        new("budget", "Budget", "Spend against today's cap", "\uE8C7"),
        new("missions", "Missions", "Active runs & tasks", "\uE7C1"),
        new("recents", "Recent sessions", "Jump back into a conversation", "\uE81C"),
    };

    private static IEnumerable<FlyoutModule> OrderedCatalog(IReadOnlyList<string>? savedOrder)
    {
        var catalog = Catalog();
        if (savedOrder is null || savedOrder.Count == 0)
        {
            return catalog;
        }

        var byKey = catalog.ToDictionary(m => m.Key, StringComparer.Ordinal);
        var ordered = new List<FlyoutModule>();

        // Saved keys first (in saved order), then any new catalog modules not yet persisted.
        foreach (var key in savedOrder)
        {
            if (byKey.TryGetValue(key, out var module))
            {
                ordered.Add(module);
                byKey.Remove(key);
            }
        }

        ordered.AddRange(catalog.Where(m => byKey.ContainsKey(m.Key)));
        return ordered;
    }
}
