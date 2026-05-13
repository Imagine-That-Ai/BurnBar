# Router Benchmark Policy

> Benchmark snapshots are **advisory metadata for routing explanations**.
> Account auth, quota, availability, user pinning, and safety policy are
> hard constraints — they are evaluated at runtime and always override
> any ranking shown in a benchmark-derived score.

This document is the operator-facing companion to
[`functions/src/modelLandscape.ts`](../functions/src/modelLandscape.ts) and
[`docs/ROUTED_CLIENT_GATEWAY.md`](./ROUTED_CLIENT_GATEWAY.md). It lists every
benchmark source BurnBar uses, how their signals are normalised, how
freshness is tagged, and which rules the Intelligent Model Router refuses
to bend.

---

## Sources today

OpenBurnBar's daily refresh consults four public sources plus an optional
operator-curated fixture. Every source ships with a default confidence
weight, a freshness state, and a documented update path.

### Artificial Analysis

- **Endpoint:** `https://artificialanalysis.ai/api/v2/data/llms/models`
- **Auth:** `ARTIFICIAL_ANALYSIS_API_KEY` header `x-api-key`
- **Surfaces:**
  - `artificial_analysis_intelligence_index` → `general` task score
  - `artificial_analysis_coding_index` / `livecodebench` → `coding` task score
  - `price_1m_input_tokens` / `price_1m_output_tokens` → cost signal
    (computed `1 / (1 + blended)` with a 0.75/0.25 input/output blend if
    `price_1m_blended_3_to_1` is absent)
  - `median_output_tokens_per_second` + `median_time_to_first_token_seconds`
    → latency signal (TPS-dominant, TTFT-modulated, both clamped to `[0, 1]`)
- **Default confidence:** `0.8`
- **Default freshness:** `fresh` on a successful refresh, otherwise the
  source-status row carries `error` / `unavailable` and the snapshot is
  dropped from the score until the next refresh.
- **Why it's first:** the only source today that gives BurnBar a unified
  view of intelligence, coding, cost, and latency in one normalised shape.

### Terminal-Bench (via Hugging Face)

- **Endpoint:** `https://huggingface.co/api/datasets/harborframework/terminal-bench-2.0/leaderboard`
- **Auth:** public · no key required
- **Surfaces:** `score` + `rank` per model; `verified` boolean flags
  reproducible runs.
- **Confidence:** `0.9` if `verified === true`, otherwise `0.65`.
- **Default freshness:** `fresh` on a successful read.
- **Maps to:** `terminal` task category — shell-loop agents that execute,
  observe, and self-correct. Routed surfaces that opt in (autopilot,
  scout) weigh this dimension when they advertise terminal access.

### Design Arena

- **Endpoint:** `https://www.designarena.ai/api/v1/models`
- **Auth:** `DESIGN_ARENA_API_KEY` header `Authorization: Bearer <key>`
- **Fallback:** if the live API is unreachable, BurnBar uses the
  `DESIGN_ARENA_FIXTURE_JSON` cached fixture — the source row stays
  visible and is tagged `stale` in the daily rundown so the operator
  can see the substitution.
- **Surfaces:** per-arena, per-category metrics — `normalizedScore` /
  `score` / `elo` / `winRate` (with `eloToUnit` re-mapping centred at
  1000 ±600) and an optional `avgGenerationTimeMs` for latency.
- **Confidence:** `0.75` default (metric-level confidence may override).
- **Maps to:** `design`, `coding`, `agent`, `analysis`, `general` — the
  arena/category mapping lives in
  [`designArenaTaskCategory`](../functions/src/modelLandscape.ts).

### Hugging Face (generic)

- **Endpoint:** the same public dataset endpoint pattern used for
  Terminal-Bench; reserved for additional leaderboards the router opts
  into in future releases.
- **Auth:** public.
- **Default freshness:** `fresh` on success.

### Manual fixture · operator gap-fill

- **Source ID:** `manual_fixture`
- **Authority:** operator-curated JSON kept under
  `website/src/data/router-rundown-history/`. Used when a public source
  is unreachable for an extended period or when a model has no
  benchmark coverage in any live source yet.
- **Default freshness:** `manual` — surfaced in the daily rundown with
  its own logo so the reader can tell which numbers came from a cached
  hand-curated fixture instead of a live refresh.

---

## Freshness states

Every snapshot and source-status row carries one of these states. The
website renders each state with a distinct dot colour so operators can
read freshness at a glance.

| State         | Meaning                                                                 |
|---------------|-------------------------------------------------------------------------|
| `fresh`       | Normalised from a successful refresh in the last 24 h                   |
| `stale`       | Last successful refresh is older than 24 h                              |
| `manual`      | Operator-cached fixture is the active source — not live                 |
| `unavailable` | No API key configured and no fixture present                            |
| `error`       | Last refresh raised an exception · check the source-status row message  |

A `stale` or `manual` score is **not silently dropped**. It stays in the
ranking with its age and source clearly labelled, and the daily rundown
at `/router/daily/<date>` shows the freshness state next to every cited
score.

---

## How daily rundown selection works

The public daily rundown has two numbers:

- `score` — raw evidence score from benchmark/runtime signals. It stays
  visible even when policy picks another model.
- `selectionScore` — ordinal policy score after the final board order is
  resolved. This is the number the website uses for the displayed order,
  so the public score cannot contradict the public rank.

The evidence score is deterministic:

```
score = benchmarkScore     * 0.55
      + benchmarkFreshness * 0.14
      + sourceConfidence   * 0.05
      + reliability        * 0.14
      + latency            * 0.03
      + cost               * 0.06
      + contextFit         * 0.03
```

Missing signals are excluded from the weighted average, then
`evidenceCoverage` discounts incomplete rows. Older signals are weighted
down by `freshnessSignal()` before they influence the evidence score —
they are never dropped without surfacing the age.

After evidence is computed, the daily model board applies the stable
favorite policy:

1. GPT-5.5 xhigh
2. Claude Opus 4.7
3. GLM 5.1

These favorites keep their order only while they clear hard gates:
routable, flagship-tier, benchmark score present, and benchmark
freshness at least `0.55`. A challenger can dethrone a protected
favorite only when it is also routable/flagship/fresh and clears both
margins:

- evidence score beats the favorite by at least `0.08`
- benchmark score beats the favorite by at least `0.05`
- the same challenger beat the same favorite by those margins in the
  previous rundown, unless the favorite failed a hard gate

The board language is literal but bounded: it means a board of language
models runs daily research and analysis tasks over the source feed. The
published artifact is still deterministic code in
[`functions/src/routerRundown.ts`](../functions/src/routerRundown.ts)
and
[`website/scripts/lib/rundown-generator.mjs`](../website/scripts/lib/rundown-generator.mjs),
not an opaque vote.

---

## What the router will not do with benchmark data

These rules are enforced in
[`functions/src/modelLandscape.ts`](../functions/src/modelLandscape.ts)
and
[`OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/ProviderAccountTypes.swift`](../OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/ProviderAccountTypes.swift)
— not promises, code.

- **Will not override a user pin.** A pinned model or pinned account that
  meets the floor wins over any benchmark-derived alternative.
- **Will not override live quota state.** A model that benchmarks two
  points higher but is currently rate-limited still loses to a healthy
  pin or healthy runner-up.
- **Will not swap your model on failover.** Provider-Family Failover
  only considers candidate accounts that carry the exact requested
  model. If no candidate survives, the gateway returns a structured
  `503` — never a silent substitute.
- **Will not log secrets.** Decision events store account ids, skip
  reasons, and signal weights — never API keys, OAuth bearers, request
  bodies, or response bodies.
- **Will not synthesize benchmarks.** Sources are cited verbatim with
  attribution + URL. The daily rundown shows every logo. If a source
  goes down, BurnBar marks the row `stale` / `error` instead of
  fabricating numbers.

---

## Daily rundown · the public artifact

The Intelligent Model Router's reasoning is pre-rendered once every
twenty-four hours. Each rundown is frozen, dated, and inspectable:

- **Index:** [`/router/daily`](https://burnbar.ai/router/daily)
- **Per-day:** `/router/daily/<YYYY-MM-DD>` — e.g.
  [`/router/daily/2026-05-13`](https://burnbar.ai/router/daily/2026-05-13)
- **Schema:** [`website/src/data/router-rundown.ts`](../website/src/data/router-rundown.ts)
- **History:** [`website/src/data/router-rundown-history/`](../website/src/data/router-rundown-history/)

Each rundown carries the source statuses for the day, per-task
recommendations with raw evidence `score`, policy `selectionScore`,
plain-English board verdicts, and explicit limitations. Build-time
hydration is via
[`router-rundown-loader.ts`](../website/src/data/router-rundown-loader.ts);
production daily refresh runs through the
[`refreshModelLandscapeBenchmarks`](../functions/src/scheduled.ts)
Cloud Function, writes Firestore at `model_benchmark_snapshots/*` +
`model_benchmark_source_status/*`, then persists
`router_rundowns/<date>` + `router_rundowns/latest`.

---

## Operator workflow · adding a benchmark source

1. Add a new `SourceID` to
   [`website/src/data/router-rundown.ts`](../website/src/data/router-rundown.ts)
   with attribution, short label, blurb, and a logo path under
   `/brand/sources/`.
2. Add an adapter to
   [`functions/src/modelLandscape.ts`](../functions/src/modelLandscape.ts)
   that normalises the raw payload into `ModelBenchmarkSnapshotDoc[]`,
   including a default confidence and freshness state.
3. Wire the adapter into `collectModelLandscapeBenchmarks()` with an
   API-key check and a fixture fallback if applicable.
4. Add the source's logo SVG to
   [`website/public/brand/sources/`](../website/public/brand/sources/).
5. Update this document with the new source's endpoint, surfaces,
   confidence, and freshness rules.
6. Run `node website/scripts/generate-rundown.mjs` to refresh the
   build-time history with the new source name visible in the source
   masthead.

The release-time grep `stable favorite policy` should return matches in
the generator, Functions implementation, policy doc, and generated rundown;
if it ever drops to zero, the marketing language and the code have drifted.
