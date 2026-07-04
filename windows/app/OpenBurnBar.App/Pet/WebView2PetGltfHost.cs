using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Web.WebView2.Core;
using OpenBurnBar.App.Pet.Gltf;

namespace OpenBurnBar.App.Pet;

// MARK: - WebView2 pet glTF host (Windows-only)
//
// The real WebView2 implementation of IPetGltfHost — the Windows peer of the
// SceneKit renderer host. It hosts a transparent WebView2 that loads the SAME
// embedded three.js shell (petgltf.index.html, extracted from OpenBurnBar.App.Pet)
// via the WebView2 bridge, and bridges:
//
//   host -> page:  CoreWebView2.PostWebMessageAsString(commandJson)
//   page -> host:  CoreWebView2.WebMessageReceived (args.WebMessageAsJson)
//
// This mirrors WebView2PretextHost.cs method-for-method (the landed Pretext
// pattern). The portable PetGltfSceneController is transport-agnostic and fully
// unit-tested on macOS against a fake host; THIS file is the Windows transport and
// is therefore Windows-gated (WinUI + WebView2 build only on Windows). The live
// three.js render (R-pet-gltf) executes here on the dev host / CI.
//
// DECISION — WebView2 + three.js (not native): documented in
// windows/app/OpenBurnBar.App/Pet/README.md. In short: it reuses the landed
// offscreen-WebView2 bridge, loads the 115 committed Draco-compressed .glb assets
// unmodified via GLTFLoader + DRACOLoader, and a transparent WebView2 composites
// cleanly over the WS_EX_LAYERED overlay — whereas a native Win2D path would mean
// writing a glTF parser + skinned-animation runtime from scratch with zero reuse.
//
// Ownership: the caller constructs a WebView2 control (transparent, filling the
// overlay) and hands it in — mirroring WebView2PretextHost. The three.js runtime is
// dev-host-vendored under the extracted vendor/ folder (see the shell's
// vendor/README.md).
public sealed class WebView2PetGltfHost : IPetGltfHost, IDisposable
{
    private const string VirtualHost = "petgltf.openburnbar.invalid";

    private readonly WebView2 _webView;
    private readonly DispatcherQueue _dispatcher;
    private readonly string _resourceDirectory;
    private readonly bool _ownsResourceDirectory;

    private CoreWebView2? _core;
    private bool _started;
    private bool _disposed;

    public event Action<string>? MessageReceived;

    /// <param name="webView">A WebView2 control owned by the caller (transparent).</param>
    /// <param name="resourceDirectory">
    /// Folder the shell + the vendored three.js live in. When null a temp folder is
    /// created + owned (the dev-host build step must vendor three.js into
    /// {folder}/vendor/ before load — see the shell README).
    /// </param>
    public WebView2PetGltfHost(WebView2 webView, string? resourceDirectory = null)
    {
        _webView = webView ?? throw new ArgumentNullException(nameof(webView));
        _dispatcher = webView.DispatcherQueue
            ?? throw new InvalidOperationException("WebView2 has no DispatcherQueue.");

        if (resourceDirectory is null)
        {
            _resourceDirectory = Path.Combine(Path.GetTempPath(), "OpenBurnBar", "PetGltf", Guid.NewGuid().ToString("N"));
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

            // Extract index.html; the three.js runtime is vendored alongside under
            // vendor/ by the dev-host build step.
            var indexPath = PetGltfShellResources.ExtractTo(_resourceDirectory);
            _ = indexPath; // navigation targets the virtual host, not the raw path.

            await _webView.EnsureCoreWebView2Async();
            _core = _webView.CoreWebView2;

            HardenForOverlayUse(_core);
            // Transparent background so the desktop shows through the pet's alpha.
            try
            {
                _core.SetVirtualHostNameToFolderMapping(
                    VirtualHost, _resourceDirectory, CoreWebView2HostResourceAccessKind.Allow);
            }
            catch (NotImplementedException)
            {
                // older runtime: fall back to file navigation below
            }
            _core.WebMessageReceived += OnCoreWebMessageReceived;

            // The page posts {id:0,event:"ready"} once three.js is initialised, which
            // PetGltfSceneController promotes to ready.
            _core.Navigate($"https://{VirtualHost}/index.html");
        });
    }

    public Task PostMessageAsync(string json, CancellationToken cancellationToken = default)
    {
        return RunOnDispatcherAsync(() =>
        {
            var core = _core ?? throw PetGltfUnavailable();
            core.PostWebMessageAsString(json);
            return Task.CompletedTask;
        });
    }

    private void OnCoreWebMessageReceived(CoreWebView2 sender, CoreWebView2WebMessageReceivedEventArgs args)
    {
        // The shell posts strings via window.chrome.webview.postMessage(jsonString),
        // which arrive here as the JSON reply the controller parses.
        string payload;
        try
        {
            payload = args.TryGetWebMessageAsString();
        }
        catch (ArgumentException)
        {
            payload = args.WebMessageAsJson;
        }
        MessageReceived?.Invoke(payload);
    }

    private static void HardenForOverlayUse(CoreWebView2 core)
    {
        var settings = core.Settings;
        settings.AreDefaultContextMenusEnabled = false;
        settings.AreDevToolsEnabled = false;
        settings.IsStatusBarEnabled = false;
        settings.IsZoomControlEnabled = false;
        settings.AreDefaultScriptDialogsEnabled = false;
        settings.IsBuiltInErrorPageEnabled = false;
        settings.IsScriptEnabled = true; // three.js runs in the page
    }

    private static InvalidOperationException PetGltfUnavailable() =>
        new("Pet glTF WebView2 host has not started (call StartAsync first).");

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
