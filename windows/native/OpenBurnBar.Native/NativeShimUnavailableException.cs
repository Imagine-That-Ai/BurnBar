using System;

namespace OpenBurnBar.Native;

/// <summary>
/// The graceful NotSupported surface of the native shim: thrown by the managed
/// facades (<c>OpenBurnBar.Native.BurnBarRemote</c>, <c>OpenBurnBar.Native.Iroh</c>)
/// when the Rust cdylib backing a call is not present on this host, instead of
/// letting a raw <see cref="System.DllNotFoundException"/> escape from deep
/// inside a generated P/Invoke.
///
/// Hosts without the cdylib are a supported, first-class state: the macOS dev
/// host compiles and unit-tests the whole shim without any Rust build, and the
/// Windows CI full-suite lane runs the shim's tests with the loopback subset
/// skipped. Callers that can degrade (e.g. hide the remote-session surface)
/// should branch on <c>IsAvailable</c> rather than catch this.
/// </summary>
public sealed class NativeShimUnavailableException : NotSupportedException
{
    /// <summary>The logical library name that could not be resolved
    /// (e.g. <c>burnbar_remote</c>, <c>openburnbar_iroh</c>).</summary>
    public string LibraryLogicalName { get; }

    public NativeShimUnavailableException(string libraryLogicalName, string shimDescription)
        : base(
            $"The native library '{libraryLogicalName}' ({shimDescription}) is not available on this host. " +
            $"Searched: {NativeLibraryLocator.SearchDirEnvVar} (env), the application base directory, and " +
            "runtimes/<rid>/native. Build the Rust cdylib (see windows/native/README.md) or point " +
            $"{NativeLibraryLocator.SearchDirEnvVar} at a directory containing " +
            $"{NativeLibraryLocator.PlatformFileName(libraryLogicalName)}.")
    {
        LibraryLogicalName = libraryLogicalName;
    }
}
