using OpenBurnBar.Native;
using Xunit;

namespace OpenBurnBar.Native.Tests;

/// <summary>
/// An xunit <see cref="FactAttribute"/> for loopback tests that require a
/// natively built Rust cdylib: runs when the hardened locator can find the
/// library, and SKIPS (never fails) when it cannot — so the same test assembly
/// is green on hosts with no Rust build (e.g. the pr-windows-full CI legs) and
/// exercises the real FFI on hosts that have run `cargo build`.
/// </summary>
public sealed class NativeFactAttribute : FactAttribute
{
    public NativeFactAttribute(string logicalLibraryName)
    {
        if (NativeLibraryLocator.Locate(logicalLibraryName) is null)
        {
            Skip = $"native cdylib '{NativeLibraryLocator.PlatformFileName(logicalLibraryName)}' not present " +
                   "on this host — loopback skipped (build it with cargo; see windows/native/README.md)";
        }
    }
}
