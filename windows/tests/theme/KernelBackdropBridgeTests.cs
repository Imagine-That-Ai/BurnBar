using OpenBurnBar.App.Dashboard;
using Xunit;

namespace OpenBurnBar.App.Theme.Tests;

/// <summary>
/// Drives the shipped <see cref="KernelCatalog"/> and <see cref="KernelBackdropBridge"/>
/// — the pure half of the WebGL2 host. Asserts catalog size (31), default id, bridge
/// script surface (__setKernel / __setTheme / __setBackdropActive), and ready-gating.
/// </summary>
public sealed class KernelBackdropBridgeTests
{
    [Fact]
    public void Catalog_HasThirtyOneKernels_AndDefaultIsFluidAurora()
    {
        Assert.Equal(31, KernelCatalog.All.Count);
        Assert.Equal("fluid-aurora", KernelCatalog.DefaultId);
        Assert.True(KernelCatalog.IsValid(KernelCatalog.DefaultId));
        Assert.Contains(KernelCatalog.All, e => e.Id == "boids");
        Assert.Contains(KernelCatalog.All, e => e.Id == "constellation");
    }

    [Fact]
    public void Resolve_ClampsJunkToDefault()
    {
        Assert.Equal(KernelCatalog.DefaultId, KernelCatalog.Resolve(null));
        Assert.Equal(KernelCatalog.DefaultId, KernelCatalog.Resolve(""));
        Assert.Equal(KernelCatalog.DefaultId, KernelCatalog.Resolve("not-a-kernel"));
        Assert.Equal("aurora", KernelCatalog.Resolve("aurora"));
    }

    [Fact]
    public void SetKernelScript_ContainsBridgeAndReadyGate()
    {
        string? script = KernelBackdropBridge.SetKernelScript("aurora");
        Assert.NotNull(script);
        Assert.Contains("window.__setKernel('aurora')", script);
        Assert.Contains("window.__backdropReady", script);
        Assert.Contains("typeof window.__setKernel", script);
    }

    [Fact]
    public void SetKernelScript_InvalidId_StillResolvesToDefault()
    {
        // Resolve clamps first; script always targets a valid catalog id.
        string? script = KernelBackdropBridge.SetKernelScript("totally-invalid");
        Assert.NotNull(script);
        Assert.Contains("window.__setKernel('fluid-aurora')", script);
    }

    [Fact]
    public void SetThemeScript_NormalizesToLightOrDark()
    {
        string light = KernelBackdropBridge.SetThemeScript("LIGHT");
        Assert.Contains("window.__setTheme('light')", light);

        string dark = KernelBackdropBridge.SetThemeScript("whatever");
        Assert.Contains("window.__setTheme('dark')", dark);
    }

    [Fact]
    public void SetBackdropActiveScript_OptionalCall()
    {
        string on = KernelBackdropBridge.SetBackdropActiveScript(true);
        Assert.Contains("window.__setBackdropActive", on);
        Assert.Contains("(true)", on);

        string off = KernelBackdropBridge.SetBackdropActiveScript(false);
        Assert.Contains("(false)", off);
    }

    [Fact]
    public void PreferenceKeys_MatchMacOSSpelling()
    {
        Assert.Equal("backdropKernel", KernelBackdropPreferences.KernelKey);
        Assert.Equal("useKernelBackdrop", KernelBackdropPreferences.EnabledKey);
    }

    [Fact]
    public void Label_ReturnsCatalogLabel_OrIdFallback()
    {
        Assert.Equal("Fluid Aurora", KernelCatalog.Label("fluid-aurora"));
        Assert.Equal("not-a-kernel", KernelCatalog.Label("not-a-kernel"));
    }

    [Fact]
    public void HashFragmentFor_UsesResolvedId()
    {
        Assert.Equal("mesh", KernelBackdropBridge.HashFragmentFor("mesh"));
        Assert.Equal(KernelCatalog.DefaultId, KernelBackdropBridge.HashFragmentFor("nope"));
    }
}
