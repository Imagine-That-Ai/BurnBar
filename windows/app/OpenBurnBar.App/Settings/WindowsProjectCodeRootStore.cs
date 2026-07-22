using System;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using OpenBurnBar.App.Settings.ViewModels;

namespace OpenBurnBar.App.Settings.Winui;

internal sealed class WindowsProjectCodeRootStore : IProjectCodeRootSettingsStore
{
    private const string SettingsKey = "projectCode.root";
    private readonly WindowsSettingsPersistence _persistence;

    public WindowsProjectCodeRootStore(WindowsSettingsPersistence persistence) =>
        _persistence = persistence ?? throw new ArgumentNullException(nameof(persistence));

    public ProjectCodeRootSettingsSnapshot Load() =>
        _persistence.Read(SettingsKey, ProjectCodeRootSettingsSnapshot.Default);

    public void Save(ProjectCodeRootSettingsSnapshot settings) =>
        _persistence.Write(SettingsKey, settings);
}

internal static class WindowsProjectCodePaths
{
    public static string IndexPathForRoot(string rootPath)
    {
        string canonical = Path.TrimEndingDirectorySeparator(Path.GetFullPath(rootPath));
        StringComparison comparison = OperatingSystem.IsWindows()
            ? StringComparison.OrdinalIgnoreCase
            : StringComparison.Ordinal;
        string identityInput = comparison == StringComparison.OrdinalIgnoreCase
            ? canonical.ToUpperInvariant()
            : canonical;
        string identity = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(identityInput)))
            .ToLowerInvariant();
        return Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "OpenBurnBar",
            "ProjectCode",
            "indexes",
            identity + ".json");
    }
}
