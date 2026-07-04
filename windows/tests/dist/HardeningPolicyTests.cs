// DLL-hardening POLICY ↔ PROPS cross-check + runtime shim behavior (Phase 5 · R19).
//
// Asserts the packaging props under windows/dist/props actually carry every flag/property the
// HardeningPolicy requires — so the policy and the shipped props can never silently drift — and
// that the runtime search-order shim is a documented no-op on the (non-Windows) test host.

using System.IO;
using OpenBurnBar.Dist.Hardening;
using Xunit;

namespace OpenBurnBar.Dist.Tests;

public sealed class HardeningPolicyTests
{
    private static string ReadProps(string fileName) =>
        File.ReadAllText(Path.Combine(DistTestSupport.PropsDirectory(), fileName));

    [Fact]
    public void NativeHardeningProps_CarryEveryRequiredLinkerFlag()
    {
        var props = ReadProps("OpenBurnBar.Windows.NativeHardening.props");
        foreach (var flag in HardeningPolicy.RequiredNativeLinkerFlags)
        {
            Assert.Contains(flag, props);
        }
    }

    [Fact]
    public void ManagedHardeningProps_SetEveryRequiredPeProperty()
    {
        var props = ReadProps("OpenBurnBar.Windows.Hardening.props");
        foreach (var kvp in HardeningPolicy.RequiredManagedPeProperties)
        {
            // e.g. <HighEntropyVA>true</HighEntropyVA>
            Assert.Contains($"<{kvp.Key}>{kvp.Value}</{kvp.Key}>", props);
        }
    }

    [Fact]
    public void DependentLoadFlag_IsSystem32()
    {
        Assert.Equal(0x0800, HardeningPolicy.DependentLoadFlagSystem32);
        Assert.Equal("0x0800", HardeningPolicy.DependentLoadFlagHex);
        Assert.Contains($"/DEPENDENTLOADFLAG:{HardeningPolicy.DependentLoadFlagHex}", HardeningPolicy.RequiredNativeLinkerFlags);
    }

    [Fact]
    public void RecommendedDefaultDllDirectories_IsTheSafeCompositeFlag()
    {
        // LOAD_LIBRARY_SEARCH_DEFAULT_DIRS == 0x1000.
        Assert.Equal(0x1000, HardeningPolicy.RecommendedDefaultDllDirectories);
    }

    [Fact]
    public void ApplyOnNonWindowsHost_IsADocumentedNoOp()
    {
        // The macOS/Linux CI host is not Windows: the shim reports a no-op rather than throwing.
        var result = DllSearchHardening.Apply();
        Assert.False(result.OnWindows);
        Assert.False(result.Applied);
        Assert.Equal(0, result.AppliedFlags);
        Assert.NotEmpty(result.Detail);
    }
}
