using System;
using System.Collections.Generic;
using System.IO;
using OpenBurnBar.App.Configuration;

namespace OpenBurnBar.App.Quota.Acquisition.Windows;

// Default on-disk locations for the acquisition mechanisms — the Windows peers
// of OpenBurnBarCore/.../Services/OpenBurnBarIdentity.swift (the Mac keeps its
// bridge artifacts under ~/Library/Application Support/OpenBurnBar/). Follows
// the RuntimePaths convention: %LOCALAPPDATA%\OpenBurnBar in normal runs,
// OPENBURNBAR_AUTOMATION_PROFILE_ROOT in harness runs, else ~/.openburnbar.

/// <summary>Default acquisition paths (env-derived; every consumer is path-injected).</summary>
public static class WindowsQuotaAcquisitionPaths
{
    /// <summary><c>%LOCALAPPDATA%\OpenBurnBar</c>, automation profile root, or dev-host fallback <c>~/.openburnbar</c>.</summary>
    public static string SupportDirectory() => RuntimePaths.AppDataDirectory();

    /// <summary>Mac peer: <c>claude_statusline_snapshot.json</c> in the support dir.</summary>
    public static string ClaudeStatuslineSnapshotPath() =>
        Path.Combine(SupportDirectory(), "claude_statusline_snapshot.json");

    /// <summary>The <c>.cmd</c> entry point Claude Code's statusLine invokes.</summary>
    public static string ClaudeStatuslineWrapperCmdPath() =>
        Path.Combine(SupportDirectory(), "claude_statusline_bridge.cmd");

    /// <summary>The PowerShell body the <c>.cmd</c> delegates to.</summary>
    public static string ClaudeStatuslineWrapperPs1Path() =>
        Path.Combine(SupportDirectory(), "claude_statusline_bridge.ps1");

    /// <summary>Mac peer: <c>claude_statusline_bridge_metadata.json</c>.</summary>
    public static string ClaudeStatuslineMetadataPath() =>
        Path.Combine(SupportDirectory(), "claude_statusline_bridge_metadata.json");

    /// <summary><c>~/.claude/settings.json</c> (same relative home path on both platforms).</summary>
    public static string ClaudeSettingsPath() =>
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            ".claude",
            "settings.json");

    /// <summary>The full hook path set for <c>ClaudeStatuslineHookInstaller</c>.</summary>
    public static ClaudeStatuslineHookPaths ClaudeHookPaths() => new(
        ClaudeSettingsPath(),
        ClaudeStatuslineWrapperCmdPath(),
        ClaudeStatuslineWrapperPs1Path(),
        ClaudeStatuslineSnapshotPath(),
        ClaudeStatuslineMetadataPath());

    /// <summary>
    /// Cursor <c>state.vscdb</c> candidates, primary then Nightly (Swift
    /// CursorCookieExtractor order). Windows: <c>%APPDATA%\Cursor\User\globalStorage</c>;
    /// dev-host fallback: the macOS <c>~/Library/Application Support</c> layout so a
    /// real Cursor install feeds the dev host too.
    /// </summary>
    public static IReadOnlyList<string> CursorStateDbCandidates()
    {
        string? appData = Environment.GetEnvironmentVariable("APPDATA");
        string root = !string.IsNullOrWhiteSpace(appData)
            ? appData
            : Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                "Library",
                "Application Support");

        return new[]
        {
            Path.Combine(root, "Cursor", "User", "globalStorage", "state.vscdb"),
            Path.Combine(root, "Cursor Nightly", "User", "globalStorage", "state.vscdb"),
        };
    }

    /// <summary>
    /// The Codex home holding <c>auth.json</c>: <c>CODEX_HOME</c>, else the
    /// <c>CODEX_CONFIG_PATH</c> directory, else <c>~/.codex</c> (Swift
    /// <c>codexConfigURL</c> order).
    /// </summary>
    public static string CodexHomeDirectory()
    {
        string? home = Environment.GetEnvironmentVariable("CODEX_HOME");
        if (!string.IsNullOrWhiteSpace(home))
        {
            return home;
        }

        string? configPath = Environment.GetEnvironmentVariable("CODEX_CONFIG_PATH");
        if (!string.IsNullOrWhiteSpace(configPath))
        {
            return configPath;
        }

        return Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            ".codex");
    }
}
