// PORTED from AgentLens/Views/Settings/Search/SettingsRouter.swift (@Observable SettingsRouter).
//
// Drives programmatic navigation inside Settings when the search bar is used:
//   1. User types into the search field — Query updates.
//   2. The detail pane swaps to the search results while IsSearching == true.
//   3. User taps a result → Navigate(item) selects the owning tab, sets Path to the
//      route's drill path, and primes PendingAnchor / PendingFocus / HighlightedAnchor.
//   4. The destination page detects a matching PendingAnchor, scrolls there, pulse-
//      highlights, and focuses the bound control if a FocusId was supplied.
//
// The Swift type is a SwiftUI @Observable @MainActor class; this is the portable
// INotifyPropertyChanged peer. The 1.4s highlight fade — Swift's
// DispatchQueue.main.asyncAfter — is delegated to an injectable IHighlightScheduler
// so the pure navigation logic stays deterministic under unit test (the default
// scheduler is a no-op; the WinUI shell injects a DispatcherQueue-backed one). The
// route→path decision (PathForRoute) is a pure static function with direct coverage.

using System.Collections.Generic;
using System.ComponentModel;
using System.Linq;
using System.Runtime.CompilerServices;

namespace OpenBurnBar.App.Settings;

/// <summary>Schedules the delayed highlight-fade. The WinUI shell backs this with a DispatcherQueue.</summary>
public interface IHighlightScheduler
{
    /// <summary>Invoke <paramref name="action"/> after <paramref name="seconds"/>.</summary>
    void Schedule(double seconds, Action action);
}

/// <summary>Deterministic default: never fires (tests observe the primed highlight state).</summary>
public sealed class NoopHighlightScheduler : IHighlightScheduler
{
    public static readonly NoopHighlightScheduler Instance = new();

    public void Schedule(double seconds, Action action) { }
}

/// <summary>Drives programmatic Settings navigation from search (Swift <c>SettingsRouter</c>).</summary>
public sealed class SettingsRouter : INotifyPropertyChanged
{
    /// <summary>Seconds the arrival highlight stays lit before fading (Swift's 1.4s).</summary>
    public const double HighlightFadeSeconds = 1.4;

    private readonly IHighlightScheduler _scheduler;

    private string _query = string.Empty;
    private SettingsTab? _selectedTab = SettingsTab.Home;
    private IReadOnlyList<SettingsPageRoute> _path = Array.Empty<SettingsPageRoute>();
    private string? _pendingAnchor;
    private string? _pendingFocus;
    private string? _highlightedAnchor;

    public SettingsRouter(IHighlightScheduler? scheduler = null)
    {
        _scheduler = scheduler ?? NoopHighlightScheduler.Instance;
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    /// <summary>Current search query. Empty string means "no search active".</summary>
    public string Query
    {
        get => _query;
        set => SetField(ref _query, value ?? string.Empty, nameof(Query), nameof(IsSearching));
    }

    /// <summary>Sidebar tab the detail pane is currently bound to.</summary>
    public SettingsTab? SelectedTab
    {
        get => _selectedTab;
        set => SetField(ref _selectedTab, value, nameof(SelectedTab));
    }

    /// <summary>Navigation path inside the detail stack (route values).</summary>
    public IReadOnlyList<SettingsPageRoute> Path
    {
        get => _path;
        private set => SetField(ref _path, value, nameof(Path));
    }

    /// <summary>Anchor id destination pages should scroll to once on appear.</summary>
    public string? PendingAnchor
    {
        get => _pendingAnchor;
        private set => SetField(ref _pendingAnchor, value, nameof(PendingAnchor));
    }

    /// <summary>Focus id destination pages should latch onto.</summary>
    public string? PendingFocus
    {
        get => _pendingFocus;
        private set => SetField(ref _pendingFocus, value, nameof(PendingFocus));
    }

    /// <summary>Anchor that should pulse-highlight on arrival (fades independently).</summary>
    public string? HighlightedAnchor
    {
        get => _highlightedAnchor;
        private set => SetField(ref _highlightedAnchor, value, nameof(HighlightedAnchor));
    }

    /// <summary><c>true</c> when the user is actively searching.</summary>
    public bool IsSearching => !string.IsNullOrWhiteSpace(_query);

    /// <summary>Ranked results for the current query (convenience used by the results view).</summary>
    public IReadOnlyList<SettingsItem> Results(IReadOnlyList<SettingsItem>? items = null) =>
        SettingsSearchEngine.Search(_query, items ?? SettingsManifest.All);

    /// <summary>
    /// Drive navigation to the chosen item. Safe to call repeatedly — it replaces any
    /// pending navigation state.
    /// </summary>
    public void Navigate(SettingsItem item)
    {
        SelectedTab = item.Tab;
        PendingAnchor = item.AnchorId;
        HighlightedAnchor = item.AnchorId;
        PendingFocus = item.FocusId;

        Path = PathForRoute(item.PageRoute);

        // Clear the query so the detail pane shows the destination, not the results.
        Query = string.Empty;

        // Fade the highlight after 1.4s (delegated so tests stay deterministic).
        ScheduleHighlightClear(item.AnchorId, HighlightFadeSeconds);
    }

    /// <summary>Reset all pending navigation state (search dismissed without a selection).</summary>
    public void Reset()
    {
        Query = string.Empty;
        PendingAnchor = null;
        PendingFocus = null;
        HighlightedAnchor = null;
        Path = Array.Empty<SettingsPageRoute>();
    }

    /// <summary>Destination pages call this once they've scrolled to the anchor.</summary>
    public void ConsumePendingAnchor(string anchor)
    {
        if (_pendingAnchor == anchor) PendingAnchor = null;
    }

    /// <summary>Destination pages call this once they've claimed the focus state.</summary>
    public void ConsumePendingFocus(string focus)
    {
        if (_pendingFocus == focus) PendingFocus = null;
    }

    /// <summary>
    /// Maps a page route to the navigation path the detail stack should hold. Many tabs
    /// land on their root (empty path); deep routes append the route. Pure + testable
    /// (Swift <c>pathForRoute</c>).
    /// </summary>
    public static IReadOnlyList<SettingsPageRoute> PathForRoute(SettingsPageRoute route) => route switch
    {
        // Home — the landing tab; no drill path.
        SettingsPageRoute.HomeRoot => Array.Empty<SettingsPageRoute>(),

        // General subpages drill from the General landing.
        SettingsPageRoute.GeneralRoot => Array.Empty<SettingsPageRoute>(),
        SettingsPageRoute.OperatorModel or SettingsPageRoute.Appearance or SettingsPageRoute.DefaultView
            or SettingsPageRoute.DataRefresh or SettingsPageRoute.Indexing
            or SettingsPageRoute.SessionSummaries => new[] { route },

        // Daemon subpages.
        SettingsPageRoute.DaemonRoot => Array.Empty<SettingsPageRoute>(),
        SettingsPageRoute.DaemonLifecycle or SettingsPageRoute.HttpGateway
            or SettingsPageRoute.ControllerRuntime => new[] { route },

        // Tabs whose root view *is* the destination.
        SettingsPageRoute.UpdatesRoot or SettingsPageRoute.AccountRoot or SettingsPageRoute.CloudRoot
            or SettingsPageRoute.AgentsRoot or SettingsPageRoute.AlertsRoot
            or SettingsPageRoute.NotificationsRoot or SettingsPageRoute.DevicesAndSyncRoot
            or SettingsPageRoute.TextExpansionRoot or SettingsPageRoute.MediaRoot
            or SettingsPageRoute.DataControlCenterRoot or SettingsPageRoute.ComputerUseRoot
            or SettingsPageRoute.PetsRoot => Array.Empty<SettingsPageRoute>(),

        // Agents sub-pages: single drill from the agents landing.
        SettingsPageRoute.AgentsAccounts or SettingsPageRoute.AgentsCLIs or SettingsPageRoute.AgentsRuntimes
            or SettingsPageRoute.AgentsModels or SettingsPageRoute.AgentsAdvanced => new[] { route },

        // Model Proxy — top-level tab, no drill path.
        SettingsPageRoute.ModelProxyRoot => Array.Empty<SettingsPageRoute>(),

        // The Elder Wand configurator + the standing Fusion Impact screen each drill
        // from the Agents landing into their own detail.
        SettingsPageRoute.AnalysisConfigurator or SettingsPageRoute.FusionImpact => new[] { route },

        // Legacy roots: forward into the merged Agents tab (land on the Agents landing).
        SettingsPageRoute.ConnectionsRoot or SettingsPageRoute.ProvidersRoot
            or SettingsPageRoute.RoutingPoolsRoot or SettingsPageRoute.SwitcherRoot
            or SettingsPageRoute.HermesRoot => Array.Empty<SettingsPageRoute>(),

        // Legacy Hermes detail routes: drill into Agents → Advanced or Agents → Runtimes.
        SettingsPageRoute.HermesChatEngines => new[] { SettingsPageRoute.AgentsAdvanced },
        SettingsPageRoute.HermesGateway or SettingsPageRoute.HermesPiAgent
            or SettingsPageRoute.HermesRelay or SettingsPageRoute.HermesPiRelay =>
                new[] { SettingsPageRoute.AgentsRuntimes },

        _ => Array.Empty<SettingsPageRoute>(),
    };

    private void ScheduleHighlightClear(string anchor, double seconds)
    {
        var target = anchor;
        _scheduler.Schedule(seconds, () =>
        {
            if (_highlightedAnchor == target) HighlightedAnchor = null;
        });
    }

    private void SetField<T>(ref T field, T value, params string[] propertyNames)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return;
        field = value;
        foreach (var name in propertyNames)
        {
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
        }
    }
}
