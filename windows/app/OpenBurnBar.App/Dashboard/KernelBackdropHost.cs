using System;
using System.IO;
using System.Numerics;
using System.Threading.Tasks;
using Microsoft.UI.Composition;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.Web.WebView2.Core;
using OpenBurnBar.App.Diagnostics;
using Path = System.IO.Path;

namespace OpenBurnBar.App.Dashboard;

/// <summary>
/// WebView2 host for the shared WebGL2 kernel backdrop field
/// (<c>AgentLens/Resources/KernelBackdrop/</c>). Mirrors macOS
/// <c>KernelBackdropView</c>: loads the offline bundle, bridges
/// <c>__setKernel</c> / <c>__setTheme</c> / <c>__setBackdropActive</c>, and is
/// hosted through a composition controller below dashboard XAML so native browser
/// airspace can never cover the command sidebar or detail content.
/// Permanent failure is signaled via <see cref="Failed"/> so the dashboard can
/// fail over to the Win2D swarm.
/// </summary>
public sealed class KernelBackdropHost : IDisposable
{
    private const string VirtualHost = "kernelbackdrop.openburnbar.invalid";

    private readonly Grid _anchor;
    private readonly TaskCompletionSource _loaded = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private CoreWebView2Environment? _environment;
    private CoreWebView2CompositionController? _compositionController;
    private CoreWebView2Controller? _controller;
    private CoreWebView2? _core;
    private SpriteVisual? _visual;
    private bool _started;
    private bool _disposed;
    private bool _isLoaded;
    private bool _isFailed;
    private string? _failureReason;
    private string _kernelId = KernelCatalog.DefaultId;
    private string _theme = "dark";
    private bool? _lastActive;

    public KernelBackdropHost()
    {
        _anchor = new Grid
        {
            HorizontalAlignment = HorizontalAlignment.Stretch,
            VerticalAlignment = VerticalAlignment.Stretch,
            IsHitTestVisible = false,
        };
        _anchor.Loaded += OnAnchorLoaded;
        _anchor.SizeChanged += OnAnchorSizeChanged;
    }

    /// <summary>The XAML anchor whose child visual hosts the browser composition tree.</summary>
    public Grid Control => _anchor;

    /// <summary>True once the CoreWebView2 session loaded the kernel bundle successfully.</summary>
    public bool IsReady => _isLoaded;

    /// <summary>True after a permanent failure (missing assets, init throw, nav fail).</summary>
    public bool IsFailed => _isFailed;

    /// <summary>Reason string for the last permanent failure, if any.</summary>
    public string? FailureReason => _failureReason;

    /// <summary>Raised when the bundle has loaded and the JS bridge is live.</summary>
    public event EventHandler? Ready;

    /// <summary>
    /// Raised once on permanent failure so the dashboard can fail over to Win2D.
    /// Argument is a short diagnostic reason (not user-facing copy).
    /// </summary>
    public event EventHandler<string>? Failed;

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

    /// <summary>
    /// Initialize CoreWebView2 and navigate to the kernel bundle.
    /// Permanent failures raise <see cref="Failed"/> (missing assets, init throw).
    /// Navigation failure raises <see cref="Failed"/> from the completion handler.
    /// </summary>
    public async Task StartAsync(string? kernelId = null, string theme = "dark")
    {
        if (_disposed || _started || _isFailed)
        {
            return;
        }

        _started = true;
        _kernelId = KernelCatalog.Resolve(kernelId);
        _theme = string.Equals(theme, "light", StringComparison.OrdinalIgnoreCase) ? "light" : "dark";

        string? resourceDir = ResolveResourceDirectory();
        if (resourceDir is null)
        {
            Fail("missing-assets");
            return;
        }

        try
        {
            await WaitUntilLoadedAsync();
            if (_disposed)
            {
                return;
            }

            nint parentWindow = App.Current.MainWindowHandle;
            if (parentWindow == 0)
            {
                throw new InvalidOperationException("The main window handle is unavailable.");
            }

            string userDataFolder = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "OpenBurnBar",
                "WebView2",
                "KernelBackdrop");
            Directory.CreateDirectory(userDataFolder);
            _environment = await CoreWebView2Environment.CreateWithOptionsAsync(
                browserExecutableFolder: null,
                userDataFolder,
                environmentOptions: null);
            var windowReference = CoreWebView2ControllerWindowReference.CreateFromWindowHandle(
                checked((ulong)parentWindow));
            _compositionController = await _environment.CreateCoreWebView2CompositionControllerAsync(windowReference);
            _controller = _compositionController;
            _core = _controller.CoreWebView2;

            _controller.DefaultBackgroundColor = Windows.UI.Color.FromArgb(0, 0, 0, 0);
            _controller.ShouldDetectMonitorScaleChanges = false;
            CreateAndAttachVisual();
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
            Fail("init-exception:" + ex.GetType().Name);
        }
    }

    /// <summary>Push a new kernel id through the JS bridge (no-op until loaded).</summary>
    public void SetKernel(string? kernelId)
    {
        if (_isFailed)
        {
            return;
        }

        string resolved = KernelCatalog.Resolve(kernelId);
        bool same = string.Equals(_kernelId, resolved, StringComparison.Ordinal);
        _kernelId = resolved;

        if (!_isLoaded || _core is null)
        {
            return;
        }

        // Always re-dispatch when loaded so a re-selection of the current id still
        // restarts the field (layout switcher may re-apply the same mapped id after
        // a pause/failover cycle).
        string? script = KernelBackdropBridge.SetKernelScript(resolved);
        if (script is not null)
        {
            _ = ExecuteScriptAsync(script);
        }
        else if (!same)
        {
            AppDiagnostics.LogEvent("kernel-backdrop.set-kernel-skip", resolved);
        }
    }

    /// <summary>Push theme (<c>light</c>/<c>dark</c>) through the JS bridge.</summary>
    public void SetTheme(string theme)
    {
        if (_isFailed)
        {
            return;
        }

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
        if (_isFailed)
        {
            return;
        }

        if (_lastActive == active)
        {
            return;
        }

        _lastActive = active;
        if (_controller is not null)
        {
            _controller.IsVisible = active;
        }
        if (_core is null)
        {
            return;
        }

        _ = ExecuteScriptAsync(KernelBackdropBridge.SetBackdropActiveScript(active));
    }

    private void OnNavigationCompleted(CoreWebView2 sender, CoreWebView2NavigationCompletedEventArgs args)
    {
        if (!args.IsSuccess)
        {
            AppDiagnostics.LogEvent("kernel-backdrop.nav-failed", args.WebErrorStatus.ToString());
            Fail("nav-failed:" + args.WebErrorStatus);
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
        Ready?.Invoke(this, EventArgs.Empty);
    }

    private Task WaitUntilLoadedAsync()
    {
        if (_anchor.IsLoaded)
        {
            return Task.CompletedTask;
        }

        return _loaded.Task;
    }

    private void OnAnchorLoaded(object sender, RoutedEventArgs args)
    {
        _loaded.TrySetResult();
        if (_anchor.XamlRoot is { } root)
        {
            root.Changed -= OnXamlRootChanged;
            root.Changed += OnXamlRootChanged;
        }
        ResizeCompositionSurface();
    }

    private void OnAnchorSizeChanged(object sender, SizeChangedEventArgs args) => ResizeCompositionSurface();

    private void OnXamlRootChanged(XamlRoot sender, XamlRootChangedEventArgs args) => ResizeCompositionSurface();

    private void CreateAndAttachVisual()
    {
        if (_compositionController is null)
        {
            return;
        }

        _visual ??= ElementCompositionPreview.GetElementVisual(_anchor).Compositor.CreateSpriteVisual();
        ElementCompositionPreview.SetElementChildVisual(_anchor, _visual);
        _compositionController.RootVisualTarget = _visual;
        ResizeCompositionSurface();
    }

    private void ResizeCompositionSurface()
    {
        if (_controller is null || _visual is null)
        {
            return;
        }

        double scale = _anchor.XamlRoot?.RasterizationScale ?? 1.0;
        double width = Math.Max(1, _anchor.ActualWidth);
        double height = Math.Max(1, _anchor.ActualHeight);
        double pixelWidth = Math.Ceiling(width * scale);
        double pixelHeight = Math.Ceiling(height * scale);

        _controller.RasterizationScale = scale;
        _controller.Bounds = new Windows.Foundation.Rect(0, 0, pixelWidth, pixelHeight);
        _visual.Size = new Vector2((float)pixelWidth, (float)pixelHeight);
        _visual.Scale = new Vector3((float)(1.0 / scale), (float)(1.0 / scale), 1);
    }

    private void Fail(string reason)
    {
        if (_isFailed || _disposed)
        {
            return;
        }

        _isFailed = true;
        _failureReason = reason;
        AppDiagnostics.LogEvent("kernel-backdrop.failed", reason);
        Failed?.Invoke(this, reason);
    }

    private async Task ExecuteScriptAsync(string script)
    {
        try
        {
            if (_core is null || _isFailed)
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
        _loaded.TrySetResult();
        _anchor.Loaded -= OnAnchorLoaded;
        _anchor.SizeChanged -= OnAnchorSizeChanged;
        if (_anchor.XamlRoot is { } root)
        {
            root.Changed -= OnXamlRootChanged;
        }
        if (_core is not null)
        {
            _core.NavigationCompleted -= OnNavigationCompleted;
        }

        try
        {
            if (_compositionController is not null)
            {
                _compositionController.RootVisualTarget = null;
            }
            ElementCompositionPreview.SetElementChildVisual(_anchor, null);
            _controller?.Close();
        }
        catch (Exception)
        {
            // Control may already be torn down with the page.
        }
    }
}
