# Hermes chat

A chat panel for querying your usage data and interacting with agents. Supports two backends — a local CLI subprocess and the Hermes webapi — switched transparently at detection time.

## Backends

### Local Index mode (CLI subprocess)

- Spawns `codex` or `claude` as a child process.
- Stateless per-turn: each message triggers fresh retrieval and a new subprocess invocation.
- Falls back to this mode when Hermes is not running.

### Hermes mode (webapi)

- Connects to `http://127.0.0.1:8642` (OpenAI-compatible API).
- Streams responses via SSE (`POST /v1/chat/completions` with `stream: true`).
- Multi-turn: full message history is sent with each request so Hermes maintains conversational memory.
- Tool calls are handled server-side; results arrive as `.toolUse` events in the stream.

## Backend detection

`CLIBridge.detect()` resolves the CLI backend:

```swift
func detect() async {
    // Prefer Codex when both are installed
    if let path = await resolveExecutable(named: "codex") {
        detectedBackend = .codex(path: path)
        return
    }
    if let path = await resolveExecutable(named: "claude") {
        detectedBackend = .claudeCode(path: path)
        return
    }
    detectedBackend = nil
}
```

Hermes availability is probed separately via `probeHermesAvailability(baseURL:bearerToken:)`, which hits `/v1/models`. If the probe succeeds, `hermesAvailable = true` and the UI can offer Hermes mode.

```swift
enum Backend: Equatable {
    case claudeCode(path: String)
    case codex(path: String)
    case hermes(baseURL: URL)
}
```

## Context injection

Before each chat turn, the retrieval pipeline builds a system prompt augmented with live usage data:

```
User message
    → SearchService.retrieve() → relevant session chunks
    → ContextBuilder.buildDatabaseAnalystSystemPrompt()
        → token usage summary, recent sessions, quota headroom
    → CLIBridge.chat() with enriched system prompt
```

This applies to both backends. In Hermes mode the augmented system prompt is prepended to the messages array.

## Popover Hermes strip

A compact chat entry point embedded in the menu bar popover, between the provider list and the action bar.

| State | Height | Description |
|---|---|---|
| Collapsed | ~44 px | ☿ caduceus glyph + "Ask Hermes…" placeholder |
| Expanded | max ~220 px | Inline thread (up to 3 messages), "Open in Dashboard →" link |

- Border: 1 px `mercuryGradient` with a slow shimmer overlay (3 s cycle).
- Background: `surfaceElevated`.
- Expand/collapse animation: `gentle` spring (`response: 0.4, dampingFraction: 0.85`).

## Dashboard chat panel

The full chat panel in the Dashboard adds a mode toggle:

```
[ Local Index ]  [ Hermes ]
```

- **Local Index**: whimsy/ember assistant bubble strokes, stateless CLI bridge.
- **Hermes**: mercury-stroked assistant bubbles, multi-turn memory, collapsible tool cards.

Active mode uses `accentGradient` (Index) or `mercuryGradient` (Hermes); inactive is transparent + `textMuted`.

### Tool cards (Hermes mode)

Tool calls from Hermes render as collapsible cards:

- Border: 1 px `mercuryGradient`.
- Tool name: `caption` semibold, `mercuryGradient` text fill.
- Running indicator: 6 px pulsing dot + `textMuted` status text.
- Completed: collapsed to one line, expandable on tap.
- Tools grouped by capability icon (search, code, file, web, system).

### Thinking state

Three 8 px circles in `mercuryGradient` that pool and separate using `mercuryPool` keyframes (1.8 s duration, 0.3 s stagger between drops). No spinner.

### "via Hermes" badge

Shown above each Hermes assistant message using `hermesAureate` color with ☿ prefix.

## Key files

| File | Purpose |
|---|---|
| `AgentLens/Services/CLIBridge/CLIBridge.swift` | Backend enum, detection, Hermes probe, streaming |
| `AgentLens/Services/CLIAgentRelayChatExecutor.swift` | Executes chat turns via CLI subprocess |
| `AgentLens/Services/HermesRealtimeRelayHostClient.swift` | iroh relay client used by Hermes mode |
| `AgentLens/Services/CLIBridge/CLIBridgeStreamRuntimeCoordinator.swift` | SSE stream parsing and event dispatch |
| `AgentLens/Services/CLIBridge/RoutingClientWiring.swift` | Wires backend selection to active session |
