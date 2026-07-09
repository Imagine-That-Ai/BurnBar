using System;
using System.IO;
using System.Threading.Tasks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Web.WebView2.Core;
using OpenBurnBar.App.Diagnostics;
using OpenBurnBar.App.Theme;
using Path = System.IO.Path;

namespace OpenBurnBar.App.Dashboard;

/// <summary>
/// WebView2 host for the shared WebGL2 kernel backdrop field
/// (<c>AgentLens/Resources/KernelBackdrop/</c>). Mirrors macOS
/// <c>KernelBackdropView</c>: loads the offline bundle, bridges
/// <c>__setKernel</c> / <c>__setTheme</c> / <c>__setBackdropActive</c>, and is
/// hit-test disabled so dashboard content composites cleanly on top.
/// </summary>
public sealed class KernelBackdropHost : IDisposable
{
    private const string VirtualHost = "kernelbackdrop.openburnbar.invalid";

    private readonly WebView2 _webView;
    private CoreWebView2? _core;
    private bool _started;
    private bool _disposed;
    private bool _isLoaded;
    private string _kernelId = KernelCatalog.DefaultId;
    private string _theme = "dark";
    private bool? _lastActive;

    public KernelBackdropHost()
    {
        _webView = new WebView2
        {
            DefaultBackgroundColor = Windows.UI.Color.FromArgb(0, 0, 0, 0),
            HorizontalAlignment = HorizontalAlignment.Stretch,
            VerticalAlignment = VerticalAlignment.Stretch,
            IsHitTestVisible = false,
        };
        // Never steal focus/clicks from the dashboard content layer.
        _webView.IsTabStop = false;
    }

    /// <summary>The WebView2 control to place at the back of the dashboard visual tree.</summary>
    public WebView2 Control => _webView;

    /// <summary>True once the CoreWebView2 session is ready (or failed permanently).</summary>
    public bool IsReady => _isLoaded;

    /// <summary>
    /// Resolve the KernelBackdrop asset folder (packaged beside the exe under
    /// <c>Resources/KernelBackdrop</c>, or next to the repo source during development).
    /// </summary>
    public static string? ResolveResourceDirectory()
    {
        string baseDir = AppContext.BaseDirectory;
        string[] candidates =
        {
            Path.Combine(baseDir, "Resources", "KernelBackdrop"),
            Path.Combine(baseDir, "KernelBackdrop"),
            // Dev-host: walk up from bin/… toward the monorepo root.
            Path.GetFullPath(Path.Combine(baseDir, "..", "..", "..", "..", "..", "..", "AgentLens", "Resources", "KernelBackdrop")),
            Path.GetFullPath(Path.Combine(baseDir, "..", "..", "..", "..", "..", "AgentLens", "Resources", "KernelBackdrop")),
        };

        foreach (string candidate in candidates)
        {
            string index = Path.Combine(candidate, "index.html");
            if (File.Exists(index) && File.Exists(Path.Combine(candidate, "kernel-backdrop.js")))
            {
                return candidate;
            }
        }

        return null;
    }

    /// <summary>Initialize CoreWebView2 and navigate to the kernel bundle.</summary>
    public async Task StartAsync(string? kernelId = null, string theme = "dark")
    {
        if (_disposed || _started)
        {
            return;
        }

        _started = true;
        _kernelId = KernelCatalog.Resolve(kernelId);
        _theme = string.Equals(theme, "light", StringComparison.OrdinalIgnoreCase) ? "light" : "dark";

        string? resourceDir = ResolveResourceDirectory();
        if (resourceDir is null)
        {
            AppDiagnostics.LogEvent("kernel-backdrop.missing-assets", "KernelBackdrop index.html not found");
            return;
        }

        try
        {
            await _webView.EnsureCoreWebView2Async();
            _core = _webView.CoreWebView2;
            Harden(_core);

            _core.SetVirtualHostNameToFolderMapping(
                VirtualHost, resourceDir, CoreWebView2HostResourceAccessKind.Allow);
            _core.NavigationCompleted += OnNavigationCompleted;

            string fragment = KernelBackdropBridge.HashFragmentFor(_kernelId);
            _core.Navigate($"https://{VirtualHost}/index.html#{fragment}");
        }
        catch (Exception ex)
        {
            AppDiagnostics.LogException("kernel-backdrop.start", ex);
        }
    }

    /// <summary>Push a new kernel id through the JS bridge (no-op until loaded).</summary>
    public void SetKernel(string? kernelId)
    {
        string resolved = KernelCatalog.Resolve(kernelId);
        if (string.Equals(_kernelId, resolved, StringComparison.Ordinal) && _isLoaded)
        {
            return;
        }

        _kernelId = resolved;
        if (!_isLoaded || _core is null)
        {
            return;
        }

        string? script = KernelBackdropBridge.SetKernelScript(resolved);
        if (script is not null)
        {
            _ = ExecuteScriptAsync(script);
        }
    }

    /// <summary>Push theme (<c>light</c>/<c>dark</c>) through the JS bridge.</summary>
    public void SetTheme(string theme)
    {
        string normalized = string.Equals(theme, "light", StringComparison.OrdinalIgnoreCase) ? "light" : "dark";
        if (string.Equals(_theme, normalized, StringComparison.Ordinal) && _isLoaded)
        {
            return;
        }

        _theme = normalized;
        if (!_isLoaded || _core is null)
        {
            return;
        }

        _ = ExecuteScriptAsync(KernelBackdropBridge.SetThemeScript(normalized));
    }

    /// <summary>
    /// Gate the WebGL rAF loop when the host window is occluded/minimized.
    /// Mirrors macOS <c>__setBackdropActive</c>.
    /// </summary>
    public void SetBackdropActive(bool active)
    {
        if (_lastActive == active)
        {
            return;
        }

        _lastActive = active;
        if (_core is null)
        {
            return;
        }

        _ = ExecuteScriptAsync(KernelBackdropBridge.SetBackdropActiveScript(active));
    }

    /// <summary>Read the live preference and apply kernel + enabled visibility.</summary>
    public void ApplyFromPreferences()
    {
        var env = LiquidGlassEnvironment.Current;
        string kernel = env.GetString(KernelBackdropPreferences.KernelKey, KernelCatalog.DefaultId);
        SetKernel(kernel);
    }

    private void OnNavigationCompleted(CoreWebView2 sender, CoreWebView2NavigationCompletedEventArgs args)
    {
        if (!args.IsSuccess)
        {
            AppDiagnostics.LogEvent("kernel-backdrop.nav-failed", args.WebErrorStatus.ToString());
            return;
        }

        _isLoaded = true;
        string? kernelScript = KernelBackdropBridge.SetKernelScript(_kernelId);
        if (kernelScript is not null)
        {
            _ = ExecuteScriptAsync(kernelScript);
        }

        _ = ExecuteScriptAsync(KernelBackdropBridge.SetThemeScript(_theme));
        _lastActive = null;
        SetBackdropActive(true);
    }

    private async Task ExecuteScriptAsync(string script)
    {
        try
        {
            if (_core is null)
            {
                return;
            }

            await _core.ExecuteScriptAsync(script);
        }
        catch (Exception ex)
        {
            AppDiagnostics.LogException("kernel-backdrop.script", ex);
        }
    }

    private static void Harden(CoreWebView2 core)
    {
        core.Settings.IsStatusBarEnabled = false;
        core.Settings.AreDefaultContextMenusEnabled = false;
        core.Settings.IsZoomControlEnabled = false;
        core.Settings.AreDevToolsEnabled = false;
        core.Settings.IsSwipeNavigationEnabled = false;
        try
        {
            core.Settings.IsGeneralAutofillEnabled = false;
            core.Settings.IsPasswordAutosaveEnabled = false;
        }
        catch (Exception)
        {
            // Older WebView2 runtimes may lack these settings.
        }
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        if (_core is not null)
        {
            _core.NavigationCompleted -= OnNavigationCompleted;
        }

        try
        {
            _webView.Close();
        }
        catch (Exception)
        {
            // Control may already be torn down with the page.
        }
    }
}
