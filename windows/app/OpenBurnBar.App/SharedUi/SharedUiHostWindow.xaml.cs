using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Web.WebView2.Core;
using OpenBurnBar.App.Diagnostics;
using OpenBurnBar.App.Interop;
using OpenBurnBar.App.Theme;
using Path = System.IO.Path;

namespace OpenBurnBar.App.SharedUi;

/// <summary>
/// The SharedUi host window — the Windows peer of the Linux Tauri shell. It
/// loads the SAME React bundle the Linux app renders (apps/linux-desktop,
/// built with the `windows` Vite mode into apps/linux-desktop/dist-windows and
/// shipped as app content under Resources/SharedUi) inside a WebView2, and
/// bridges its `chrome.webview.postMessage` command traffic to
/// <see cref="SharedUiDispatcher"/> — the C# peer of the Linux Tauri backend.
/// Visually this window IS the Linux app: same HTML, CSS, fonts, and kernels.
///
/// Failure honesty: a missing bundle or a failed WebView2/navigation surfaces
/// the in-window failure panel (with a path to the legacy native window) —
/// never a silent blank page.
/// </summary>
public sealed partial class SharedUiHostWindow : Window
{
    private const string VirtualHost = "shared.openburnbar.invalid";

    private readonly ThemeService _theme;
    private readonly SharedUiDispatcher _dispatcher;
    private readonly WebView2 _webView;
    private CoreWebView2? _core;
    private bool _started;
    private bool _closed;

    /// <summary>Raised when the shared bundle cannot be hosted at all (caller may fail over).</summary>
    public event EventHandler<string>? Failed;

    public SharedUiHostWindow(ThemeService theme, SharedUiDispatcher dispatcher)
    {
        _theme = theme;
        _dispatcher = dispatcher;
        InitializeComponent();

        // Created in code (never XAML) like KernelBackdropHost / the chat host —
        // keeps raw colors out of XAML (CI token discipline) and the control's
        // lifetime explicit.
        _webView = new WebView2
        {
            DefaultBackgroundColor = Windows.UI.Color.FromArgb(0, 0, 0, 0),
            HorizontalAlignment = HorizontalAlignment.Stretch,
            VerticalAlignment = VerticalAlignment.Stretch,
        };
        WebViewHost.Children.Add(_webView);

        var appWindow = WindowChrome.GetAppWindow(this);
        // Linux tauri.conf.json window size — pixel parity with the Linux shell.
        appWindow.Resize(new Windows.Graphics.SizeInt32(1280, 840));

        ExtendsContentIntoTitleBar = true;
        SetTitleBar(TitleBar);

        ApplyGlassChrome();
        LiquidGlassEnvironment.PreferencesChanged += OnGlassPreferencesChanged;
        theme.Register(this);
        RootGrid.ActualThemeChanged += OnActualThemeChanged;

        Closed += OnClosed;
    }

    /// <summary>
    /// True when the shared bundle is present and WebView2 is not env-disabled —
    /// the static probe the app uses to decide between this window and the
    /// legacy native window before construction.
    /// </summary>
    public static bool IsAvailable(out string reason)
    {
        if (!NativeCapability.IsWebView2Enabled(out reason))
        {
            return false;
        }

        if (ResolveResourceDirectory() is null)
        {
            reason = "The shared UI bundle (Resources/SharedUi) is not present in this build.";
            return false;
        }

        reason = string.Empty;
        return true;
    }

    /// <summary>
    /// Resolve the shared-bundle asset folder (packaged beside the exe under
    /// Resources/SharedUi, or the repo dist-windows output during development).
    /// </summary>
    public static string? ResolveResourceDirectory()
    {
        string baseDir = AppContext.BaseDirectory;
        string packaged = Path.Combine(baseDir, "Resources", "SharedUi");
        if (File.Exists(Path.Combine(packaged, "index.html")))
        {
            return packaged;
        }

        // Development fallback: walk up from bin/… toward the monorepo root (bounded).
        var probe = new DirectoryInfo(baseDir);
        for (int depth = 0; depth < 10 && probe is not null; depth += 1, probe = probe.Parent)
        {
            string candidate = Path.Combine(probe.FullName, "apps", "linux-desktop", "dist-windows");
            if (File.Exists(Path.Combine(candidate, "index.html")))
            {
                return candidate;
            }
        }

        return null;
    }

    /// <summary>Initialize CoreWebView2 and navigate to the shared bundle.</summary>
    public async Task StartAsync()
    {
        if (_started || _closed)
        {
            return;
        }

        _started = true;

        string? resourceDir = ResolveResourceDirectory();
        if (resourceDir is null)
        {
            ShowFailure("The shared UI bundle (Resources/SharedUi) is missing from this install.");
            return;
        }

        try
        {
            await _webView.EnsureCoreWebView2Async();
            if (_closed)
            {
                return;
            }

            _core = _webView.CoreWebView2;
            Harden(_core);
            ApplyColorScheme();

            _core.SetVirtualHostNameToFolderMapping(
                VirtualHost, resourceDir, CoreWebView2HostResourceAccessKind.Allow);
            _core.WebMessageReceived += OnWebMessageReceived;
            _core.NavigationCompleted += OnNavigationCompleted;
            _core.Navigate($"https://{VirtualHost}/index.html");
        }
        catch (Exception ex)
        {
            AppDiagnostics.LogException("shared-ui.start", ex);
            ShowFailure("WebView2 failed to initialize: " + ex.GetType().Name);
        }
    }

    private void OnNavigationCompleted(CoreWebView2 sender, CoreWebView2NavigationCompletedEventArgs args)
    {
        if (!args.IsSuccess)
        {
            AppDiagnostics.LogEvent("shared-ui.nav-failed", args.WebErrorStatus.ToString());
            ShowFailure("The shared UI bundle failed to load (" + args.WebErrorStatus + ").");
        }
    }

    private void OnWebMessageReceived(CoreWebView2 sender, CoreWebView2WebMessageReceivedEventArgs args)
    {
        string json;
        try
        {
            json = args.WebMessageAsJson;
        }
        catch (ArgumentException)
        {
            return; // Non-JSON post — not from the shim; drop.
        }

        // Command handlers do SQLite/HTTP IO — never on the UI thread. Emits are
        // marshaled back per call, so per-request ordering (channel chunks before
        // the resolving invoke-result) is preserved.
        _ = Task.Run(() => _dispatcher.HandleMessageAsync(json, EmitAsync));
    }

    /// <summary>Deliver one outbound message to the renderer (UI-thread marshaled).</summary>
    private async Task EmitAsync(System.Text.Json.Nodes.JsonObject message, CancellationToken ct)
    {
        var script = SharedUiBridgeScript.BuildDispatchScript(message);
        var tcs = new TaskCompletionSource();
        if (!DispatcherQueue.TryEnqueue(async () =>
            {
                try
                {
                    if (_core is not null && !_closed)
                    {
                        await _core.ExecuteScriptAsync(script);
                    }

                    tcs.TrySetResult();
                }
                catch (Exception ex)
                {
                    // A torn-down web view must not fault the dispatcher.
                    AppDiagnostics.LogException("shared-ui.emit", ex);
                    tcs.TrySetResult();
                }
            }))
        {
            tcs.TrySetException(new InvalidOperationException("Failed to enqueue on the window dispatcher."));
        }

        await tcs.Task;
    }

    private void OnActualThemeChanged(FrameworkElement sender, object args) => ApplyColorScheme();

    private void ApplyColorScheme()
    {
        if (_core is null)
        {
            return;
        }

        try
        {
            // The shared CSS keys light/dark off prefers-color-scheme.
            _core.Profile.PreferredColorScheme = RootGrid.ActualTheme == ElementTheme.Light
                ? CoreWebView2PreferredColorScheme.Light
                : CoreWebView2PreferredColorScheme.Dark;
        }
        catch (Exception ex)
        {
            AppDiagnostics.LogException("shared-ui.color-scheme", ex);
        }
    }

    private void ApplyGlassChrome()
    {
        LiquidGlass.ApplyWindowBackdrop(this, LiquidGlassEnvironment.Current);
        LiquidGlassWindowBlend.ApplyScrim(WindowBlendScrim, LiquidGlassEnvironment.Current);
    }

    private void OnGlassPreferencesChanged(object? sender, EventArgs e)
    {
        LiquidGlassWindowBlend.ApplyScrim(WindowBlendScrim, LiquidGlassEnvironment.Current);
        if (_theme.Mode.AllowsBackdrop() && !_theme.EffectiveReduceTransparency)
        {
            LiquidGlass.ApplyWindowBackdrop(this, LiquidGlassEnvironment.Current);
        }
    }

    private void ShowFailure(string reason)
    {
        AppDiagnostics.LogEvent("shared-ui.failed", reason);
        if (DispatcherQueue.HasThreadAccess)
        {
            FailureReasonText.Text = reason;
            FailurePanel.Visibility = Visibility.Visible;
            _webView.Visibility = Visibility.Collapsed;
        }

        Failed?.Invoke(this, reason);
    }

    private void OpenLegacyWindowButton_Click(object sender, RoutedEventArgs e)
    {
        App.Current.ShowLegacyMainWindow();
    }

    private static void Harden(CoreWebView2 core)
    {
        var settings = core.Settings;
        settings.AreDefaultContextMenusEnabled = false;
        settings.AreDevToolsEnabled = false;
        settings.IsStatusBarEnabled = false;
        settings.IsZoomControlEnabled = false;
        settings.AreDefaultScriptDialogsEnabled = false;
        settings.IsBuiltInErrorPageEnabled = false;
        settings.IsSwipeNavigationEnabled = false;
        // JavaScript stays enabled — the shared shell IS JavaScript.
        settings.IsScriptEnabled = true;
        try
        {
            settings.IsGeneralAutofillEnabled = false;
            settings.IsPasswordAutosaveEnabled = false;
        }
        catch (Exception)
        {
            // Older WebView2 runtimes may lack these settings.
        }
    }

    private void OnClosed(object sender, WindowEventArgs args)
    {
        _closed = true;
        RootGrid.ActualThemeChanged -= OnActualThemeChanged;
        LiquidGlassEnvironment.PreferencesChanged -= OnGlassPreferencesChanged;
        if (_core is not null)
        {
            _core.WebMessageReceived -= OnWebMessageReceived;
            _core.NavigationCompleted -= OnNavigationCompleted;
        }

        try
        {
            _webView.Close();
        }
        catch (Exception)
        {
            // The control may already be torn down with the page.
        }

        Closed -= OnClosed;
    }
}
