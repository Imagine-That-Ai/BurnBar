# Bundled Pretext shell (WebView2)

Two files load into the offscreen WebView2 that measures Chat text on Windows.

## `pretext.bundle.min.js` — VERBATIM copy, do not edit

Byte-for-byte identical to the macOS engine's bundle at
`OpenBurnBarCore/Sources/OpenBurnBarCore/Resources/Pretext/pretext.bundle.min.js`.

Keeping it verbatim is what makes the layout **math** identical across WebKit and Chromium; the
only remaining variable is the font-metric backend (risk R22 — see
`docs/windows-port/design/0005-pretext-webview2-metric-parity.md`).

**Invariant (must stay true):**

```sh
cmp OpenBurnBarCore/Sources/OpenBurnBarCore/Resources/Pretext/pretext.bundle.min.js \
    windows/pretext/OpenBurnBar.Pretext/Resources/Pretext/pretext.bundle.min.js
```

When the macOS bundle is regenerated, re-copy it here (and re-capture the golden — see
`windows/pretext/tools/pretext-golden/`).

## `index.html` — WebView2 bridge shell

The Windows peer of the WKWebView `index.html`. The method table (`prepare`, `layout`,
`layoutWithLines`, `measureLineStats`, `measureNaturalWidth`, `prepareRichInline`,
`layoutRichInline`, `releaseHandle`, `renderToCanvas`) is **identical**; only the transport
channel differs:

| | macOS (WKWebView) | Windows (WebView2) |
|---|---|---|
| host → page | `WKWebView.evaluateJavaScript` | `CoreWebView2.ExecuteScriptAsync` |
| page → host | `window.webkit.messageHandlers.pretext.postMessage` | `window.chrome.webview.postMessage` |
| entry point | `window.__pretextDispatch(json)` | `window.__pretextDispatch(json)` (same) |
| heartbeat | `{ id: 0, ok: true, value: { ready: true } }` | same |

It also carries a commented `@font-face` seam for exact-parity font pinning (R22).

Both files are embedded in the `OpenBurnBar.Pretext` assembly (see the csproj `LogicalName`s)
and extracted at runtime by `PretextShellResources.ExtractTo(...)`.
