# Token usage

The unified token and cost ledger that powers every spending surface in OpenBurnBar.

## Purpose

Store per-session token counts and estimated costs from 17+ AI agents in a single GRDB-backed SQLite table so the dashboard, Insights, and Hermes chat can query it consistently.

## Key models

| Model | File | Fields |
|-------|------|--------|
| `TokenUsage` | `AgentLens/Models/TokenUsage.swift` | provider, model, inputTokens, outputTokens, totalTokens, cost, timestamp |
| `UsageRollups` | `AgentLens/Models/UsageRollups.swift` | today, 7d, 30d, 90d, allTime aggregated windows |
| `ModelPricing` | `AgentLens/Services/UsageAggregator.swift` | public pricing table lookups per provider/model |

## How it works

1. **Parsing** — `UsageAggregator` calls each registered parser for its file pattern. Parsers return `TokenUsage` rows.
2. **Cost calculation** — `ModelPricing` applies public pricing tables (not invoice data) to compute estimated cost. For providers without per-token pricing, costs are estimated with assumptions (e.g., Codex 50/50 input/output split).
3. **Storage** — rows are written to GRDB via `DataStore.swift`. The daemon writes its own usage ledger in the support directory for routed provider traffic.
4. **Rollups** — Cloud Functions write 5 separate `usage_rollups` documents (today, 7d, 30d, 90d, all_time) to Firestore. The app merges them into a single flat `UsageRollups` client model.

## Integration points

- **Dashboard** — queries rollups for the popover chart and per-provider breakdown.
- **Insights** — feeds `InsightEngine` for spend patterns and anomalies.
- **Hermes chat** — injected as system prompt context for usage-related questions.
- **Budget governance** — `BudgetGate` reads rollups to enforce daily/monthly caps.

## Entry points for modification

- Add new pricing rules in `AgentLens/Services/UsageAggregator.swift` or `ModelPricing.swift`.
- Change rollup window logic in `AgentLens/Models/UsageRollups.swift`.
- Update the Firestore schema in `functions/src/types.ts` if adding new usage fields.

## Related pages

- [Usage tracking](../features/usage-tracking.md)
- [Budget governance](../features/budget-governance.md)
- [macOS app](../apps/macos-app/index.md)
