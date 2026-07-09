using OpenBurnBar.App.Dashboard;
using Xunit;

namespace OpenBurnBar.App.Theme.Tests;

public sealed class KernelBackdropSelectionTests
{
    [Theory]
    [InlineData(true, true, true, false, true, DashboardBackdropLayer.Kernel)]
    [InlineData(true, true, true, false, false, DashboardBackdropLayer.Kernel)]
    [InlineData(true, true, false, false, true, DashboardBackdropLayer.Win2D)]
    [InlineData(true, true, false, true, true, DashboardBackdropLayer.Win2D)]
    [InlineData(true, true, true, true, true, DashboardBackdropLayer.Win2D)]
    [InlineData(true, false, false, false, true, DashboardBackdropLayer.Win2D)]
    [InlineData(false, true, true, false, true, DashboardBackdropLayer.Win2D)]
    [InlineData(false, true, false, false, true, DashboardBackdropLayer.Win2D)]
    [InlineData(true, true, false, true, false, DashboardBackdropLayer.None)]
    [InlineData(false, false, false, false, false, DashboardBackdropLayer.None)]
    [InlineData(true, false, false, false, false, DashboardBackdropLayer.None)]
    public void Resolve_MatchesDecisionTable(
        bool enabled, bool webView2, bool ready, bool failed, bool win2d,
        DashboardBackdropLayer expected)
    {
        Assert.Equal(expected, KernelBackdropSelection.Resolve(enabled, webView2, ready, failed, win2d));
    }

    [Fact]
    public void LoadingState_KeepsWin2D_UntilReady_ThenKernel()
    {
        Assert.Equal(DashboardBackdropLayer.Win2D,
            KernelBackdropSelection.Resolve(true, true, hostReady: false, hostFailed: false, win2DAvailable: true));
        Assert.Equal(DashboardBackdropLayer.Kernel,
            KernelBackdropSelection.Resolve(true, true, hostReady: true, hostFailed: false, win2DAvailable: true));
        Assert.Equal(DashboardBackdropLayer.Win2D,
            KernelBackdropSelection.Resolve(true, true, hostReady: false, hostFailed: true, win2DAvailable: true));
    }

    [Fact]
    public void ShouldShowHelpers_MatchResolve()
    {
        Assert.True(KernelBackdropSelection.ShouldShowKernel(true, true, true, false, true));
        Assert.False(KernelBackdropSelection.ShouldShowWin2D(true, true, true, false, true));
        Assert.False(KernelBackdropSelection.ShouldShowKernel(true, true, false, false, true));
        Assert.True(KernelBackdropSelection.ShouldShowWin2D(true, true, false, false, true));
    }
}
