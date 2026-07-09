using System;

namespace OpenBurnBar.App.Dashboard;

/// <summary>
/// Pure JS bridge script builders for the shared KernelBackdrop WebGL2 bundle.
/// Mirrors the macOS <c>KernelBackdropView.Coordinator</c> evaluateJavaScript
/// payloads (<c>__setKernel</c>, <c>__setTheme</c>, <c>__setBackdropActive</c>)
/// so unit tests can assert the exact bridge surface without a WebView2 host.
/// </summary>
public static class KernelBackdropBridge
{
    /// <summary>
    /// Build a ready-gated call that polls until <c>window.__backdropReady</c> is true
    /// (and <c>__setKernel</c> exists), matching the Swift coordinator's 120×50ms poll.
    /// </summary>
    public static string ReadyGatedCall(string call)
    {
        if (string.IsNullOrWhiteSpace(call))
        {
            throw new ArgumentException("Bridge call must not be empty.", nameof(call));
        }

        return
            "(function () {\n" +
            "  var tries = 0;\n" +
            "  function go() {\n" +
            "    if (window.__backdropReady === true && typeof window.__setKernel === 'function') {\n" +
            "      try { " + call + "; } catch (e) {}\n" +
            "      return;\n" +
            "    }\n" +
            "    if (tries++ < 120) { setTimeout(go, 50); }\n" +
            "  }\n" +
            "  go();\n" +
            "})();";
    }

    /// <summary>Script for <c>window.__setKernel('&lt;id&gt;')</c>, or null when the id is invalid.</summary>
    public static string? SetKernelScript(string? kernelId)
    {
        string resolved = KernelCatalog.Resolve(kernelId);
        if (!KernelCatalog.IsValid(resolved))
        {
            return null;
        }

        // Catalog ids are constrained to [a-z0-9-] so they cannot break out of the string.
        return ReadyGatedCall("window.__setKernel('" + resolved + "')");
    }

    /// <summary>Script for <c>window.__setTheme('light'|'dark')</c>.</summary>
    public static string SetThemeScript(string? theme)
    {
        string normalized = string.Equals(theme, "light", StringComparison.OrdinalIgnoreCase)
            ? "light"
            : "dark";
        return ReadyGatedCall("window.__setTheme('" + normalized + "')");
    }

    /// <summary>
    /// Optional-call script for render-loop gating when the host window is occluded.
    /// Mirrors <c>window.__setBackdropActive &amp;&amp; window.__setBackdropActive(flag)</c>.
    /// </summary>
    public static string SetBackdropActiveScript(bool active)
    {
        string flag = active ? "true" : "false";
        return "window.__setBackdropActive && window.__setBackdropActive(" + flag + ");";
    }

    /// <summary>
    /// Build a file URL fragment for the initial kernel so the bundle boots on the
    /// selected field (macOS seeds via <c>location.hash</c>).
    /// </summary>
    public static string HashFragmentFor(string? kernelId) => KernelCatalog.Resolve(kernelId);
}
