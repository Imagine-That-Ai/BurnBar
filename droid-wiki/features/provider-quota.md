# Provider quota

## Purpose

Tracks per-provider API quota usage and remaining headroom in real time. AI coding agents consume API quota in different ways — Anthropic enforces a 5-hour rolling token window, OpenAI enforces per-minute and per-day rate limits, Factory enforces session-level usage floors. Without visibility into quota state, agents hit limits mid-session. The provider quota surface shows current usage bars in the popover and fires warnings before limits are reached.

## Directory layout

```
AgentLens/Services/ProviderQuota/
├── ProviderQuotaService.swift           # Main orchestration (~70,972 bytes)
├── QuotaRefreshActor.swift              # Actor that owns all HTTP fetching (~31,774 bytes)
├── ProviderQuotaAdapter.swift           # Protocol + ProviderQuotaAdapterContext (~581 lines)
├── ProviderQuotaTypes.swift             # QuotaSnapshot, QuotaBucket, etc. (~28,172 bytes)
├── ProviderQuotaSnapshotStore.swift     # Local SQLite persistence
├── FlexibleQuotaBucketNormalizer.swift  # Bucket normalisation (~22,558 bytes)
├── QuotaRefreshLifecycle.swift          # Automatic refresh scheduling
├── ProviderQuotaAutomaticRefreshLifecycle.swift  # Daemon credential slot projection
└── [22+ adapter files]
    ├── ClaudeQuotaAdapter.swift         # Anthropic Claude (OAuth + API key, 5-hour rolling window)
    ├── CodexQuotaAdapter.swift          # OpenAI Codex
    ├── FactoryQuotaAdapter.swift        # Factory Droid (session classifier, dashboard scraper)
    ├── CursorQuotaAdapter.swift         # Cursor (cookie extractor)
    ├── MiniMaxQuotaAdapter.swift        # MiniMax
    ├── KimiQuotaAdapter.swift           # Kimi
    ├── XAIQuotaAdapter.swift            # xAI Grok
    ├── ZAIQuotaAdapter.swift            # ZAI
    ├── MimoQuotaAdapter.swift           # MiMo
    ├── OllamaQuotaAdapter.swift         # Ollama Cloud
    ├── ForgeQuotaAdapter.swift          # Forge Dev
    ├── WarpQuotaAdapter.swift           # Warp
    ├── AntigravityQuotaAdapter.swift    # Antigravity
    ├── AiderQuotaAdapter.swift          # Aider
    ├── CopilotQuotaAdapter.swift        # GitHub Copilot
    ├── KiloCodeQuotaAdapter.swift       # KiloCode
    ├── HermesQuotaAdapter.swift         # Hermes (local, stub)
    ├── ClaudeCredentialsReader.swift    # Reads Claude Code credentials (production uses NoClaudeCredentialsReader)
    └── StubQuotaAdapter.swift           # Fallback adapter

AgentLens/Services/DataStore/
└── ProviderQuotaSnapshotStore.swift     # SQLite persistence for quota snapshots

AgentLens/Views/Dashboard/Components/
└── BurnRailBudgetChip.swift             # Inline quota bar in session rail

AgentLensTests/Active/
└── ProviderQuotaServiceTests.swift      # Unit tests for quota service

android/app/src/main/java/com/openburnbar/data/models/
└── TokenUsage.kt                        # Android `ProviderQuotaSnapshot` + `QuotaBucket`
```

## Key abstractions

### `ProviderQuotaAdapter`

```swift
protocol ProviderQuotaAdapter: Sendable {
    func fetch(context: ProviderQuotaAdapterContext) async throws -> ProviderQuotaSnapshot
}
```

Each adapter knows how to fetch or infer a provider's quota state. The `ProviderQuotaAdapterContext` carries resolved API keys, file manager, URL session, plan readers, and credential readers — all assembled on the main actor before quota work is dispatched.

### `QuotaRefreshActor`

Actor that owns all HTTP fetching for provider quota adapters. Heavy I/O runs here, off the main thread.

- `maxConcurrentQuotaFetches = 4`
- Returns `ProviderQuotaRefreshBatch` containing `providerSnapshots` and `accountSnapshots`

### `ProviderQuotaSnapshot`

Normalised quota state per provider:

```swift
struct ProviderQuotaSnapshot {
    let provider: AgentProvider
    let sourceID: String
    let buckets: [QuotaBucket]
    let fetchedAt: Date
    let confidence: QuotaConfidence
}
```

### `QuotaBucket`

| Field | Type | Description |
|---|---|---|
| `window` | `String` | `"5h"`, `"daily"`, `"monthly"`, etc. |
| `used` | `Int` | Tokens or requests consumed |
| `limit` | `Int` | Window limit |
| `resetAt` | `Date?` | When the window resets |
| `confidence` | `String` | `"exact"` or `"estimated"` |

## How it works

```mermaid
graph TD
    A[QuotaRefreshActor] --> B[ProviderQuotaAdapter per provider]
    B --> C[fetch or scrape quota state]
    C --> D[normalize to QuotaBucket[]]
    D --> E[ProviderQuotaSnapshotStore local SQLite]
    E --> F[QuotaSnapshotSyncService Firestore]
    E --> G[Dashboard / Popover quota bars]
```

1. `QuotaRefreshActor` orchestrates polling across all registered adapters.
2. Each adapter fetches or scrapes quota state using provider-specific APIs.
3. Results are normalised to `QuotaBucket[]` via `FlexibleQuotaBucketNormalizer`.
4. `ProviderQuotaSnapshotStore` persists snapshots in local SQLite.
5. `QuotaSnapshotSyncService` mirrors to Firestore for cross-device visibility.
6. Dashboard and popover render quota bars when a provider's active bucket exceeds a warning threshold (typically 80%).

## Integration points

- **Usage tracking** — `UsageAggregator` triggers quota refresh alongside usage parsing.
- **Budget governance** — `BudgetGate` reads quota snapshots when evaluating whether to allow a Computer Use action. If a provider is at or near its hard limit, the gate can block new actions independent of dollar-denominated caps.
- **Cloud sync** — `QuotaSnapshotSyncService` replicates to `users/{uid}/quota_snapshots/{provider}_{sourceId}`.
- **Dashboard** — `BurnRailBudgetChip` renders quota state inline in the session rail.

## Entry points for modification

- **Add a new provider adapter** — create a new `ProviderQuotaAdapter` conforming type, register it in `ProviderQuotaService`, and add tests.
- **Change refresh cadence** — adjust `QuotaRefreshActor` scheduling or `ProviderQuotaAutomaticRefreshLifecycle` intervals.
- **Modify bucket normalisation** — edit `FlexibleQuotaBucketNormalizer.swift`.
- **Update UI thresholds** — change the warning threshold in `BurnRailBudgetChip` or the dashboard view model.
- **Add cross-device sync** — ensure the new adapter's snapshot format matches `functions/src/types.ts` and Android `TokenUsage.kt`.

---

Cross-links:
- [Usage tracking](usage-tracking.md)
- [Budget governance](budget-governance.md)
- [Cloud sync](cloud-sync.md)
- [Hermes chat](hermes-chat.md)
