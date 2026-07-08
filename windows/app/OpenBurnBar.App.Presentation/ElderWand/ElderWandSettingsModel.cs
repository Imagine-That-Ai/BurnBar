using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace OpenBurnBar.App.Presentation.ElderWand;

// PORTED (faithful) from
//   AgentLens/Services/Settings/Stores/ElderWandSettings.swift
//
// Persists the user's saved Elder Wand fusion presets. Each preset names an analysis
// panel, a judge, and a tool-call budget; exactly one preset is the default, enforced
// by PresetsSanitized(). The list is JSON-encoded under "elderWand.presets.v1" via the
// injected persistence seam — the Windows analog of the Swift
// SettingsPersistenceCoordinator string read/write, and the seam the tests fake.
//
// ElderWandPluginsPayload() lowers the active/default preset into the OpenRouter
// "Fusion"-compatible `plugins` block the daemon gateway expects; null means
// "no fusion this request". A JSON form is exposed so the tests assert byte-level
// wire-key parity with the Swift dictionary.

/// <summary>The string-keyed persistence seam the preset store reads/writes through.
/// Windows analog of the Swift <c>SettingsPersistenceCoordinator</c> (optionalString / set).</summary>
public interface IElderWandPresetPersistence
{
    /// <summary>The stored JSON string for <paramref name="key"/>, or <c>null</c> when unset.</summary>
    string? ReadString(string key);

    /// <summary>Writes <paramref name="value"/> for <paramref name="key"/>.</summary>
    void WriteString(string key, string value);
}

/// <summary>The Elder Wand preset store (Windows).
/// Swift: <c>@Observable @MainActor final class ElderWandSettings</c>.</summary>
public sealed class ElderWandSettingsModel : INotifyPropertyChanged
{
    /// <summary>Persistence key for the JSON-encoded preset list. Swift: <c>presetsStorageName</c>.</summary>
    public const string PresetsStorageKey = "elderWand.presets.v1";

    private static readonly JsonSerializerOptions SerializerOptions = new()
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.Never,
    };

    private readonly IElderWandPresetPersistence _persistence;

    /// <summary>The user's saved presets, sanitized so exactly one is the default. Rebuilt in
    /// place on every mutation so WinUI list bindings refresh. Swift: <c>presets</c> (didSet persist).</summary>
    public ObservableCollection<ElderWandPreset> Presets { get; } = new();

    public ElderWandSettingsModel(IElderWandPresetPersistence persistence)
    {
        _persistence = persistence ?? throw new ArgumentNullException(nameof(persistence));
        var decoded = DecodePresets(_persistence.ReadString(PresetsStorageKey)).PresetsSanitized();
        ReplaceInPlace(decoded, persist: false);
    }

    // MARK: - Derived state

    /// <summary>The active preset is the user's default. <c>null</c> when no presets exist.
    /// Swift: <c>activePreset</c>.</summary>
    public ElderWandPreset? ActivePreset =>
        Presets.FirstOrDefault(p => p.IsDefault) ?? (Presets.Count > 0 ? Presets[0] : null);

    /// <summary>Alias for call sites that read the default explicitly. Swift: <c>defaultPreset</c>.</summary>
    public ElderWandPreset? DefaultPreset => ActivePreset;

    /// <summary>Whether any presets exist (drives the empty-state switch).</summary>
    public bool HasPresets => Presets.Count > 0;

    // MARK: - Mutators

    /// <summary>Saves a new preset or replaces an existing one with the same id. The list is
    /// re-sanitized so exactly one preset stays the default. Swift: <c>save(_:)</c>.</summary>
    public void Save(ElderWandPreset preset)
    {
        if (preset is null)
        {
            throw new ArgumentNullException(nameof(preset));
        }

        var next = new List<ElderWandPreset>(Presets);
        int index = next.FindIndex(p => string.Equals(p.Id, preset.Id, StringComparison.Ordinal));
        bool existingWasDefault;
        if (index >= 0)
        {
            existingWasDefault = next[index].IsDefault;
            next[index] = preset.WithIsDefault(preset.IsDefault || existingWasDefault);
        }
        else
        {
            existingWasDefault = false;
            next.Add(preset);
        }

        if (preset.IsDefault || existingWasDefault)
        {
            var promoted = next
                .Select(p => p.WithIsDefault(string.Equals(p.Id, preset.Id, StringComparison.Ordinal)))
                .ToList();
            ReplaceInPlace(promoted, persist: true);
        }
        else
        {
            ReplaceInPlace(((IReadOnlyList<ElderWandPreset>)next).PresetsSanitized(), persist: true);
        }
    }

    /// <summary>Renames the preset with the given id. No-op when the id is unknown.
    /// Swift: <c>rename(id:to:)</c>.</summary>
    public void Rename(string id, string name)
    {
        int index = IndexOf(id);
        if (index < 0)
        {
            return;
        }

        var existing = Presets[index];
        var next = new List<ElderWandPreset>(Presets)
        {
            [index] = new ElderWandPreset(
                existing.Id,
                name,
                existing.AnalysisModelIds,
                existing.JudgeModelId,
                existing.MaxToolCalls,
                existing.IsDefault),
        };
        ReplaceInPlace(((IReadOnlyList<ElderWandPreset>)next).PresetsSanitized(), persist: true);
    }

    /// <summary>Deletes the preset with the given id, promoting a new default if needed.
    /// Swift: <c>delete(id:)</c>.</summary>
    public void Delete(string id)
    {
        var next = Presets
            .Where(p => !string.Equals(p.Id, id, StringComparison.Ordinal))
            .ToList();
        ReplaceInPlace(((IReadOnlyList<ElderWandPreset>)next).PresetsSanitized(), persist: true);
    }

    /// <summary>Marks the preset with the given id as the default. No-op when unknown.
    /// Swift: <c>setDefault(id:)</c>.</summary>
    public void SetDefault(string id)
    {
        if (IndexOf(id) < 0)
        {
            return;
        }

        var next = Presets
            .Select(p => p.WithIsDefault(string.Equals(p.Id, id, StringComparison.Ordinal)))
            .ToList();
        ReplaceInPlace(((IReadOnlyList<ElderWandPreset>)next).PresetsSanitized(), persist: true);
    }

    /// <summary>Replaces the entire preset list. Swift: <c>replaceAll(_:)</c>.</summary>
    public void ReplaceAll(IReadOnlyList<ElderWandPreset> newPresets) =>
        ReplaceInPlace((newPresets ?? Array.Empty<ElderWandPreset>()).PresetsSanitized(), persist: true);

    // MARK: - Wire payload

    /// <summary>Lowers the active preset into the Fusion-compatible plugin blocks the daemon
    /// gateway reads. <c>null</c> when no preset is configured or the active preset is degenerate
    /// (empty panel / judge). Swift: <c>elderWandPluginsPayload()</c>.</summary>
    public IReadOnlyList<ElderWandFusionPlugin>? ElderWandPluginsPayload()
    {
        var preset = ActivePreset;
        if (preset is null)
        {
            return null;
        }

        var analysisModels = preset.AnalysisModelIds
            .Select(m => m.Trim())
            .Where(m => m.Length > 0)
            .ToList();
        string judge = (preset.JudgeModelId ?? string.Empty).Trim();
        if (analysisModels.Count == 0 || judge.Length == 0)
        {
            return null;
        }

        int clampedToolCalls = ElderWandPreset.MaxToolCallsRange.Clamp(preset.MaxToolCalls);
        return new[]
        {
            new ElderWandFusionPlugin("fusion", Enabled: true, analysisModels, judge, clampedToolCalls),
        };
    }

    /// <summary>The Fusion plugin payload serialized to the EXACT wire JSON the gateway reads —
    /// key order + names identical to the Swift dictionary
    /// (<c>id</c>/<c>enabled</c>/<c>analysis_models</c>/<c>model</c>/<c>max_tool_calls</c>).
    /// <c>null</c> mirrors the payload's <c>null</c>.</summary>
    public string? ElderWandPluginsPayloadJson()
    {
        var payload = ElderWandPluginsPayload();
        if (payload is null)
        {
            return null;
        }

        var wire = payload
            .Select(p => new FusionWire(p.Id, p.Enabled, p.AnalysisModels, p.Model, p.MaxToolCalls))
            .ToArray();
        return JsonSerializer.Serialize(wire, SerializerOptions);
    }

    // MARK: - Persistence

    private void ReplaceInPlace(IReadOnlyList<ElderWandPreset> presets, bool persist)
    {
        Presets.Clear();
        foreach (var preset in presets)
        {
            Presets.Add(preset);
        }

        OnPropertyChanged(nameof(Presets));
        OnPropertyChanged(nameof(ActivePreset));
        OnPropertyChanged(nameof(DefaultPreset));
        OnPropertyChanged(nameof(HasPresets));

        if (persist)
        {
            Persist();
        }
    }

    private void Persist()
    {
        try
        {
            string json = JsonSerializer.Serialize(Presets.ToArray(), SerializerOptions);
            _persistence.WriteString(PresetsStorageKey, json);
        }
        catch (Exception error) when (error is JsonException or NotSupportedException)
        {
            // Best-effort persist (Swift: try?-ok) — a bad list is never written.
        }
    }

    private static IReadOnlyList<ElderWandPreset> DecodePresets(string? json)
    {
        if (string.IsNullOrEmpty(json))
        {
            return Array.Empty<ElderWandPreset>();
        }

        try
        {
            return JsonSerializer.Deserialize<List<ElderWandPreset>>(json, SerializerOptions)
                   ?? (IReadOnlyList<ElderWandPreset>)Array.Empty<ElderWandPreset>();
        }
        catch (JsonException)
        {
            // Corrupt store → empty list (Swift: try?-ok).
            return Array.Empty<ElderWandPreset>();
        }
    }

    private int IndexOf(string id)
    {
        for (int i = 0; i < Presets.Count; i++)
        {
            if (string.Equals(Presets[i].Id, id, StringComparison.Ordinal))
            {
                return i;
            }
        }

        return -1;
    }

    /// <summary>Ordered wire projection guaranteeing the Swift dictionary key order.</summary>
    private sealed record FusionWire(
        [property: JsonPropertyName("id")] string Id,
        [property: JsonPropertyName("enabled")] bool Enabled,
        [property: JsonPropertyName("analysis_models")] IReadOnlyList<string> AnalysisModels,
        [property: JsonPropertyName("model")] string Model,
        [property: JsonPropertyName("max_tool_calls")] int MaxToolCalls);

    public event PropertyChangedEventHandler? PropertyChanged;

    private void OnPropertyChanged([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}
