using OpenBurnBar.App.Dashboard;
using Xunit;

namespace OpenBurnBar.App.Theme.Tests;

/// <summary>
/// Decision-table tests for the shipped <see cref="KernelBackdropSelection"/> resolver.
/// Exercises the real failover path (kernel preferred → permanent failure → Win2D)
/// without a live WebView2/GPU host — the pure half of criterion 3.
/// </summary>
public sealed class KernelBackdropSelectionTests
{
    // Columns: enabled, webView2, ready, failed, win2d → expected layer

    [Theory]
    // Prefer kernel when enabled, capable, not failed (ready or still loading).
    [InlineData(true, true, true, false, true, DashboardBackdropLayer.Kernel)]
    [InlineData(true, true, false, false, true, DashboardBackdropLayer.Kernel)] // loading
    [InlineData(true, true, true, false, false, DashboardBackdropLayer.Kernel)] // kernel only
    // Permanent host failure → Win2D when available.
    [InlineData(true, true, false, true, true, DashboardBackdropLayer.Win2D)]
    [InlineData(true, true, true, true, true, DashboardBackdropLayer.Win2D)] // failed after ready
    // WebView2 unavailable → Win2D.
    [InlineData(true, false, false, false, true, DashboardBackdropLayer.Win2D)]
    // User turned kernel off → Win2D.
    [InlineData(false, true, true, false, true, DashboardBackdropLayer.Win2D)]
    [InlineData(false, true, false, false, true, DashboardBackdropLayer.Win2D)]
    // No renderer left.
    [InlineData(true, true, false, true, false, DashboardBackdropLayer.None)]
    [InlineData(false, false, false, false, false, DashboardBackdropLayer.None)]
    [InlineData(true, false, false, false, false, DashboardBackdropLayer.None)]
    public void Resolve_MatchesDecisionTable(
        bool enabled,
        bool webView2,
        bool ready,
        bool failed,
        bool win2d,
        DashboardBackdropLayer expected)
    {
        DashboardBackdropLayer layer = KernelBackdropSelection.Resolve(
            kernelEnabled: enabled,
            webView2Capable: webView2,
            hostReady: ready,
            hostFailed: failed,
            win2DAvailable: win2d);

        Assert.Equal(expected, layer);
    }

    [Fact]
    public void ShouldShowKernel_TrueOnlyWhenResolveIsKernel()
    {
        Assert.True(KernelBackdropSelection.ShouldShowKernel(true, true, false, false, true));
        Assert.False(KernelBackdropSelection.ShouldShowKernel(true, true, false, true, true));
        Assert.False(KernelBackdropSelection.ShouldShowKernel(false, true, true, false, true));
    }

    [Fact]
    public void ShouldShowWin2D_TrueOnFailoverAndWhenKernelOff()
    {
        // Failover path (the bug the skeptic flagged).
        Assert.True(KernelBackdropSelection.ShouldShowWin2D(true, true, false, true, true));
        // Kernel off.
        Assert.True(KernelBackdropSelection.ShouldShowWin2D(false, true, false, false, true));
        // Kernel healthy — Win2D hidden.
        Assert.False(KernelBackdropSelection.ShouldShowWin2D(true, true, true, false, true));
    }

    [Fact]
    public void LoadingState_KeepsKernelVisible_UntilFailed()
    {
        // ready=false, failed=false → still Kernel (optimistic load).
        Assert.Equal(
            DashboardBackdropLayer.Kernel,
            KernelBackdropSelection.Resolve(true, true, hostReady: false, hostFailed: false, win2DAvailable: true));

        // Permanent failure flips to Win2D.
        Assert.Equal(
            DashboardBackdropLayer.Win2D,
            KernelBackdropSelection.Resolve(true, true, hostReady: false, hostFailed: true, win2DAvailable: true));
    }
}
