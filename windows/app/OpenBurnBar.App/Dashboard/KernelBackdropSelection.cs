namespace OpenBurnBar.App.Dashboard;

/// <summary>
/// Which dashboard backdrop layer should be visible. Pure decision table so unit tests
/// can exercise WebView2/WebGL2 fallback without a live GPU or WebView2 host.
/// </summary>
public enum DashboardBackdropLayer
{
    /// <summary>No backdrop renderer available.</summary>
    None,

    /// <summary>WebGL2 kernel field (WebView2).</summary>
    Kernel,

    /// <summary>Win2D particle swarm fallback.</summary>
    Win2D,
}

/// <summary>
/// Hostable selector for kernel-vs-Win2D backdrop visibility. Mirrors the macOS
/// <c>useKernelBackdrop</c> gate: prefer the WebGL2 field when enabled and healthy;
/// fall back to the native swarm when the kernel is off, WebView2 is unavailable,
/// or the host reports permanent failure.
/// </summary>
public static class KernelBackdropSelection
{
    /// <summary>
    /// Resolve the active backdrop layer from capability + host lifecycle flags.
    /// </summary>
    /// <param name="kernelEnabled">User preference <c>useKernelBackdrop</c>.</param>
    /// <param name="webView2Capable">Runtime gate: WebView2 not env-disabled and host constructed.</param>
    /// <param name="hostReady">Kernel host finished loading the bundle successfully.</param>
    /// <param name="hostFailed">Kernel host permanently failed (missing assets, init throw, nav fail).</param>
    /// <param name="win2DAvailable">Win2D swarm host was constructed successfully.</param>
    public static DashboardBackdropLayer Resolve(
        bool kernelEnabled,
        bool webView2Capable,
        bool hostReady,
        bool hostFailed,
        bool win2DAvailable)
    {
        // Prefer kernel while enabled + capable and not permanently failed.
        // Loading (ready=false, failed=false) still selects Kernel so the host can
        // paint; failure must flip to Win2D (criterion 3 failover).
        if (kernelEnabled && webView2Capable && !hostFailed)
        {
            return DashboardBackdropLayer.Kernel;
        }

        if (win2DAvailable)
        {
            return DashboardBackdropLayer.Win2D;
        }

        return DashboardBackdropLayer.None;
    }

    /// <summary>Whether the kernel WebView2 host should be Visible.</summary>
    public static bool ShouldShowKernel(
        bool kernelEnabled,
        bool webView2Capable,
        bool hostReady,
        bool hostFailed,
        bool win2DAvailable) =>
        Resolve(kernelEnabled, webView2Capable, hostReady, hostFailed, win2DAvailable)
            == DashboardBackdropLayer.Kernel;

    /// <summary>Whether the Win2D swarm host should be Visible.</summary>
    public static bool ShouldShowWin2D(
        bool kernelEnabled,
        bool webView2Capable,
        bool hostReady,
        bool hostFailed,
        bool win2DAvailable) =>
        Resolve(kernelEnabled, webView2Capable, hostReady, hostFailed, win2DAvailable)
            == DashboardBackdropLayer.Win2D;
}
