using System;

namespace OpenBurnBar.App.Diagnostics;

/// <summary>
/// Runtime gates for optional native renderers. They deliberately prefer a visible degraded route
/// over a process crash when a VM lacks Win2D/WebView2/runtime support.
/// </summary>
public static class NativeCapability
{
    public static bool IsWin2DEnabled(out string reason) => IsEnabled("OPENBURNBAR_DISABLE_WIN2D", "Win2D", out reason);

    public static bool IsWebView2Enabled(out string reason) => IsEnabled("OPENBURNBAR_DISABLE_WEBVIEW2", "WebView2", out reason);

    private static bool IsEnabled(string environmentVariable, string feature, out string reason)
    {
        string? value = Environment.GetEnvironmentVariable(environmentVariable);
        if (string.Equals(value, "1", StringComparison.OrdinalIgnoreCase)
            || string.Equals(value, "true", StringComparison.OrdinalIgnoreCase)
            || string.Equals(value, "yes", StringComparison.OrdinalIgnoreCase))
        {
            reason = $"{feature} disabled by {environmentVariable}={value}";
            AppDiagnostics.NativeCapabilitySkipped(feature, reason);
            return false;
        }

        reason = $"{feature} enabled";
        return true;
    }
}
