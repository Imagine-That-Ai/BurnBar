using System;
using System.IO;
using System.Linq;

namespace OpenBurnBar.UiAutomationHarness;

internal static class AppExeResolver
{
    public static string Resolve(string repoRoot, string? requested)
    {
        if (!string.IsNullOrWhiteSpace(requested))
        {
            string full = Path.GetFullPath(requested);
            if (!File.Exists(full))
            {
                throw new FileNotFoundException("OpenBurnBar app executable was not found.", full);
            }

            return full;
        }

        string binRoot = Path.Combine(repoRoot, "windows", "app", "OpenBurnBar.App", "bin");
        if (!Directory.Exists(binRoot))
        {
            throw new DirectoryNotFoundException($"OpenBurnBar app bin directory was not found: {binRoot}");
        }

        string? latest = Directory
            .EnumerateFiles(binRoot, "OpenBurnBar.App.exe", SearchOption.AllDirectories)
            .Select(path => new FileInfo(path))
            .OrderByDescending(info => info.LastWriteTimeUtc)
            .FirstOrDefault()
            ?.FullName;
        return latest ?? throw new FileNotFoundException("OpenBurnBar.App.exe was not found. Build windows/app/OpenBurnBar.App/OpenBurnBar.App.csproj first.");
    }
}
