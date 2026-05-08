# Conversation Atoms

> Hermes responses on every OpenBurnBar surface are no longer passive walls of
> prose — entities the app already has UI for (costs, sessions, models,
> providers, time windows, projects, tools, token totals, quota usage, runtime
> profiles) are emitted as atomic `burnbar://` markdown links and rendered as
> tappable inline chips that open the matching native view. Pretext rich-inline
> guarantees those chips never break across lines and that prose flows naturally
> around them. Streaming bubbles measure themselves on every chunk and animate
> their frame; on completion they shrink-wrap to the tightest comfortable width.

## What is it

**Conversation Atoms** is the cross-platform layer that turns Hermes prose into
navigable UI. It runs on iOS, iPadOS, and macOS, sharing a single Swift package
(`OpenBurnBarCore`) for parsing, URL encoding, and the system-prompt directive,
and a single offscreen WKWebView (`PretextEngine`) for layout measurement.

Three compounding transformations:

1. **Atomic chips** — every entity Hermes references is wrapped in a
   `[label](burnbar://...)` markdown link. The parser decodes those into typed
   `HermesAtom` values and renders them as `HermesAtomChip` views. Chips never
   wrap mid-token; they fall to the next line whole.
2. **Streaming-stable bubbles** — `StreamingBubble` measures the in-flight text
   via Pretext on each SSE chunk (debounced into 32-char buckets) and animates
   the bubble's `frame(height:)` between snapshots with a calm spring. Scroll
   anchoring stays smooth instead of thrashing on every chunk.
3. **Shrink-wrapped bubbles** — when streaming completes (and the message isn't
   an error), the engine runs a binary search to find the tightest width that
   keeps the bubble at ≤ 4 lines, and animates `frame(width:)` down to it.

## Architecture

```
Hermes (chat-completions) ──► Markdown links: [label](burnbar://...)
                                     │
                                     ▼
                          HermesAtomParser.parse(text)
                                     │
                       ┌─────────────┴─────────────┐
                       ▼                           ▼
              [HermesRichRun]              PretextRichInlineItem[]
                                                   │
                                                   ▼
                                        PretextEngine (WKWebView)
                                          prepareRichInline +
                                          layoutRichInline
                                                   │
                                     ┌─────────────┴─────────────┐
                                     ▼                           ▼
                            PretextRichLine[]               render fragments
                                                                  │
                                                  ┌───────────────┼───────────────┐
                                                  ▼               ▼               ▼
                                          HermesAtomChip      Text(body)      mention/code
                                                  │
                                                  ▼ tap
                                       HermesAtomNavigator (env)
                                                  │
                                ┌─────────────────┴─────────────────┐
                                ▼                                   ▼
                         iOS detail sheet                 macOS detail popover
                                │                                   │
                                ▼                                   ▼
                      push / switch tab / sheet         open route / panel / menu
```

## Atom URL scheme

All atoms encode as `burnbar://<host>?<query>`. The same vocabulary is the
authoritative directive sent to Hermes via `HermesSystemPromptBuilder`, and the
client decoder used by `HermesAtomParser`.

- `burnbar://burn?window=today&amount=2.34` — cost atom, window ∈ `today |
  yesterday | 7d | 30d | 90d | all`
- `burnbar://session?id=abc-123` — session atom
- `burnbar://provider?token=anthropic` — provider atom (token matches
  `AgentProvider.fromPersistedToken`)
- `burnbar://model?id=claude-sonnet-4.7` — model atom
- `burnbar://window?value=7d` — window-switch atom
- `burnbar://tool?name=ReadFile` — tool atom
- `burnbar://project?id=BurnBar` — project atom
- `burnbar://tokens?value=12400&scope=session` — token total atom, scope ∈
  `today | session | run | lifetime`
- `burnbar://quota?provider=anthropic&percent=78` — quota atom
- `burnbar://runtime?profile=hermes` — Hermes runtime atom

`HermesAtomURL.encode(_:)` and `HermesAtomURL.decode(_:)` are inverses; round
trips are stable. Decoding rejects unknown hosts, missing required params, and
any URL whose scheme isn't `burnbar`.

## Hermes prompt directive

`HermesSystemPromptBuilder` is the single source of truth for the directive
appended to every Hermes chat-completions system prompt. Both
`OpenBurnBarMobile/Services/HermesService.swift` (iOS) and
`AgentLens/Services/Chat/ChatSessionController.swift` (macOS) consume it via
`HermesSystemPromptBuilder(...).build()`.

The directive lists every atom URL form, three worked examples, and four rules:

- Atoms are atomic — keep labels short (~30 chars).
- Use atoms only for entities the user can navigate to. No made-up IDs.
- Prefer atoms for the **first** mention of an entity in a paragraph; later
  references can be plain text.
- Never wrap an atom inside another atom.

The builder also accepts an optional `dashboardContext` (the live cost / session
/ provider snapshot each app already builds) and an optional `preamble`, both
joined with the atom directive into a single system message.

## Two-pass parser

`HermesAtomParser.parse(_:)` returns `[HermesRichRun]` in source order:

1. **Pass 1 — Markdown link extraction.** Scans for `[label](burnbar://...)`
   constructs, respecting `\\[` escapes and rejecting links that span newlines.
   Each match decodes via `HermesAtomURL.decode(_:)`; failed decodes fall
   through as plain body text.
2. **Pass 2 — Regex fallback.** For every body region not consumed by Pass 1:
   - `@handle` mentions (alphanumeric + `_-.`).
   - `` `inline code` `` spans (backticks stripped from emitted text).
   - `$cost` patterns (`$1`, `$1,234.56`) → `.cost(amount:, window: .today)`.
   - Known model IDs from a small allowlist (`claude-sonnet-4.7`, `gpt-5`,
     `kimi-k1.7`, `glm-5`, `gemini-3-pro`, …) → `.model(id:)`.

`HermesRichRun` cases are `.body`, `.atom(HermesAtom, label: String)`,
`.mention(handle:)`, and `.code`. Run order is always the source-text order;
concatenating `runs.map(\.text)` reproduces the input within link-flattening
semantics.

Test coverage lives in
`OpenBurnBarCore/Tests/OpenBurnBarCoreTests/HermesAtomParserTests.swift`:
markdown link extraction, regex fallback for `$amounts` and known model IDs,
mixed atoms + mentions + code in one message, malformed URLs falling back to
body, and ordering preservation under interleaved regions.

## Streaming + shrink-wrap

`StreamingBubble<Content>` (one copy per platform — `OpenBurnBarMobile/Views/
Components/StreamingBubble.swift` and `AgentLens/Views/Chat/
HermesAtomComponents.swift`) wraps any inner content view with a measurement-
animated frame:

- While `isStreaming` is `true`:
  - The trigger key buckets text length into 32-character chunks so very fast
    SSE bursts coalesce into roughly one bridge call every few lines.
  - `PretextEngine.prepare + layout` returns a target height. The bubble's
    `frame(height:)` animates between snapshots with `.spring(response: 0.32,
    dampingFraction: 0.86)`.
  - Width is left at the container's `proxy.size.width` so the user sees full
    chunks.
- When streaming completes (and the message isn't an error):
  - `PretextEngine.shrinkWrapWidth(upper: width, targetLines: 4)` runs a binary
    search to find the tightest width keeping the bubble ≤ 4 lines.
  - `frame(width:)` animates down with the same spring; height is re-measured
    against the new width.

The inner content view (`HermesRichBubble`) keeps drawing without animation, so
text materializes inside a moving bubble instead of double-easing.

## Components

Cross-platform core (`OpenBurnBarCore/Sources/OpenBurnBarCore/`):

- `Hermes/HermesAtom.swift` — `HermesAtom` enum (10 cases), `HermesAtomKind`
  with SF Symbol / category / one-line description, plus
  `HermesAtomWindow` and `HermesAtomTokenScope`.
- `Hermes/HermesAtomURL.swift` — encode/decode against the `burnbar://` scheme.
- `Hermes/HermesAtomParser.swift` — two-pass parser returning
  `[HermesRichRun]`.
- `Hermes/HermesSystemPromptBuilder.swift` — atom-directive composer.
- `Hermes/HermesAtomNavigator.swift` — abstract `@MainActor` navigator
  protocol with a `NoopHermesAtomNavigator` default (logs missed wiring via
  `OSLog`).
- `Pretext/PretextEngine.swift` — singleton WKWebView bridge with prepared-
  text cache, request-correlated async API, and `shrinkWrapWidth` helper.
- `Pretext/PretextTypes.swift` — `PretextHandle`, `PretextOptions`,
  `PretextLine`, `PretextLineStats`, `PretextRichInlineItem`,
  `PretextRichLine`, `PretextRichFragment`, `PretextError`.
- `Resources/Pretext/index.html` + `Resources/Pretext/pretext.bundle.min.js` —
  themed shell + JS bundle, loaded via `Bundle.module` so both apps share one
  copy.

iOS / iPadOS (`OpenBurnBarMobile/`):

- `Views/Components/HermesAtomChip.swift` — SwiftUI chip, `MobileTheme` accent
  per `HermesAtomKind`, inline / standalone size variants.
- `Views/Components/HermesRichBubble.swift` — parses + lays out via Pretext,
  renders fragments as native views.
- `Views/Components/StreamingBubble.swift` — measurement-animated frame.
- `Views/Components/HermesAtomEnvironment.swift` — environment key for the
  navigator.
- `Views/Hermes/HermesAtomDetailSheet.swift` — quick-look sheet with a primary
  action button.
- `Services/HermesAtomRouter.swift` — `@Observable` router implementing
  `HermesAtomNavigator`, exposing `pending` (sheet) and
  `confirmedDestination` (route) slots.
- Wired into `HermesTabView`, `HermesChatView`, and `ChatView`. `HermesService`
  builds its system prompt via `HermesSystemPromptBuilder`.

macOS (`AgentLens/`):

- `Views/Chat/HermesAtomComponents.swift` — same chip, router, rich bubble,
  streaming bubble, and detail popover, but using `DesignSystem` tokens and
  AppKit cursor / hover semantics. Popover is presented on chip tap rather
  than a sheet.
- Wired into `ChatMessageView.proseBubble` (assistant turns only).
  `ChatSessionController` builds its system prompt via
  `HermesSystemPromptBuilder`.

## Tests

- `OpenBurnBarCore/Tests/OpenBurnBarCoreTests/HermesAtomParserTests.swift` —
  markdown-link extraction, regex fallback, mixed runs, malformed URL fallback,
  ordering preservation, `\\[` escape handling, code-span backtick stripping.

Run with `swift test --package-path OpenBurnBarCore`.

## Files

Core (shared):

- `OpenBurnBarCore/Sources/OpenBurnBarCore/Hermes/HermesAtom.swift`
- `OpenBurnBarCore/Sources/OpenBurnBarCore/Hermes/HermesAtomURL.swift`
- `OpenBurnBarCore/Sources/OpenBurnBarCore/Hermes/HermesAtomParser.swift`
- `OpenBurnBarCore/Sources/OpenBurnBarCore/Hermes/HermesSystemPromptBuilder.swift`
- `OpenBurnBarCore/Sources/OpenBurnBarCore/Hermes/HermesAtomNavigator.swift`
- `OpenBurnBarCore/Sources/OpenBurnBarCore/Pretext/PretextEngine.swift`
- `OpenBurnBarCore/Sources/OpenBurnBarCore/Pretext/PretextTypes.swift`
- `OpenBurnBarCore/Sources/OpenBurnBarCore/Resources/Pretext/index.html`
- `OpenBurnBarCore/Sources/OpenBurnBarCore/Resources/Pretext/pretext.bundle.min.js`
- `OpenBurnBarCore/Tests/OpenBurnBarCoreTests/HermesAtomParserTests.swift`

iOS / iPadOS:

- `OpenBurnBarMobile/Views/Components/HermesAtomChip.swift`
- `OpenBurnBarMobile/Views/Components/HermesAtomEnvironment.swift`
- `OpenBurnBarMobile/Views/Components/HermesRichBubble.swift`
- `OpenBurnBarMobile/Views/Components/StreamingBubble.swift`
- `OpenBurnBarMobile/Views/Hermes/HermesAtomDetailSheet.swift`
- `OpenBurnBarMobile/Services/HermesAtomRouter.swift`
- `OpenBurnBarMobile/Services/HermesService.swift`
- `OpenBurnBarMobile/Views/Hermes/HermesTabView.swift`
- `OpenBurnBarMobile/Views/Hermes/HermesChatView.swift`
- `OpenBurnBarMobile/Views/ChatView.swift`

macOS:

- `AgentLens/Views/Chat/HermesAtomComponents.swift`
- `AgentLens/Views/Chat/ChatMessageView.swift`
- `AgentLens/Services/Chat/ChatSessionController.swift`
