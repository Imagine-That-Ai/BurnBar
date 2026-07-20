namespace OpenBurnBar.App.Dashboard;

/// <summary>
/// Which dashboard backdrop layer should be visible. Pure decision table so unit tests
/// can exercise native-kernel fallback without a live GPU host.
/// </summary>
public enum DashboardBackdropLayer
{
    None,
    Kernel,
    Win2D,
}

/// <summary>
/// Prefer the selected native kernel host when enabled, capable, and ready;
/// keep the layout-driven Win2D fallback while loading or after failure.
/// </summary>
public static class KernelBackdropSelection
{
    public static DashboardBackdropLayer Resolve(
        bool kernelEnabled,
        bool kernelCapable,
        bool hostReady,
        bool hostFailed,
        bool win2DAvailable)
    {
        if (kernelEnabled && kernelCapable && hostReady && !hostFailed)
        {
            return DashboardBackdropLayer.Kernel;
        }

        if (win2DAvailable)
        {
            return DashboardBackdropLayer.Win2D;
        }

        return DashboardBackdropLayer.None;
    }

    public static bool ShouldShowKernel(
        bool kernelEnabled,
        bool kernelCapable,
        bool hostReady,
        bool hostFailed,
        bool win2DAvailable) =>
        Resolve(kernelEnabled, kernelCapable, hostReady, hostFailed, win2DAvailable)
            == DashboardBackdropLayer.Kernel;

    public static bool ShouldShowWin2D(
        bool kernelEnabled,
        bool kernelCapable,
        bool hostReady,
        bool hostFailed,
        bool win2DAvailable) =>
        Resolve(kernelEnabled, kernelCapable, hostReady, hostFailed, win2DAvailable)
            == DashboardBackdropLayer.Win2D;
}
