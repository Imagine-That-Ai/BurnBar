using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;

namespace OpenBurnBar.App.Data;

/// <summary>
/// In-process Swift Engine compute via the C-ABI export (<c>obb_parse_cli_stdout</c>).
/// This is the WPD-0007 production path: the app calls the Swift Engine in-process
/// through P/Invoke, not via a <c>swift run</c> subprocess.
///
/// When the native library (<c>libOpenBurnBarCoreCAbi.dylib</c> on macOS,
/// <c>OpenBurnBarCoreCAbi.dll</c> on Windows) is loadable, this class provides
/// real in-process parse. When it is NOT loadable (e.g., the dylib hasn't been
/// built, or the app is running on a host without the Swift toolchain), the
/// caller falls back to <see cref="SwiftEngineInterim"/> (the <c>swift run</c>
/// subprocess path) or returns no data.
/// </summary>
public static class CAbiEngineProvider
{
    private const string MacLibraryName = "libOpenBurnBarCoreCAbi.dylib";
    private const string WindowsLibraryName = "OpenBurnBarCoreCAbi.dll";

    [DllImport(MacLibraryName, EntryPoint = "obb_parse_cli_stdout", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr ParseCliStdoutMac(IntPtr stdout, IntPtr provider);

    [DllImport(MacLibraryName, EntryPoint = "obb_string_free", CallingConvention = CallingConvention.Cdecl)]
    private static extern void StringFreeMac(IntPtr ptr);

    [DllImport(WindowsLibraryName, EntryPoint = "obb_parse_cli_stdout", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr ParseCliStdoutWindows(IntPtr stdout, IntPtr provider);

    [DllImport(WindowsLibraryName, EntryPoint = "obb_string_free", CallingConvention = CallingConvention.Cdecl)]
    private static extern void StringFreeWindows(IntPtr ptr);

    /// <summary>
    /// Attempts to locate the built C-ABI native library.
    /// Returns the full path when found; null when not built.
    /// </summary>
    public static string? TryResolveLibraryPath()
    {
        // Check for the dylib/DLL in the standard SwiftPM build output locations.
        // On macOS: OpenBurnBarCore/.build/{out/Products/Debug, debug, arm64-apple-macosx/debug}
        // On Windows: OpenBurnBarCore/.build/{debug, x86_64-unknown-windows-msvc/debug, aarch64-unknown-windows-msvc/debug}
        string? env = Environment.GetEnvironmentVariable("OPENBURNBAR_CORE_PACKAGE_PATH");
        string? packagePath = null;

        if (!string.IsNullOrWhiteSpace(env) && Directory.Exists(env))
        {
            packagePath = Path.GetFullPath(env);
        }
        else
        {
            // Search up from the app's base directory for the OpenBurnBarCore package.
            string? dir = AppContext.BaseDirectory;
            for (int i = 0; i < 12 && dir is not null; i++)
            {
                string candidate = Path.Combine(dir, "OpenBurnBarCore");
                if (Directory.Exists(candidate) && File.Exists(Path.Combine(candidate, "Package.swift")))
                {
                    packagePath = candidate;
                    break;
                }
                dir = Directory.GetParent(dir)?.FullName;
            }
        }

        if (packagePath is null)
        {
            return null;
        }

        string libName = OperatingSystem.IsWindows() ? WindowsLibraryName : MacLibraryName;
        string[] candidates =
        [
            Path.Combine(packagePath, ".build", "out", "Products", "Debug", libName),
            Path.Combine(packagePath, ".build", "debug", libName),
            Path.Combine(packagePath, ".build", "arm64-apple-macosx", "debug", libName),
            Path.Combine(packagePath, ".build", "x86_64-unknown-windows-msvc", "debug", libName),
            Path.Combine(packagePath, ".build", "aarch64-unknown-windows-msvc", "debug", libName),
        ];

        foreach (string path in candidates)
        {
            if (File.Exists(path))
            {
                return path;
            }
        }

        return null;
    }

    /// <summary>
    /// Calls <c>obb_parse_cli_stdout</c> in-process when the native library is loadable.
    /// Returns the parsed usage as JSON, or null when the library is missing.
    /// The caller MUST treat null as "engine not available" and fall back.
    /// </summary>
    /// <param name="stdout">The raw CLI stdout to parse (e.g., Claude Code stream-json).</param>
    /// <param name="provider">The provider name (e.g., "Claude Code").</param>
    /// <returns>JSON result with <c>{ ok: true, usages: [...] }</c> or <c>{ ok: false, error: "..." }</c>; null when the library is not loadable.</returns>
    public static string? TryParseCliStdout(string stdout, string provider)
    {
        string? libPath = TryResolveLibraryPath();
        if (libPath is null)
        {
            return null; // Library not built — caller falls back.
        }

        // Set up the DllImport resolver to load from the discovered path.
        NativeLibrary.SetDllImportResolver(typeof(CAbiEngineProvider).Assembly, (_, _, _) =>
        {
            if (NativeLibrary.TryLoad(libPath, out IntPtr handle))
            {
                return handle;
            }
            return IntPtr.Zero;
        });

        byte[] stdoutBytes = Encoding.UTF8.GetBytes(stdout + "\0");
        byte[] providerBytes = Encoding.UTF8.GetBytes(provider + "\0");

        IntPtr stdoutPtr = Marshal.AllocHGlobal(stdoutBytes.Length);
        IntPtr providerPtr = Marshal.AllocHGlobal(providerBytes.Length);
        try
        {
            Marshal.Copy(stdoutBytes, 0, stdoutPtr, stdoutBytes.Length);
            Marshal.Copy(providerBytes, 0, providerPtr, providerBytes.Length);

            IntPtr jsonPtr = OperatingSystem.IsWindows()
                ? ParseCliStdoutWindows(stdoutPtr, providerPtr)
                : ParseCliStdoutMac(stdoutPtr, providerPtr);

            if (jsonPtr == IntPtr.Zero)
            {
                return null; // Parse failed.
            }

            try
            {
                return Marshal.PtrToStringUTF8(jsonPtr);
            }
            finally
            {
                // The caller MUST free the returned string via obb_string_free.
                if (OperatingSystem.IsWindows())
                {
                    StringFreeWindows(jsonPtr);
                }
                else
                {
                    StringFreeMac(jsonPtr);
                }
            }
        }
        finally
        {
            Marshal.FreeHGlobal(stdoutPtr);
            Marshal.FreeHGlobal(providerPtr);
        }
    }

    /// <summary>
    /// Returns true when the C-ABI native library is loadable (the in-process
    /// engine binding is available). The app should check this at startup to
    /// decide whether to use the in-process path or fall back to the
    /// <see cref="SwiftEngineInterim"/> subprocess path.
    /// </summary>
    public static bool IsAvailable => TryResolveLibraryPath() is not null;
}