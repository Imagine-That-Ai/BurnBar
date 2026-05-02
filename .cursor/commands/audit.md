---
description: Post-implementation launch-readiness audit; fixes reachable issues and reports ship/hold readiness.
---

You have completed the implementation run. Now run the `/audit` launch-readiness workflow on the completed work.

Audit focus or scope, if provided by the user: $ARGUMENTS

If no explicit scope was provided, infer the scope from the current conversation, changed files, branch name, recent commits, and repository state.

# /audit: Post-Implementation Launch-Readiness Audit

You have completed the implementation run. Switch roles from builder to uncompromising principal reviewer, launch-readiness auditor, staff engineer, product designer, QA lead, and SOTA evaluator.

Your mission is to inspect, verify, stress-test, and improve the completed work until it meets the highest professional standard possible. Do not merely summarize what happened. Do not assume success. Prove it.

The standard is not "the task is done." The standard is:

> Would this impress a serious frontier product team, survive scrutiny from a staff engineer, delight a user visually, and remain extendable six months from now?

The finish line is:

> Holy shit, that's done.

## Operating rules

- Do not assume success because tests pass or because you wrote the code.
- Do not stop at critique when the fix is reachable. Fix real issues, add missing tests, strengthen weak polish, and rerun validators.
- Do not fabricate verification. Every claim in the closure report must tie to a file, command, flow, screenshot, or explicit inspection.
- Do not benchmark-max, fake polish, or add complexity for its own sake. Improve the real product.
- Preserve user work. Inspect repository status before editing and avoid overwriting unrelated changes.
- Do not commit, push, deploy, or merge unless the user explicitly asked for it.
- If the original mission is ambiguous, reconstruct it from the current conversation, changed files, recent commits, branch name, and tests. Ask only if the audit cannot proceed safely without the answer.

## Phase 1: Reconstruct intent and scope

1. Capture repository state:
   - Current branch.
   - `git status`.
   - Changed files.
   - Recent commits.
   - Diff/stat against the relevant base branch when available.
2. Reconstruct the original implementation mission from:
   - The latest user request and current conversation.
   - Recent commits and branch name.
   - Changed files, tests, fixtures, docs, scripts, and config.
3. Identify affected surfaces:
   - Backend/services/contracts.
   - CLI, daemon, extension, desktop, IPC, renderer, or provider behavior.
   - Frontend UI, visual system, accessibility, responsive behavior, and motion.
   - Persistence, migrations, state, cache, retries, and recovery.
   - Tests, docs, release artifacts, and operational scripts.
4. Output a short working audit plan before making fixes.

## Phase 2: Evidence-first inspection

Evaluate the completed work end to end across these dimensions.

### 1. Correctness

- Does the implementation satisfy the original mission?
- Are all promised features complete?
- Are there silent failures, broken flows, edge cases, or partial implementations?
- Are there places where the app appears to work but the underlying logic is fragile?
- Are new statuses, enum values, routes, events, actions, IPC channels, provider states, and error codes handled everywhere they need to be handled?

### 2. Architecture

- Is the solution clean, modular, future-proof, and extendable?
- Are responsibilities separated properly?
- Are there rushed abstractions, leaky boundaries, duplicated logic, hidden coupling, or fragile convenience shortcuts?
- Would another strong engineer understand and safely extend this six months from now?

### 3. Frontend quality and visual delight

For UI changes, verify the live surface whenever feasible.

- Does the UI feel premium, intuitive, polished, and emotionally compelling?
- Does it create a "holy shit this is cool" reaction?
- Are spacing, typography, motion, hierarchy, empty states, loading states, error states, hover/focus states, and interaction details thoughtfully handled?
- Are there parts that still feel generic, awkward, unfinished, or merely functional?
- Does the surface feel specific to this product, not like a generic dashboard or template?

### 4. User experience

- Is the product flow obvious and satisfying?
- Does the user always know what is happening, what changed, and what to do next?
- Are there unnecessary steps, confusing labels, missing affordances, or weak feedback loops?
- Does the implementation reduce cognitive load while increasing perceived power?
- Are success, failure, pending, retry, cancel, and recovery states explicit?

### 5. State, data, and persistence

- Is state handled correctly across refreshes, navigation, retries, failures, restarts, interrupted flows, and out-of-order user actions?
- Are mutations durable, attributable, recoverable, idempotent, and easy to reason about?
- Are there race conditions, stale state risks, cache invalidation issues, or data consistency problems?
- Are migrations, schemas, and persisted records backward-compatible when they need to be?

### 6. Edge cases and failure modes

Stress inputs and dependencies:

- Empty, malformed, huge, duplicated, stale, slow, unavailable, missing, and unexpected data.
- API failures, network degradation, missing assets, permission failures, provider mismatches, process crashes, repeated clicks, and user actions out of order.
- Errors must be graceful, useful, attributable, and recoverable.

### 7. Testing

- Tests must prove critical behavior, not merely exercise code.
- Cover critical paths, edge cases, and regression risks.
- Add or improve unit, integration, UI, smoke, E2E, contract, visual, accessibility, or regression tests when missing.
- Run relevant validators: lint, type checks, tests, and build checks. Prefer scoped checks during iteration, then final relevant checks before reporting.
- If validators fail, fix failures and rerun. Do not hand-wave failures.

### 8. Documentation

- Update docs only when the work changes architecture, setup, operations, product behavior, public contracts, agent workflows, or assumptions future humans/agents must understand.
- Prefer small, accurate updates over broad documentation churn.
- If docs remain stale by choice, justify the risk explicitly in the closure report.

### 9. SOTA / frontier standard

- Compare the implementation against what a modern excellent product would do.
- Search current docs or best practices when platform/provider behavior, library APIs, security expectations, accessibility standards, or design conventions may have changed.
- Distinguish "good" from genuinely excellent.
- Do not add complexity to score points. Raise the real product quality.

### 10. Completeness

- Search for related `TODO`, `FIXME`, `HACK`, `XXX`, `placeholder`, `stub`, `mock`, `temporary`, `good enough`, `later`, `follow-up`, brittle assumptions, unreachable paths, and dead code.
- Resolve reachable dangling threads.
- Explicitly justify anything left behind.

## Phase 3: Stress test and improve

When you find an issue:

1. Classify severity:
   - **P0 Blocker:** ship would be unsafe, broken, misleading, or data-damaging.
   - **P1 High:** core flow broken, serious regression risk, poor recovery, or significant UX failure.
   - **P2 Medium:** meaningful quality, maintainability, edge-case, or polish gap.
   - **P3 Low:** cleanup, minor polish, or follow-up that does not block launch.
2. Fix P0/P1/P2 issues when the permanent solve is reachable.
3. Add or update tests for fixes when behavior can regress.
4. Rerun the smallest useful validator, then rerun the final relevant validator set.
5. Keep a running list of issues found, fixes applied, and evidence gathered.

If a real issue is not fixed, the closure report must explain why it is not safely reachable in this pass and what exact follow-up is required.

## Phase 4: Validation checklist

Use professional judgment to select validators, but always record exact commands and outcomes.

Typical checks:

- `git diff`, `git status`, and relevant changed-file review.
- Typecheck for affected packages.
- Lint for affected packages.
- Unit/integration tests for changed code.
- Contract/schema tests when contracts changed.
- E2E/smoke/browser/manual QA when user-facing flows changed.
- Build checks when packaging/runtime surfaces changed or before release.

For UI changes, capture live evidence when feasible:

- Navigate to affected surfaces.
- Exercise changed interactions.
- Check empty, loading, error, success, and recovery states.
- Check console/runtime errors.
- Check responsive behavior if layout changed.
- Check accessibility basics: labels, focus order, contrast, keyboard paths, and reduced-motion behavior.

## Phase 5: Closure report

End with this exact structure:

```markdown
# Audit Closure Report

## Executive Verdict
Truly done / Nearly done / Not done — one direct sentence explaining why.

## What Was Verified
- Commands:
- Files inspected:
- Flows exercised:
- External/current-practice checks:

## Issues Found
| Severity | Issue | Evidence | Resolution |
|---|---|---|---|

## Fixes Applied
- File/path: what changed and why.

## Remaining Risks
- Concrete risk, impact, and owner/follow-up. Do not include vague disclaimers.

## SOTA Score
| Dimension | Score / 10 | Rationale |
|---|---:|---|
| Engineering quality |  |
| UX polish |  |
| Visual delight |  |
| Reliability |  |
| Future extensibility |  |

## Final Recommendation
Ship / Hold / Continue hardening — direct recommendation with the next action.
```

If no issues were found and no fixes were needed, the report must still include the evidence that supports that conclusion.
