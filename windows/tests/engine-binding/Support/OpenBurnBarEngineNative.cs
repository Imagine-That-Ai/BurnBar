using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

/// <summary>Locates repository root for native library discovery.</summary>
internal static class RepoRootLocator
{
    public static string Find()
    {
        string? dir = AppContext.BaseDirectory;
        for (int i = 0; i < 12 && dir is not null; i++)
        {
            if (File.Exists(Path.Combine(dir, "OpenBurnBarCore", "Package.swift")))
            {
                return dir;
            }

            dir = Directory.GetParent(dir)?.FullName;
        }

        throw new InvalidOperationException(
            "Could not locate repo root (OpenBurnBarCore/Package.swift) from test output dir.");
    }
}

/// <summary>P/Invoke surface for <c>OpenBurnBarCoreCAbi</c> (WPD-0007).</summary>
internal static class OpenBurnBarEngineNative
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

    /// <summary>Locates the built C-ABI dylib/DLL if present; otherwise null.</summary>
    public static string? TryResolveLibraryPath()
    {
        string repoRoot = RepoRootLocator.Find();
        string packagePath = Path.Combine(repoRoot, "OpenBurnBarCore");
        string[] candidates =
        [
            Path.Combine(packagePath, ".build", "out", "Products", "Debug", MacLibraryName),
            Path.Combine(packagePath, ".build", "debug", MacLibraryName),
            Path.Combine(packagePath, ".build", "arm64-apple-macosx", "debug", MacLibraryName),
            Path.Combine(packagePath, ".build", "x86_64-apple-macosx", "debug", MacLibraryName),
            Path.Combine(packagePath, ".build", "debug", WindowsLibraryName),
            Path.Combine(packagePath, ".build", "x86_64-unknown-windows-msvc", "debug", WindowsLibraryName),
            Path.Combine(packagePath, ".build", "aarch64-unknown-windows-msvc", "debug", WindowsLibraryName),
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
    /// Calls <c>obb_parse_cli_stdout</c> when the native library is loadable.
    /// Returns null when the library is missing (test should skip).
    /// </summary>
    public static string? TryParseCliStdout(string stdout, string provider)
    {
        string? libPath = TryResolveLibraryPath();
        if (libPath is null)
        {
            return null;
        }

        string? dir = Path.GetDirectoryName(libPath);
        if (dir is not null)
        {
            NativeLibrary.SetDllImportResolver(typeof(OpenBurnBarEngineNative).Assembly, (_, _, _) =>
            {
                if (NativeLibrary.TryLoad(libPath, out IntPtr handle))
                {
                    return handle;
                }

                return IntPtr.Zero;
            });
        }

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
                return null;
            }

            try
            {
                return Marshal.PtrToStringUTF8(jsonPtr);
            }
            finally
            {
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
}