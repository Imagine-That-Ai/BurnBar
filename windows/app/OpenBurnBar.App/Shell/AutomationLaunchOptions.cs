using System;
using System.Collections.Generic;
using System.IO;
using OpenBurnBar.App.Configuration;

namespace OpenBurnBar.App.Shell;

internal sealed class AutomationLaunchOptions
{
    private AutomationLaunchOptions(bool mainWindow, string? profileRoot, string? outputDirectory)
    {
        MainWindow = mainWindow;
        ProfileRoot = profileRoot;
        OutputDirectory = outputDirectory;
    }

    public bool MainWindow { get; }

    public string? ProfileRoot { get; }

    public string? OutputDirectory { get; }

    public bool Enabled => MainWindow || !string.IsNullOrWhiteSpace(ProfileRoot) || !string.IsNullOrWhiteSpace(OutputDirectory);

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
        }

        var options = new AutomationLaunchOptions(
            mainWindow,
            NormalizeDirectory(profileRoot),
            NormalizeDirectory(outputDirectory));
        return options.Enabled ? options : null;
    }

    public void ApplyEnvironment()
    {
        if (!string.IsNullOrWhiteSpace(ProfileRoot))
        {
            Environment.SetEnvironmentVariable(RuntimePaths.AutomationProfileRootEnvironmentVariable, ProfileRoot);
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

    private static string Json(string? value) =>
        value is null ? "null" : "\"" + value.Replace("\\", "\\\\", StringComparison.Ordinal).Replace("\"", "\\\"", StringComparison.Ordinal) + "\"";
}
