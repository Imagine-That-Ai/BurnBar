using System;
using System.Collections.Generic;
using OpenBurnBar.Native;
using OpenBurnBar.Native.BurnBarRemote;
using OpenBurnBar.Native.Iroh;
using Xunit;

namespace OpenBurnBar.Native.Tests;

/// <summary>
/// Turns the release/full-suite native-shim requirement into a normal xUnit
/// failure with a clear message. Optional developer hosts may still run the
/// portable tests without Rust cdylibs; certification lanes set the environment
/// variable and must load and execute both real shims.
/// </summary>
public sealed class NativeRequirementTests
{
    public const string RequireNativeShimsEnvironmentVariable = "OPENBURNBAR_REQUIRE_NATIVE_SHIMS";

    [Fact]
    public void RequiredNativeShims_ArePresentAndLoadable()
    {
        if (!string.Equals(
                Environment.GetEnvironmentVariable(RequireNativeShimsEnvironmentVariable),
                "1",
                StringComparison.Ordinal))
        {
            return;
        }

        var missing = new List<string>();
        foreach (string logicalName in new[]
                 {
                     BurnBarRemoteNative.LibraryLogicalName,
                     IrohNative.LibraryLogicalName,
                 })
        {
            if (NativeLibraryLocator.Locate(logicalName) is null)
            {
                missing.Add(NativeLibraryLocator.PlatformFileName(logicalName));
            }
        }

        Assert.True(
            missing.Count == 0,
            $"{RequireNativeShimsEnvironmentVariable}=1 requires both Rust native libraries; missing: {string.Join(", ", missing)}");

        // These calls cross each generated C# binding into Rust. A present but
        // corrupt, wrong-architecture, or dependency-broken library fails here
        // instead of being mistaken for usable native proof.
        _ = BurnBarRemoteNative.Readiness();
        _ = IrohNative.ProtocolVersion();
    }
}
