using System;

namespace OpenBurnBar.Native;

/// <summary>
/// The graceful NotSupported surface of the native shim: thrown by the managed
/// facades (<c>OpenBurnBar.Native.BurnBarRemote</c>, <c>OpenBurnBar.Native.Iroh</c>)
/// when the Rust cdylib backing a call is not present on this host, instead of
/// letting a raw <see cref="System.DllNotFoundException"/> escape from deep
/// inside a generated P/Invoke.
///
/// Hosts without the cdylib are a supported, first-class state for optional
/// development and degradable product surfaces. The Windows full-suite and
/// physical release-certification harnesses build and require both Rust shims,
/// so those proofs fail instead of treating absent loopbacks as success.
/// Callers that can degrade (e.g. hide the remote-session surface) should
/// branch on <c>IsAvailable</c> rather than catch this.
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
