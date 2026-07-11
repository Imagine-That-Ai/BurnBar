using System;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace OpenBurnBar.App.Presentation.ElderWand;

// PORTED (faithful) from the preset-list rendering in
//   AgentLens/Views/Chat/ElderWand/ElderWandPresetSection.swift (ElderWandPresetRow)
//
// Projects the ElderWandSettingsModel store into observable, display-ready rows: each
// row carries the preset, whether it is the active (default) one, and the Swift row
// summary ("N models · judge X"). Rebuilt whenever the store changes so the WinUI list
// refreshes without per-row recompute in the view. Fully unit-tested on macOS.

/// <summary>One display row for a saved preset. Swift: <c>ElderWandPresetRow</c>.</summary>
public sealed class ElderWandPresetRow
{
    public ElderWandPresetRow(ElderWandPreset preset, bool isActive)
    {
        Preset = preset ?? throw new ArgumentNullException(nameof(preset));
        IsActive = isActive;
    }

    public ElderWandPreset Preset { get; }

    /// <summary>The wire model ID for XAML accent lookup (judge tint).</summary>
    public string JudgeModelId => Preset.JudgeModelId;

    /// <summary>The preset's stable id (menu action routing).</summary>
    public string Id => Preset.Id;

    /// <summary>The preset name.</summary>
    public string Name => Preset.Name;

    /// <summary>Whether this is the store's active/default preset (drives the "Default" badge
    /// and the "Set as Default" menu visibility). Swift: <c>isActive</c>.</summary>
    public bool IsActive { get; }

    /// <summary>Inverse convenience for XAML (show "Set as Default" only when not active).</summary>
    public bool IsNotActive => !IsActive;

    /// <summary>Panel-size label, e.g. "1 model" / "3 models". Swift: <c>panelLabel</c>.</summary>
    public string PanelLabel
    {
        get
        {
            int panel = Preset.AnalysisModelIds.Count;
            return panel == 1 ? "1 model" : $"{panel} models";
        }
    }

    /// <summary>Row summary "N models · judge X". Swift: <c>summary</c>.</summary>
    public string Summary => $"{PanelLabel} · judge {ElderWandModelName.Abbreviate(Preset.JudgeModelId)}";

    /// <summary>Accessibility label, e.g. "My Panel, default. 3 models · judge …". Swift: the row
    /// <c>accessibilityLabel</c>.</summary>
    public string AccessibilityLabel => $"{Name}{(IsActive ? ", default" : string.Empty)}. {Summary}";
}

/// <summary>Observable projection of the preset store into display rows. Swift: the
/// <c>ForEach(settings.presets)</c> in <c>ElderWandPresetSection</c>.</summary>
public sealed class ElderWandPresetListViewModel : INotifyPropertyChanged, IDisposable
{
    private readonly ElderWandSettingsModel _settings;
    private bool _disposed;

    public ElderWandPresetListViewModel(ElderWandSettingsModel settings)
    {
        _settings = settings ?? throw new ArgumentNullException(nameof(settings));
        _settings.PropertyChanged += OnSettingsChanged;
        Rebuild();
    }

    /// <summary>The display rows, in store order.</summary>
    public ObservableCollection<ElderWandPresetRow> Rows { get; } = new();

    /// <summary>Whether there are no saved presets (drives the empty-state switch).</summary>
    public bool IsEmpty => Rows.Count == 0;

    /// <summary>Whether there is at least one saved preset.</summary>
    public bool HasRows => Rows.Count > 0;

    private void OnSettingsChanged(object? sender, PropertyChangedEventArgs e)
    {
        // Any store mutation re-sanitizes and replaces the list; rebuild the projection.
        if (e.PropertyName is null
            || e.PropertyName == nameof(ElderWandSettingsModel.Presets)
            || e.PropertyName == nameof(ElderWandSettingsModel.ActivePreset))
        {
            Rebuild();
        }
    }

    private void Rebuild()
    {
        string? activeId = _settings.ActivePreset?.Id;
        Rows.Clear();
        foreach (var preset in _settings.Presets)
        {
            bool isActive = activeId is not null
                && string.Equals(preset.Id, activeId, StringComparison.Ordinal);
            Rows.Add(new ElderWandPresetRow(preset, isActive));
        }

        OnPropertyChanged(nameof(IsEmpty));
        OnPropertyChanged(nameof(HasRows));
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        _settings.PropertyChanged -= OnSettingsChanged;
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    private void OnPropertyChanged([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}
