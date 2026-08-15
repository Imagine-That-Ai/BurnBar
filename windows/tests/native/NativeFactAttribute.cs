using OpenBurnBar.Native;
using Xunit;

namespace OpenBurnBar.Native.Tests;

/// <summary>
/// An xunit <see cref="FactAttribute"/> for loopback tests that require a
/// natively built Rust cdylib: runs when the hardened locator can find the
/// library, and SKIPS when it cannot — so optional developer hosts can run the
/// portable surface without a Rust build. The full-suite and physical
/// release-certification harnesses set
/// <see cref="NativeRequirementTests.RequireNativeShimsEnvironmentVariable"/>;
/// the normal requirement test then fails clearly unless both cdylibs are
/// present and loadable, while the loopback tests execute the real FFI.
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
