namespace OpenBurnBar.App.Dashboard;

/// <summary>
/// Which dashboard backdrop layer should be visible. Pure decision table so unit tests
/// can exercise WebView2/WebGL2 fallback without a live GPU or WebView2 host.
/// </summary>
public enum DashboardBackdropLayer
{
    None,
    Kernel,
    Win2D,
}

/// <summary>
/// Prefer WebGL2 only when enabled, capable, and ready; keep Win2D while loading / on failure.
/// </summary>
public static class KernelBackdropSelection
{
    public static DashboardBackdropLayer Resolve(
        bool kernelEnabled,
        bool webView2Capable,
        bool hostReady,
        bool hostFailed,
        bool win2DAvailable)
    {
        if (kernelEnabled && webView2Capable && hostReady && !hostFailed)
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
        bool webView2Capable,
        bool hostReady,
        bool hostFailed,
        bool win2DAvailable) =>
        Resolve(kernelEnabled, webView2Capable, hostReady, hostFailed, win2DAvailable)
            == DashboardBackdropLayer.Kernel;

    public static bool ShouldShowWin2D(
        bool kernelEnabled,
        bool webView2Capable,
        bool hostReady,
        bool hostFailed,
        bool win2DAvailable) =>
        Resolve(kernelEnabled, webView2Capable, hostReady, hostFailed, win2DAvailable)
            == DashboardBackdropLayer.Win2D;
}
