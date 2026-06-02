# Usage tracking

## Purpose

Reads local session logs from 17+ AI coding agents, extracts token counts and costs, and stores the results in a local SQLite database via GRDB. No network calls are required — all data comes from files on disk written by each agent. This is the source of truth for the dashboard, insights, cloud sync, and budget governance.

## Directory layout

```
AgentLens/Services/LogParser/
├── LogParserProtocol.swift          # Protocol + ParseResult + FileHandle line reader
├── ClaudeCodeParser.swift           # Anthropic Claude Code (~397 lines)
├── FactoryDroidParser.swift         # Factory Droid (~417 lines)
├── KimiParser.swift                 # Moonshot Kimi CLI (~328 lines)
├── CodexParser.swift                # OpenAI Codex
├── GrokParser.swift               # xAI Grok Build
├── CursorParser.swift               # Cursor IDE
├── CursorAgentParser.swift          # Cursor agent mode
├── CopilotParser.swift              # GitHub Copilot CLI
├── AiderParser.swift                # Aider
├── ClineFormatParser.swift          # Cline / KiloCode / Roo Code
├── ForgeDevParser.swift             # Forge
├── AugmentParser.swift              # Augment
├── AntigravityParser.swift          # Antigravity / Z.ai
├── GooseParser.swift                # Goose
├── WindsurfParser.swift             # Windsurf
├── WarpParser.swift                 # Warp
├── HermesParser.swift               # Hermes
├── GeminiCLIParser.swift            # Gemini CLI
├── OpenClawParser.swift             # OpenClaw
├── PiAgentParser.swift              # Pi Agent
├── OpenCodeParser.swift             # OpenCode
├── ModelFilterParser.swift          # Generic pattern-matching parser (Ollama, MiMo, Z.ai, MiniMax)
└── TokenExtractionUtility.swift     # Shared token-count extraction helpers

AgentLens/Services/UsageAggregation/
├── ParserRegistry.swift             # Canonical provider → parser map (all 17+ providers)
├── UsageAggregator.swift            # @Observable facade, refresh coordination (~554 lines)
└── UsageAggregatorParsers.swift     # Historical catch-all (being broken up into per-parser files)

AgentLens/Services/DataStore/
├── UsageStore.swift                 # SQLite persistence via GRDB (~82 KB)
├── ModelPricing.swift               # Per-model token pricing lookup
└── ParserCheckpointStore.swift      # Last-seen offsets to skip duplicate rows

AgentLensTests/Active/Parsers/
├── ClaudeCodeParserTests.swift
├── ClaudeCodeParserIntegrationTests.swift
├── FactoryDroidParserTests.swift
├── FactoryDroidParserIntegrationTests.swift
├── KimiParserTests.swift
└── TestableClaudeCodeParser.swift
```

## Key abstractions

### `LogParser` protocol

```swift
protocol LogParser: LogParserProtocol {
    func parse() async throws -> ParseResult
}

struct ParseResult: Sendable {
    let usages: [TokenUsage]
    let conversations: [ConversationRecord]
}
```

Every parser returns both usage rows and conversation records. The `provider` property keys the parser inside `ParserRegistry`.

### `TokenUsage`

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

### `ModelPricing`

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

## How it works

```mermaid
graph LR
    A[Agent log files on disk] --> B[LogParser per provider]
    B --> C[ParserCheckpointStore
(skip seen rows)]
    C --> D[UsageAggregator]
    D --> E[UsageStore → SQLite]
    E --> F[SwiftUI dashboard]
    D --> G[CloudSyncService
(Firestore mirror)]
```

1. **RefreshOrchestrator** schedules a detached background task to avoid blocking the main actor.
2. Each registered `LogParser` (resolved via `ParserRegistry.defaultParsers()`) scans its directory and emits `ParseResult`.
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

## Integration points

- **Dashboard** — `UsageStore` feeds the live cost totals and provider bars.
- **Insights** — `InsightEngine` reads the same SQLite tables to compute rollups.
- **Cloud sync** — `CloudSyncService` uploads unsynced rows to `users/{uid}/usage/{doc}`.
- **Budget governance** — `BudgetGate` and `BudgetLedger` consume usage rows to enforce caps.
- **Hermes chat** — `ContextBuilder` injects recent usage summaries into the chat system prompt.

## Entry points for modification

- **Add a new provider parser** — create a new `LogParser` conforming type under `AgentLens/Services/LogParser/`, register it in `ParserRegistry.swift`, and add a test in `AgentLensTests/Active/Parsers/`.
- **Update pricing** — edit `AgentLens/Services/DataStore/ModelPricing.swift` (public pricing tables, no API calls).
- **Change refresh cadence** — adjust `RefreshOrchestrator` scheduling intervals.
- **Fix duplicate detection** — tune `ParserCheckpointStore` keying logic (file path + last-modified).

---

Cross-links:
- [Insights](insights.md)
- [Budget governance](budget-governance.md)
- [Cloud sync](cloud-sync.md)
- [Hermes chat](hermes-chat.md)
