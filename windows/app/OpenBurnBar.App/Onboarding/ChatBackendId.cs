// PORTED (portable, unit-tested) from AgentLens/Models/ChatBackendID.swift
//   enum ChatBackendID: String, Identifiable, Codable { ... }
//
// Dependency-free (System-only, NO WinUI). The raw string values, the AllCases
// ORDER, the agent-provider logo mapping, and the CSV encode/decode are the
// settings-compatibility surface — they must round-trip the exact same strings
// the macOS app persists, so they are asserted by a real `dotnet test`.

using System;
using System.Collections.Generic;
using System.Linq;
using OpenBurnBar.App.Theme;

namespace OpenBurnBar.App.Onboarding;

/// <summary>
/// User-selected chat engine. Mirrors the macOS <c>ChatBackendID</c> — including its
/// custom <c>allCases</c> order (which differs from declaration order) and its raw
/// string values (the persisted, CSV-encoded settings token).
/// </summary>
public enum ChatBackendId
{
    Codex,
    Claude,
    Hermes,
    OpenClaw,
    OpenClaude,
    Omp,
    PiAgent,
    Droid,
    Forge,
    Antigravity,
    CursorAgent,
}

/// <summary>Metadata for <see cref="ChatBackendId"/>, parity with the Swift enum members.</summary>
public static class ChatBackendMetadata
{
    /// <summary>
    /// Enabled/ordered list order. Swift: the hand-built <c>static var allCases</c>
    /// (codex, claude, hermes, piAgent, openclaw, openClaude, omp, droid, forge,
    /// antigravity, cursorAgent) — NOT declaration order. This is the order enabled
    /// backends render in and the order a default engine falls back through.
    /// </summary>
    public static readonly ChatBackendId[] AllCases =
    {
        ChatBackendId.Codex,
        ChatBackendId.Claude,
        ChatBackendId.Hermes,
        ChatBackendId.PiAgent,
        ChatBackendId.OpenClaw,
        ChatBackendId.OpenClaude,
        ChatBackendId.Omp,
        ChatBackendId.Droid,
        ChatBackendId.Forge,
        ChatBackendId.Antigravity,
        ChatBackendId.CursorAgent,
    };

    /// <summary>The persisted raw value (Swift <c>rawValue</c>). Drives CSV round-trip.</summary>
    public static string RawValue(this ChatBackendId backend) => backend switch
    {
        ChatBackendId.Codex => "codex",
        ChatBackendId.Claude => "claude",
        ChatBackendId.Hermes => "hermes",
        ChatBackendId.OpenClaw => "openclaw",
        ChatBackendId.OpenClaude => "openclaude",
        ChatBackendId.Omp => "omp",
        ChatBackendId.PiAgent => "piAgent",
        ChatBackendId.Droid => "droid",
        ChatBackendId.Forge => "forge",
        ChatBackendId.Antigravity => "antigravity",
        ChatBackendId.CursorAgent => "cursorAgent",
        _ => throw new ArgumentOutOfRangeException(nameof(backend), backend, null),
    };

    /// <summary>Parse a persisted raw value, or <c>null</c> if unknown. Swift:
    /// <c>ChatBackendID(rawValue:)</c>.</summary>
    public static ChatBackendId? FromRawValue(string? raw)
    {
        foreach (ChatBackendId backend in AllCases)
        {
            if (string.Equals(backend.RawValue(), raw, StringComparison.Ordinal))
            {
                return backend;
            }
        }

        return null;
    }

    /// <summary>Full display name. Swift <c>displayName</c>.</summary>
    public static string DisplayName(this ChatBackendId backend) => backend switch
    {
        ChatBackendId.Codex => "Codex",
        ChatBackendId.Claude => "Claude Code",
        ChatBackendId.Hermes => "Hermes",
        ChatBackendId.OpenClaw => "OpenClaw",
        ChatBackendId.OpenClaude => "OpenClaude",
        ChatBackendId.Omp => "OMP",
        ChatBackendId.PiAgent => "Pi Agent",
        ChatBackendId.Droid => "Droid",
        ChatBackendId.Forge => "Forge",
        ChatBackendId.Antigravity => "Antigravity",
        ChatBackendId.CursorAgent => "Cursor Agent",
        _ => throw new ArgumentOutOfRangeException(nameof(backend), backend, null),
    };

    /// <summary>Short label for compact toggles. Swift <c>shortLabel</c>.</summary>
    public static string ShortLabel(this ChatBackendId backend) => backend switch
    {
        ChatBackendId.Codex => "Codex",
        ChatBackendId.Claude => "Claude",
        ChatBackendId.Hermes => "Hermes",
        ChatBackendId.OpenClaw => "Claw",
        ChatBackendId.OpenClaude => "OClaude",
        ChatBackendId.Omp => "OMP",
        ChatBackendId.PiAgent => "Pi",
        ChatBackendId.Droid => "Droid",
        ChatBackendId.Forge => "Forge",
        ChatBackendId.Antigravity => "AGY",
        ChatBackendId.CursorAgent => "Cursor",
        _ => throw new ArgumentOutOfRangeException(nameof(backend), backend, null),
    };

    /// <summary>Emblem glyph. Swift <c>glyph</c> (caduceus ☿ Hermes, π Pi, etc.).</summary>
    public static string Glyph(this ChatBackendId backend) => backend switch
    {
        ChatBackendId.Hermes => "☿",
        ChatBackendId.PiAgent => "π",
        ChatBackendId.Codex => "↻",
        ChatBackendId.Claude => "✦",
        ChatBackendId.OpenClaw => "⚡",
        ChatBackendId.OpenClaude => "✸",
        ChatBackendId.Omp => "⌘",
        ChatBackendId.Droid => "◆",
        ChatBackendId.Forge => "▰",
        ChatBackendId.Antigravity => "✧",
        ChatBackendId.CursorAgent => "➤",
        _ => throw new ArgumentOutOfRangeException(nameof(backend), backend, null),
    };

    /// <summary>The provider whose logo represents this backend in UI. Swift
    /// <c>agentProvider</c>. Never <c>null</c> on Windows (every backend maps).</summary>
    public static AgentProviderBrand AgentProvider(this ChatBackendId backend) => backend switch
    {
        ChatBackendId.Codex => AgentProviderBrand.Codex,
        ChatBackendId.Claude => AgentProviderBrand.ClaudeCode,
        ChatBackendId.Hermes => AgentProviderBrand.Hermes,
        ChatBackendId.OpenClaw => AgentProviderBrand.OpenClaw,
        ChatBackendId.OpenClaude => AgentProviderBrand.OpenClaude,
        ChatBackendId.Omp => AgentProviderBrand.Omp,
        ChatBackendId.PiAgent => AgentProviderBrand.PiAgent,
        ChatBackendId.Droid => AgentProviderBrand.Factory,
        ChatBackendId.Forge => AgentProviderBrand.ForgeDev,
        ChatBackendId.Antigravity => AgentProviderBrand.Antigravity,
        ChatBackendId.CursorAgent => AgentProviderBrand.CursorAgent,
        _ => throw new ArgumentOutOfRangeException(nameof(backend), backend, null),
    };

    /// <summary>Whether this backend uses the local Codex/Claude CLIs (privacy-gated).
    /// Swift <c>requiresCLIAssistantConsent</c>.</summary>
    public static bool RequiresCliAssistantConsent(this ChatBackendId backend) => backend switch
    {
        ChatBackendId.Codex or ChatBackendId.Claude or ChatBackendId.Droid
            or ChatBackendId.Forge or ChatBackendId.Antigravity or ChatBackendId.CursorAgent
            or ChatBackendId.OpenClaude or ChatBackendId.Omp => true,
        ChatBackendId.Hermes or ChatBackendId.OpenClaw or ChatBackendId.PiAgent => false,
        _ => throw new ArgumentOutOfRangeException(nameof(backend), backend, null),
    };

    /// <summary>Lossless comma-separated order of enabled backends (Settings order
    /// preserved). Swift <c>decodeEnabledList(fromCSV:)</c>.</summary>
    public static IReadOnlyList<ChatBackendId> DecodeEnabledList(string csv)
    {
        if (string.IsNullOrEmpty(csv))
        {
            return Array.Empty<ChatBackendId>();
        }

        return csv
            .Split(',')
            .Select(part => part.Trim())
            .Where(part => part.Length > 0)
            .Select(FromRawValue)
            .Where(backend => backend is not null)
            .Select(backend => backend!.Value)
            .ToList();
    }

    /// <summary>Swift <c>encodeEnabledList(_:)</c>.</summary>
    public static string EncodeEnabledList(IEnumerable<ChatBackendId> backends) =>
        string.Join(",", backends.Select(backend => backend.RawValue()));
}
