using System.Linq;
using OpenBurnBar.App.Presentation.ElderWand;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests;

/// <summary>
/// Real, macOS-runnable tests for the ported configurator edit buffer
/// (windows/app/OpenBurnBar.App.Presentation/ElderWand/ElderWandConfiguratorModel.cs),
/// parity with AgentLens/Views/Chat/ElderWand/ElderWandConfiguratorModel.swift.
/// </summary>
public sealed class ElderWandConfiguratorModelTests
{
    [Fact]
    public void ToggleAnalysis_AddsAndRemoves()
    {
        var m = new ElderWandConfiguratorModel();
        m.ToggleAnalysis("m1");
        Assert.Equal(1, m.AnalysisCount);
        Assert.True(m.IsAnalysisSelected("m1"));

        m.ToggleAnalysis("m1");
        Assert.Equal(0, m.AnalysisCount);
        Assert.False(m.IsAnalysisSelected("m1"));
    }

    [Fact]
    public void ToggleAnalysis_TrimsAndIgnoresEmpty()
    {
        var m = new ElderWandConfiguratorModel();
        m.ToggleAnalysis("   ");
        Assert.Equal(0, m.AnalysisCount);

        m.ToggleAnalysis("  m1  ");
        Assert.True(m.IsAnalysisSelected("m1"));
    }

    [Fact]
    public void ToggleAnalysis_CapsAtEight()
    {
        var m = new ElderWandConfiguratorModel();
        for (int i = 0; i < 8; i++)
        {
            m.ToggleAnalysis($"m{i}");
        }

        Assert.Equal(8, m.AnalysisCount);
        Assert.False(m.CanAddMoreAnalysis);

        m.ToggleAnalysis("overflow"); // no-op past the cap
        Assert.Equal(8, m.AnalysisCount);
        Assert.False(m.IsAnalysisSelected("overflow"));

        // An already-selected chip can still be removed even when full.
        m.ToggleAnalysis("m0");
        Assert.Equal(7, m.AnalysisCount);
        Assert.True(m.CanAddMoreAnalysis);
    }

    [Fact]
    public void SelectJudge_TogglesSelection()
    {
        var m = new ElderWandConfiguratorModel();
        m.SelectJudge("j1");
        Assert.Equal("j1", m.JudgeId);
        Assert.True(m.IsJudge("j1"));

        m.SelectJudge("j1"); // re-select clears
        Assert.Null(m.JudgeId);

        m.SelectJudge("j1");
        m.SelectJudge("j2"); // switch
        Assert.Equal("j2", m.JudgeId);
    }

    [Fact]
    public void CounterText_ReflectsCount()
    {
        var m = new ElderWandConfiguratorModel();
        Assert.Equal("0 of 8", m.AnalysisPanelCounterText);
        m.ToggleAnalysis("a");
        m.ToggleAnalysis("b");
        Assert.Equal("2 of 8", m.AnalysisPanelCounterText);
    }

    [Fact]
    public void BuildPreset_RequiresNamePanelAndJudge()
    {
        var m = new ElderWandConfiguratorModel();
        Assert.Null(m.BuildPreset());
        Assert.False(m.IsValid);

        m.Name = "My Panel";
        Assert.Null(m.BuildPreset()); // still no panel / judge

        m.ToggleAnalysis("a");
        Assert.Null(m.BuildPreset()); // no judge

        m.SelectJudge("j");
        var preset = m.BuildPreset();
        Assert.NotNull(preset);
        Assert.True(m.IsValid);
        Assert.Equal("My Panel", preset!.Name);
        Assert.Equal(new[] { "a" }, preset.AnalysisModelIds);
        Assert.Equal("j", preset.JudgeModelId);
        Assert.False(preset.IsDefault);
    }

    [Fact]
    public void BuildPreset_WhitespaceNameIsInvalid()
    {
        var m = new ElderWandConfiguratorModel { Name = "   " };
        m.ToggleAnalysis("a");
        m.SelectJudge("j");
        Assert.Null(m.BuildPreset());
    }

    [Fact]
    public void BuildPreset_SortsAnalysisIdsDeterministically()
    {
        var m = new ElderWandConfiguratorModel { Name = "Panel" };
        m.ToggleAnalysis("zeta");
        m.ToggleAnalysis("alpha");
        m.ToggleAnalysis("mid");
        m.SelectJudge("j");

        var preset = m.BuildPreset()!;
        Assert.Equal(new[] { "alpha", "mid", "zeta" }, preset.AnalysisModelIds);
    }

    [Fact]
    public void BuildPreset_ClampsToolBudget()
    {
        var m = new ElderWandConfiguratorModel { Name = "Panel", MaxToolCalls = 999 };
        m.ToggleAnalysis("a");
        m.SelectJudge("j");
        Assert.Equal(16, m.BuildPreset()!.MaxToolCalls);

        m.MaxToolCalls = -5;
        Assert.Equal(1, m.BuildPreset()!.MaxToolCalls);
    }

    [Fact]
    public void Load_PopulatesBufferAndClamps()
    {
        var preset = new ElderWandPreset("pid", "Loaded", new[] { "m1", "m2", "" }, "  judge  ", 99, true);
        var m = new ElderWandConfiguratorModel();
        m.Load(preset);

        Assert.Equal("pid", m.EditingPresetId);
        Assert.True(m.IsEditingExisting);
        Assert.Equal("Update", m.SaveButtonTitle);
        Assert.Equal("Loaded", m.Name);
        Assert.Equal(2, m.AnalysisCount); // empty id filtered
        Assert.True(m.IsAnalysisSelected("m1"));
        Assert.Equal("judge", m.JudgeId); // trimmed
        Assert.Equal(16, m.MaxToolCalls); // clamped

        // Re-building preserves the edited preset's id (in-place edit), not a new UUID.
        Assert.Equal("pid", m.BuildPreset()!.Id);
    }

    [Fact]
    public void Reset_ClearsBuffer()
    {
        var m = new ElderWandConfiguratorModel { Name = "Panel", MaxToolCalls = 3 };
        m.ToggleAnalysis("a");
        m.SelectJudge("j");
        m.Load(new ElderWandPreset("pid", "x", new[] { "a" }, "j", 5, false));

        m.Reset();
        Assert.Equal(string.Empty, m.Name);
        Assert.Equal(0, m.AnalysisCount);
        Assert.Null(m.JudgeId);
        Assert.Null(m.EditingPresetId);
        Assert.Equal("Save", m.SaveButtonTitle);
        Assert.Equal(ElderWandPreset.DefaultMaxToolCalls, m.MaxToolCalls);
    }

    [Fact]
    public void SelectionChanged_FiresOnMutations()
    {
        var m = new ElderWandConfiguratorModel();
        int fired = 0;
        m.SelectionChanged += (_, _) => fired++;

        m.ToggleAnalysis("a");
        m.SelectJudge("j");
        m.Reset();
        Assert.Equal(3, fired);
    }

    [Fact]
    public void IsValid_RaisesPropertyChanged()
    {
        var m = new ElderWandConfiguratorModel { Name = "Panel" };
        m.ToggleAnalysis("a");

        var raised = new System.Collections.Generic.List<string?>();
        m.PropertyChanged += (_, e) => raised.Add(e.PropertyName);

        m.SelectJudge("j"); // completes a valid edit

        Assert.Contains(nameof(ElderWandConfiguratorModel.JudgeId), raised);
        Assert.Contains(nameof(ElderWandConfiguratorModel.IsValid), raised);
    }
}
