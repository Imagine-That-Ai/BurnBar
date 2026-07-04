using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Web.WebView2.Core;
using OpenBurnBar.Pretext;

namespace OpenBurnBar.App.Pretext;

// MARK: - WebView2 Pretext host (Windows-only)
//
// The real offscreen-WebView2 implementation of IPretextWebHost — the Windows peer
// of the WKWebView plumbing in PretextEngine.swift. It hosts a hidden WebView2 that
// loads the SAME bundled pretext.bundle.min.js (verbatim) via the WebView2 bridge
// shell (Resources/Pretext/index.html, extracted from the OpenBurnBar.Pretext
// assembly), and bridges:
//
//   host -> page:  CoreWebView2.ExecuteScriptAsync("window.__pretextDispatch(...)")
//                  (peer of WKWebView.evaluateJavaScript)
//   page -> host:  CoreWebView2.WebMessageReceived (args.WebMessageAsJson)
//                  (peer of WKScriptMessageHandler / messageHandlers.pretext)
//
// The engine (OpenBurnBar.Pretext.PretextEngine) is transport-agnostic and fully
// unit-tested on macOS against a fake host; THIS file is the Windows transport and
// is therefore Windows-gated (WinUI + WebView2 build only on Windows — see
// windows/app/DEV_HOST_RUNBOOK.md and the VAL-P0-WINUI notes). The live
// Chromium-vs-WebKit metric-parity run (R22) executes here on the dev host / CI.
//
// Ownership: the caller constructs a hidden WebView2 control (0x0 / Collapsed, in
// the visual tree so CoreWebView2 initializes) and hands it in — mirroring the way
// the Swift engine keeps its WKWebView hidden and never displays it. Building the
// control here is intentionally avoided so this class stays a thin, testable seam.
public sealed class WebView2PretextHost : IPretextWebHost, IDisposable
{
    private const string VirtualHost = "pretext.openburnbar.invalid";

    private readonly WebView2 _webView;
    private readonly DispatcherQueue _dispatcher;
    private readonly string _resourceDirectory;
    private readonly bool _ownsResourceDirectory;

    private CoreWebView2? _core;
    private bool _started;
    private bool _disposed;

    public event Action<string>? WebMessageReceived;

    /// <param name="webView">A hidden WebView2 control owned by the caller.</param>
    /// <param name="resourceDirectory">
    /// Optional folder to extract the shell into; a temp folder is created + owned
    /// when null.
    /// </param>
    public WebView2PretextHost(WebView2 webView, string? resourceDirectory = null)
    {
        _webView = webView ?? throw new ArgumentNullException(nameof(webView));
        _dispatcher = webView.DispatcherQueue
            ?? throw new InvalidOperationException("WebView2 has no DispatcherQueue.");

        if (resourceDirectory is null)
        {
            _resourceDirectory = Path.Combine(Path.GetTempPath(), "OpenBurnBar", "Pretext", Guid.NewGuid().ToString("N"));
            _ownsResourceDirectory = true;
        }
        else
        {
            _resourceDirectory = resourceDirectory;
            _ownsResourceDirectory = false;
        }
    }

    public Task StartAsync(CancellationToken cancellationToken = default)
    {
        return RunOnDispatcherAsync(async () =>
        {
            if (_started)
            {
                return;
            }
            _started = true;

            // Extract index.html + the verbatim bundle, then map the folder to a
            // virtual host so the <script src="pretext.bundle.min.js"> resolves with a
            // real origin (required for module/script loading semantics).
            var indexPath = PretextShellResources.ExtractTo(_resourceDirectory);
            _ = indexPath; // navigation targets the virtual host, not the raw path.

            await _webView.EnsureCoreWebView2Async();
            _core = _webView.CoreWebView2;

            HardenForOffscreenUse(_core);
            _core.SetVirtualHostNameToFolderMapping(
                VirtualHost, _resourceDirectory, CoreWebView2HostResourceAccessKind.Allow);
            _core.WebMessageReceived += OnCoreWebMessageReceived;

            // The page posts the readiness heartbeat ({id:0,...}) once loaded, which
            // the engine's HandleBridgeMessage promotes to ready.
            _core.Navigate($"https://{VirtualHost}/index.html");
        });
    }

    public Task<string?> ExecuteScriptAsync(string script, CancellationToken cancellationToken = default)
    {
        return RunOnDispatcherAsync(async () =>
        {
            var core = _core ?? throw PretextUnavailable();
            var result = await core.ExecuteScriptAsync(script);
            return (string?)result;
        });
    }

    private void OnCoreWebMessageReceived(CoreWebView2 sender, CoreWebView2WebMessageReceivedEventArgs args)
    {
        // The shell posts objects via window.chrome.webview.postMessage(...), which
        // arrive as JSON here — exactly the reply shape the engine parses.
        WebMessageReceived?.Invoke(args.WebMessageAsJson);
    }

    private static void HardenForOffscreenUse(CoreWebView2 core)
    {
        var settings = core.Settings;
        settings.AreDefaultContextMenusEnabled = false;
        settings.AreDevToolsEnabled = false;
        settings.IsStatusBarEnabled = false;
        settings.IsZoomControlEnabled = false;
        settings.AreDefaultScriptDialogsEnabled = false;
        settings.IsBuiltInErrorPageEnabled = false;
        // JavaScript stays enabled — the layout engine runs in the page.
        settings.IsScriptEnabled = true;
    }

    private static InvalidOperationException PretextUnavailable() =>
        new("Pretext WebView2 host has not started (call StartAsync first).");

    // Marshal work onto the WebView2's UI thread and await its completion.
    private Task RunOnDispatcherAsync(Func<Task> work)
    {
        var tcs = new TaskCompletionSource();
        if (!_dispatcher.TryEnqueue(async () =>
            {
                try
                {
                    await work();
                    tcs.TrySetResult();
                }
                catch (Exception ex)
                {
                    tcs.TrySetException(ex);
                }
            }))
        {
            tcs.TrySetException(new InvalidOperationException("Failed to enqueue work on the WebView2 dispatcher."));
        }
        return tcs.Task;
    }

    private Task<T> RunOnDispatcherAsync<T>(Func<Task<T>> work)
    {
        var tcs = new TaskCompletionSource<T>();
        if (!_dispatcher.TryEnqueue(async () =>
            {
                try
                {
                    tcs.TrySetResult(await work());
                }
                catch (Exception ex)
                {
                    tcs.TrySetException(ex);
                }
            }))
        {
            tcs.TrySetException(new InvalidOperationException("Failed to enqueue work on the WebView2 dispatcher."));
        }
        return tcs.Task;
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
            _core.WebMessageReceived -= OnCoreWebMessageReceived;
        }
        if (_ownsResourceDirectory)
        {
            try
            {
                if (Directory.Exists(_resourceDirectory))
                {
                    Directory.Delete(_resourceDirectory, recursive: true);
                }
            }
            catch (IOException)
            {
                // best-effort cleanup
            }
        }
    }
}
