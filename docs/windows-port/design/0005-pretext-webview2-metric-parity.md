# 0005 — Pretext text-layout on WebView2 + metric parity (R22)

**Phase 3 · W6-DS-PRETEXT · blocks all of Chat.** Status: engine + bridge + corpus + Mac
golden landed and green on macOS (`dotnet test`); the live Chromium-vs-WebKit measurement
run is Windows/dev-host-deferred.

## Problem

Chat draws every bubble from geometry the **Pretext** text-layout engine returns
(paragraph height, line count, per-line widths, natural width, rich-inline runs). On macOS
that engine is an offscreen `WKWebView` running a bundled JS layout library
(`pretext.bundle.min.js`) behind a JSON bridge
(`OpenBurnBarCore/.../Pretext/PretextEngine.swift`). Windows has no WKWebView. If the numbers
drift, every bubble mislays.

## Approach

Port the *host*, keep the *engine* byte-identical.

- **Bundle:** `pretext.bundle.min.js` is copied **byte-verbatim** into the Windows app tree
  (`windows/pretext/OpenBurnBar.Pretext/Resources/Pretext/pretext.bundle.min.js`; a `cmp`
  invariant + provenance note guard it). The layout math is therefore identical to macOS.
- **Host:** an offscreen **WebView2** loads the same bundle through a WebView2 bridge shell
  (`Resources/Pretext/index.html`) that mirrors the WKWebView shell **method-for-method**;
  only the transport channel differs (`window.chrome.webview.postMessage` +
  `CoreWebView2.WebMessageReceived` instead of `window.webkit.messageHandlers.pretext`;
  `CoreWebView2.ExecuteScriptAsync` instead of `WKWebView.evaluateJavaScript`).
- **Protocol:** the C# `PretextEngine` (`windows/pretext/OpenBurnBar.Pretext/`) is a
  method-for-method port of the Swift engine — same `{id, method, params}` → `{id, ok, value,
  error}` envelope, the same JS-string escaping (backslash-first, then `"` `\n` `\r` `\t`
  U+2028 U+2029), the same readiness heartbeat (`id: 0`), and the same handle cache
  (`prepare`/`prepareWithSegments` memoized per `(text, font, options)`).

### Method map (Swift ⟷ C#)

| JS bridge method       | Swift `PretextEngine`        | C# `PretextEngine`             |
|------------------------|------------------------------|--------------------------------|
| `prepare`              | `prepare`                    | `PrepareAsync`                 |
| `prepareWithSegments`  | `prepareWithSegments`        | `PrepareWithSegmentsAsync`     |
| `layout`               | `layout`                     | `LayoutAsync`                  |
| `layoutWithLines`      | `layoutWithLines`            | `LayoutWithLinesAsync`         |
| `measureLineStats`     | `measureLineStats`           | `MeasureLineStatsAsync`        |
| `measureNaturalWidth`  | `measureNaturalWidth`        | `MeasureNaturalWidthAsync`     |
| `prepareRichInline`    | `prepareRichInline`          | `PrepareRichInlineAsync`       |
| `layoutRichInline`     | `layoutRichInline`           | `LayoutRichInlineAsync`        |
| `releaseHandle`        | `release(_:)`                | `ReleaseAsync`                 |
| (client-side bisection)| `shrinkWrapWidth`            | `ShrinkWrapWidthAsync`         |

The transport is abstracted behind `IPretextWebHost`, so the engine, protocol, handle cache,
and metric-parity harness all compile and unit-test on the macOS authoring host against an
in-memory fake host (`FakePretextWebHost`) — no browser needed. The real WebView2 transport
(`windows/app/OpenBurnBar.App/Pretext/WebView2PretextHost.cs`) is Windows-gated.

## Risk R22 — Chromium vs WebKit text metrics

Even with the **same JS and the same font**, Chromium (WebView2) and WebKit (macOS) can
resolve a family name to different font files and round subpixel advances differently, so
`canvas.measureText` — Pretext's measurement basis — can disagree. That is a Chat-layout
correctness risk.

### Mitigations (in this change)

1. **Committed corpus** (`corpus/pretext-corpus.json`): the Chat-critical measurement paths
   (single-line width, multi-line wrap height + per-line widths, line stats, natural width,
   letter-spacing, pre-wrap whitespace, CJK keep-all, emoji, rich-inline mention/chip).
2. **Authoritative Mac golden** (`corpus/golden.mac.json`, `capturedOn: macos-webkit`):
   captured from the **verbatim bundle** via a headless `WKWebView`
   (`windows/pretext/tools/pretext-golden/capture_golden.swift`). Real numbers, not a scaffold.
3. **Parity harness** (`MetricParityRunner`): measures the corpus through any `PretextEngine`
   and diffs field-by-field within per-case tolerance. Proven on macOS (identity passes,
   injected drift fails, `MeasureAsync` drives the whole corpus end-to-end via a golden-replay
   host). The **live** run — real WebView2 vs this golden — is the required Windows gate
   (`MetricParityHarnessTests.Live_webview2_matches_mac_golden_within_tolerance`, currently
   `Skip` on macOS).
4. **Font pinning:** the corpus pins **Arial** (ships on both OSes) so the golden is
   capturable and the Windows run needs no bundled font. The `index.html` carries a commented
   `@font-face` seam: for exact parity, drop a single `.woff2` into `Resources/Pretext/` and
   repin the corpus `font` strings to that family so **both** engines measure the identical
   font file. Tolerances (default `height 1.5px / width 2.0px / lineCount 0`, looser for
   emoji + CJK) absorb residual subpixel drift.

### Tuning the gate on Windows

Run the live parity test on the dev host / Windows CI. If a field drifts past tolerance:
first prefer bundling the exact `.woff2` (removes family-resolution drift); only then widen the
specific case's tolerance, with the delta recorded here. Never widen a tolerance to hide a
real layout bug — the whole point is that Chat bubbles land on the same pixels.

## Files

- `windows/pretext/OpenBurnBar.Pretext/` — portable engine + protocol + parity harness (net8.0).
- `windows/pretext/OpenBurnBar.Pretext/Resources/Pretext/` — verbatim bundle + WebView2 shell.
- `windows/pretext/OpenBurnBar.Pretext/corpus/` — corpus + Mac golden.
- `windows/pretext/OpenBurnBar.Pretext.Tests/` — macOS-green protocol + harness tests.
- `windows/pretext/tools/pretext-golden/capture_golden.swift` — golden regeneration harness.
- `windows/app/OpenBurnBar.App/Pretext/WebView2PretextHost.cs` — Windows-only WebView2 transport.

## Follow-ups

- Land the live Windows parity run as a required check once WINUI-017 unblocks WebView2 CI.
- Optionally register `windows/pretext/` as a fifth area in
  `budgets/windows-tree-baseline.json` + `scripts/debt/check-windows-tree-budget.sh` (today it
  is simply not ratcheted; all files are well under the 800-line target).
