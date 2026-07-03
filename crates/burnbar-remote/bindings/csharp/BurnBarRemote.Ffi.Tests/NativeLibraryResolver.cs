using System;
using System.IO;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace BurnBarRemote.Ffi.Tests;

/// <summary>
/// Points the generated <c>DllImport("burnbar_remote")</c> P/Invokes at the
/// cdylib the build copied next to the test binary, instead of relying on the
/// platform loader's default search path. Runs before any P/Invoke via a module
/// initializer, and resolves the right file name per OS so the same test binary
/// loads <c>libburnbar_remote.dylib</c> on macOS and <c>burnbar_remote.dll</c> on
/// Windows (FFI-008).
/// </summary>
internal static class NativeLibraryResolver
{
    [ModuleInitializer]
    internal static void Register()
    {
        // The generated binding assembly is the one that declares the DllImports,
        // so register the resolver against it.
        var bindingAssembly = typeof(uniffi.burnbar_remote.BurnbarRemoteMethods).Assembly;
        NativeLibrary.SetDllImportResolver(bindingAssembly, Resolve);
    }

    private static IntPtr Resolve(string libraryName, Assembly assembly, DllImportSearchPath? searchPath)
    {
        if (libraryName != "burnbar_remote")
        {
            return IntPtr.Zero; // fall back to the default resolver
        }

        var fileName = RuntimeInformation.IsOSPlatform(OSPlatform.Windows)
            ? "burnbar_remote.dll"
            : RuntimeInformation.IsOSPlatform(OSPlatform.OSX)
                ? "libburnbar_remote.dylib"
                : "libburnbar_remote.so";

        var candidate = Path.Combine(AppContext.BaseDirectory, fileName);
        return File.Exists(candidate) && NativeLibrary.TryLoad(candidate, out var handle)
            ? handle
            : IntPtr.Zero;
    }
}
