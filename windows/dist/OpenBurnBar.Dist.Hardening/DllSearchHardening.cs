// Runtime DLL-search hardening for the Windows app (Phase 5 · R19 library-validation equivalent).
//
// OpenBurnBar uses two runtime hardening modes:
// 1. Apply() for non-XAML processes that can safely opt into SetDefaultDllDirectories.
// 2. ApplyWinUICompatible() for the WinUI shell, where SetDefaultDllDirectories breaks WinUI 3
//    ms-appx resource resolution for Microsoft.UI.Xaml themes. The compatible mode still strips
//    the current working directory via SetDllDirectory("") and leaves link-time hardening intact.
//
// The Win32 P/Invoke declarations are pure metadata and compile on any host; they only EXECUTE on
// Windows (guarded by OperatingSystem.IsWindows()), so this restores + is unit-tested on macOS.

using System;
using System.Runtime.InteropServices;

namespace OpenBurnBar.Dist.Hardening;

/// <summary>What <see cref="DllSearchHardening.Apply"/> did.</summary>
public sealed class DllSearchHardeningResult
{
    internal DllSearchHardeningResult(bool applied, bool onWindows, int appliedFlags, string detail)
    {
        Applied = applied;
        OnWindows = onWindows;
        AppliedFlags = appliedFlags;
        Detail = detail;
    }

    /// <summary>True iff the OS search-order hardening was successfully applied.</summary>
    public bool Applied { get; }

    /// <summary>True iff running on Windows (on other hosts the call is a documented no-op).</summary>
    public bool OnWindows { get; }

    /// <summary>The LOAD_LIBRARY_SEARCH_* flags passed to SetDefaultDllDirectories (0 if skipped).</summary>
    public int AppliedFlags { get; }

    /// <summary>Human-readable detail for logging.</summary>
    public string Detail { get; }
}

/// <summary>Applies OS-level DLL-search-path hardening.</summary>
public static class DllSearchHardening
{
    /// <summary>
    /// Harden the process DLL search path. On Windows this calls
    /// SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_DEFAULT_DIRS) and SetDllDirectory("") so DLLs
    /// resolve only from the application directory, explicitly added user dirs, and System32 —
    /// never the current working directory. On non-Windows hosts it is a documented no-op. Never
    /// throws; a failed SetDefaultDllDirectories is reported via <see cref="DllSearchHardeningResult.Applied"/>.
    /// </summary>
    public static DllSearchHardeningResult Apply()
    {
        if (!OperatingSystem.IsWindows())
        {
            return new DllSearchHardeningResult(
                applied: false,
                onWindows: false,
                appliedFlags: 0,
                detail: "Non-Windows host: DLL-search hardening is a no-op (macOS uses library-validation instead).");
        }

        try
        {
            var ok = SetDefaultDllDirectories(HardeningPolicy.RecommendedDefaultDllDirectories);
            // Belt-and-suspenders: also drop the CWD from the LoadLibrary search path for callers
            // that do not use the flag-based search (SetDllDirectory("") removes the current dir).
            _ = SetDllDirectory(string.Empty);
            return ok
                ? new DllSearchHardeningResult(
                    applied: true,
                    onWindows: true,
                    appliedFlags: HardeningPolicy.RecommendedDefaultDllDirectories,
                    detail: "SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_DEFAULT_DIRS) + SetDllDirectory(\"\") applied.")
                : new DllSearchHardeningResult(
                    applied: false,
                    onWindows: true,
                    appliedFlags: 0,
                    detail: $"SetDefaultDllDirectories failed (Win32 error {Marshal.GetLastWin32Error()}).");
        }
        catch (DllNotFoundException ex)
        {
            return new DllSearchHardeningResult(false, true, 0, $"kernel32 entry point unavailable: {ex.Message}");
        }
        catch (EntryPointNotFoundException ex)
        {
            return new DllSearchHardeningResult(false, true, 0, $"SetDefaultDllDirectories unavailable: {ex.Message}");
        }
    }

    /// <summary>
    /// Harden the WinUI app without breaking Microsoft.UI.Xaml ms-appx resource resolution.
    /// SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_DEFAULT_DIRS) prevents WinUI 3 from resolving
    /// package theme resources in unpackaged self-contained runs, so the shell uses the compatible
    /// layer: drop the current directory from legacy LoadLibrary search while retaining the app's
    /// link-time hardening and dependency-load flags.
    /// </summary>
    public static DllSearchHardeningResult ApplyWinUICompatible()
    {
        if (!OperatingSystem.IsWindows())
        {
            return new DllSearchHardeningResult(
                applied: false,
                onWindows: false,
                appliedFlags: 0,
                detail: "Non-Windows host: WinUI-compatible DLL-search hardening is a no-op.");
        }

        try
        {
            var ok = SetDllDirectory(string.Empty);
            return ok
                ? new DllSearchHardeningResult(
                    applied: true,
                    onWindows: true,
                    appliedFlags: 0,
                    detail: "SetDllDirectory(\"\") applied; SetDefaultDllDirectories skipped for WinUI resource compatibility.")
                : new DllSearchHardeningResult(
                    applied: false,
                    onWindows: true,
                    appliedFlags: 0,
                    detail: $"SetDllDirectory failed (Win32 error {Marshal.GetLastWin32Error()}).");
        }
        catch (DllNotFoundException ex)
        {
            return new DllSearchHardeningResult(false, true, 0, $"kernel32 entry point unavailable: {ex.Message}");
        }
        catch (EntryPointNotFoundException ex)
        {
            return new DllSearchHardeningResult(false, true, 0, $"SetDllDirectory unavailable: {ex.Message}");
        }
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetDefaultDllDirectories(int directoryFlags);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetDllDirectory(string? lpPathName);
}
