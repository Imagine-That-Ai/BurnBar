# Pretext text-layout bridge (Windows)

The Windows peer of the macOS `PretextEngine` — the offscreen text-**layout** engine every Chat
bubble measures against (paragraph height, line count, per-line widths, natural width, rich-inline
runs). See `docs/windows-port/design/0005-pretext-webview2-metric-parity.md` (W6-DS-PRETEXT / R22).

## Layout

```
windows/pretext/
  OpenBurnBar.Pretext/            net8.0 — portable, no Windows deps
    PretextTypes.cs               value-type mirror of PretextTypes.swift
    PretextBridge.cs             {id,method,params} <-> {id,ok,value,error} codec + JS escaping
    IPretextWebHost.cs           transport seam (WKWebView.evaluateJavaScript / messageHandlers peer)
    PretextEngine.cs             method-for-method port of PretextEngine.swift (+ handle cache)
    PretextShellResources.cs     extracts the embedded shell for a host to load
    MetricParity/                corpus + golden models + the parity runner
    Resources/Pretext/           VERBATIM pretext.bundle.min.js + WebView2 index.html
    corpus/                      pretext-corpus.json + golden.mac.json (real WebKit capture)
  OpenBurnBar.Pretext.Tests/     net10.0, xUnit — macOS-green protocol + harness tests
  tools/pretext-golden/          headless-WKWebView golden capture harness

windows/app/OpenBurnBar.App/Pretext/
  WebView2PretextHost.cs         Windows-only real offscreen-WebView2 transport
```

## Why split portable vs Windows-only

The engine, protocol, handle cache, and metric-parity harness are transport-agnostic (they talk to
`IPretextWebHost`), so they **compile and unit-test on the macOS authoring host** against an
in-memory fake host — no browser. Only `WebView2PretextHost` needs Windows, and only the **live**
Chromium-vs-WebKit measurement run is Windows/dev-host-deferred.

## Verify

```sh
# portable engine + protocol + parity harness (macOS-green today):
dotnet test windows/pretext/OpenBurnBar.Pretext.Tests

# bundle stays byte-verbatim vs the macOS engine:
cmp OpenBurnBarCore/Sources/OpenBurnBarCore/Resources/Pretext/pretext.bundle.min.js \
    windows/pretext/OpenBurnBar.Pretext/Resources/Pretext/pretext.bundle.min.js
```

The WinUI app + WebView2 live parity run build on Windows only (see
`windows/app/DEV_HOST_RUNBOOK.md`).
