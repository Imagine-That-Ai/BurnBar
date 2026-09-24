# Cost rule v1 (Wave 2.5) — normative

One cost field: `costUSD`, the TypeSpec spelling (`tools/schema-sync/typespec/
domains/usage-quota.tsp`). `costUsd` and `cost` are read-only legacy fallbacks
behind this rule. Producers MUST write numbers; string/bool/object payloads are
never coerced.

## The rule (effectiveCostUSD)

Given an event with optional `costUSD`, `costUsd`, `cost`:

> `effectiveCostUSD` is the FIRST value in precedence order
> [`costUSD`, `costUsd`, `cost`] that is a JSON number, finite, and ≥ 0.
> Otherwise `0`.
>
> `total` is the IEEE-754 double sum of `effectiveCostUSD` over events, in
> fixture order.

Notes the fixture pins:

- `0` is a valid cost: a zero `costUSD` WINS over positive legacy values
  (the rule is `≥ 0`, not `> 0`).
- Negative, NaN, and infinite values are corrupt data: they are SKIPPED
  (fall through to the next spelling), never clamped.
- Strings are never parsed: `"1.5"` is not a number. A string `costUSD`
  with a numeric `costUsd` yields the `costUsd` value.
- Missing, null, and absent are all "no value".

## Implementations (must agree byte-for-byte on `v1.json`)

- TypeScript: `functions/src/costRule.ts` (`effectiveCostUSD`)
- Kotlin: `TokenUsage.effectiveCost` via `CostRule.kt`
  (`android/app/src/main/java/com/openburnbar/data/models/`)
- Swift: `CostRule.effectiveCostUSD`
  (`OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/CostRule.swift`,
  shared by the Mac app, daemon, and mobile via OpenBurnBarCore)

Each client has a test that loads `v1.json`, asserts every per-event
`expectedEffective`, and asserts the `expectedTotal`. The fixture values are
dyadic rationals so the total (`5.5`) is exact in binary on all three runtimes.

## SQLite boundary

Every SQLite table carries exactly one cost column, so no intra-row
precedence decision exists in SQLite — the rule has no SQL application
point. Readers map their table's native column into `costUSD`-named model
fields; writers persist the model's canon value under the native name:

| Table | Column | Model field |
|---|---|---|
| `token_usage` | `cost` | `TokenUsage.costUSD` |
| `summary_runs` | `costUSD` | (same) |
| `ai_inbox_runs`, `ai_inbox_thread_messages` | `cost_usd` | `costUSD` |
| `ai_inbox_threads` | `total_cost_usd` | (aggregate total) |

Column renames are deliberately out of scope (migration churn across the
migrator, Windows parity, and every reader for zero semantic gain — the
canon lives at the model/API layers).

## Transition (decision 3)

Writers emit `costUSD` on every new/updated usage document and keep writing
each surface's historical legacy twin for old readers (`cost` on Firestore
usage docs and Core JSON, `costUsd` on the pricing/shadow emitters).
Readers use this rule and never read a legacy spelling directly. Legacy
twins are removed in a later wave once no reader depends on them.
