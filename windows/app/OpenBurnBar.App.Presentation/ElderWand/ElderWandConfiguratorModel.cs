using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Linq;
using System.Runtime.CompilerServices;

namespace OpenBurnBar.App.Presentation.ElderWand;

// PORTED (faithful) from
//   AgentLens/Views/Chat/ElderWand/ElderWandConfiguratorModel.swift
//
// Pure in-flight edit state for the Elder Wand configurator: the panel the user is
// assembling (selected analysis models, judge, tool-call budget, name) and which saved
// preset — if any — is being edited. It performs NO persistence; the view reads
// BuildPreset() and hands the result to the ElderWandSettingsModel store.
//
// Swift `@Observable` becomes INotifyPropertyChanged so WinUI x:Bind refreshes; the
// selection-change fan-out to the chip clouds rides a dedicated SelectionChanged event
// (raised on every toggle / load / reset) so the reactive clouds re-derive chip flags
// without recomputing on unrelated edits like a name keystroke.

/// <summary>The Elder Wand configurator edit buffer (Windows).
/// Swift: <c>@Observable @MainActor final class ElderWandConfiguratorModel</c>.</summary>
public sealed class ElderWandConfiguratorModel : INotifyPropertyChanged
{
    private readonly HashSet<string> _selectedAnalysisIds = new(StringComparer.Ordinal);
    private string? _judgeId;
    private int _maxToolCalls = ElderWandPreset.DefaultMaxToolCalls;
    private string _name = string.Empty;
    private string? _editingPresetId;

    /// <summary>The currently selected analysis-panel model IDs (order-independent).
    /// Swift: <c>selectedAnalysisIDs: Set&lt;String&gt;</c>.</summary>
    public IReadOnlyCollection<string> SelectedAnalysisIds => _selectedAnalysisIds;

    /// <summary>The judge model ID, or <c>null</c> when none is chosen. Swift: <c>judgeID</c>.</summary>
    public string? JudgeId
    {
        get => _judgeId;
        private set
        {
            if (!string.Equals(_judgeId, value, StringComparison.Ordinal))
            {
                _judgeId = value;
                OnPropertyChanged();
                OnPropertyChanged(nameof(IsValid));
            }
        }
    }

    /// <summary>Per-model tool-loop budget (Fusion parity: 1–16, default 8). Stored raw like
    /// the Swift original; BuildPreset/Load clamp to range. Swift: <c>maxToolCalls</c>.</summary>
    public int MaxToolCalls
    {
        get => _maxToolCalls;
        set
        {
            if (_maxToolCalls != value)
            {
                _maxToolCalls = value;
                OnPropertyChanged();
                OnPropertyChanged(nameof(IsValid));
            }
        }
    }

    /// <summary>Working preset name. Swift: <c>name</c>.</summary>
    public string Name
    {
        get => _name;
        set
        {
            value ??= string.Empty;
            if (!string.Equals(_name, value, StringComparison.Ordinal))
            {
                _name = value;
                OnPropertyChanged();
                OnPropertyChanged(nameof(IsValid));
            }
        }
    }

    /// <summary>The id of the saved preset being edited, or <c>null</c> for a new one.
    /// Swift: <c>editingPresetID</c>.</summary>
    public string? EditingPresetId
    {
        get => _editingPresetId;
        private set
        {
            if (!string.Equals(_editingPresetId, value, StringComparison.Ordinal))
            {
                _editingPresetId = value;
                OnPropertyChanged();
                OnPropertyChanged(nameof(IsEditingExisting));
                OnPropertyChanged(nameof(SaveButtonTitle));
            }
        }
    }

    /// <summary>Raised on any selection change (analysis toggle, judge select, load, reset) so
    /// the chip clouds re-derive their per-chip selected/disabled flags.</summary>
    public event EventHandler? SelectionChanged;

    // MARK: - Derived validity

    /// <summary>Whether the current edit satisfies the Fusion contract. Swift: <c>isValid</c>.</summary>
    public bool IsValid => BuildPreset() is not null;

    /// <summary>The panel size. Swift: <c>analysisCount</c>.</summary>
    public int AnalysisCount => _selectedAnalysisIds.Count;

    /// <summary>Whether the panel can accept another analysis model (Fusion caps at 8).
    /// Swift: <c>canAddMoreAnalysis</c>.</summary>
    public bool CanAddMoreAnalysis => _selectedAnalysisIds.Count < ElderWandPreset.AnalysisPanelRange.Upper;

    /// <summary>Header affordance text, e.g. "3 of 8". Swift: the analysis section's
    /// "N of 8 selected" counter.</summary>
    public string AnalysisPanelCounterText => $"{AnalysisCount} of {ElderWandPreset.AnalysisPanelRange.Upper}";

    /// <summary>Whether an existing preset is loaded (drives Save vs Update). Swift: <c>editingPresetID != nil</c>.</summary>
    public bool IsEditingExisting => _editingPresetId is not null;

    /// <summary>Save-button label. Swift: the section's <c>"Save"</c>/<c>"Update"</c> title.</summary>
    public string SaveButtonTitle => _editingPresetId is null ? "Save" : "Update";

    /// <summary>Whether <paramref name="id"/> is in the analysis panel (chip selected state).</summary>
    public bool IsAnalysisSelected(string id) => _selectedAnalysisIds.Contains(id);

    /// <summary>Whether <paramref name="id"/> is the chosen judge (chip selected state).</summary>
    public bool IsJudge(string id) => string.Equals(_judgeId, id, StringComparison.Ordinal);

    // MARK: - Mutation

    /// <summary>Toggles a model in the analysis panel. Adding past the maximum is a no-op.
    /// Swift: <c>toggleAnalysis(_:)</c>.</summary>
    public void ToggleAnalysis(string id)
    {
        string key = (id ?? string.Empty).Trim();
        if (key.Length == 0)
        {
            return;
        }

        bool changed;
        if (_selectedAnalysisIds.Contains(key))
        {
            _selectedAnalysisIds.Remove(key);
            changed = true;
        }
        else if (CanAddMoreAnalysis)
        {
            _selectedAnalysisIds.Add(key);
            changed = true;
        }
        else
        {
            changed = false;
        }

        if (changed)
        {
            RaiseSelectionDerived();
        }
    }

    /// <summary>Selects (or clears) the judge model. Passing the already-selected id
    /// deselects it. Swift: <c>selectJudge(_:)</c>.</summary>
    public void SelectJudge(string id)
    {
        string key = (id ?? string.Empty).Trim();
        if (key.Length == 0)
        {
            return;
        }

        JudgeId = IsJudge(key) ? null : key;
        SelectionChanged?.Invoke(this, EventArgs.Empty);
    }

    // MARK: - Load / build / reset

    /// <summary>Loads an existing preset into the edit buffer for in-place editing.
    /// Swift: <c>load(from:)</c>.</summary>
    public void Load(ElderWandPreset preset)
    {
        if (preset is null)
        {
            throw new ArgumentNullException(nameof(preset));
        }

        EditingPresetId = preset.Id;
        Name = preset.Name;

        _selectedAnalysisIds.Clear();
        foreach (var id in preset.AnalysisModelIds)
        {
            if (!string.IsNullOrEmpty(id))
            {
                _selectedAnalysisIds.Add(id);
            }
        }

        string judge = (preset.JudgeModelId ?? string.Empty).Trim();
        JudgeId = judge.Length == 0 ? null : judge;

        MaxToolCalls = ElderWandPreset.MaxToolCallsRange.Clamp(preset.MaxToolCalls);

        RaiseSelectionDerived();
    }

    /// <summary>Builds a sanitized preset from the current edit state, or <c>null</c> when the
    /// edit is incomplete (missing name, empty/oversized panel, or missing judge). When editing
    /// an existing preset its id is preserved; <c>IsDefault</c> is <c>false</c> — the store
    /// re-applies the one-default invariant on save. Swift: <c>buildPreset()</c>.</summary>
    public ElderWandPreset? BuildPreset()
    {
        string trimmedName = _name.Trim();
        if (trimmedName.Length == 0)
        {
            return null;
        }

        var analysis = _selectedAnalysisIds
            .Select(id => id.Trim())
            .Where(id => id.Length > 0)
            .OrderBy(id => id, StringComparer.Ordinal)
            .ToList();
        if (!ElderWandPreset.AnalysisPanelRange.Contains(analysis.Count))
        {
            return null;
        }

        string judge = (_judgeId ?? string.Empty).Trim();
        if (judge.Length == 0)
        {
            return null;
        }

        int clampedToolCalls = ElderWandPreset.MaxToolCallsRange.Clamp(_maxToolCalls);

        return new ElderWandPreset(
            _editingPresetId ?? Guid.NewGuid().ToString(),
            trimmedName,
            analysis,
            judge,
            clampedToolCalls,
            IsDefault: false);
    }

    /// <summary>Clears the edit buffer back to a fresh, unnamed panel. Swift: <c>reset()</c>.</summary>
    public void Reset()
    {
        _selectedAnalysisIds.Clear();
        JudgeId = null;
        MaxToolCalls = ElderWandPreset.DefaultMaxToolCalls;
        Name = string.Empty;
        EditingPresetId = null;
        RaiseSelectionDerived();
    }

    private void RaiseSelectionDerived()
    {
        OnPropertyChanged(nameof(AnalysisCount));
        OnPropertyChanged(nameof(CanAddMoreAnalysis));
        OnPropertyChanged(nameof(AnalysisPanelCounterText));
        OnPropertyChanged(nameof(IsValid));
        SelectionChanged?.Invoke(this, EventArgs.Empty);
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    private void OnPropertyChanged([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}
