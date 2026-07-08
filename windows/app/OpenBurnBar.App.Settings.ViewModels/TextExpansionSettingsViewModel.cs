// View-model for the Text Expansion settings tab.
//
// Faithful port of AgentLens/Views/Settings/TextExpansionSettingsView.swift + the
// backing TextExpansionSettings store. Reuses the portable TextExpansion core
// (windows/app/OpenBurnBar.App.TextExpansion): TextExpansionSnippet, TextExpansionMode,
// TextExpansionTrigger (the &&-prefix / min-2 / max-64 / [a-z0-9_-] validator).
//
// Runtime toggles (defaults from TextExpansionSettings):
//   inAppExpansionEnabled       = true
//   macGlobalExpansionEnabled   = false  (requires accessibility)
//   llmRewritePreviewEnabled    = true
//   exportKeyboardSnapshotEnabled = true
//   cloudSyncEnabled            = true
// Editor validation (Swift view): triggerError (nil when empty) + duplicateTriggerError
// ("Trigger already exists.") + canSave (no errors AND non-empty title/trigger/body).

using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
using OpenBurnBar.App.TextExpansion;

namespace OpenBurnBar.App.Settings.ViewModels;

/// <summary>The five persisted runtime toggles (TextExpansionSettings).</summary>
public sealed record TextExpansionRuntimeSettings(
    bool InAppEnabled,
    bool MacGlobalEnabled,
    bool LlmPreviewEnabled,
    bool ExportSnapshotEnabled,
    bool CloudSyncEnabled)
{
    /// <summary>The macOS defaults.</summary>
    public static readonly TextExpansionRuntimeSettings Default = new(
        InAppEnabled: true,
        MacGlobalEnabled: false,
        LlmPreviewEnabled: true,
        ExportSnapshotEnabled: true,
        CloudSyncEnabled: true);
}

/// <summary>Full CRUD over the snippet catalog + the runtime toggles (WinUI: SQLCipher-backed).</summary>
public interface ITextExpansionSettingsStore
{
    /// <summary>All non-deleted snippets.</summary>
    IReadOnlyList<TextExpansionSnippet> LoadSnippets();

    /// <summary>Insert or update a snippet.</summary>
    void Upsert(TextExpansionSnippet snippet);

    /// <summary>Soft-delete the snippet with <paramref name="id"/> at <paramref name="at"/>.</summary>
    void Delete(string id, DateTimeOffset at);

    /// <summary>Read the runtime toggles.</summary>
    TextExpansionRuntimeSettings LoadRuntime();

    /// <summary>Persist the runtime toggles.</summary>
    void SaveRuntime(TextExpansionRuntimeSettings settings);
}

/// <summary>In-memory snippet + toggle store (default for tests).</summary>
public sealed class InMemoryTextExpansionSettingsStore : ITextExpansionSettingsStore
{
    private readonly Dictionary<string, TextExpansionSnippet> _snippets = new(StringComparer.Ordinal);
    private TextExpansionRuntimeSettings _runtime;

    public InMemoryTextExpansionSettingsStore(
        IEnumerable<TextExpansionSnippet>? seed = null,
        TextExpansionRuntimeSettings? runtime = null)
    {
        _runtime = runtime ?? TextExpansionRuntimeSettings.Default;
        if (seed is not null)
        {
            foreach (var snippet in seed)
            {
                _snippets[snippet.Id] = snippet;
            }
        }
    }

    /// <inheritdoc />
    public IReadOnlyList<TextExpansionSnippet> LoadSnippets() =>
        _snippets.Values.Where(s => s.DeletedAt is null).ToArray();

    /// <inheritdoc />
    public void Upsert(TextExpansionSnippet snippet) => _snippets[snippet.Id] = snippet;

    /// <inheritdoc />
    public void Delete(string id, DateTimeOffset at)
    {
        if (_snippets.TryGetValue(id, out var snippet))
        {
            _snippets[id] = snippet.With(deletedAt: new Optional<DateTimeOffset?>(at), updatedAt: at);
        }
    }

    /// <inheritdoc />
    public TextExpansionRuntimeSettings LoadRuntime() => _runtime;

    /// <inheritdoc />
    public void SaveRuntime(TextExpansionRuntimeSettings settings) => _runtime = settings;
}

/// <summary>Backs the Text Expansion tab (snippet editor + expansion-runtime toggles).</summary>
public sealed class TextExpansionSettingsViewModel : ObservableSettingsViewModel
{
    private readonly ITextExpansionSettingsStore _store;
    private readonly IAccessibilityProbe _accessibility;
    private readonly Func<DateTimeOffset> _now;
    private readonly Func<string> _idFactory;

    private TextExpansionRuntimeSettings _runtime = TextExpansionRuntimeSettings.Default;
    private IReadOnlyList<TextExpansionSnippet> _snippets = Array.Empty<TextExpansionSnippet>();

    private string? _selectedId;
    private string _draftTitle = string.Empty;
    private string _draftTrigger = string.Empty;
    private string _draftBody = string.Empty;
    private TextExpansionMode _draftMode = TextExpansionMode.StaticText;
    private bool _draftIsEnabled = true;
    private string _searchQuery = string.Empty;

    public TextExpansionSettingsViewModel(
        ITextExpansionSettingsStore? store = null,
        IAccessibilityProbe? accessibility = null,
        Func<DateTimeOffset>? now = null,
        Func<string>? idFactory = null)
    {
        _store = store ?? new InMemoryTextExpansionSettingsStore();
        _accessibility = accessibility ?? new StaticAccessibilityProbe(false);
        _now = now ?? (() => DateTimeOffset.UtcNow);
        _idFactory = idFactory ?? (() => Guid.NewGuid().ToString());
        Load();
    }

    /// <summary>The visible snippet rows (filtered by <see cref="SearchQuery"/>).</summary>
    public ObservableCollection<TextExpansionSnippet> Snippets { get; } = new();

    /// <summary>Total non-deleted snippet count.</summary>
    public int SnippetCount => _snippets.Count;

    /// <summary>Load snippets + runtime toggles from the store.</summary>
    public void Load()
    {
        _runtime = _store.LoadRuntime();
        _snippets = _store.LoadSnippets()
            .OrderBy(s => s.Title, StringComparer.CurrentCultureIgnoreCase)
            .ToArray();
        RebuildVisible();
        RaiseRuntime();
        OnPropertyChanged(nameof(SnippetCount));
    }

    // ── Runtime toggles ───────────────────────────────────────────────────────

    /// <summary>Expand snippets inside OpenBurnBar's own text surfaces.</summary>
    public bool InAppEnabled
    {
        get => _runtime.InAppEnabled;
        set { if (value != _runtime.InAppEnabled) { _runtime = _runtime with { InAppEnabled = value }; PersistRuntime(); OnPropertyChanged(); } }
    }

    /// <summary>Expand snippets system-wide (requires accessibility).</summary>
    public bool MacGlobalEnabled
    {
        get => _runtime.MacGlobalEnabled;
        set
        {
            if (value != _runtime.MacGlobalEnabled)
            {
                _runtime = _runtime with { MacGlobalEnabled = value };
                PersistRuntime();
                OnPropertyChanged();
                OnPropertyChanged(nameof(MacGlobalBlocked));
                OnPropertyChanged(nameof(MacGlobalBlockedMessage));
            }
        }
    }

    /// <summary>Whether global expansion is on but the accessibility grant is missing.</summary>
    public bool MacGlobalBlocked => _runtime.MacGlobalEnabled && !_accessibility.IsAccessibilityTrusted;

    /// <summary>The nudge shown when <see cref="MacGlobalBlocked"/> is true.</summary>
    public string? MacGlobalBlockedMessage =>
        MacGlobalBlocked ? "Grant accessibility access to enable system-wide expansion." : null;

    /// <summary>Show an LLM-rewrite preview before committing an expansion.</summary>
    public bool LlmPreviewEnabled
    {
        get => _runtime.LlmPreviewEnabled;
        set { if (value != _runtime.LlmPreviewEnabled) { _runtime = _runtime with { LlmPreviewEnabled = value }; PersistRuntime(); OnPropertyChanged(); } }
    }

    /// <summary>Export a keyboard snapshot for iOS/Android keyboard sync.</summary>
    public bool ExportSnapshotEnabled
    {
        get => _runtime.ExportSnapshotEnabled;
        set { if (value != _runtime.ExportSnapshotEnabled) { _runtime = _runtime with { ExportSnapshotEnabled = value }; PersistRuntime(); OnPropertyChanged(); } }
    }

    /// <summary>Sync snippets across devices through the cloud.</summary>
    public bool CloudSyncEnabled
    {
        get => _runtime.CloudSyncEnabled;
        set { if (value != _runtime.CloudSyncEnabled) { _runtime = _runtime with { CloudSyncEnabled = value }; PersistRuntime(); OnPropertyChanged(); } }
    }

    // ── Editor draft ──────────────────────────────────────────────────────────

    /// <summary>Id of the snippet being edited; <c>null</c> for a new draft.</summary>
    public string? SelectedId
    {
        get => _selectedId;
        private set { if (Set(ref _selectedId, value)) { OnPropertyChanged(nameof(IsEditingExisting)); } }
    }

    /// <summary>Whether the draft edits an existing snippet (vs. a new one).</summary>
    public bool IsEditingExisting => _selectedId is not null;

    /// <summary>Draft title.</summary>
    public string DraftTitle
    {
        get => _draftTitle;
        set { if (Set(ref _draftTitle, value ?? string.Empty)) { RaiseValidation(); } }
    }

    /// <summary>Draft trigger (without the <c>&amp;&amp;</c> prefix).</summary>
    public string DraftTrigger
    {
        get => _draftTrigger;
        set { if (Set(ref _draftTrigger, value ?? string.Empty)) { RaiseValidation(); } }
    }

    /// <summary>Draft body.</summary>
    public string DraftBody
    {
        get => _draftBody;
        set { if (Set(ref _draftBody, value ?? string.Empty)) { RaiseValidation(); } }
    }

    /// <summary>Draft expansion mode.</summary>
    public TextExpansionMode DraftMode
    {
        get => _draftMode;
        set => Set(ref _draftMode, value);
    }

    /// <summary>Whether the draft snippet is enabled.</summary>
    public bool DraftIsEnabled
    {
        get => _draftIsEnabled;
        set => Set(ref _draftIsEnabled, value);
    }

    /// <summary>Live search filter over the snippet list.</summary>
    public string SearchQuery
    {
        get => _searchQuery;
        set { if (Set(ref _searchQuery, value ?? string.Empty)) { RebuildVisible(); } }
    }

    // ── Validation ────────────────────────────────────────────────────────────

    /// <summary>
    /// Trigger validation error (min 2 / max 64 / lowercase alnum + <c>-_</c>). Null when the
    /// trigger is empty (Swift <c>triggerError</c> returns nil for an empty field).
    /// </summary>
    public string? TriggerError =>
        string.IsNullOrEmpty(_draftTrigger) ? null : TextExpansionTrigger.ValidationError(_draftTrigger);

    /// <summary>"Trigger already exists." when another active snippet shares the canonical trigger.</summary>
    public string? DuplicateTriggerError
    {
        get
        {
            if (string.IsNullOrEmpty(_draftTrigger))
            {
                return null;
            }

            var canonical = TextExpansionTrigger.CanonicalName(_draftTrigger);
            bool clash = _snippets.Any(s =>
                s.Id != _selectedId &&
                s.DeletedAt is null &&
                string.Equals(s.Trigger, canonical, StringComparison.Ordinal));
            return clash ? "Trigger already exists." : null;
        }
    }

    /// <summary>Whether the draft can be saved (Swift <c>canSave</c>).</summary>
    public bool CanSave =>
        TriggerError is null &&
        DuplicateTriggerError is null &&
        !string.IsNullOrWhiteSpace(_draftTitle) &&
        !string.IsNullOrWhiteSpace(_draftTrigger) &&
        !string.IsNullOrWhiteSpace(_draftBody);

    // ── Actions ───────────────────────────────────────────────────────────────

    /// <summary>Reset the editor to a fresh draft (Swift <c>createDraft</c>).</summary>
    public void CreateDraft()
    {
        SelectedId = null;
        DraftTitle = string.Empty;
        DraftTrigger = string.Empty;
        DraftBody = string.Empty;
        DraftMode = TextExpansionMode.StaticText;
        DraftIsEnabled = true;
    }

    /// <summary>Load an existing snippet into the editor.</summary>
    public void Select(string id)
    {
        var snippet = _snippets.FirstOrDefault(s => s.Id == id);
        if (snippet is null)
        {
            return;
        }

        SelectedId = snippet.Id;
        DraftTitle = snippet.Title;
        DraftTrigger = snippet.Trigger;
        DraftBody = snippet.Body;
        DraftMode = snippet.Mode;
        DraftIsEnabled = snippet.IsEnabled;
    }

    /// <summary>
    /// Persist the current draft (create or update). Returns false when
    /// <see cref="CanSave"/> is false. Swift <c>saveSnippet</c>.
    /// </summary>
    public bool Save()
    {
        if (!CanSave)
        {
            return false;
        }

        var now = _now();
        TextExpansionSnippet snippet;
        if (_selectedId is { } id && _snippets.FirstOrDefault(s => s.Id == id) is { } existing)
        {
            snippet = existing.With(
                title: _draftTitle,
                trigger: _draftTrigger,
                body: _draftBody,
                mode: _draftMode,
                isEnabled: _draftIsEnabled,
                revision: existing.Revision + 1,
                updatedAt: now);
        }
        else
        {
            snippet = new TextExpansionSnippet(
                title: _draftTitle,
                trigger: _draftTrigger,
                body: _draftBody,
                id: _idFactory(),
                mode: _draftMode,
                isEnabled: _draftIsEnabled,
                createdAt: now,
                updatedAt: now);
        }

        _store.Upsert(snippet);
        Load();
        Select(snippet.Id);
        return true;
    }

    /// <summary>Delete the selected snippet and reset to a fresh draft (Swift <c>deleteSelectedSnippet</c>).</summary>
    public bool DeleteSelected()
    {
        if (_selectedId is not { } id)
        {
            return false;
        }

        _store.Delete(id, _now());
        Load();
        CreateDraft();
        return true;
    }

    private void RebuildVisible()
    {
        Snippets.Clear();
        IEnumerable<TextExpansionSnippet> rows = _snippets;
        if (!string.IsNullOrWhiteSpace(_searchQuery))
        {
            var q = _searchQuery.Trim();
            rows = rows.Where(s =>
                s.Title.Contains(q, StringComparison.CurrentCultureIgnoreCase) ||
                s.Trigger.Contains(q, StringComparison.CurrentCultureIgnoreCase) ||
                s.Body.Contains(q, StringComparison.CurrentCultureIgnoreCase));
        }

        foreach (var snippet in rows)
        {
            Snippets.Add(snippet);
        }
    }

    private void PersistRuntime() => _store.SaveRuntime(_runtime);

    private void RaiseRuntime()
    {
        OnPropertyChanged(nameof(InAppEnabled));
        OnPropertyChanged(nameof(MacGlobalEnabled));
        OnPropertyChanged(nameof(MacGlobalBlocked));
        OnPropertyChanged(nameof(MacGlobalBlockedMessage));
        OnPropertyChanged(nameof(LlmPreviewEnabled));
        OnPropertyChanged(nameof(ExportSnapshotEnabled));
        OnPropertyChanged(nameof(CloudSyncEnabled));
    }

    private void RaiseValidation()
    {
        OnPropertyChanged(nameof(TriggerError));
        OnPropertyChanged(nameof(DuplicateTriggerError));
        OnPropertyChanged(nameof(CanSave));
    }
}
