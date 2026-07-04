# Pretext Mac golden capture

`capture_golden.swift` regenerates `windows/pretext/OpenBurnBar.Pretext/corpus/golden.mac.json`
— the authoritative macOS/WebKit measurement the Windows/WebView2 parity run is checked against
(risk R22).

It loads the **verbatim** `pretext.bundle.min.js` into a headless `WKWebView`, runs every corpus
case through the SAME method table as the WebView2 bridge shell (`prepare`→`layout`,
`prepareWithSegments`→`layoutWithLines`, `measureLineStats`, `measureNaturalWidth`,
`prepareRichInline`→`layoutRichInline`), and writes the golden JSON.

## Run (macOS)

```sh
swift windows/pretext/tools/pretext-golden/capture_golden.swift \
  windows/pretext/OpenBurnBar.Pretext/Resources/Pretext/pretext.bundle.min.js \
  windows/pretext/OpenBurnBar.Pretext/corpus/pretext-corpus.json \
  windows/pretext/OpenBurnBar.Pretext/corpus/golden.mac.json
```

Regenerate whenever the corpus changes or the bundle is re-copied. The result must have
`"capturedOn": "macos-webkit"` — the parity harness rejects a scaffold placeholder
(`MetricParityHarnessTests.Golden_is_authoritative_capture_not_scaffold`).

## Notes

- `prepare` feeds `layout`; `prepareWithSegments` feeds `layoutWithLines` — this pairing matches
  the macOS call site (`AgentLens/Views/Chat/HermesAtomComponents.swift`). Using plain `prepare`
  for `layoutWithLines` throws `e.segments[...]` inside the bundle.
- Emoji/CJK widths are WebKit-specific here; Chromium will differ, which is why those cases carry
  looser tolerances in the corpus.
