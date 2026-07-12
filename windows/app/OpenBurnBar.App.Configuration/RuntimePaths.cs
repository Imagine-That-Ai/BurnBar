using System;
using System.IO;

namespace OpenBurnBar.App.Configuration;

/// <summary>
/// Process-wide filesystem roots for the Windows app.
///
/// Normal runs use the user's app data folder. Automation runs may set
/// <c>OPENBURNBAR_AUTOMATION_PROFILE_ROOT</c> before any app services initialize;
/// every app-owned state/log/config file then lives under that throwaway root.
/// </summary>
public static class RuntimePaths
{
    public const string AutomationProfileRootEnvironmentVariable = "OPENBURNBAR_AUTOMATION_PROFILE_ROOT";

    public static string AppDataDirectory()
    {
        string? automationRoot = Environment.GetEnvironmentVariable(AutomationProfileRootEnvironmentVariable);
        if (!string.IsNullOrWhiteSpace(automationRoot))
        {
            return Path.GetFullPath(automationRoot.Trim());
        }

        string? local = Environment.GetEnvironmentVariable("LOCALAPPDATA");
        if (!string.IsNullOrWhiteSpace(local))
        {
            return Path.Combine(local, "OpenBurnBar");
        }

        string home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        return Path.Combine(home, ".openburnbar");
    }

    public static string AppDataFile(string fileName)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(fileName);
        return Path.Combine(AppDataDirectory(), fileName);
    }

    public static string AppDataSubdirectory(string name)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(name);
        return Path.Combine(AppDataDirectory(), name);
    }
}
