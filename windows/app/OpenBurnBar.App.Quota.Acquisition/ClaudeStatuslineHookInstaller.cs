using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace OpenBurnBar.App.Quota.Acquisition;

// ── MECHANISM 1 · hook installer ─────────────────────────────────────────────
//
// Windows peer of AgentLens/Services/ProviderQuota/ClaudeQuotaBridgeManager.swift.
// Installs a `.cmd` + PowerShell wrapper pair as the Claude Code `statusLine`
// command in ~/.claude/settings.json. The wrapper's contract mirrors the Mac
// `claude_statusline_bridge.sh` exactly: tee stdin → snapshot file, then replay
// the same stdin bytes into the user's ORIGINAL statusline command (recorded in
// a metadata sidecar) so their statusline keeps rendering. Uninstall restores
// the original statusLine verbatim and removes the wrapper + metadata.
//
// The logic is path-injected and portable so it is fully unit-tested on macOS;
// the .Windows sibling supplies the real %LOCALAPPDATA%/%USERPROFILE% defaults.

/// <summary>Where the hook artifacts live. Defaults come from the .Windows sibling.</summary>
public sealed record ClaudeStatuslineHookPaths(
    string ClaudeSettingsPath,
    string WrapperCmdPath,
    string WrapperPs1Path,
    string SnapshotPath,
    string MetadataPath);

/// <summary>Installs/uninstalls the Claude Code statusline quota bridge.</summary>
public sealed class ClaudeStatuslineHookInstaller
{
    // Swift ClaudeQuotaBridgeManager.shellSplit rejects command strings carrying
    // shell metacharacters rather than mis-parsing them (`originalCommandSpec`
    // becomes null and only the raw statusLine is preserved for restore).
    private static readonly char[] UnsafeCommandCharacters =
        { '|', '&', ';', '<', '>', '(', ')', '$', '`', '%', '^' };

    private static readonly JsonSerializerOptions WriteOptions = new() { WriteIndented = true };

    private readonly ClaudeStatuslineHookPaths _paths;
    private readonly Func<DateTimeOffset> _now;

    /// <summary>Create an installer over explicit paths (injectable clock discipline).</summary>
    public ClaudeStatuslineHookInstaller(ClaudeStatuslineHookPaths paths, Func<DateTimeOffset>? now = null)
    {
        _paths = paths ?? throw new ArgumentNullException(nameof(paths));
        _now = now ?? (static () => DateTimeOffset.UtcNow);
    }

    /// <summary>The settings.json <c>statusLine.command</c> value pointing at the wrapper.</summary>
    public string BridgeCommand =>
        _paths.WrapperCmdPath.Contains(' ', StringComparison.Ordinal)
            ? $"\"{_paths.WrapperCmdPath}\""
            : _paths.WrapperCmdPath;

    /// <summary>Whether settings.json currently routes the statusline through the wrapper.</summary>
    public bool IsInstalled()
    {
        JsonObject settings = LoadSettings();
        return IsBridgeStatusLine(settings["statusLine"]);
    }

    /// <summary>
    /// Install: capture the user's original statusline into the metadata sidecar
    /// (unless the bridge is already installed), write the wrapper pair, and point
    /// <c>statusLine</c> at the <c>.cmd</c>. Idempotent — re-installing never
    /// records the bridge as the "original".
    /// </summary>
    public void Install()
    {
        EnsureParentDirectory(_paths.ClaudeSettingsPath);
        EnsureParentDirectory(_paths.WrapperCmdPath);
        EnsureParentDirectory(_paths.WrapperPs1Path);
        EnsureParentDirectory(_paths.SnapshotPath);
        EnsureParentDirectory(_paths.MetadataPath);

        JsonObject settings = LoadSettings();
        JsonNode? existing = settings["statusLine"];

        if (!IsBridgeStatusLine(existing))
        {
            WriteMetadata(existing);
        }

        File.WriteAllText(_paths.WrapperCmdPath, BuildCmdScript(), new UTF8Encoding(false));
        File.WriteAllText(_paths.WrapperPs1Path, BuildPowerShellScript(), new UTF8Encoding(false));

        settings["statusLine"] = new JsonObject
        {
            ["type"] = "command",
            ["command"] = BridgeCommand,
        };
        SaveSettings(settings);
    }

    /// <summary>
    /// Uninstall: restore the original statusLine recorded at install time (or
    /// remove the key when there was none), then delete the wrapper pair and the
    /// metadata sidecar. The snapshot file is left in place (Mac parity).
    /// </summary>
    public void Uninstall()
    {
        JsonObject settings = LoadSettings();

        JsonNode? original = null;
        var hadMetadata = false;
        if (File.Exists(_paths.MetadataPath))
        {
            hadMetadata = true;
            try
            {
                var metadata = JsonNode.Parse(File.ReadAllText(_paths.MetadataPath)) as JsonObject;
                original = metadata?["originalStatusLine"]?.DeepClone();
            }
            catch (JsonException)
            {
                original = null;
            }
        }

        if (IsBridgeStatusLine(settings["statusLine"]) || hadMetadata)
        {
            if (original is null || original.GetValueKind() == JsonValueKind.Null)
            {
                settings.Remove("statusLine");
            }
            else
            {
                settings["statusLine"] = original;
            }

            SaveSettings(settings);
        }

        DeleteIfExists(_paths.WrapperCmdPath);
        DeleteIfExists(_paths.WrapperPs1Path);
        DeleteIfExists(_paths.MetadataPath);
    }

    // ── settings.json ────────────────────────────────────────────────────────

    private JsonObject LoadSettings()
    {
        if (!File.Exists(_paths.ClaudeSettingsPath))
        {
            return new JsonObject();
        }

        try
        {
            return JsonNode.Parse(File.ReadAllText(_paths.ClaudeSettingsPath)) as JsonObject ?? new JsonObject();
        }
        catch (JsonException)
        {
            return new JsonObject();
        }
    }

    private void SaveSettings(JsonObject settings)
    {
        File.WriteAllText(
            _paths.ClaudeSettingsPath,
            settings.ToJsonString(WriteOptions),
            new UTF8Encoding(false));
    }

    private bool IsBridgeStatusLine(JsonNode? statusLine)
    {
        if (statusLine is not JsonObject obj)
        {
            return false;
        }

        var command = obj["command"]?.GetValue<string>();
        return command is not null
            && command.Contains(_paths.WrapperCmdPath, StringComparison.OrdinalIgnoreCase);
    }

    // ── metadata sidecar (Swift claude_statusline_bridge_metadata.json) ──────

    private void WriteMetadata(JsonNode? originalStatusLine)
    {
        JsonNode? spec = null;
        if (originalStatusLine is JsonObject obj
            && obj["command"]?.GetValue<string>() is string command
            && CommandSpec(command) is var (executable, arguments)
            && executable is not null)
        {
            var argumentsNode = new JsonArray();
            foreach (var argument in arguments)
            {
                argumentsNode.Add(argument);
            }

            spec = new JsonObject
            {
                ["executable"] = executable,
                ["arguments"] = argumentsNode,
            };
        }

        var metadata = new JsonObject
        {
            ["originalStatusLine"] = originalStatusLine?.DeepClone() ?? JsonValue.Create((string?)null),
            ["originalCommandSpec"] = spec,
            ["installedAt"] = _now().UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture),
            ["wrapperPath"] = _paths.WrapperCmdPath,
        };

        File.WriteAllText(_paths.MetadataPath, metadata.ToJsonString(WriteOptions), new UTF8Encoding(false));
    }

    /// <summary>
    /// Split a statusline command string into executable + arguments, mirroring
    /// the Swift <c>shellSplit</c>: honor single/double quotes, and refuse (null)
    /// any string carrying shell metacharacters instead of mis-executing it.
    /// </summary>
    public static (string? Executable, IReadOnlyList<string> Arguments) CommandSpec(string command)
    {
        var trimmed = command.Trim();
        if (trimmed.Length == 0 || trimmed.IndexOfAny(UnsafeCommandCharacters) >= 0)
        {
            return (null, Array.Empty<string>());
        }

        var parts = new List<string>();
        var current = new StringBuilder();
        char? quote = null;
        foreach (var ch in trimmed)
        {
            if (quote is char q)
            {
                if (ch == q)
                {
                    quote = null;
                }
                else
                {
                    current.Append(ch);
                }
            }
            else if (ch is '\'' or '"')
            {
                quote = ch;
            }
            else if (char.IsWhiteSpace(ch))
            {
                if (current.Length > 0)
                {
                    parts.Add(current.ToString());
                    current.Clear();
                }
            }
            else
            {
                current.Append(ch);
            }
        }

        if (quote is not null)
        {
            return (null, Array.Empty<string>());
        }

        if (current.Length > 0)
        {
            parts.Add(current.ToString());
        }

        return parts.Count == 0
            ? (null, Array.Empty<string>())
            : (parts[0], parts.GetRange(1, parts.Count - 1));
    }

    // ── wrapper scripts ──────────────────────────────────────────────────────

    private string BuildCmdScript()
    {
        // %* forwards nothing statusline-relevant (Claude pipes JSON via stdin),
        // but keeps parity with how Claude Code invokes statusline commands.
        return "@echo off\r\n"
            + "rem OpenBurnBar Claude statusline quota bridge (Windows peer of claude_statusline_bridge.sh).\r\n"
            + $"powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"{_paths.WrapperPs1Path}\" %*\r\n";
    }

    private string BuildPowerShellScript()
    {
        var snapshot = EscapePowerShellLiteral(_paths.SnapshotPath);
        var metadata = EscapePowerShellLiteral(_paths.MetadataPath);
        return string.Join("\r\n", new[]
        {
            "# OpenBurnBar Claude statusline quota bridge.",
            "# Contract (parity with the macOS claude_statusline_bridge.sh):",
            "#   1. tee the statusline JSON from stdin into the snapshot file,",
            "#   2. replay the SAME stdin bytes into the user's original statusline",
            "#      command (from the metadata sidecar) so their statusline still renders.",
            "$ErrorActionPreference = 'SilentlyContinue'",
            $"$snapshotPath = '{snapshot}'",
            $"$metadataPath = '{metadata}'",
            "$payload = [Console]::In.ReadToEnd()",
            "[System.IO.File]::WriteAllText($snapshotPath, $payload)",
            "try {",
            "  if (Test-Path -LiteralPath $metadataPath) {",
            "    $meta = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json",
            "    $spec = $meta.originalCommandSpec",
            "    if ($null -ne $spec -and $spec.executable) {",
            "      $wrapper = $meta.wrapperPath",
            "      if (-not $wrapper -or ($spec.executable -ne $wrapper)) {",
            "        $psi = New-Object System.Diagnostics.ProcessStartInfo",
            "        $psi.FileName = $spec.executable",
            "        foreach ($arg in @($spec.arguments)) { [void]$psi.ArgumentList.Add([string]$arg) }",
            "        $psi.UseShellExecute = $false",
            "        $psi.RedirectStandardInput = $true",
            "        $proc = [System.Diagnostics.Process]::Start($psi)",
            "        $proc.StandardInput.Write($payload)",
            "        $proc.StandardInput.Close()",
            "        $proc.WaitForExit()",
            "      }",
            "    }",
            "  }",
            "} catch { }",
            string.Empty,
        });
    }

    private static string EscapePowerShellLiteral(string value) =>
        value.Replace("'", "''", StringComparison.Ordinal);

    private static void EnsureParentDirectory(string path)
    {
        var directory = Path.GetDirectoryName(path);
        if (!string.IsNullOrEmpty(directory))
        {
            Directory.CreateDirectory(directory);
        }
    }

    private static void DeleteIfExists(string path)
    {
        if (File.Exists(path))
        {
            File.Delete(path);
        }
    }
}
