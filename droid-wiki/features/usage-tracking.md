# Usage tracking

Reads local session logs from AI coding agents, extracts token counts and costs, and stores results in SQLite via GRDB. No network calls are required — all data comes from files on disk written by each agent.

## Supported providers

17+ providers are supported:

| Provider | Session path |
|---|---|
| Claude Code | `~/.claude/projects/` |
| Factory Droid | `~/.factory/sessions/` |
| Codex | `~/.codex/sessions/` |
| Kimi | `~/.kimi/sessions/` |
| Grok Build | `~/.grok/sessions/` |
| Cursor | Cursor-specific log directory |
| Goose | Goose log directory |
| Hermes | Hermes session logs |
| Gemini CLI | Gemini CLI session path |
| Warp | Warp AI logs |
| Windsurf | Windsurf session logs |
| Forge | Forge log path |
| Augment | Augment session path |
| Antigravity / Z.ai | Z.ai session path |
| Cline | Cline log path |
| Copilot | via `UsageAggregatorParsers` generic parser |
| Aider | via `UsageAggregatorParsers` generic parser |

## LogParser protocol

Every parser conforms to:

```swift
protocol LogParser {
    var provider: AgentProvider { get }
    func parse() async throws -> [TokenUsage]
}
```

Each parser is keyed by `AgentProvider` inside `UsageAggregator`:

```swift
private let parsers: [AgentProvider: any LogParser]
```

## TokenUsage model

Core data record produced by all parsers:

| Field | Type | Description |
|---|---|---|
| `provider` | `AgentProvider` | Identifies the agent (e.g. `.claudeCode`) |
| `model` | `String` | Model identifier (e.g. `claude-sonnet-4-5`) |
| `inputTokens` | `Int` | Prompt tokens |
| `outputTokens` | `Int` | Completion tokens |
| `cacheTokens` | `Int` | Cache-read tokens |
| `cost` | `Double` | Computed cost in USD |
| `sessionPath` | `String` | Absolute path to source log file |
| `timestamp` | `Date` | When the session occurred |

## ModelPricing

`ModelPricing.lookup(model:providerID:)` normalises the model name and returns per-million-token rates:

```swift
struct ModelPricing {
    let inputPerMToken: Double
    let outputPerMToken: Double
    let cacheCreationPerMToken: Double?
    let cacheReadPerMToken: Double
}
```

Cache creation and cache read are optional; many models carry only input/output rates.

## Refresh pipeline

```mermaid
graph LR
    A[Agent log files on disk] --> B[LogParser per provider]
    B --> C[ParserCheckpointStore\n(skip seen rows)]
    C --> D[UsageAggregator]
    D --> E[UsageStore → SQLite]
    E --> F[SwiftUI dashboard]
    D --> G[CloudSyncService\n(Firestore mirror)]
```

1. **RefreshOrchestrator** schedules a detached background task to avoid blocking the main actor.
2. Each registered `LogParser` scans its directory and emits `[TokenUsage]`.
3. **ParserCheckpointStore** tracks the last-seen file offset/timestamp per parser, preventing duplicate rows across refreshes.
4. **UsageAggregator** merges results and calls `UsageStore.persist(_:)`.
5. On success, `CloudSyncService` mirrors records to Firestore for cross-device access.

`UsageAggregator` exposes observable state so views react immediately:

```swift
private(set) var isRefreshing = false
private(set) var lastRefresh: Date?
private(set) var errors: [AgentProvider: String] = [:]
private(set) var parserHealth: [AgentProvider: ParserHealth] = [:]
```

## Key files

| File | Purpose |
|---|---|
| `AgentLens/Services/UsageAggregator.swift` | `@Observable` facade, refresh coordination (~554 lines) |
| `AgentLens/Services/UsageAggregatorParsers.swift` | All parser implementations (~96 KB) |
| `AgentLens/Services/RefreshOrchestrator.swift` | Refresh scheduling and background task management |
| `AgentLens/Services/ModelPricing.swift` | Per-model token pricing lookup |
| `AgentLens/Services/DataStore/UsageStore.swift` | SQLite persistence via GRDB (~82 KB) |

## Parser health

`parserHealth` maps each provider to a `ParserHealth` enum, allowing the UI to surface per-provider errors without blocking the rest of the refresh. `persistenceErrorMessage` and `typedPersistenceError` capture any failure that occurs during the final write to SQLite.
