# OpenBurnBar.App.TextExpansion (Windows portable core)

The Windows peer of the macOS `&&`-trigger text-expansion engine. Framework-free
`net8.0`; the same managed assembly the WinUI shell links is unit-tested on the macOS
authoring host today (`dotnet test`). Tests: `windows/tests/text-expansion/`.

## What this is (portable, covered)

| File | macOS oracle | Responsibility |
| --- | --- | --- |
| `TextExpansionModel.cs` | `TextExpansion.swift` (model) | `TextExpansionMode` / `Surface` / `Scope` / `Snippet` / `Snapshot`, canonicalizing snippet ctor, raw-value bridging |
| `TextExpansionTrigger.cs` | `TextExpansion.swift` (`TextExpansionTrigger`) | canonical name (strip `&&`, lowercase), `[a-z0-9_-]` validation, length bounds |
| `TextExpansionMatcher.cs` | `TextExpansion.swift` (`TextExpansionMatcher`) | the byte-faithful match engine: boundary rules, token walk-back, `&&` prefix, prefix-collision ambiguity guard, static expand |
| `TextExpansionGlobalReplacement.cs` | `TextExpansion.swift` (policy + planner) | `TextExpansionGlobalTapPolicy.ShouldInterceptKeystrokes`, non-swallowing-monitor `Planner` |
| `TextExpansionRuntimeController.cs` | `TextExpansionRuntimeController.swift` (`handleEvent`) | the OS-agnostic state machine: rolling buffer, per-key match, swallowing-tap delete-count model, suppression window (injected clock), policy + secure-field gates |
| `TextExpansionUsKeyboardMap.cs` | `TextExpansionKeyEventCharacters.swift` | US-ANSI keycode→char fallback (the pure lookup half) so `&&` builds up when a key event has no unicode payload |
| `TextExpansionKeyboardComposer.cs` | `TextExpansionInbox.swift` (`makeSnippet`) | validate + de-dup + build a keyboard-composed snippet |
| `TextExpansionUsageStore.cs` | `TextExpansionUsageStore.swift` | usage ledger + count/recency/title ranking |
| `TextExpansionSnapshotStore.cs` | `TextExpansionSnapshotStore.swift` | JSON snapshot codec, byte-shape compatible with the Swift `Codable` encoding |
| `TextExpansionSnippetSource.cs` | controller cache | the `ITextExpansionSnippetSource` store seam + in-memory impl |

DB persistence is the SQLCipher peer of the Mac GRDB `TextExpansionSnippetStore`, in
`windows/storage/OpenBurnBar.Storage/TextExpansionSnippetWriteSeam.cs` (over the same
`v43_text_expansion_snippets` schema).

## What is deferred (OS adapter — bucket B/C)

The REAL keystroke **capture** (a Win32 low-level keyboard hook, the peer of the macOS
CGEvent session tap) and **injection** (`SendInput` / UI Automation, the peer of the
macOS AX value mutation + synthetic keys) are the OS adapter. They plug in behind the
seams defined here:

- `ITextExpansionKeystrokeSink` — perform the delete-N + type-replacement command.
- `ITextExpansionSnippetSource` — supply the active snippet set (DB-backed in prod).
- the injected clock (`Func<DateTimeOffset>`) — drives the suppression window.
- the secure-field predicate (`Func<bool>`) — never expand into a password field.

Everything above those seams is portable and carries the golden xUnit corpus.
