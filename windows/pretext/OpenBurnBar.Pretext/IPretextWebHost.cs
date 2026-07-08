using System;
using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.Pretext;

// MARK: - Web-host transport seam
//
// The `PretextEngine` is transport-agnostic: it only knows how to (a) ask the
// host to load the bundled shell, (b) push a `window.__pretextDispatch("...")`
// script into the page, and (c) receive JSON bridge replies the page posts back.
//
// This mirrors the WKWebView split on the Swift side: `PretextEngine.swift`'s
// `webView.evaluateJavaScript(...)` maps to <see cref="ExecuteScriptAsync"/>, and
// the `WKScriptMessageHandler` that forwards `messageHandlers.pretext` maps to
// the <see cref="WebMessageReceived"/> event. The concrete WebView2 host lives in
// the WinUI app (`WebView2PretextHost`); the tests supply an in-memory fake so the
// whole protocol is exercised on the macOS authoring host without a browser.

/// Transport seam between the portable <see cref="PretextEngine"/> and a concrete
/// web view (real: offscreen WebView2 on Windows; test: in-memory fake).
public interface IPretextWebHost
{
    /// Load the bundled Pretext shell (index.html + pretext.bundle.min.js). Must be
    /// idempotent — safe to call more than once. The host raises
    /// <see cref="WebMessageReceived"/> with the readiness heartbeat
    /// (<c>{ "id": 0, "ok": true, "value": { "ready": true } }</c>) once the shell
    /// has loaded and Pretext is available.
    Task StartAsync(CancellationToken cancellationToken = default);

    /// Execute a script in the page. The engine hands this the escaped
    /// <c>window.__pretextDispatch("...")</c> call. The returned string is the raw
    /// JS result (unused by the protocol — replies come back over
    /// <see cref="WebMessageReceived"/>); errors surface as a faulted task.
    Task<string?> ExecuteScriptAsync(string script, CancellationToken cancellationToken = default);

    /// Raised whenever the page posts a bridge reply. The payload is the reply JSON
    /// string (the shape produced by `postReply` in the WebView2 index.html).
    event Action<string> WebMessageReceived;
}
