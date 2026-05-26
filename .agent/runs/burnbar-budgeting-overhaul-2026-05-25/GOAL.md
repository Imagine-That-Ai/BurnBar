# BurnBar enterprise budgeting, forecasting & hard limits

Goal ID: `burnbar-budgeting-overhaul-2026-05-25`
Started: 2026-05-26T00:27:24Z
Parent goal: none
Mode: full
Ledger path: `.agent/runs/burnbar-budgeting-overhaul-2026-05-25/`

## Objective

Ship phases 3-8 of the budgeting/forecasting/accounting plan: BudgetSettings + Settings UI, two-plane BudgetGate enforcement, notifications + forecast, billing-API truth-up, Hermes/MCP read+write tools, and enterprise cross-seat rollup — turning OpenBurnBar into a trustworthy cost monitor with hard per-credential spending limits.

## Goal Mode Coupling

When creating or updating the matching `/goal`, include this ledger pointer in the goal objective:

`Maintain the agent-owned ledger at /Users/albertonunez/Documents/Windsurf/BurnBar/.agent/runs/burnbar-budgeting-overhaul-2026-05-25/ and keep implementation-notes.html current at checkpoints, before compaction, and before final handoff.`

## Finishing Criteria

- [done] Phase 1 — Per-credential ledger foundation (dashboard credential lane live, build green).
- [done] Phase 2 — Project & model attribution lanes (project lane live, build green).
- [todo] Phase 3 — `budget_rules` + `budget_events` SQLite migration; `BudgetSettings` store; Settings → Budgets view; migrate legacy `costAlertThreshold` into `BudgetRule(.global, .warnOnly)`.
- [todo] Phase 4 — `BudgetLedger` actor, `BudgetGate`, daemon gateway insertion (handleChatCompletions/Responses/AnthropicMessages with 402 + `BurnBar-Budget-Limit`), AgentLens insertion (`runStream`/`runToolEnabledLoop`/`nonStreamingFallback` with `BudgetBlockedError`), `BudgetBlockedCard` in chat, cancellation via `CLIBridgeStreamRuntimeCoordinator`.
- [todo] Phase 5 — `BudgetNotificationCenter` (80% + 100% debounced), `BudgetForecast` (port mobile `VelocityForecastStore`), `BurnRailBudgetChip` on top rail, forecast values on credential cards.
- [todo] Phase 6 — Confirm OpenRouter/Copilot APIs are pulled, drift events when local vs billing diverges >5%, "Sync now" per credential, Anthropic Console-vs-OAuth key distinction in Settings.
- [todo] Phase 7 — Hermes context injection (budgets/credentials + active blocks), 7 Hermes tools (query_spend, budget_status, spend_forecast, set_budget_limit, pause/resume, audit), MCP server parity, `HermesToolCard` rendering, confirmation interstitials for writes.
- [todo] Phase 8 — `CloudSync` extension for `budget_rules`/`budget_events`, `CloudBudgetService` aggregate queries, `OrgRollupView` (by user/project/credential), `burnbar_org_spend` MCP tool, shared budget rules.
- [todo] Final build green after every phase via `xcodebuild build -scheme OpenBurnBar -destination "platform=macOS,arch=arm64"`.
- [todo] `implementation-notes.html` current at each phase boundary with status, decisions, tradeoffs, and validation evidence.

## Escape Hatch

Pause, ask the user, or mark a scoped item `[blocked]` / `[incomplete]` if:
- validation contradicts the goal
- the goal requires a scope change
- the agent is looping without measurable progress
- the next step risks deleting or rewriting durable memory
- the PRD and actual repo disagree
- the ledger itself contaminates validation
