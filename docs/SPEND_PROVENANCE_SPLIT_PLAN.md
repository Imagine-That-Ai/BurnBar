# Spend Provenance Split — API dollars vs subscription spend

**Owner ask (2026-08-09):** BurnBar mixes two kinds of "spend" into one number:

1. **API spend** — real dollars leaving a wallet per token: deepseek, OpenAI API,
   OpenRouter, meta.dev, anything proxied through the daemon gateway with an API
   key, and anything confirmed by a provider billing API.
2. **Subscription spend** — imputed list-price value of sessions that actually run
   on a flat plan (Claude Code on Max, Codex on ChatGPT, Cursor, Factory, Junie…).
   Useful as a "what would this have cost" signal, but it is not money leaving.

Users must be able to (a) see these merged, separated, or overlaid on one graph —
Apple-grade, liquid glass; and (b) keep subscription spend from consuming the AI
Inbox's protective daily budget, which exists to guard real dollars.

## Ground truth (verified in code, 2026-08-09)

- **Two ledgers.** The daemon keeps its own `BurnBarUsageRecord` ledger
  (`OpenBurnBarDaemon/OpenBurnBarUsageRecorder.swift`) — gateway proxy calls and
  AI Inbox analyst/verifier/reply calls land here; the inbox budget gate
  (`BurnBarAIInboxService.spendToday()`) sums it filtered only by
  `executionSourceID`, so a subscription-routed analyst call eats the dollar
  budget today. The app keeps `token_usage` in GRDB
  (`OpenBurnBarCore/OpenBurnBarData`), fed by harness log parsers, provider
  billing APIs, connector bridges, and the daemon bridge; the burn header and
  ChartKit read this.
- **`TokenUsage` already carries the raw signals**: `usageSource`
  (`providerLog` / `billingAPI` / `connectorBridge` / `daemonBridge` /
  `inAppChat`), `providerID`, `providerAccountID/Label/Source`, execution-source
  taxonomy (v57), provenance method + confidence. What is missing is one derived,
  queryable dimension.
- SwitcherCLI account metadata already knows `subscriptionTierID` for CLI
  profiles.

## Design

### 1. Kernel: `BillingKind` + classifier (shared, deterministic)

`OpenBurnBarKernel/SharedModels/TokenUsage.swift` (+ a new
`BillingProvenanceClassifier.swift`):

```swift
public enum BillingKind: String, Codable, Sendable, CaseIterable {
    case api            // real dollars per token
    case subscription   // imputed value inside a flat plan
    case unknown        // fail-honest default, rendered as its own bucket
}
```

Classifier precedence (first match wins), pure function of fields already on the
event so every platform (Swift, Windows C#, Linux) can mirror it byte-for-byte:

1. `usageSource == .billingAPI` → `.api` (it *is* the provider's bill).
2. Explicit per-account override (new user setting, keyed by
   `providerID + providerAccountID`) → whatever the user set.
3. Account metadata: `subscriptionTierID` present → `.subscription`;
   account source says API key → `.api`.
4. Provider-default table (versioned constant, curated): gateway/API-key-only
   providers (deepseek, openrouter, meta.dev, "openai-api", …) → `.api`;
   plan-first harness providers (claude-code, codex, cursor, factory, junie,
   copilot…) → `.subscription`.
5. Otherwise `.unknown` — shown honestly, never silently merged.

### 2. Storage

- **GRDB `token_usage`**: migration `v60_billing_kind` — `billingKind TEXT NOT
  NULL DEFAULT 'unknown'` + index `(billingKind, startTime)` + deterministic
  backfill via the same precedence expressed in SQL CASE. Regenerate the
  byte-compat fixture kit (endpoint + fixtureBaseName + vector JSON + `.sqlcipher`
  binary move together — same flow as v59, commit `46f9edecf5`). Mirror the
  migration in the Windows and Linux migrators in the same PR (the
  Swift↔Windows↔Linux migrator-parity gate enforces this).
- **Daemon ledger**: `BurnBarUsageRecord` gains optional `billingKind` (Codable,
  absent in old records → classify at read). Gateway proxy writes `.api` (it
  holds the API key it just used); inbox calls record the kind of the route that
  served them (API-key provider → `.api`, CLI-bridge/sub route →
  `.subscription`).

### 3. Inbox protective quota (the part that unblocks the owner tonight)

`spendToday()` counts **only `.api`** records. New config knob
`subscriptionSpendCountsAgainstInboxBudget` (default **false**). Budget banner
copy says which number it is guarding: "Budget guards real API dollars — $X.XX
of $Y today. Subscription-routed calls run free."

### 4. UI — one lens, three modes (macOS first)

`SpendLensMode: combined | split | overlay`, persisted per user, surfaced as a
liquid-glass segmented capsule in the burn header (glass wash 0.08, never tint
0.35 — charts-atelier rule):

- **combined** — today's single number/curve, unchanged.
- **split** — two stat tiles + two curves: "API $" (money) and "Sub $"
  (imputed), each with its own accent; `unknown` appears as a third muted tile
  only when non-zero.
- **overlay** — one chart, stacked/broken-out series with a shared axis; the
  API series carries the accent, sub is the quieter layer.

Implementation: `ChartKind` registry + snapshot builder grow a
`billingKind` group-by; header counters read the same snapshot so the number
and the curve can never disagree. Settings gets the per-account billing
override table. iOS/widgets inherit the snapshot model later.

### 5. Honesty fixes riding along (already-diagnosed defects)

- "no model calls" label → distinguish "budget exhausted — local rules" from
  "nothing to analyze" (AgentLens `InboxView` + settings run log).
- Redaction blobs: `BurnBarAIInboxEvidencePack.redact()` emits `“(excerpt
  withheld — contained a secret)”` inline instead of the 100-char scanner essay;
  the full label list stays in the item's provenance detail.

## Delivery plan (factory lanes)

| PR | Scope | Gate risk |
|----|-------|-----------|
| A (this branch, stacked on #2200) | Kernel `BillingKind` + classifier + tests; daemon ledger field + gateway/inbox writers; inbox gate + config + banner copy; honesty fixes | daemon tests, swift-consumer |
| B | GRDB v60 + backfill + byte-compat fixture regen + Windows/Linux migrator parity | migrator parity, fixture kit |
| C | SpendLens UI: header capsule, split/overlay charts, per-account overrides in Settings | UI tests, snapshot |

Rollback: each PR is independently revertible; `billingKind` is additive with a
fail-honest `unknown` default everywhere.
