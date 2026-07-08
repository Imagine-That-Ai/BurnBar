using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using OpenBurnBar.App.Presentation.ElderWand;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests;

/// <summary>
/// Real, macOS-runnable tests for the ported FROZEN preset contract
/// (windows/app/OpenBurnBar.App.Presentation/ElderWand/ElderWandPreset.cs), parity with
/// OpenBurnBarCore/.../SharedModels/ElderWandPreset.swift. Locks the Fusion contract
/// constants, the one-default sanitizer, and — critically — the cross-platform JSON
/// wire-key parity a macOS-written preset store depends on.
/// </summary>
public sealed class ElderWandPresetTests
{
    private static ElderWandPreset Preset(string id, bool isDefault = false) =>
        new(id, $"Panel {id}", new[] { "a", "b" }, "judge", 8, isDefault);

    [Fact]
    public void ContractConstants_MatchSwift()
    {
        Assert.Equal(8, ElderWandPreset.DefaultMaxToolCalls);
        Assert.Equal(1, ElderWandPreset.MaxToolCallsRange.Lower);
        Assert.Equal(16, ElderWandPreset.MaxToolCallsRange.Upper);
        Assert.Equal(1, ElderWandPreset.AnalysisPanelRange.Lower);
        Assert.Equal(8, ElderWandPreset.AnalysisPanelRange.Upper);
    }

    [Theory]
    [InlineData(0, false)]
    [InlineData(17, false)]
    [InlineData(1, true)]
    [InlineData(16, true)]
    public void InclusiveRange_ContainsAndClamp(int value, bool contained)
    {
        Assert.Equal(contained, ElderWandPreset.MaxToolCallsRange.Contains(value));
        int clamped = ElderWandPreset.MaxToolCallsRange.Clamp(value);
        Assert.InRange(clamped, 1, 16);
    }

    [Fact]
    public void IsWithinContractBounds_ChecksPanelAndBudget()
    {
        Assert.True(Preset("p").IsWithinContractBounds);
        var empty = new ElderWandPreset("p", "n", System.Array.Empty<string>(), "j", 8, false);
        Assert.False(empty.IsWithinContractBounds);
        var overBudget = new ElderWandPreset("p", "n", new[] { "a" }, "j", 99, false);
        Assert.False(overBudget.IsWithinContractBounds);
    }

    [Fact]
    public void WithIsDefault_TogglesOnlyTheFlag()
    {
        var p = Preset("p", isDefault: false);
        var d = p.WithIsDefault(true);
        Assert.True(d.IsDefault);
        Assert.Equal(p.Id, d.Id);
        Assert.Equal(p.AnalysisModelIds, d.AnalysisModelIds);
        Assert.False(p.IsDefault); // original unchanged (value type)
    }

    [Fact]
    public void PresetsSanitized_Empty_ReturnsEmpty()
    {
        var result = System.Array.Empty<ElderWandPreset>().PresetsSanitized();
        Assert.Empty(result);
    }

    [Fact]
    public void PresetsSanitized_NoneDefault_PromotesFirst()
    {
        var result = new[] { Preset("a"), Preset("b"), Preset("c") }.PresetsSanitized();
        Assert.True(result[0].IsDefault);
        Assert.False(result[1].IsDefault);
        Assert.False(result[2].IsDefault);
    }

    [Fact]
    public void PresetsSanitized_MultipleDefault_KeepsFirstMarked()
    {
        var result = new[] { Preset("a"), Preset("b", true), Preset("c", true) }.PresetsSanitized();
        Assert.False(result[0].IsDefault);
        Assert.True(result[1].IsDefault);
        Assert.False(result[2].IsDefault);
        Assert.Single(result, p => p.IsDefault);
    }

    [Fact]
    public void PresetsSanitized_ExactlyOneDefault_ReturnsSameReferenceFastPath()
    {
        IReadOnlyList<ElderWandPreset> input = new[] { Preset("a", true), Preset("b") };
        var result = input.PresetsSanitized();
        Assert.Same(input, result);
    }

    [Fact]
    public void Json_KeysMatchSwiftCodable_RoundTrips()
    {
        var preset = new ElderWandPreset("id-1", "Deep Panel", new[] { "m1", "m2" }, "judge-x", 12, true);
        string json = JsonSerializer.Serialize(preset);

        // Wire keys must match the Swift Codable property names exactly.
        Assert.Contains("\"id\":\"id-1\"", json);
        Assert.Contains("\"name\":\"Deep Panel\"", json);
        Assert.Contains("\"analysisModelIDs\":[\"m1\",\"m2\"]", json);
        Assert.Contains("\"judgeModelID\":\"judge-x\"", json);
        Assert.Contains("\"maxToolCalls\":12", json);
        Assert.Contains("\"isDefault\":true", json);

        var back = JsonSerializer.Deserialize<ElderWandPreset>(json)!;
        Assert.Equal(preset.Id, back.Id);
        Assert.Equal(preset.Name, back.Name);
        Assert.Equal(preset.AnalysisModelIds, back.AnalysisModelIds);
        Assert.Equal(preset.JudgeModelId, back.JudgeModelId);
        Assert.Equal(preset.MaxToolCalls, back.MaxToolCalls);
        Assert.Equal(preset.IsDefault, back.IsDefault);
    }

    [Fact]
    public void Json_DecodesMacWrittenPayload()
    {
        // A preset list exactly as the Swift SettingsPersistenceCoordinator would write it.
        const string macJson =
            "[{\"id\":\"p1\",\"name\":\"Fusion A\",\"analysisModelIDs\":[\"anthropic/claude\",\"openai/gpt\"]," +
            "\"judgeModelID\":\"google/gemini\",\"maxToolCalls\":8,\"isDefault\":true}]";

        var presets = JsonSerializer.Deserialize<List<ElderWandPreset>>(macJson)!;
        Assert.Single(presets);
        Assert.Equal("p1", presets[0].Id);
        Assert.Equal(new[] { "anthropic/claude", "openai/gpt" }, presets[0].AnalysisModelIds);
        Assert.Equal("google/gemini", presets[0].JudgeModelId);
        Assert.True(presets[0].IsDefault);
    }

    [Fact]
    public void Create_AppliesSwiftInitDefaults()
    {
        var p = ElderWandPreset.Create("Panel", new[] { "a" }, "j");
        Assert.False(string.IsNullOrEmpty(p.Id));
        Assert.Equal(ElderWandPreset.DefaultMaxToolCalls, p.MaxToolCalls);
        Assert.False(p.IsDefault);
    }

    [Fact]
    public void ModelName_Abbreviate_MatchesSwift()
    {
        Assert.Equal("Model", ElderWandModelName.Abbreviate("   "));
        Assert.Equal("llama-3.1-70b", ElderWandModelName.Abbreviate("meta-llama/llama-3.1-70b"));
        Assert.Equal("gpt-4o", ElderWandModelName.Abbreviate("gpt-4o"));

        string longName = new string('x', 40);
        string abbreviated = ElderWandModelName.Abbreviate(longName);
        Assert.Equal(31, abbreviated.Length); // 30 chars + ellipsis
        Assert.EndsWith("…", abbreviated);
    }
}
