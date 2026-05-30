# Budget governance

Per-user spend caps with automated enforcement. Prevents runaway costs from long-running agent sessions.

---

## Purpose

Agent sessions can run unattended for hours. Without caps, a single bug in a routing loop or a poorly scoped Computer Use mission can generate hundreds of dollars of API spend before a human notices. Budget governance provides layered protection: warn early, block at hard limits, and allow remote kill-switch override.

---

## Cap layers

| Layer | Scope | Behavior |
|-------|-------|---------|
| Per-user daily ceiling | $5 normal / $2.50 soft / $0 hard | Blocks new actions when daily spend hits ceiling |
| Soft monthly cap | $1,500/mo (Computer Use) | Enforces 25 actions/run × 100 actions/day; warns in UI |
| Hard monthly cap | $2,500/mo (Computer Use) | Blocks all Computer Use actions |
| Remote Config kill-switch | `computer_use_kill_switch` | Remotely disables Computer Use for all users |

These caps are specific to Computer Use. Usage tracking for passive token accounting has separate per-provider quota limits (see [provider-quota.md](provider-quota.md)).

---

## Key files

All under `AgentLens/Services/DataStore/` and `AgentLens/Services/`:

| File | Role |
|------|------|
| `BudgetGate.swift` | Entry point — evaluates whether an action is allowed; blocks at hard limit, warns at soft |
| `BudgetEnforcement.swift` | Enforcement logic: computes current spend against cap layers |
| `BudgetLedger.swift` | Append-only log of spend events; persisted in GRDB SQLite |
| `BudgetForecast.swift` | Projects end-of-period spend given current trajectory |
| `BudgetRulesStore.swift` | Reads and writes cap configuration (per-user overrides, remote config values) |
| `BudgetSettings.swift` | User-visible settings model for cap values |
| `BudgetNotificationCenter.swift` | Fires local notifications when soft cap is approached |
| `CloudBudgetService.swift` | Syncs budget state with Firestore for cross-device visibility |
| `ComputerUseBudgetStatusStore.swift` | Real-time status for the Computer Use panel |

UI: `AgentLens/Views/Settings/BudgetSettingsView.swift`, `AgentLens/Views/Chat/BudgetBlockedCard.swift`, `AgentLens/Views/Dashboard/Components/BurnRailBudgetChip.swift`.

---

## Cloud enforcement

`functions/src/computerUseBudget.ts` is a Firebase Cloud Function that runs hourly and evaluates each active user's Computer Use spend against the cap tiers. It writes enforcement decisions to Firestore so all devices see consistent state.

A second function, `functions/src/mediaBudget.ts`, applies analogous enforcement for Mercury media bandwidth costs.

---

## BudgetGate flow

```
Action requested
    → BudgetGate.evaluate(action)
        → BudgetEnforcement.currentSpend(window: .daily | .monthly)
        → compare against BudgetRulesStore.caps
            → .allowed       → proceed
            → .softWarning   → proceed + show warning UI
            → .hardBlocked   → block + show BudgetBlockedCard
        → Remote Config kill-switch check
            → if active      → block regardless of spend
```

---

## Budget tables in SQLite

The `BudgetLedger` persists spend events in GRDB (v42+). Budget rows include:
- Provider ID
- Action type (Computer Use action, model request, etc.)
- Token count + cost
- Timestamp
- Cap tier at time of write

This allows accurate reconstruction of spend within any rolling window without relying on Firestore.
