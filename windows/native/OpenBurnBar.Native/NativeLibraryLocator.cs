using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;

namespace OpenBurnBar.Native;

/// <summary>
/// Locates a Rust cdylib by logical name using a fixed, hardened probe order.
///
/// Search-order hardening (the managed half of the R19 DLL-planting posture —
/// see windows/dist/DLL_HARDENING.md): only ABSOLUTE, explicitly enumerated
/// directories are probed — never the current working directory, never
/// PATH — and the resolved candidate is handed to
/// <see cref="System.Runtime.InteropServices.NativeLibrary"/> as a fully
/// qualified path so the OS loader performs no search of its own. This
/// composes with the app-level <c>DllSearchHardening.Apply()</c>
/// (SetDefaultDllDirectories) rather than replacing it.
///
/// Probe order:
///   1. <c>OPENBURNBAR_NATIVE_DIR</c> — explicit operator/test override.
///   2. The application base directory (where the build copies the cdylib).
///   3. <c>runtimes/&lt;rid&gt;/native</c> under the base directory — the
///      standard .NET packaging layout for architecture-split native assets
///      (x64 + ARM64 in one distribution).
/// </summary>
public static class NativeLibraryLocator
{
    /// <summary>Environment variable naming an absolute directory to probe
    /// first. Used by the loopback tests and by dev hosts running against a
    /// locally built cargo target directory.</summary>
    public const string SearchDirEnvVar = "OPENBURNBAR_NATIVE_DIR";

    /// <summary>Maps a logical library name (<c>burnbar_remote</c>) to the
    /// platform file name (<c>burnbar_remote.dll</c> /
    /// <c>libburnbar_remote.dylib</c> / <c>libburnbar_remote.so</c>).</summary>
    public static string PlatformFileName(string logicalName)
    {
        if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
        {
            return logicalName + ".dll";
        }

        return RuntimeInformation.IsOSPlatform(OSPlatform.OSX)
            ? "lib" + logicalName + ".dylib"
            : "lib" + logicalName + ".so";
    }

    /// <summary>The default hardened probe directories, in order. Every entry
    /// is absolute; relative candidates (e.g. a relative
    /// <see cref="SearchDirEnvVar"/> value) are rejected rather than resolved
    /// against the current working directory.</summary>
    public static IReadOnlyList<string> DefaultSearchDirectories()
    {
        var directories = new List<string>(3);

        string? overrideDir = Environment.GetEnvironmentVariable(SearchDirEnvVar);
        if (!string.IsNullOrWhiteSpace(overrideDir) && Path.IsPathRooted(overrideDir))
        {
            directories.Add(overrideDir);
        }

        string baseDir = AppContext.BaseDirectory;
        if (!string.IsNullOrEmpty(baseDir))
        {
            directories.Add(baseDir);
            directories.Add(Path.Combine(baseDir, "runtimes", RuntimeInformation.RuntimeIdentifier, "native"));
        }

        return directories;
    }

    /// <summary>Locates the cdylib in the default probe directories. Returns
    /// the absolute path of the first hit, or null when absent.</summary>
    public static string? Locate(string logicalName) => Locate(logicalName, DefaultSearchDirectories());

    /// <summary>Pure probe over an explicit directory list (unit-testable with
    /// no native library present). Non-absolute directories are skipped —
    /// the locator never consults the current working directory.</summary>
    public static string? Locate(string logicalName, IEnumerable<string> searchDirectories)
    {
        if (string.IsNullOrWhiteSpace(logicalName))
        {
            throw new ArgumentException("logical library name must be non-empty", nameof(logicalName));
        }

        string fileName = PlatformFileName(logicalName);
        foreach (string directory in searchDirectories)
        {
            if (string.IsNullOrWhiteSpace(directory) || !Path.IsPathRooted(directory))
            {
                continue;
            }

            string candidate = Path.GetFullPath(Path.Combine(directory, fileName));
            if (File.Exists(candidate))
            {
                return candidate;
            }
        }

        return null;
    }
}
