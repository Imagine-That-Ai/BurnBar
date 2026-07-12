using System;
using System.Collections.Generic;
using System.IO;
using OpenBurnBar.App.Configuration;

namespace OpenBurnBar.App.Shell;

internal sealed class AutomationLaunchOptions
{
    private AutomationLaunchOptions(
        bool mainWindow,
        string? profileRoot,
        string? outputDirectory,
        string? appearanceMode,
        bool? reduceTransparency)
    {
        MainWindow = mainWindow;
        ProfileRoot = profileRoot;
        OutputDirectory = outputDirectory;
        AppearanceMode = appearanceMode;
        ReduceTransparency = reduceTransparency;
    }

    public bool MainWindow { get; }

    public string? ProfileRoot { get; }

    public string? OutputDirectory { get; }

    public string? AppearanceMode { get; }

    public bool? ReduceTransparency { get; }

    public bool Enabled =>
        MainWindow
        || !string.IsNullOrWhiteSpace(ProfileRoot)
        || !string.IsNullOrWhiteSpace(OutputDirectory)
        || !string.IsNullOrWhiteSpace(AppearanceMode)
        || ReduceTransparency is not null;

    public static AutomationLaunchOptions? Parse(string? arguments)
    {
        IReadOnlyList<string> parts = CommandLineParts.Split(arguments);
        if (parts.Count == 0)
        {
            return null;
        }

        var mainWindow = false;
        string? profileRoot = null;
        string? outputDirectory = null;
        string? appearanceMode = null;
        bool? reduceTransparency = null;
        for (var i = 0; i < parts.Count; i++)
        {
            string token = parts[i];
            if (string.Equals(token, "--automation-main-window", StringComparison.OrdinalIgnoreCase))
            {
                mainWindow = true;
            }
            else if (string.Equals(token, "--automation-profile", StringComparison.OrdinalIgnoreCase) && i + 1 < parts.Count)
            {
                profileRoot = parts[++i];
            }
            else if (string.Equals(token, "--automation-out", StringComparison.OrdinalIgnoreCase) && i + 1 < parts.Count)
            {
                outputDirectory = parts[++i];
            }
            else if (string.Equals(token, "--automation-appearance", StringComparison.OrdinalIgnoreCase) && i + 1 < parts.Count)
            {
                appearanceMode = NormalizeAppearance(parts[++i]);
            }
            else if (string.Equals(token, "--automation-reduce-transparency", StringComparison.OrdinalIgnoreCase) && i + 1 < parts.Count)
            {
                reduceTransparency = ParseBoolean(parts[++i]);
            }
        }

        var options = new AutomationLaunchOptions(
            mainWindow,
            NormalizeDirectory(profileRoot),
            NormalizeDirectory(outputDirectory),
            appearanceMode,
            reduceTransparency);
        return options.Enabled ? options : null;
    }

    public void ApplyEnvironment()
    {
        if (!string.IsNullOrWhiteSpace(ProfileRoot))
        {
            Environment.SetEnvironmentVariable(RuntimePaths.AutomationProfileRootEnvironmentVariable, ProfileRoot);
        }
    }

    public void ApplyStateSeed(AppStatePersistence persistence)
    {
        var changed = false;
        if (!string.IsNullOrWhiteSpace(AppearanceMode))
        {
            persistence.State.AppearanceMode = AppearanceMode;
            changed = true;
        }

        if (ReduceTransparency is bool reduceTransparency)
        {
            persistence.State.ReduceTransparency = reduceTransparency;
            changed = true;
        }

        if (changed)
        {
            persistence.Save();
        }
    }

    public void WriteLaunchMarker()
    {
        if (string.IsNullOrWhiteSpace(OutputDirectory))
        {
            return;
        }

        try
        {
            Directory.CreateDirectory(OutputDirectory);
            File.WriteAllText(
                Path.Combine(OutputDirectory, "automation-launch.json"),
                $$"""
                {
                  "pid": {{Environment.ProcessId}},
                  "profileRoot": {{Json(ProfileRoot)}},
                  "appDataDirectory": {{Json(RuntimePaths.AppDataDirectory())}},
                  "appearanceMode": {{Json(AppearanceMode)}},
                  "reduceTransparency": {{Json(ReduceTransparency)}},
                  "generatedAtUtc": {{Json(DateTimeOffset.UtcNow.ToString("O"))}}
                }
                """);
        }
        catch
        {
            // Automation markers are diagnostic only; never block app launch.
        }
    }

    private static string? NormalizeDirectory(string? path) =>
        string.IsNullOrWhiteSpace(path) ? null : Path.GetFullPath(path.Trim());

    private static string? NormalizeAppearance(string? raw) =>
        raw?.Trim().ToLowerInvariant() switch
        {
            "system" => "system",
            "light" => "light",
            "dark" => "dark",
            "highcontrast" or "high-contrast" or "high_contrast" => "highcontrast",
            _ => null,
        };

    private static bool? ParseBoolean(string? raw) =>
        bool.TryParse(raw, out bool parsed) ? parsed : null;

    private static string Json(string? value) =>
        value is null ? "null" : "\"" + value.Replace("\\", "\\\\", StringComparison.Ordinal).Replace("\"", "\\\"", StringComparison.Ordinal) + "\"";

    private static string Json(bool? value) =>
        value is bool parsed ? (parsed ? "true" : "false") : "null";
}
