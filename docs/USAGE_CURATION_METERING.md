# Usage-Memory Curation Metering (U4)

The `curateUsageMemoryBatch` callable is the metered, entitlement-gated gateway
for cloud usage-memory curation inference. BurnBar pays for this inference, so
the flow is strictly fail-closed:

```
kill flag → entitlement (lane-scoped) → validate → estimate → RESERVE
         → OpenRouter (CoreWeave-pinned) → SETTLE actual → respond
```

Source of truth: `functions/src/callables/usageCuration.ts` plus the
`functions/src/usageCuration/` modules (`limits.ts`, `allowance.ts`,
`openrouterClient.ts`, `prompt.ts`). This page documents the operational
contract; when it disagrees with the code, the code wins and this page needs a
fix in the same PR.

## Lanes and entitlements

| Lane | Model | Who may call it |
| --- | --- | --- |
| `text` | `deepseek/deepseek-v4-flash` | Any ACTIVE Pro tier (`pro`, `pro_max`, `ultra`) |
| `multimodal` | `minimax/minimax-m3` (OpenAI-format image parts) | ACTIVE Pro Max only (Ultra mirrors Pro Max) |

A pro-tier caller on the multimodal lane is rejected by the entitlement
assertion, and `usageCurationLaneLimits` returning `undefined` is a
defense-in-depth `permission-denied` — an entitlement denial, never a
zero-budget meter.

## Request contract

`{ lane, candidates, requestId? }` where each candidate is
`{ id, sourceKind, text, imageRefs? }`.

- ≤ 25 candidates per batch; candidate ids must be unique; `text` ≤ 4 KiB.
- `imageRefs` only on the multimodal lane; ≤ 4 images per batch; each ref is a
  `data:image/...;base64,` URI or an `https://` URL, ≤ 1,048,576 chars.
- `requestId` (≤ 128 chars) is the idempotency key: the reservation doc id is
  `curate_<lane>_<requestId>` (a random id is generated when omitted).

Response: `{ results, promptVersion, usage, allowance }` — sanitized A-MEM
atomic notes, the frozen prompt version, actual token usage, and the remaining
monthly allowance per lane (`resetsAt` = first instant of next UTC month).

## Token allowance (per uid, per lane)

Unit = input + output tokens. Compiled-in defaults, all Remote Config tunable:

| Lane / tier | Monthly | Daily | RC parameters |
| --- | --- | --- | --- |
| text / pro | 1,000,000 | 100,000 | `usage_curation_text_pro_monthly_tokens`, `usage_curation_text_pro_daily_tokens` |
| text / pro_max | 5,000,000 | 250,000 | `usage_curation_text_pro_max_monthly_tokens`, `usage_curation_text_pro_max_daily_tokens` |
| multimodal / pro_max | 2,000,000 | 150,000 | `usage_curation_multimodal_pro_max_monthly_tokens`, `usage_curation_multimodal_pro_max_daily_tokens` |
| ultra | pro_max × 10 | pro_max × 4 | `usage_curation_ultra_monthly_multiplier`, `usage_curation_ultra_daily_multiplier` |

The **kill flag** `usage_curation_enabled` (Remote Config, default `true`)
stops all curation spend with one RC publish: when `false` the callable throws
`failed-precondition` before any entitlement read or reservation. Any RC
template read failure fails open to the compiled defaults (the kill flag's
documented default is enabled).

The estimate reserved up front is `ceil(promptChars / 4)` + 1,024 tokens per
image + the flat 512-token output budget.

## Reservation ledger (server-only Firestore)

```
users/{uid}/usageCurationAllowance/{monthKey}
  { schemaVersion, textTokensUsed, multimodalTokensUsed,
    textTokensUsedToday, multimodalTokensUsedToday, dayKey, updatedAt }

users/{uid}/usageCurationAllowance/{monthKey}/reservations/{reservationId}
  { uid, monthKey, dayKey, lane, reservationId, estimatedTokens,
    settledTokens?, status: "reserved" | "settled", createdAt, updatedAt,
    schemaVersion }
```

Written ONLY by the Admin SDK inside transactions; `firestore.rules` grants no
client access. Daily reset is transactional `dayKey` comparison (no scheduled
job); monthly reset is structural (a new monthKey doc).

Semantics (mirrors the cloudProAllowance reservation pattern):

- **Reserve before spend.** No reservation, no OpenRouter call.
- **Replay refusal.** Any pre-existing reservation for a requestId — settled
  OR still in flight — already backs exactly one cloud call; a replay throws
  `already-exists`. This prevents N concurrent calls sharing one requestId
  from funding N model calls off a single deduction. The trade: a crashed
  attempt strands its estimate until the monthly reset (bounded, fail-closed
  in the payer's favor). Reusing a requestId with different parameters is also
  `already-exists`.
- **Settle to actual.** After the call, `actual − estimated` adjusts the
  monthly counter (clamped ≥ 0) and the daily counter only while the ledger is
  still on the reservation's `dayKey`. Settle never throws
  `resource-exhausted`; an under-estimate overage fail-closes the NEXT
  reservation instead.
- **Release on failure.** A failed model call settles to 0 tokens
  (best-effort) so an outage cannot strand allowance; the release failure is
  logged (`usage_curation.settle_release_failed`) and never masks the real
  error.
- **Shortfalls** throw `resource-exhausted` with
  `{ lane, resetsAt, reason, monthlyRemaining, dailyRemaining }`; `resetsAt`
  names the boundary that actually unblocks the caller (next UTC midnight for
  daily, first of next UTC month for monthly).
- **Unmetered completions are rejected.** A completion whose response omits
  usage token counts throws `internal` and releases the reservation — a
  provider usage-reporting regression surfaces loudly instead of silently
  making inference free.

## Privacy invariants (do not "optimize" away)

- **CoreWeave pin.** Both models have Chinese-operated first-party hosts on
  OpenRouter, and curation batches contain the member's own page/session text.
  EVERY request pins `provider.order` to CoreWeave (US) with
  `allow_fallbacks: false` (an outage FAILS the call rather than rerouting),
  `data_collection: "deny"`, and `zdr: true`.
- **Candidate text is DATA, never prompt.** The batch is serialized inside an
  untrusted-data fence appended after the frozen, versioned prompt prefix
  (`USAGE_CURATION_PROMPT_VERSION`, currently `usage-curation-v1`; any byte
  change to the prefix or fence wrapping must bump it). Literal fence-marker
  strings inside candidate fields are neutralized before serialization so data
  cannot fake the boundary. Model output is sanitized against the A-MEM note
  contract and dropped unless it names a real candidate id.
- **Secrets.** The OpenRouter key lives in the `OPENROUTER_API_KEY` Functions
  secret and is checked BEFORE reserving, so a misconfigured deploy never
  burns allowance. It is never logged.

## Resilience

The OpenRouter call goes through `modelInferenceFetch`
(`functions/src/resilienceHelpers.ts`): a provider-isolated circuit breaker
(`model_inference:openrouter`) with a 60-second cap and NO retry — inference
is paid, non-idempotent work, and a timed-out attempt may still bill upstream.
It deliberately does not use the generic `resilientFetch` (shared breaker,
20-second timeout that multimodal completions legitimately exceed). The
callable runs with `timeoutSeconds: 120`, `memory: 512MiB`,
`maxInstances: 50`.

## Known gap (tracked)

`users/{uid}/usageCurationAllowance` is not yet registered in
`packages/data-domains/registry.json` / `DATA_DOMAIN_PATHS`
(`functions/src/callables/dataExport.ts`), so domain-scoped export and
deletion do not cover the ledger yet. Registering it fans out into the
generated Swift/Kotlin/web domain artifacts and needs a product decision on
whether reservation docs are export-excluded bookkeeping (like `_rate_limits`)
— tracked as a follow-up to the U4 PR (#2261) rather than smuggled into it.
