using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Globalization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using OpenBurnBar.App.Presentation.ElderWand;

namespace OpenBurnBar.App.ElderWand;

/// <summary>
/// The Elder Wand configurator (Windows) — a scrolling multi-section form: analysis panel, judge,
/// research budget, and preset lifecycle. Windows render of
/// <c>AgentLens/Views/Chat/ElderWand/ElderWandConfiguratorView.swift</c>. The view owns its edit
/// buffer (<see cref="Editor"/>, the SwiftUI <c>@State</c> analog); the caller injects the preset
/// store + the resolved live-model catalog via <see cref="Configure"/>. All section logic is
/// portable and unit-tested on macOS; this control is the render + input wiring.
/// </summary>
public sealed partial class ElderWandConfiguratorView : UserControl
{
    private ElderWandChipCloudViewModel? _analysisCloud;
    private ElderWandChipCloudViewModel? _judgeCloud;
    private ElderWandPresetListViewModel? _presetList;
    private bool _configured;
    private bool _hasLiveModels;
    private bool _syncingBudget;

    public ElderWandConfiguratorView()
    {
        InitializeComponent();
        ConfigureBudgetSlider();
        Editor = new ElderWandConfiguratorModel();
        Editor.PropertyChanged += OnEditorPropertyChanged;
        Unloaded += OnUnloaded;
    }

    /// <summary>The view-owned edit buffer (SwiftUI <c>@State private var editor</c>).</summary>
    public ElderWandConfiguratorModel Editor { get; }

    /// <summary>Whether the live form (sections + budget + presets) should show.</summary>
    public bool HasLiveModels => _hasLiveModels;

    /// <summary>Whether the "configured but no models advertised" card should show.</summary>
    public bool ShowNoModels => _configured && !_hasLiveModels;

    /// <summary>Whether the "open from a chat" card should show (not yet configured).</summary>
    public bool ShowNotConfigured => !_configured;

    /// <summary>
    /// Injects the preset store and the resolved live-model catalog, builds the section
    /// view-models, and wires the sections. The Windows analog of the SwiftUI body picking up
    /// <c>controller.liveAdvertisedModels</c> + <c>settingsManager.elderWand</c>.
    /// </summary>
    public void Configure(ElderWandSettingsModel settings, IReadOnlyList<ElderWandProviderGroup> groups)
    {
        ArgumentNullException.ThrowIfNull(settings);
        ArgumentNullException.ThrowIfNull(groups);

        _analysisCloud?.Dispose();
        _judgeCloud?.Dispose();
        _presetList?.Dispose();

        _analysisCloud = new ElderWandChipCloudViewModel(Editor, groups, ElderWandCloudMode.Analysis);
        _judgeCloud = new ElderWandChipCloudViewModel(Editor, groups, ElderWandCloudMode.Judge);
        _presetList = new ElderWandPresetListViewModel(settings);

        _configured = true;
        _hasLiveModels = groups.Count > 0;

        AnalysisSection.SetContext(Editor, _analysisCloud);
        JudgeSection.SetCloud(_judgeCloud);
        PresetSection.SetContext(Editor, settings, _presetList);

        SyncSliderToEditor();
        Bindings.Update();
    }

    /// <summary>x:Bind function: the tool-call budget as a display string.</summary>
    public string BudgetLabel(int value) => value.ToString(CultureInfo.InvariantCulture);

    private void ConfigureBudgetSlider()
    {
        // WinUI's unpackaged XAML loader fails on RangeBase numeric attributes on ARM64.
        // Apply the same range in managed code after the control is constructed.
        _syncingBudget = true;
        BudgetSlider.Value = 1;
        BudgetSlider.Minimum = 1;
        BudgetSlider.Maximum = 16;
        BudgetSlider.StepFrequency = 1;
        BudgetSlider.SmallChange = 1;
        BudgetSlider.LargeChange = 1;
        _syncingBudget = false;
    }

    private void OnBudgetChanged(object sender, RangeBaseValueChangedEventArgs e)
    {
        if (_syncingBudget)
        {
            return;
        }

        Editor.MaxToolCalls = Math.Max(1, (int)Math.Round(e.NewValue));
    }

    private void OnEditorPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(ElderWandConfiguratorModel.MaxToolCalls))
        {
            SyncSliderToEditor();
        }
    }

    private void SyncSliderToEditor()
    {
        // Keep the slider in step with the buffer (e.g. after loading a preset) without
        // re-entering OnBudgetChanged.
        if ((int)Math.Round(BudgetSlider.Value) == Editor.MaxToolCalls)
        {
            return;
        }

        _syncingBudget = true;
        BudgetSlider.Value = Editor.MaxToolCalls;
        _syncingBudget = false;
    }

    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        Editor.PropertyChanged -= OnEditorPropertyChanged;
        _analysisCloud?.Dispose();
        _judgeCloud?.Dispose();
        _presetList?.Dispose();
    }
}
