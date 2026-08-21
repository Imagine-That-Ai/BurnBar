---
name: optimization-mission-playbook
description: "Domain playbook for optimization missions — any task whose goal is to move a metric: performance, latency, throughput, memory, cost, score, quality, compression, ranking, solver, model/eval, and similar metric-improvement work. Defines how to think about and run an optimization mission: establishing the ground truth, trusting the measurement, profiling to the dominant cost, estimating the ceiling, generating and pruning disposable hypotheses, exploring cheaply before verifying expensively, guarding against metric gaming and overfitting, reasoning about correctness and trade-offs, and stopping on evidence."
---

# Optimization Mission Playbook

## What This Playbook Is For

Load this playbook when the mission's goal is to **move a metric**: make something faster, smaller, cheaper, higher-scoring, more accurate, higher-throughput, better-compressed, better-ranked, or closer to a solver/objective bound. The signal is a number with a direction and a workload that produces it.

Do not use it for missions whose goal is durable behavior (a feature, a port, a migration, an API) — those are engineering missions; use `engineering-mission-playbook`. When a mission has both — build a benchmark harness *then* optimize a hot path, port a library *then* tune it — load both playbooks and record the boundary. Durable behavior and scaffolding may use engineering assertions; metric search should normally run as targetless optimization work, with formal assertions reserved for genuine durable commitments or externally required sign-off.

This playbook has two halves. **The strategy** (Posture through Anti-patterns) is how to think about an optimization mission — read it first; it is the reasoning every decision below depends on. **The method** (Operating Order onward) is how to express that thinking as orchestrator investigation, targetless experiment work in the current checkout, ledger review, and patches in this runtime. The method references the runtime lifecycle and task schema but does not redefine them.

## Posture

An optimization mission moves a metric. You are not building toward a known end state — you are running an experiment whose answer you do not yet know, against a measurement that can mislead you. Think like a skeptical experimentalist, not a builder: most of the work is deciding *what to measure, where, and whether the number is real* — not deciding how to change the code.

Hold two ideas at once:

- The metric is the goal.
- The metric is a proxy that can lie — through noise, through non-comparable measurement, through gaming, through overfitting the cases you happened to look at.

A real win moves the metric **and** survives that skepticism: correctness preserved, guardrails intact, comparison fair, improvement reproducible, and the gain generalizes beyond the cases it was tuned on. A number that goes up by breaking any of those is not a win.

Honest "no win" is a valid outcome when the search was credible, bounded, and recorded. Do not manufacture a win, and do not let effort spent become evidence of progress.

## Three Things You Must Never Conflate

Most optimization confusion comes from collapsing three separate concepts. Name them apart and keep them apart for the whole mission:

- **The working point** — where your current best candidate sits; the parent you launch the next experiment from. It moves every time you promote a win.
- **The scoring reference** — the fixed yardstick the result is judged against. It does not move; if it moves, every past and future comparison is corrupted.
- **The correctness oracle** — the strongest available source of truth for "still correct." It is almost never "whatever the current code happens to output." It is an explicit spec, a reference implementation, a known-good output, a differential run, or a documented verifier — chosen for independence from the candidate.

When someone says "compare against the baseline," ask *which* of these three they mean. A measurement that uses the working point as its scoring reference, or the candidate's own output as its correctness oracle, proves nothing.

## Establish The Ground Truth First

Before the first experiment, map the terrain deeply. You cannot search a space
you have not measured, and in optimization the two easiest ways to fool yourself
are weak correctness and weak measurement. Deep investigation must produce two
reusable protocols with evidence, not assumption:

- **Correctness protocol** — the strongest available oracle, how independent it
  is from the candidate, the case set, adversarial/edge/stress coverage,
  tolerances, invariants, missing-output behavior, per-case failure handling,
  candidate-specific evidence requirements, and protected oracle, verifier,
  fixture, golden-output, and reference paths. If the candidate can pass by
  matching its own output, a cached public output, a happy-path sample, or an
  aggregate score while breaking individual cases, the correctness protocol is
  not ready.
- **Metric protocol** — metric name, direction (higher or lower wins), unit,
  exact command/procedure, workload/case mix, scoring reference, working point,
  candidate binding, build/cache/input state, repetitions, aggregation,
  warmup/cold-state handling, seeds, timeout, resource limits, per-case vs
  aggregate reporting, noise band/MDE, and protected benchmark, scorer, fixture,
  seed, judged-set, and data paths. If you cannot reproduce the number by hand
  and compare baseline vs candidate apples-to-apples, the metric protocol is not
  ready.

Also establish:

- **The workload** — what inputs the metric and correctness protocols cover, and
  whether they represent what is actually used or scored. Optimizing a toy
  workload that does not match the scored one is wasted from the start.
- **The scoring reference and the correctness oracle** — identified separately,
  per the three-way distinction above. For the oracle, rank the candidate sources
  by independence and pick the strongest one that is actually available.
- **The guardrails** — every floor and ceiling a win must not cross:
  correctness/pass-rate floor, quality floor, memory/latency/cost ceilings,
  compatibility and API promises, safety bounds. These are budgets, not
  afterthoughts.
- **The scoring surface** — anything that computes or defines the score:
  benchmark scripts, reference outputs, verifiers, fixtures, seeds, judged sets.
  This is the ruler. Treat it as read-only ground truth; inspect it to understand
  the metric, never to move the number.
- **The budget** — how much measurement and compute you can spend. The budget
  decides how broad you explore and how expensively you verify.
- **The noise** — characterized before any change (see §1). Without a noise
  estimate you cannot tell a win from a fluctuation.

If the correctness protocol or metric protocol is unknown, weak, ambiguous, or
unverifiable, resolving it is the first work — not a step you skip to start
changing code.

### Know The Shape Of Your Metric

Where cost hides, what the ceiling is, and what noise to distrust differ by metric family. Read your metric before you profile it:

| Family | Where the cost/loss usually hides | Typical ceiling / floor | Main noise or illusion |
| --- | --- | --- | --- |
| **Latency** | I/O waits, serialization, lock contention, cold caches, allocation, the critical path | Irreducible critical-path work / round-trip time | Warmup, co-tenancy, frequency scaling; use tail percentiles, not the mean |
| **Throughput** | Synchronization, per-item overhead, batching limits, the saturated resource | Saturation of the bottleneck resource (CPU / mem-bandwidth / I/O) | Too-short measurement window, queue warmup; often trades against latency |
| **Memory** | Retained allocations, duplication, over-allocation, fragmentation, caches | Irreducible live working set | Peak vs steady-state vs average; GC timing — measure the high-water mark you care about |
| **Cost** | Redundant calls, oversized resources, retries, idle time, data movement | Minimum required work × unit price | Pricing tiers and amortization; cheaper-per-unit but slower can raise total cost |
| **Compression / size** | Redundancy not exploited, format overhead | Entropy of the data | Ratio on one corpus ≠ general; watch the decode-cost and correctness trade |
| **Score / quality (eval)** | A subset of cases or classes; the aggregate hides per-case regressions | Irreducible error / oracle (or human) agreement ceiling | Small-N sampling noise is large; contamination; overfit to the eval set — never tune on the held-out split |
| **Ranking** | Head vs tail positions; specific query classes | The ideal ordering (e.g. perfect NDCG = 1) | Per-query variance, small judged pools; the aggregate hides query-class regressions |
| **Solver / objective** | Problem structure and instance mix; time-to-solution vs solution quality | A known bound (optimal, LP relaxation, dual bound) | Instance-specific results; seed/heuristic randomness; a win on one instance ≠ general |

## The Loop

Run the mission as a loop, not a straight line; new evidence sends you back up. Each pass:

1. **Trust the ruler.** Make the metric precise, cheap to read, and hard to fool. Characterize its noise before you optimize anything.
2. **Find the target.** Measure where the cost actually is. Optimize the dominant term; ignore the rest.
3. **Know the ceiling.** Estimate the best achievable. Decide whether the gap is worth pursuing and where you will stop.
4. **Form disposable hypotheses.** Derive candidates from the measurement, ranked by leverage. Hold them loosely.
5. **Explore cheap and broad, then verify narrow and expensive.** Prune with cheap proxies; spend faithful measurement only on survivors.
6. **Distrust each win.** Confirm it is real, fair, generalizing, and clean.
7. **Promote or stop on evidence.** Lock in a confirmed win as the new working point, then loop. Stop when the ceiling, the budget, or diminishing returns say so.

The sections below are how to think inside each step.

## 1. Trust The Ruler

The first question of every optimization mission is not "what do I change?" — it is "do I believe the number?" Resolve that before touching the system.

**Pin the metric down.** Name, direction, unit, the exact command that produces it, the workload, the aggregation, warmup handling, seeds, and what it means to take the same measurement twice. Choose the aggregation to match the metric: tail percentiles (p95/p99) when the tail is what hurts, median when single runs are noisy and skewed, mean/throughput for steady batch work. Never report a bare point estimate — always carry the spread with it.

**Characterize the noise before optimizing.** Run the unchanged baseline several times under realistic conditions and look at the spread. From that spread, fix a **minimum detectable effect (MDE)**: the smallest delta you are willing to claim as real — a safe rule of thumb is a few times the run-to-run spread. Treat any change inside the noise band as zero, no matter how much you want it to be a win. If the noise is larger than the gains you expect to find, you must reduce it before optimizing, or you will spend the whole mission chasing fluctuations.

**Reduce noise at the source.** Stable environment, warmup runs discarded, enough repetitions, one variable changed at a time, nothing else competing for the machine, fixed seeds where the work is stochastic. Interleave baseline and candidate measurements in the same session so environmental drift cancels instead of biasing one side. Early on, a cheap and stable ruler you can read many times beats a faithful one you can only afford once — you need iteration speed more than the last decimal.

**Check whether the ruler can be fooled.** Ask: could this number improve without the thing it represents actually improving? Could the score move by changing *how* it is measured rather than *what* is measured? The classic gaming routes — hardcoding or special-casing known inputs, weakening or short-circuiting the check, measuring a cheaper but different workload, caching across the measurement boundary, or editing the scorer/reference/fixtures — all move the number while moving nothing real. Anything that scores the work is part of the ruler and is read-only. If a candidate's gain traces to the ruler rather than the work, it is not a gain; it is a leak.

### Design The Case Set — Don't Accept The Easy One

The workload and the correctness cases are not given to you; they are *designed*, and the strength of that design caps how much any result can mean. A weak case set produces confident-looking verdicts worth nothing — a "2× faster" measured on one small convenient input, or a "still correct" checked on three happy-path examples.

Name the bias and resist it: a minimal benchmark and a handful of happy-path checks are less work to build and more likely to pass, so there is a constant pull toward them. You will be tempted to take the easy case set precisely because designing the comprehensive one is harder. "It passed the cases I wrote" is near-zero evidence when you wrote easy cases. Design the test to *surface failure*, not to confirm success — a case set that cannot distinguish a real improvement from a benchmark-only trick or a hidden correctness regression is not a test.

Build the case space by enumerating axes deliberately, then covering them:

- **size** — empty, tiny, typical, large, pathological;
- **structure** — sorted, random, degenerate, adversarial, duplicate-heavy;
- **boundaries** — off-by-one, limits, zero, overflow, the edges of any approximation;
- **error and failure paths** — invalid input, partial input, resource exhaustion, cancellation;
- **variants** — formats, configs, encodings, locales, concurrency, ordering;
- **distribution** — common, rare-but-real, and out-of-distribution.

For **correctness**, cover behaviors and failure modes against the oracle, not just the happy path, and add adversarial cases aimed at exactly where *this* candidate is most likely to break: the inputs it special-cases, the regime where its approximation degrades, the boundary its fast path skips. The cases an optimization is most likely to break are precisely the ones a lazy test omits — target them first.

For **speed**, measure a representative mix, not one easy input, and include the large and pathological cases where an optimization can collapse: a cache that helps the common case but thrashes on the adversarial one, a fast path that silently falls back to something slower, a change that wins at small N and loses at large N. Keep per-case timing — an aggregate over an easy mix hides every one of these.

A narrow case set is also what makes gaming profitable: hardcoding and special-casing only pay off when the cases are few and known. Comprehensive, adversarial coverage is the correctness defense and the anti-gaming defense at the same time.

## 2. Find The Target — Measure, Don't Guess

You can only win where the cost actually is. Before forming any hypothesis, profile the current system and find the **dominant term** — the part of the work that consumes most of the metric.

**Amdahl is the law here.** If a part accounts for fraction `p` of the metric, then optimizing only that part — even to zero — cannot improve the whole by more than `1 / (1 - p)`. So the first job is to find `p`. Spending effort on a 5% term caps your win at ~5% no matter how clever the change.

**Hot is not the same as leverage.** A path can be hot (lots of time/cost) yet already near-optimal, leaving little to gain. Leverage is `cost × how much of it you can plausibly remove`. Rank targets by leverage, not by raw heat.

**Profile with the right instrument for the metric.** A sampling/time profiler for latency; an allocation profiler and heap snapshots for memory; counters and instrumentation at the bottleneck for throughput; per-call/per-token/per-request attribution for cost; a per-case breakdown for score and ranking. Profile on a workload that matches what is actually scored or used — a profile of a toy input points you at the wrong target.

**Hypotheses come *from* the profile**, not from brainstorming in the abstract. If you have an "optimization idea" before you have a profile, you are guessing.

**The bottleneck moves.** Every time you remove one, re-measure — the next dominant term is rarely where you expected, and the gain you just made changed the breakdown. Profiling is not a one-time step at the start; it is the engine that drives every round. Beware optimizing yesterday's bottleneck.

## 3. Know The Ceiling

Before you start climbing, estimate the top. You rarely need a precise bound; an order-of-magnitude estimate changes your decisions.

**Estimate two bounds.** A *floor* on the irreducible work — the cost of just reading the input, a physical or information-theoretic limit, a known complexity bound, a dual/relaxation bound, or the number a known-better system already achieves. And a *round ceiling* from Amdahl — "if I drove the current dominant term to zero, the metric would become X." The gap between where you are and these bounds is the real size of the opportunity.

**Use the ceiling to make two cheap decisions:**

- **Is this worth pursuing?** A 1.2× when the ceiling is ~1.3× means you are nearly done; further effort has low expected value. A 1.2× when the floor implies ~50× is available means you have barely started. Same gain, opposite next move.
- **When do I stop?** Define "good enough" relative to the ceiling and the budget *up front*, so you neither quit with easy gains on the table nor grind past the point of diminishing returns.

If the target is already close to its floor, redirect to the next dominant term rather than squeezing a near-exhausted one.

## 4. Hypotheses Are Disposable

**Generate from the profile and from how the system works.** Common families, roughly in order of how often they pay off: do less (skip, early-exit, prune, deduplicate), do it once (cache, memoize, hoist, precompute), do it cheaper (better algorithm/complexity, better data layout and locality), do it together (batch, vectorize, coalesce I/O), do it approximately (lower precision or an approximation where the guardrail allows), and add concurrency only after the serial work is lean — spreading waste across workers just spreads the waste.

**Rank by expected value:** `leverage on the dominant term × probability it works × 1 / cost to try`. Pursue the cheap, high-leverage ones first, and prefer experiments designed to *disconfirm fast* — if an idea is wrong, you want to know cheaply and early.

**Pre-register the kill criterion.** Before running, state what "this didn't work" looks like (e.g. "if it isn't at least X better on the proxy, drop it"). This stops you from moving the goalposts after you have grown attached to a candidate.

**Hold every hypothesis loosely** and prefer breadth before depth. Try several distinct families before committing budget to deepening one. The most expensive mistake in optimization is staying with a direction because you already invested in it — sunk cost is the enemy of search. Measure, and let the data redirect you.

## 5. Explore Cheap And Broad, Then Exploit Narrow And Expensive

You have a finite budget. Spend it like a bandit: wide, cheap exploration to find what has promise, then concentrated, expensive verification on the few survivors.

**Climb a fidelity ladder.** Micro-benchmark or proxy workload → representative subset → full faithful measurement with correctness checked. Each rung costs more and decides more. Match the rung to the stakes: a quick proxy is enough to *prune* a hypothesis or rank a batch roughly; it is never enough to *promote* one. Reserve the full, faithful, costly measurement — real workload, enough repetitions, correctness in full, per-case evidence — for candidates that could actually be selected.

**Know what a proxy may and may not conclude.** A cheap check can rule a hypothesis *out* (no signal → kill) and order candidates approximately. It cannot confirm a promotable win. And the proxy itself can lie: periodically confirm that it still correlates with the real metric on at least one candidate. A proxy that has drifted from the real metric is just a second ruler that needs trusting.

**Avoid both failure modes:** full-verifying every idea burns the budget on dead ends; trusting a cheap proxy as if it were the real metric promotes a mirage. Spend more measurement where the decision is close (tie-breaks, promotion) and less where the outcome is already obvious.

## 6. Distrust The Win — Goodhart And Generalization

The metric is a proxy for what you actually want. The moment you optimize hard against it, the gap between "scores better" and "is better" is exactly where self-deception lives (when a measure becomes a target, it stops being a good measure). Put every apparent win through four questions, and treat failure on any one as disqualifying — a win that fails a question is not a smaller win, it is not a win:

- **Is it real?** Larger than the noise band, on enough repetitions, confirmed on a re-run, and not driven by a single outlier. Interleave baseline and candidate runs so drift cannot manufacture the delta.
- **Is it fair?** Baseline and candidate measured the same way — same workload, environment, build and cache state, concurrency, input order, timing scope. Enumerate the confounds and equalize them. Never compare a warm run to a cold one.
- **Does it generalize?** Show the gain on cases the candidate was *not* shaped against: held-out and unseen inputs, larger and smaller sizes, edge and stress cases, out-of-distribution workloads. The harder a candidate was tuned, the harder this test must be. Be most suspicious of a win that fits the visible cases exactly — that is the signature of overfitting, not improvement. Where a public and a hidden set exist, a gain that appears only on the public one is a red flag.
- **Is it clean?** Correctness preserved against the strongest available oracle (not the candidate's own output), every guardrail still inside its bound, and evidence per-case — an aggregate can hide a handful of catastrophic regressions behind an average that improved.

## 7. Think In Trade-offs, Not A Single Number

Optimization is almost always multi-objective. Faster often costs memory; smaller often costs accuracy; a higher score often costs latency, complexity, or compatibility. You are moving along a frontier, not climbing one axis.

**Carry the other axes explicitly.** Make correctness and every guardrail — accuracy floor, memory ceiling, latency budget, cost limit, compatibility promise — a budget you check on *every* candidate, not at the end. A candidate that is worse on no axis and better on one *dominates* and is a clean win; anything else is a trade that requires a decision.

**Watch the hidden costs** the headline metric does not show: maintainability, complexity, numerical stability, portability, build/cold-start time, and operational risk. State the trade in plain terms ("+8% throughput for +15% memory and a more fragile code path") and decide whether it is acceptable, rather than letting one number hide what it cost to move it. Record the trades you accept.

## 8. Keep A Fixed, Comparable Baseline

Hold one reference to measure against and keep it stable. Every candidate must be measured apples-to-apples against it — same workload, environment, build, cache state, and conditions — and must be reconstructible and reversible so you can re-measure, compare, or roll back cleanly. A measurement taken under drifted conditions is not evidence; it is noise wearing a number.

When a win passes all four tests of §6, lock it in as the new working point and optimize from there. Keep the working point separate from the scoring reference (see "Three Things You Must Never Conflate"): one is where the next experiment starts, the other is the fixed yardstick the result is judged against. Promoting a win advances the former and must never quietly move the latter.

## 9. Stop On Evidence

Stopping is a decision made from evidence, not from exhaustion. Stop when:

- you have reached the ceiling, or "good enough" relative to it;
- repeated clean rounds show diminishing returns — the last several rounds produced gains too small to be worth their cost;
- the budget is spent;
- the cost or risk of the next gain exceeds its value;
- the environment cannot measure credibly and that cannot be fixed.

A credible, bounded search that ends in "no further win" is a successful mission with an honest result, and should be recorded as such — what was tried, what was ruled out, and why. An unbounded search that never decides is not a success; it is a failure to stop.

## Anti-patterns

These kill more optimization missions than any missing trick:

- **Optimize first, measure later.** "It must be faster now" is not evidence. No claim without a before/after on a trusted ruler.
- **Guess the target.** Optimizing a part that is not the dominant cost — effort spent where Amdahl caps the gain at near-zero.
- **Chase noise.** Celebrating a delta smaller than the measurement spread. If you never characterized the noise, every win is suspect.
- **Measure the wrong workload.** Profiling and tuning on inputs that do not match what is actually scored or used.
- **Take the easy case set.** Benchmarking on one small convenient input, or checking correctness on a few happy-path examples, because the comprehensive, adversarial set is more work to build.
- **Trust the aggregate.** Shipping an average that improved while a few cases regressed catastrophically underneath it.
- **Single-run win.** Promoting on one measurement instead of enough repetitions to clear the noise band.
- **Tunnel on one number.** Overfitting the visible benchmark while ignoring whether the gain generalizes or what it cost on the other axes.
- **Fall in love with a hypothesis.** Pouring budget into a direction because you already invested in it, instead of killing it on the evidence.
- **Compare non-comparable runs.** Different workload, environment, build, or cache state on each side — the delta means nothing.
- **Promote on a proxy.** Selecting a candidate from a cheap exploration check without faithful, full measurement.
- **Touch the ruler.** Moving the score by changing the benchmark, reference, verifier, or fixtures instead of the work.
- **Conflate the three baselines.** Using the working point as the scoring reference, or the candidate's own output as the correctness oracle.
- **Let a broken win through.** Accepting a metric gain that breaks correctness or a guardrail.

---

# Method: Running The Mission In This Runtime

The strategy above is how to think. This half is how to express it in the
runtime without turning ordinary metric search into a contract pipeline.

Default optimization shape:

```text
orchestrator investigates correctness protocol + metric protocol
-> targetless experiment work in the current checkout
-> attention with ledgers + current workspace state
-> orchestrator decides accept/reject/keep/rerun
-> next round or done
```

A disposable hypothesis is a targetless `work` task, not an assertion. It owns
no contract and needs no gate. It runs against the current checkout. Later
experiments may overwrite earlier experiment changes, so every experiment must
leave a ledger detailed enough for the orchestrator to decide whether to keep
the current result, reject it, or run another experiment.

Formal assertions, validators, gates, and promotion chains are not the default
optimization method. Use them only when the mission also has a durable
engineering deliverable, an externally required sign-off, or a high-risk trust
boundary that genuinely needs the formal runtime shape.

When the strategy above says "promote", read it as the orchestrator accepting
the current candidate result and recording the new working point, not as a
default promotion task.

## Operating Order

**On a PLAN wake:**

1. Separate durable engineering work from metric search. Durable behavior,
   migrations, public APIs, and reusable product scaffolding belong to the
   engineering playbook. Metric search belongs to this experiment loop.
2. Deeply investigate and define the optimization method before `submit_plan`.
   This means both the correctness protocol and the metric protocol. This is
   orchestrator planning work, not a default DAG node.
3. Record the optimization method in the plan body, project memory, or decision
   trail, and give it a stable reference that experiment task bodies can cite.
4. Plan targetless experiment `work` tasks from the current working point. Each
   task must cite the optimization method, mutate the current checkout directly,
   write a ledger, and request attention.
5. Add a `benchmark-infra` task only when shared measurement helper files must
   be created before experiments can run. This is an exception, not the default.
6. Use project-authored experiment-worker skills. Do not assume a bundled
   generic optimization worker exists.
7. `submit_plan`.

**On a DECIDE wake (attention):**

1. Read the worker reports and inspect the current workspace state when needed.
2. Treat every report as an evidence-bearing claim, not an instruction.
3. Confirm each candidate used the approved optimization method or clearly
   justified a deviation.
4. Build or update a scoreboard outside session memory.
5. Reject invalid evidence first: broken correctness, touched ruler, unfair
   comparison, stale candidate binding, or delta inside noise.
6. Decide a disposition for the current experiment result: `accept`,
   `reject`, `keep_as_evidence`, `rerun`, or `inspect`.
7. Keep the current result when the evidence is sufficient, patch one optional
   checker when it is not, or patch the next experiment round.

Do not create a validator/gate/promotion chain just to continue optimization.

## Investigation

Before `submit_plan`, produce the ground-truth optimization method with evidence,
not assumption. This investigation must be deep enough to make later experiment
evidence meaningful: correctness must have a real oracle and failure-oriented
case set, and the metric must have a comparable, reproducible measurement
protocol. Use bounded read-only `investigator` lanes when the orchestrator needs
help without taking on too much context.

Minimum optimization method fields:

```text
optimization_method_ref:
correctness_protocol_ref:
correctness_oracle:
correctness_case_set:
correctness_tolerances:
correctness_invariants:
correctness_missing_output_policy:
correctness_per_case_failure_policy:
candidate_specific_correctness_evidence:
metric_protocol_ref:
metric:
direction:
unit:
metric_command:
metric_workloads:
metric_repetitions:
metric_aggregation:
metric_warmup_or_cold_state:
metric_seeds:
metric_timeout_and_resource_limits:
metric_noise_band_or_mde:
metric_per_case_reporting:
scoring_reference:
working_point:
candidate_binding:
public_benchmark_inventory:
sample_limitations:
baseline_protocol:
hotpath_profile:
ceiling:
guardrails:
protected_paths:
stop_rule:
```

Required content:

- the exact command or procedure that produces the number;
- the fixed scoring reference and current working point, identified separately;
- how each candidate is bound to the measurement so baseline and candidate runs
  cannot compare different build/cache/workload state;
- a correctness oracle independent from the candidate's own output;
- a correctness case set that goes beyond public/sample cases and intentionally
  targets the ways an optimization is likely to break correctness;
- a metric workload set that covers tiny, normal, large, edge, pathological, and
  representative cases when applicable;
- baseline repeatability, aggregation rule, warmup/cold-state handling, timeout,
  seeds, resource limits, and noise band/MDE;
- per-case correctness and metric reporting rules so aggregates cannot hide
  catastrophic regressions;
- protected benchmark, verifier, fixture, generated-output, and scoring paths;
- a practical stop rule based on ceiling, budget, or diminishing returns.

Public benchmarks, sample tests, and repository-provided demo workloads are a
starting point, not the whole score unless the mission explicitly says so.

Profiling, baseline collection, oracle-finding, correctness case-set design, and
metric protocol calibration belong in PLAN investigation or, when measurement
must run in the workspace, in a clearly-labeled targetless `work` task. They are
correctness/measurement setup, not an optimization candidate.

## Core Work Shape

Default experiment tasks are targetless, workspace-mutating, and
attention-producing:

```yaml
tasks:
  - id: exp-cache
    type: work
    targets: []
    skill: latency-experiment-worker        # project-authored
    body: "Try the cache hypothesis from the current working point in the current checkout. Use optimization method opt-method-001. Write a ledger with changed files, correctness evidence, metric evidence, and any deviations, then call end_node(done=True, report=..., request_attention=True)."
    depends_on: []

  - id: exp-batch
    type: work
    targets: []
    skill: batching-experiment-worker       # project-authored
    body: "Try the batching hypothesis from the current working point in the current checkout. Use optimization method opt-method-001. Write a ledger with changed files, correctness evidence, metric evidence, and any deviations, then call end_node(done=True, report=..., request_attention=True)."
    depends_on: [exp-cache]
```

Sequence experiments with `depends_on` when they touch the same workspace state
or when later experiments should build on earlier changes. For broad exploration,
prefer one experiment per attention cycle unless the experiments are truly
independent and either completion order is acceptable.

## Benchmark Infrastructure Exception

Only add a benchmark infrastructure task when the orchestrator cannot define a
usable metric protocol, correctness protocol, or shared measurement helper
without creating files that later experiments must run.

```yaml
tasks:
  - id: benchmark-infra
    type: work
    targets: []
    skill: latency-benchmark-infra          # project-authored
    body: "Create reusable benchmark/correctness helper files for optimization method opt-method-001. Do not optimize solution code. Report created files, commands, protected paths, and any remaining gaps."
    depends_on: []

  - id: exp-cache
    type: work
    targets: []
    skill: latency-experiment-worker        # project-authored
    body: "Try the cache hypothesis using optimization method opt-method-001 and the benchmark-infra files. Mutate the current checkout, write a ledger, and request attention."
    depends_on: [benchmark-infra]
```

This task is not a validator, gate, or experiment candidate. If it changes
anything other than measurement infrastructure, split the work or reject it.

## Experiment Ledger

Each experiment worker must leave a ledger in its report. The ledger is more
important than optimistic prose.

Minimum report fields:

```text
candidate_id:
task_id:
parent_ref:
candidate_ref:
workspace_before_ref:
workspace_after_ref:
changed_files:
optimization_method_ref:
correctness_protocol_ref:
metric_protocol_ref:
metric:
baseline:
candidate:
delta:
noise_band:
commands:
correctness_per_case_result:
metric_per_case_result:
guardrails:
protected_paths_touched:
recommendation: accept | reject | keep_as_evidence | rerun | inconclusive
notes:
```

Rules for workers:

- Make one coherent hypothesis per task.
- Do not edit the scoring/ruler surface to improve the metric.
- Work in the current checkout and record enough diff/ref detail for the
  orchestrator to understand what changed.
- Run the approved correctness protocol, metric protocol, and guardrail method,
  or report exactly which workloads/cases were skipped and why. A skipped,
  stale, or weak correctness check makes the candidate non-promotable until a
  later checker or experiment produces candidate-specific correctness evidence.
  A skipped, noisy, or non-comparable metric check makes the candidate
  non-promotable until the metric protocol is rerun credibly.
- Be honest: a failed or losing experiment is a valid completed ledger.
- Call `end_node(done=True, report=<ledger>, request_attention=True)` when the
  ledger is usable.

Use `done=False` only when the worker could not produce a usable ledger.

## Optional Checker

Use one checker only when the orchestrator is about to accept a result and the evidence is
not yet strong enough. The checker is still a targetless `work` task by default,
not a `validate` task and not a gate.

```yaml
add:
  - id: check-exp-cache
    type: work
    targets: []
    skill: latency-candidate-checker        # project-authored
    body: "Inspect the current checkout or cited candidate ref, rerun optimization method opt-method-001, check protected paths, correctness, and metric comparability, and report accept/reject/rerun."
    depends_on: [exp-cache]
```

Checker report minimum:

```text
candidate_id:
candidate_ref:
optimization_method_ref:
correctness_protocol_ref:
metric_protocol_ref:
metric_rerun:
correctness_rerun:
guardrails:
protected_paths_touched:
recommendation: accept | reject | rerun | inconclusive
blocking_issues:
```

Use a formal `validate` task only when the mission also has contract assertions
that genuinely need validation.

## Acceptance Decision

Acceptance is an orchestrator decision. It is not a default runtime task chain.

Before accepting the current result:

- inspect the current checkout or candidate ref cited by the ledger;
- confirm the ledger is credible enough for the mission's stakes;
- rerun the optimization method or patch one optional checker when the delta is
  close to noise, correctness risk is high, protected paths were touched, or the
  ledger skipped important correctness cases or metric workloads;
- record why this candidate was selected and what trade-offs were accepted.

After accepting:

- update the working point;
- record the accepted candidate id/ref and evidence;
- decide whether older experiment ledgers remain useful as evidence or should be
  superseded by the new working point;
- patch the next round from the new working point if more optimization remains.

## Formal Contract Exception

Do not author `VAL-*` or `EXP-*` assertions by default.

Use formal assertions only when:

- the mission includes durable engineering scaffolding that must be delivered
  and validated as product behavior;
- an external process requires explicit contract validation;
- a high-risk final claim genuinely needs the runtime's formal `validate`/`gate`
  semantics.

Runtime obligations to respect when declaring an assertion:

- every declared assertion needs exactly one non-superseded `work` task that
  owns it for the life of the mission;
- `add_items` requires the matching `contract/<ID>.md` file on disk before the
  patch;
- a targetless experiment round adds no assertions and needs no contract review.

If formal assertions are introduced, use `contract-review` for those assertions
only. Do not demand an assertion per hypothesis.

## Patching Rounds

Patch another round when:

- no candidate is good enough;
- evidence is inconclusive but a next hypothesis is clear;
- the best candidate needs repair;
- the bottleneck moved and a new target is now more important.

Patch with more targetless `work` tasks. Keep the round small enough that the
orchestrator can compare candidates in one attention wake.

Prefer distinct hypotheses over many variants of one idea until evidence says a
family is worth deepening.

## Skills And Team

- **Project-authored experiment-worker skill(s)** — one per recurring
  optimization method. Each must define: run one hypothesis from the working
  point in the current checkout; run the approved metric and correctness checks;
  write the ledger; and call
  `end_node(done=True, report=..., request_attention=True)`.
- **Project-authored checker skill** — optional; used only before acceptance when the
  orchestrator needs one focused rerun or risk review.
- **Project-authored benchmark-infra skill** — optional; creates shared
  measurement helper files only when PLAN investigation cannot avoid it.
- **Bundled validators** — `benchmark-validator` and `scrutiny-validator` are
  for formal contract exceptions, not routine optimization search.
- **Subagents (read-only, advisory)** — `investigator` for
  protocol/profile/oracle/binding/ceiling/case-set and root-cause analysis lanes;
  `contract-review` only when formal assertions are added.

## Decision And Patch Policy

At an experiment checkpoint: read the ledger and candidate ref; apply
correctness/integrity-first triage; update the scoreboard from ledgers, not
prose; continue planned breadth unless evidence or budget justifies selecting;
patch a new round only for distinct move families.

At an acceptance checkpoint: inspect the current checkout or cited candidate ref,
rerun or check when needed, accept only when the evidence clears the mission's
risk bar, then record the new working point.

Patch the root cause, mapping the strategy's anti-patterns to a fix:

- **Noisy ruler / chasing noise** → fix the protocol, repetitions, or minimum
  detectable effect.
- **Non-comparable runs** → fix candidate binding, build/cache state, workload,
  or baseline.
- **Weak / easy case set** → strengthen the correctness protocol, metric
  protocol, or add a benchmark-infra task if shared files are needed.
- **Metric win with correctness failure** → reject or patch a focused
  correction; never accept it as a win.
- **Touched the ruler / integrity breach** → classify `invalid`, patch
  protected-file rules or measurement setup.
- **Over-broad hypothesis** → split into auditable experiments.
- **Repeated worker miss** → update the project experiment-worker skill before
  re-running.

Stop on evidence (strategy §9): ceiling reached, diminishing returns over clean
rounds, budget spent, value below cost, or the environment cannot measure
credibly.

## Memory And Artifacts

Store only durable, reusable facts in the project memory carrier (`AGENTS.md`,
`MEMORY.md`, or project-root notes the tasks cite):

- **Benchmark method** — metric, command, workload, environment, aggregation,
  noise band, scoring reference, working point, protected scoring paths.
- **Oracle note** — the chosen correctness source, tolerances, and accepted
  gaps.
- **Candidate policy** — diff/ref recording, revert, and rollback conventions.
- **Scoreboard & round synthesis** — candidate status, deltas vs the noise band,
  refs, checker verdicts, accept/reject/keep decisions, and what was ruled out.

Keep one-off runs, raw logs, and per-experiment ledgers in attempts/decisions,
not in the durable carrier. When a discovered fact changes how later work should
be planned or measured, update memory before dispatching more work.

## Pre-Submit Checklist

- The engineering/optimization boundary is explicit.
- The orchestrator has defined an optimization method with two explicit parts:
  correctness protocol and metric protocol.
- The correctness protocol names the oracle, candidate-specific evidence,
  tolerances, invariants, missing-output policy, per-case failure policy,
  adversarial/edge/stress case-set axes, and protected oracle/verifier/fixture
  paths.
- The metric protocol names the metric, direction, unit, exact command,
  workload/case mix, scoring reference, working point, candidate binding,
  repetitions, aggregation, warmup/cold-state handling, seeds, timeouts/resource
  limits, noise band/MDE, per-case reporting, protected scorer/benchmark/data
  paths, hotpath/ceiling, and stop rule.
- Both protocols go beyond public/sample cases unless the mission explicitly
  says those are the full score.
- Experiment tasks are targetless `work` tasks.
- Experiment tasks explicitly cite the optimization method.
- Experiment tasks that touch the same workspace state are dependency-sequenced
  or submitted one attention cycle at a time.
- Worker bodies require current-checkout changes, a ledger, and
  `end_node(done=True, report=..., request_attention=True)`.
- No default validator, gate, promotion task, or `EXP-*` contract is planned.
- If a final checker is needed, it is a single targetless `work` task.
- If benchmark infrastructure is needed, it is clearly separated from candidate
  optimization.
- All skill names are bundled or project-authored before their tasks run.
- The orchestrator will review ledgers and current workspace state before
  deciding accept/reject/keep.
