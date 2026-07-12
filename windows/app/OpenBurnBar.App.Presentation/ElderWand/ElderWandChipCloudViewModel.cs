using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace OpenBurnBar.App.Presentation.ElderWand;

// The reactive bridge between the resolved model catalog (ElderWandProviderGroup[]) and
// the live edit buffer (ElderWandConfiguratorModel). It is the "prepared, cached data"
// the macOS sections receive — but made observable so the WinUI chip clouds x:Bind to
// per-chip selected/disabled flags that update when the editor changes, without any
// inline recompute in a view body.
//
// PORTED (behavioral) from the per-chip state each Swift section derives:
//   ElderWandAnalysisChip.isDisabled = !routeEligible || (!isSelected && !canAdd)
//   ElderWandJudgeChip disabled       = !routeEligible
//   selected = analysisIDs.contains(id) / judgeID == id
//
// Fully unit-tested on macOS: build a cloud, drive the editor, assert chip flags across
// the whole cloud (including the "panel full disables unselected chips" and
// "ineligible route disables" rules).

/// <summary>Which selection semantics a cloud renders. Swift: the analysis vs judge sections.</summary>
public enum ElderWandCloudMode
{
    /// <summary>Multi-select analysis panel (1–8). Swift: <c>ElderWandAnalysisSection</c>.</summary>
    Analysis,

    /// <summary>Single-select judge. Swift: <c>ElderWandJudgeSection</c>.</summary>
    Judge,
}

/// <summary>One selectable chip with live selected/disabled flags. Swift: the per-chip
/// derived state inside <c>ElderWandAnalysisChip</c> / <c>ElderWandJudgeChip</c>.</summary>
public sealed class ElderWandChip : INotifyPropertyChanged
{
    private bool _isSelected;
    private bool _isDisabled;

    public ElderWandChip(ElderWandModelOption option)
    {
        Option = option ?? throw new ArgumentNullException(nameof(option));
    }

    /// <summary>The underlying model option (id / title / route eligibility).</summary>
    public ElderWandModelOption Option { get; }

    /// <summary>The wire model ID this chip toggles.</summary>
    public string ModelId => Option.Id;

    /// <summary>The chip label.</summary>
    public string Title => Option.Title;

    /// <summary>Whether the model has a live route (drives the "asleep" glyph).</summary>
    public bool IsRouteEligible => Option.IsRouteEligible;

    /// <summary>Whether the model lacks a live route (convenience for XAML visibility).</summary>
    public bool IsRouteAsleep => !Option.IsRouteEligible;

    /// <summary>Whether this chip is in the current selection.</summary>
    public bool IsSelected
    {
        get => _isSelected;
        internal set { if (_isSelected != value) { _isSelected = value; OnPropertyChanged(); } }
    }

    /// <summary>Whether this chip is non-interactive (ineligible route, or panel full).</summary>
    public bool IsDisabled
    {
        get => _isDisabled;
        internal set { if (_isDisabled != value) { _isDisabled = value; OnPropertyChanged(); OnPropertyChanged(nameof(IsEnabled)); } }
    }

    /// <summary>Convenience inverse for XAML <c>IsEnabled</c> bindings.</summary>
    public bool IsEnabled => !_isDisabled;

    public event PropertyChangedEventHandler? PropertyChanged;

    private void OnPropertyChanged([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}

/// <summary>A provider heading + its chips. Swift: the per-provider group inside a section.</summary>
public sealed class ElderWandChipGroup
{
    public ElderWandChipGroup(string providerName, IReadOnlyList<ElderWandChip> chips)
    {
        ProviderName = providerName;
        Chips = new ObservableCollection<ElderWandChip>(chips);
    }

    public string ProviderName { get; }

    public ObservableCollection<ElderWandChip> Chips { get; }
}

/// <summary>A provider-grouped chip cloud bound to the live edit buffer. Swift:
/// <c>ElderWandAnalysisSection</c> / <c>ElderWandJudgeSection</c> (the reactive half).
/// Not <c>INotifyPropertyChanged</c> itself: its <see cref="Groups"/> is observable and each
/// <see cref="ElderWandChip"/> raises its own change notifications, while
/// <see cref="HasGroups"/> / <see cref="IsEmpty"/> are fixed once the catalog is bound.</summary>
public sealed class ElderWandChipCloudViewModel : IDisposable
{
    private readonly ElderWandConfiguratorModel _editor;
    private bool _disposed;

    public ElderWandChipCloudViewModel(
        ElderWandConfiguratorModel editor,
        IReadOnlyList<ElderWandProviderGroup> groups,
        ElderWandCloudMode mode)
    {
        _editor = editor ?? throw new ArgumentNullException(nameof(editor));
        if (groups is null)
        {
            throw new ArgumentNullException(nameof(groups));
        }

        Mode = mode;
        Groups = new ObservableCollection<ElderWandChipGroup>();
        foreach (var group in groups)
        {
            var chips = new List<ElderWandChip>(group.Options.Count);
            foreach (var option in group.Options)
            {
                chips.Add(new ElderWandChip(option));
            }

            Groups.Add(new ElderWandChipGroup(group.ProviderName, chips));
        }

        _editor.SelectionChanged += OnEditorSelectionChanged;
        RefreshFlags();
    }

    /// <summary>The selection semantics this cloud renders.</summary>
    public ElderWandCloudMode Mode { get; }

    /// <summary>The provider-grouped chips.</summary>
    public ObservableCollection<ElderWandChipGroup> Groups { get; }

    /// <summary>Whether the catalog produced any groups.</summary>
    public bool HasGroups => Groups.Count > 0;

    /// <summary>Whether the catalog is empty (drives the "no live models" hint).</summary>
    public bool IsEmpty => Groups.Count == 0;

    /// <summary>Applies the selection semantics to a tapped chip. Swift: the chip's action —
    /// <c>toggleAnalysis</c> (analysis) / <c>selectJudge</c> (judge).</summary>
    public void Toggle(ElderWandChip chip)
    {
        if (chip is null)
        {
            throw new ArgumentNullException(nameof(chip));
        }

        if (Mode == ElderWandCloudMode.Analysis)
        {
            _editor.ToggleAnalysis(chip.ModelId);
        }
        else
        {
            _editor.SelectJudge(chip.ModelId);
        }
    }

    /// <summary>Re-derives every chip's selected/disabled flags from the current edit buffer.</summary>
    public void RefreshFlags()
    {
        bool canAdd = _editor.CanAddMoreAnalysis;
        foreach (var group in Groups)
        {
            foreach (var chip in group.Chips)
            {
                if (Mode == ElderWandCloudMode.Analysis)
                {
                    bool selected = _editor.IsAnalysisSelected(chip.ModelId);
                    chip.IsSelected = selected;
                    chip.IsDisabled = !chip.IsRouteEligible || (!selected && !canAdd);
                }
                else
                {
                    bool selected = _editor.IsJudge(chip.ModelId);
                    chip.IsSelected = selected;
                    chip.IsDisabled = !chip.IsRouteEligible;
                }
            }
        }
    }

    private void OnEditorSelectionChanged(object? sender, EventArgs e) => RefreshFlags();

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        _editor.SelectionChanged -= OnEditorSelectionChanged;
    }
}
