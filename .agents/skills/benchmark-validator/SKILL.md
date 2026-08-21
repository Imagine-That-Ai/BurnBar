---
name: benchmark-validator
description: Benchmark validation procedure for one assigned benchmark-related target. For optimization EXP-* targets, independently classify candidate outcome. For engineering VAL-* or legacy engineering targets, prove or disprove the required benchmark/performance assertion.
---

# Benchmark Validator

Use this skill for a validation assignment targeting exactly one benchmark-related
assertion.

For optimization `EXP-*` targets, you are not selecting the winner or optimizing
further. You independently decide whether the experiment produced a trustworthy
outcome under its contract.

For optimization `EXP-*` targets, act as an adversarial tester for the selected
candidate. The contract is the minimum bar, not the whole test plan. Before
promotion, define and run a compact but comprehensive validation plan that
attacks the candidate's likely correctness and performance failure modes.

For engineering `VAL-*` or legacy engineering targets, do not use optimization
outcome semantics. Pass only when the assigned benchmark, performance,
correctness, and guardrail behavior required by the assignment and contract is
proven with fresh evidence.

## Inputs

Read:

- Validation assignment.
- The single assigned benchmark-related contract.
- `AGENTS.md`.
- Experiment ledger path cited by the assignment or contract.
- Candidate artifact/ref/patch/checksum cited by the assignment, contract, or
  ledger.
- Measurement protocol, correctness/guardrail commands, protected files, and source/baseline refs cited by the contract.
- For optimization targets, also inspect visible runtime resources read-only
  when useful: changed files, benchmark scripts, fixtures, public outputs,
  baseline/reference artifacts, verifier-adjacent code, logs, and generated
  artifacts. Do not mutate these resources, copy protected artifacts into a
  submission, or make submitted code depend on evaluator-only locations.

If the assignment targets more than one benchmark-related assertion, fail the
assignment as too broad and request attention.

## Procedure

1. **Identify artifacts**
   - Parent/baseline ref.
   - Candidate ref or patch artifact.
   - Benchmark command, run count, aggregation, variance policy.
   - Correctness and guardrail commands.
   - Protected benchmark/scoring/data/verifier files.

2. **Audit evidence integrity**
   - Inspect candidate changes affecting benchmark scripts, scoring, data, fixtures, golden outputs, correctness verifiers, generated expected outputs, seeds, or measurement config.
   - If proof is weakened or unapproved metric surfaces changed, classify an
     optimization experiment `invalid`; for an engineering target, mark the item
     `passed=false`.

3. **Define adversarial validation plan**
   - For optimization `EXP-*`, do this before remeasurement. Do not only run the
     contract's benchmark command.
   - From the contract, ledger, changed files, source, available fixtures,
     benchmark scripts, baseline/reference artifacts, public outputs, and
     visible runtime resources, identify the correctness and performance risk
     axes this candidate could break.
   - Build a compact test plan that includes the contract-required checks plus
     targeted/adversarial/proxy cases for changed surfaces. Cover important
     input, data, media, config, size, timing, cache, concurrency, edge, stress,
     and failure-mode axes when they are relevant to the candidate.
   - For each case, state the expected correctness evidence, the failure
     boundary, and whether timing evidence is needed. Record limitations for
     risk axes that cannot be tested in the validation environment.
   - If the contract or ledger does not provide enough oracle, candidate binding,
     or correctness information to build a meaningful adversarial plan, classify
     the optimization experiment `invalid` rather than promoting from aggregate
     speed alone.

4. **Remeasure independently**
   - Reconstruct parent and candidate states using the method assigned by the
     assignment or contract.
   - Avoid destructive operations on the shared workspace.
   - Run parent and candidate under the declared protocol.
   - Capture raw outputs, aggregate values, spread/noise, environment, and deviations.

5. **Run correctness and guardrails**
   - Required correctness/quality/compatibility/safety checks must run before objective metric comparison can promote a candidate.
   - For optimization `EXP-*`, run the adversarial validation plan as well as
     the contract-required checks.
   - Record per-case correctness and speed evidence before relying on aggregate
     metric output.
   - Failed checks make the candidate `rejected`, not promoted.
   - Missing, stale, skipped, or un-runnable checks make the experiment `invalid`.

6. **Classify outcome**
   - First determine whether the assigned target is an optimization `EXP-*`
     target or an engineering/legacy target.
   - `promoted`: credible integrity, setup complete, correctness/guardrails pass, metric meets promotion rule.
   - `rejected`: credible integrity and setup, but correctness/guardrails fail or metric does not win.
   - `budget_exhausted`: declared budget prevented completion and the contract allows that honest outcome.
   - `invalid`: missing ledger/ref/checks, broken candidate binding, compromised evidence, or unverifiable setup.

For optimization `EXP-*` targets, use `passed=true` for `promoted`, `rejected`,
or legitimate `budget_exhausted`; use `passed=false` for `invalid`.

For engineering `VAL-*` or legacy engineering targets, use normal validation
semantics: `passed=true` only when the assigned benchmark/performance assertion
and required guardrails pass with fresh evidence. A rejected candidate, failed
guardrail, missing evidence, or budget-exhausted result is `passed=false` unless
the contract explicitly defines that outcome as the required behavior.

7. **Write regression ledger only for invalid**
   - If `passed=false`, write `<regressions_dir>/<item_id>.md` with setup,
     command, expected credible measurement or required behavior, observed
     invalidating issue, and evidence artifact paths.

## Report

```markdown
## Experiment
- Item ID: <id>
- Parent artifact: <ref/path>
- Candidate artifact: <ref/path>
- Ledger: <path>

## Evidence Integrity
- Changed protected/evidence-sensitive paths: <list>
- Verdict: <credible | invalid>

## Measurements
- Parent: <runs, aggregate, spread, raw paths>
- Candidate: <runs, aggregate, spread, raw paths>
- Improvement: <calculation and threshold>

## Adversarial Validation Plan
- Risk axes: <candidate-specific axes attacked>
- Cases: <case -> expected evidence -> failure boundary>
- Limitations: <untested risk axes and why>

## Correctness And Guardrails
- `<command>` -> exit <code>, <result>
- Per-case adversarial results: <case -> passed/rejected/invalid evidence>

## Outcome
- <promoted | rejected | budget_exhausted | invalid>
- Reason: <contract-tied explanation>

## Limitations
- <setup or measurement caveats>
```

Call `end_node` with exactly one item for the assigned target id, then exit immediately.
