// PORTED (portable, unit-tested) from AgentLens/Models/HermesModelID.swift
//
// Dependency-free (System-only). Hermes is a multi-runtime chat backend: under
// the hood it routes to Codex, Claude, Z.ai, Kimi, MiniMax, or Ollama. This is
// the user-selectable list of those underlying runtimes — the second-level row
// beneath the chat surface picker. The raw string values, CSV encode/decode,
// and default-enabled triple are the settings-compatibility surface.

using System;
using System.Collections.Generic;
using System.Linq;

namespace OpenBurnBar.App.Settings;

/// <summary>
/// Hermes runtime model. Mirrors the macOS <c>HermesModelID</c> — including its
/// raw string values (the persisted, CSV-encoded settings token).
/// </summary>
public enum HermesModelId
{
    Codex,
    Claude,
    Zai,
    Kimi,
    MiniMax,
    Ollama,
}

/// <summary>Metadata for <see cref="HermesModelId"/>, parity with the Swift enum members.</summary>
public static class HermesModelMetadata
{
    /// <summary>
    /// Default visible models when the user hasn't customized the list. Swift
    /// <c>defaultEnabled</c>: the minimum-default triple so existing users see
    /// the same shape on upgrade.
    /// </summary>
    public static readonly HermesModelId[] DefaultEnabled =
    {
        HermesModelId.Codex,
        HermesModelId.Claude,
        HermesModelId.Ollama,
    };

    /// <summary>The persisted raw value (Swift <c>rawValue</c>). Drives CSV round-trip.</summary>
    public static string RawValue(this HermesModelId model) => model switch
    {
        HermesModelId.Codex => "codex",
        HermesModelId.Claude => "claude",
        HermesModelId.Zai => "zai",
        HermesModelId.Kimi => "kimi",
        HermesModelId.MiniMax => "minimax",
        HermesModelId.Ollama => "ollama",
        _ => throw new ArgumentOutOfRangeException(nameof(model), model, null),
    };

    /// <summary>Parse a persisted raw value, or <c>null</c> if unknown. Swift:
    /// <c>HermesModelID(rawValue:)</c>.</summary>
    public static HermesModelId? FromRawValue(string? raw)
    {
        foreach (HermesModelId model in Enum.GetValues(typeof(HermesModelId)))
        {
            if (string.Equals(model.RawValue(), raw, StringComparison.Ordinal))
            {
                return model;
            }
        }

        return null;
    }

    /// <summary>Full display name. Swift <c>displayName</c>.</summary>
    public static string DisplayName(this HermesModelId model) => model switch
    {
        HermesModelId.Codex => "Codex",
        HermesModelId.Claude => "Claude",
        HermesModelId.Zai => "Z.ai",
        HermesModelId.Kimi => "Kimi",
        HermesModelId.MiniMax => "MiniMax",
        HermesModelId.Ollama => "Ollama",
        _ => throw new ArgumentOutOfRangeException(nameof(model), model, null),
    };

    /// <summary>Short label for the compact row. Swift <c>shortLabel</c> (== display name).</summary>
    public static string ShortLabel(this HermesModelId model) => model.DisplayName();

    /// <summary>Provider logo that represents this model in UI. Swift <c>agentProvider</c>.</summary>
    public static global::OpenBurnBar.App.Settings.AgentProvider AgentProvider(this HermesModelId model) =>
        model switch
        {
            HermesModelId.Codex => global::OpenBurnBar.App.Settings.AgentProvider.Codex,
            HermesModelId.Claude => global::OpenBurnBar.App.Settings.AgentProvider.ClaudeCode,
            HermesModelId.Zai => global::OpenBurnBar.App.Settings.AgentProvider.Zai,
            HermesModelId.Kimi => global::OpenBurnBar.App.Settings.AgentProvider.Kimi,
            HermesModelId.MiniMax => global::OpenBurnBar.App.Settings.AgentProvider.MiniMax,
            HermesModelId.Ollama => global::OpenBurnBar.App.Settings.AgentProvider.Ollama,
            _ => throw new ArgumentOutOfRangeException(nameof(model), model, null),
        };

    /// <summary>
    /// Model identifier wired into Hermes Gateway when this row is selected.
    /// Swift <c>hermesModelOverride</c>: mirrors the CLI bridge's canonical
    /// names so chat resolution needs no separate switch.
    /// </summary>
    public static string HermesModelOverride(this HermesModelId model) => model switch
    {
        HermesModelId.Codex => "codex",
        HermesModelId.Claude => "claude",
        HermesModelId.Zai => "zai",
        HermesModelId.Kimi => "kimi",
        HermesModelId.MiniMax => "minimax",
        HermesModelId.Ollama => "ollama",
        _ => throw new ArgumentOutOfRangeException(nameof(model), model, null),
    };

    /// <summary>Swift <c>decodeEnabledList(fromCSV:)</c>.</summary>
    public static IReadOnlyList<HermesModelId> DecodeEnabledList(string csv)
    {
        if (string.IsNullOrEmpty(csv))
        {
            return Array.Empty<HermesModelId>();
        }

        return csv
            .Split(',')
            .Select(part => part.Trim())
            .Where(part => part.Length > 0)
            .Select(FromRawValue)
            .Where(model => model is not null)
            .Select(model => model!.Value)
            .ToList();
    }

    /// <summary>Swift <c>encodeEnabledList(_:)</c>.</summary>
    public static string EncodeEnabledList(IEnumerable<HermesModelId> models) =>
        string.Join(",", models.Select(model => model.RawValue()));

    /// <summary>
    /// Swift <c>enabledHermesModels</c> getter: an empty persisted list means
    /// "never customized" and resolves to the minimum-default triple.
    /// </summary>
    public static IReadOnlyList<HermesModelId> EnabledOrDefault(string csv)
    {
        IReadOnlyList<HermesModelId> list = DecodeEnabledList(csv);
        return list.Count == 0 ? DefaultEnabled : list;
    }

    /// <summary>Swift <c>ChatBackendSettings.setHermesModelEnabled</c> as a pure
    /// list transform: enabling appends (deduped), disabling removes all copies.</summary>
    public static IReadOnlyList<HermesModelId> WithEnabled(
        IReadOnlyList<HermesModelId> current,
        HermesModelId id,
        bool enabled)
    {
        if (enabled)
        {
            return current.Contains(id) ? current : current.Concat(new[] { id }).ToList();
        }

        return current.Where(model => model != id).ToList();
    }

    /// <summary>
    /// Swift <c>ChatBackendSettings.applyHermesModelSelection</c> decision core:
    /// the selection mirrors into <c>hermesChatModelOverride</c> so the existing
    /// chat resolution path picks it up; clearing the selection clears the
    /// override so the gateway-advertised default wins.
    /// </summary>
    public static string HermesModelOverrideForSelection(HermesModelId? model) =>
        model?.HermesModelOverride() ?? string.Empty;
}
