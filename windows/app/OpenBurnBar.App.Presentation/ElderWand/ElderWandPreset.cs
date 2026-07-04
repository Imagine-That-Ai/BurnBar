using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json.Serialization;

namespace OpenBurnBar.App.Presentation.ElderWand;

// PORTED (faithful) from the FROZEN shared contract
//   OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/ElderWandPreset.swift
//
// A saved configuration for The Elder Wand model-fusion router (OpenRouter
// "Fusion"-compatible). A preset names a panel of analysis models that answer a
// prompt in parallel, a judge model that COMPARES their answers into a structured
// verdict (it does not merge), and a per-model tool-call budget. The originating
// chat model writes the final answer, so it is intentionally NOT stored here.
//
// Exactly one preset is the user's default, enforced by
// <see cref="ElderWandPresetCollectionExtensions.PresetsSanitized"/> — the same
// one-default invariant the Swift `Array<ElderWandPreset>.presetsSanitized()` uses.
//
// The [JsonPropertyName] keys reproduce the Swift `Codable` wire keys EXACTLY
// (id / name / analysisModelIDs / judgeModelID / maxToolCalls / isDefault) so a
// preset list JSON-encoded on macOS round-trips through this Windows type and back
// with byte-identical keys — the cross-platform persistence-parity the tests assert.

/// <summary>An inclusive integer range with the Swift <c>ClosedRange&lt;Int&gt;</c> semantics
/// the Fusion contract uses for the panel size and tool-call budget.</summary>
public readonly record struct InclusiveRange(int Lower, int Upper)
{
    /// <summary>Whether <paramref name="value"/> is within <c>[Lower, Upper]</c>.</summary>
    public bool Contains(int value) => value >= Lower && value <= Upper;

    /// <summary>Clamp <paramref name="value"/> into <c>[Lower, Upper]</c> (Swift: <c>min(max(...))</c>).</summary>
    public int Clamp(int value) => Math.Min(Math.Max(value, Lower), Upper);
}

/// <summary>A saved Elder Wand fusion preset. Swift: <c>struct ElderWandPreset</c>.</summary>
public sealed record ElderWandPreset(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("name")] string Name,
    [property: JsonPropertyName("analysisModelIDs")] IReadOnlyList<string> AnalysisModelIds,
    [property: JsonPropertyName("judgeModelID")] string JudgeModelId,
    [property: JsonPropertyName("maxToolCalls")] int MaxToolCalls,
    [property: JsonPropertyName("isDefault")] bool IsDefault)
{
    /// <summary>OpenRouter Fusion default tool-call budget. Swift: <c>defaultMaxToolCalls</c>.</summary>
    public const int DefaultMaxToolCalls = 8;

    /// <summary>OpenRouter Fusion valid <c>max_tool_calls</c> range. Swift: <c>maxToolCallsRange</c>.</summary>
    public static readonly InclusiveRange MaxToolCallsRange = new(1, 16);

    /// <summary>OpenRouter Fusion analysis-panel size range. Swift: <c>analysisPanelRange</c>.</summary>
    public static readonly InclusiveRange AnalysisPanelRange = new(1, 8);

    /// <summary>Ergonomic factory mirroring the Swift <c>init</c> defaults (new UUID id,
    /// default budget, not-default). The canonical positional constructor stays the single
    /// JSON constructor so System.Text.Json binds unambiguously.</summary>
    public static ElderWandPreset Create(
        string name,
        IReadOnlyList<string> analysisModelIds,
        string judgeModelId,
        int maxToolCalls = DefaultMaxToolCalls,
        bool isDefault = false,
        string? id = null) =>
        new(id ?? Guid.NewGuid().ToString(), name, analysisModelIds, judgeModelId, maxToolCalls, isDefault);

    /// <summary>A copy with <see cref="IsDefault"/> overridden — the value-type mutation the
    /// sanitizer and the "set default" path use. Swift: <c>withIsDefault(_:)</c>.</summary>
    public ElderWandPreset WithIsDefault(bool value) => this with { IsDefault = value };

    /// <summary>Whether the panel size and tool-call budget are within the Fusion contract
    /// bounds. Swift: <c>isWithinContractBounds</c>.</summary>
    public bool IsWithinContractBounds =>
        AnalysisPanelRange.Contains(AnalysisModelIds.Count)
        && MaxToolCallsRange.Contains(MaxToolCalls);
}

/// <summary>The one-default sanitizer. Swift: <c>extension Array where Element == ElderWandPreset</c>.</summary>
public static class ElderWandPresetCollectionExtensions
{
    /// <summary>Ensures exactly one preset is <see cref="ElderWandPreset.IsDefault"/>. If none are
    /// marked, the first is promoted; if multiple are marked, only the first marked one stays.
    /// A list that is already the single default is returned unchanged (reference-preserving,
    /// like the Swift fast path). Swift: <c>presetsSanitized()</c>.</summary>
    public static IReadOnlyList<ElderWandPreset> PresetsSanitized(this IReadOnlyList<ElderWandPreset> presets)
    {
        if (presets.Count == 0)
        {
            return Array.Empty<ElderWandPreset>();
        }

        int defaultCount = presets.Count(p => p.IsDefault);
        if (defaultCount == 1)
        {
            return presets;
        }

        int defaultIndex = 0;
        for (int i = 0; i < presets.Count; i++)
        {
            if (presets[i].IsDefault)
            {
                defaultIndex = i;
                break;
            }
        }

        var result = new List<ElderWandPreset>(presets.Count);
        for (int i = 0; i < presets.Count; i++)
        {
            result.Add(presets[i].WithIsDefault(i == defaultIndex));
        }

        return result;
    }
}
