# Provider quota

Tracks per-provider API quota usage and remaining headroom in real time.

---

## Purpose

AI coding agents consume API quota in different ways — Anthropic enforces a 5-hour rolling token window, OpenAI enforces per-minute and per-day rate limits, Factory enforces session-level usage floors. Without visibility into quota state, agents hit limits mid-session. The provider quota surface shows current usage bars in the popover and fires warnings before limits are reached.

---

## How it works

Each supported provider has a quota adapter that knows how to fetch or infer that provider's quota state. The `QuotaRefreshActor` orchestrates polling across all adapters. Results are stored as `QuotaSnapshotDoc` records — both in local SQLite and synced to Firestore.

```
QuotaRefreshActor
    → ProviderQuotaAdapter (per provider)
        → fetch or scrape quota state
        → normalize to QuotaBucket[]
    → ProviderQuotaSnapshotStore (local SQLite)
    → QuotaSnapshotSyncService (Firestore, opt-in)
```

---

## Quota adapters

Source directory: `AgentLens/Services/ProviderQuota/`

22+ adapters ship, one per supported provider:

| Adapter | Provider |
|---------|---------|
| `ClaudeQuotaAdapter.swift` | Anthropic Claude (OAuth + API key, 5-hour rolling window) |
| `CodexQuotaAdapter.swift` | OpenAI Codex |
| `FactoryQuotaAdapter.swift` | Factory Droid (session classifier, dashboard scraper) |
| `CursorQuotaAdapter.swift` | Cursor (cookie extractor) |
| `MiniMaxQuotaAdapter.swift` | MiniMax |
| `KimiQuotaAdapter.swift` | Kimi |
| `XAIQuotaAdapter.swift` | xAI Grok |
| `ZAIQuotaAdapter.swift` | ZAI |
| `MimoQuotaAdapter.swift` | MiMo |
| `OllamaQuotaAdapter.swift` | Ollama Cloud |
| `ForgeQuotaAdapter.swift` | Forge Dev |
| `WarpQuotaAdapter.swift` | Warp |
| `AntigravityQuotaAdapter.swift` | Antigravity |
| `AiderQuotaAdapter.swift` | Aider |
| `CopilotQuotaAdapter.swift` | GitHub Copilot |
| `KiloCodeQuotaAdapter.swift` | KiloCode |
| `HermesQuotaAdapter.swift` | Hermes (local, stub) |

Supporting files: `ProviderQuotaService.swift` (70,972 bytes — main orchestration), `QuotaRefreshActor.swift` (31,774 bytes), `ProviderQuotaTypes.swift` (28,172 bytes), `FlexibleQuotaBucketNormalizer.swift` (22,558 bytes).

---

## Firestore schema

```
users/{uid}/quota_snapshots/{provider}_{sourceId}
    → QuotaSnapshotDoc
        → buckets: [QuotaBucket]
            → window: "5h" | "daily" | "monthly" | ...
            → used: Int
            → limit: Int
            → resetAt: Timestamp?
            → confidence: "exact" | "estimated"
```

The Android counterpart is `ProviderQuotaSnapshot` + `QuotaBucket` in `data/models/TokenUsage.kt`, keeping field names aligned with `functions/src/types.ts`.

---

## Display

Quota bars appear in the popover and dashboard when a provider's active bucket exceeds a warning threshold (typically 80%). The `BurnRailBudgetChip` component in `AgentLens/Views/Dashboard/Components/` renders quota state inline in the session rail.

---

## Budget governance connection

`BudgetGate` reads quota snapshots when evaluating whether to allow a Computer Use action. If a provider is at or near its hard limit, the gate can block new actions independent of the dollar-denominated budget caps. See [budget-governance.md](budget-governance.md).
