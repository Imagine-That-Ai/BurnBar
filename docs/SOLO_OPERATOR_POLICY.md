# Solo-operator merge & control policy

Two consecutive diligence reviews (2026-06-10, 2026-06-11) made the same core
finding: the repository's configured controls (required review, `enforce_admins`,
quality gates) were being bypassed in practice — 0 human reviews across every
merged PR, `enforce_admins` toggled around merges, and on 06-11 a coverage gate
relaxed to flip a red check on the team's own diff. The artifacts were strong;
the _process integrity_ was not.

This repository is run by **one operator**. Pretending otherwise — a second
account that rubber-stamps its own team's changes — is the failure mode those
reviews caught, not a control. This document states the honest model instead: a
**hybrid control** in which a solo operator is backed by a credentialed AI
reviewer on every change and — on the sensitive lanes — a paid external
code-owner (the compensating control this policy is standing up; see § The hybrid
control for its current, not-yet-wired status in `CODEOWNERS`). It records what
compensates for the missing second engineer, when a bounded break-glass merge is
acceptable, and what is never acceptable.

## The hybrid control (what actually governs)

1. **Solo operator, stated plainly.** There is one developer. No second human
   approval is manufactured, and branch protection is not satisfied by a co-owner
   account that never independently reviews. The controls below are described as
   _compensation_ for the missing second engineer — never disguised as a
   two-person review.
2. **A credentialed AI reviewer posts a checkable verdict on every PR.** An
   independent AI review (the factory's Codex reviewer / `/code-review`) runs on
   the final diff of **every** PR and posts a **verdict artifact**: a durable,
   re-runnable comment or check that states what it examined, its findings, and a
   pass/blocking status. It is **compensating analysis, never sole approval** —
   its verdict never counts as the required code-owner review and never merges a
   PR by itself. Its findings are addressed or explicitly dispositioned in the PR
   before merge.
3. **A paid external reviewer is the designated code-owner on the sensitive
   lanes — a control being stood up, stated honestly.** For crypto/E2EE,
   privileged input (daemon/HID/XPC/socket), billing/entitlements,
   Firestore/storage security rules, and release/deploy, the governing intent is
   that a paid external or fractional security-literate reviewer is the required
   `CODEOWNERS` reviewer who **must approve** — either **before merge**, or
   **before the release that ships the change** under a documented hold (see
   below). This is the real second set of human eyes on the surfaces where a solo
   mistake is most costly, bought rather than pretended.

   **Current state, stated plainly (the gap this policy refuses to hide).**
   `.github/CODEOWNERS` today routes every sensitive-lane path to the operator's
   own owner accounts (`@Ajnunezg @emilio3435`), not to an external reviewer.
   Until that reviewer is wired into `CODEOWNERS`, this point is **target intent,
   not yet an operating control**: the sensitive lanes are governed by branch
   protection's code-owner gate plus the AI verdict artifact, and the compensating
   "second human on the risky surfaces" is not yet live. Adding the external
   reviewer to `CODEOWNERS` for the paths in "Sensitive lanes" below is the tracked
   step that makes this control real; it MUST land before this point is described
   as already governing. Writing it as configured fact before then would be exactly
   the "gap between configured and operating controls" this document exists to close.

## The default (branch protection)

- `enforce_admins` stays **on**. It is not toggled to merge — that toggle, not
  the review gate, was the control the diligence reviews flagged.
- Branch protection requires one code-owner approval with **zero** standing PR
  bypass allowances. On the sensitive lanes the required code-owner **will be** the
  paid external reviewer above once that reviewer is wired into `CODEOWNERS` (today
  those paths route to the operator's owner accounts — see point 3); routine lanes
  are additionally covered by the AI verdict artifact as compensating analysis.
- Every PR runs the required fast merge suite: `Fast Feedback Gate`,
  confidentiality guard, product-license posture, and PR security gates. A red
  required check is fixed, not redefined. **Changing a gate's definition in the
  same PR the gate is failing on is prohibited** — gate changes ship in their own
  PR, with the rationale in the PR description, and apply to the _next_ change.
- Full-confidence lanes (`openburnbar-pr-harness.yml`, `nightly-e2e.yml`, and
  full CodeQL) run after merge, nightly, or by manual dispatch. They are not
  daily PR blockers, but a red paged nightly older than 24 hours is active repair
  work, not background noise. `nightly-e2e.yml` is the paged core lane:
  production health, full nightly tests, and the commercial launch gate.
- `nightly-dast-sandbox.yml` is a fail-red security sandbox for
  hosted-runner-hostile DAST and privileged live-socket red-team jobs. It records
  failures through the separate `lane:nightly-sandbox` issue key and can never
  keep `lane:nightly-e2e` red. The blocking peer-auth controls remain the
  PR-unit suites until a self-hosted privileged macOS runner is armed.
- Live governance proof is not a screenshot or memory. Run
  `bash scripts/ops/verify-github-governance.sh` before any release or commercial
  launch gate; it reads GitHub's branch-protection and environment APIs and fails
  if admin enforcement, required status checks, code-owner review, stale-review
  dismissal, latest-push approval, zero-bypass policy, or release/production
  environment protection drift.

## Sensitive lanes (where the external code-owner is required)

- Crypto / E2EE lanes (`CloudVault*`, Signal-HPKE, key handling).
- Privileged input: daemon/HID/XPC/socket paths.
- Billing / entitlements (`functions/src/callables/stripe.ts`, `shared.ts`
  entitlement writes).
- Firestore / storage security rules.
- Release / deploy workflows and the provenance manifest
  (`third_party/hermes-agent/`).

A change on any of these is intended to merge only after the paid external
code-owner has approved it, or to ship only after that approval under the
documented release hold — **once that reviewer is wired into `CODEOWNERS`**. Until
then these paths carry the operator's owner code-owners plus the AI verdict
artifact, and adding the external code-owner here is the tracked step that makes
the control real (see point 3). The AI verdict artifact is attached as well, but it
does not substitute for that external approval.

## Break-glass (review gate only — never admin enforcement)

A break-glass merge exists for exactly one problem: the **1 code-owner review is
temporarily unreachable** (e.g. the required code-owner is unavailable during an
active incident). It **never** disables `enforce_admins` and never relaxes branch
protection. It is acceptable only when **all** hold:

1. The change is not on a sensitive lane, **or** the sensitive-lane review is
   deferred to a **documented release hold** — the change may land, but the
   release that ships it is blocked until the external code-owner approves.
2. **All** required status checks (not only the fast suite) report green and
   **none is still pending** — this is the `--admin` preflight below — **without
   any gate definition having changed in the same PR**.
3. The credentialed AI reviewer's verdict artifact ran on the final diff and its
   findings were addressed or dispositioned in the PR.
4. A P0 issue is opened **before** the merge naming the bypassed review gate and
   the compensating review, the bypass window is bounded to the incident, and a
   postmortem is written within 72 hours.

The merge itself is the GitHub-recorded admin path (`gh pr merge --admin`).
`--admin` is **not review-scoped**: GitHub documents it as merging "a pull request
that does not meet requirements"
([`gh pr merge`](https://cli.github.com/manual/gh_pr_merge)), so it bypasses *any*
unmet gate — a red or still-pending required check, a merge-queue requirement, or
unresolved conversations — not only the review requirement. It is bounded to
clearing the **unsatisfiable review gate only** by a mandatory preflight that MUST
pass immediately before it is invoked:

- **Every required status check reports green** on the exact commit being merged —
  none red and **none still pending**. Verify with `gh pr checks <n> --required`
  (which lists only merge-required checks); an empty or non-green result blocks the
  break-glass merge.
- **No other mergeability requirement is outstanding** — conversation resolution is
  satisfied and there is no active merge-queue entry — so the code-owner review is
  the *only* requirement left for `--admin` to clear.

Only when that preflight holds does `--admin` clear the review gate and nothing
else. There is **no** step that disables admin enforcement; a recipe that did so is
banned from the tree by `scripts/ci/check-no-bypass-recipe.sh`, enforced on the
required `guard` lane (`.github/workflows/confidentiality-guard.yml`).

## Never acceptable

- Disabling `enforce_admins` or relaxing branch protection to land work — routine
  or sensitive. The review gate is cleared by the audit-logged break-glass path
  above, never by turning admin enforcement off.
- Treating the AI verdict artifact as the required approval. It is compensating
  analysis; it never merges a PR by itself and never stands in for the external
  code-owner on a sensitive lane.
- Manufacturing a second-human review — a co-owner account approving its own
  team's changes without independent review — in place of the honest compensating
  controls above.
- Marking a launch/security gate "cleared" against an artifact that is not
  durably published (e.g. pinning a commit that exists on no remote — the exact
  failure of commit `e0ba632f5`, reverted hours later).
- Weakening a measuring gate (coverage, lint, provenance, size) in response to it
  firing on your own change. If the gate is _wrong_, fix it in a separate PR that
  states what the gate previously measured and what it measures after.

## Standing rituals (institutional, not heroic)

- **Monday red-run triage**: every scheduled workflow's latest run is reviewed;
  any paged lane red >7 days becomes P0 work with an owner, not background noise.
  Sandbox failures stay under the sandbox-lane budget below unless they become
  release-blocking. Close-on-green automation keeps failure issues honest — never
  close one by hand without a green run or a fix.
- **Nightly lane ownership**: `nightly-e2e` is the paged launch lane (production
  health, full nightly tests, commercial launch gate). `nightly-dast-sandbox` is
  the fail-red hosted-runner sandbox for public DAST, Functions-emulator DAST, and
  live privileged-socket redteam. It has its own `lane:nightly-sandbox` issue
  dedupe so sandbox failures cannot suppress the paged nightly lane. The live
  privileged-socket redteam returns to the paged lane only after a self-hosted
  privileged macOS runner is armed.
- **Sandbox-lane budget**: a security lane may remain separate from the paged
  nightly lane for at most 30 days, then it moves into the paged lane, gets a
  ratcheted baseline, or is deleted. `nightly-dast-sandbox.yml` counts against
  this budget; the intended enforcement path is a self-hosted privileged macOS
  runner for the live socket red-team and reachable DAST targets for ZAP. A lane
  that asserts nothing is removed rather than left green.
- **Quarterly restore drill**: roll back functions + hosting + one Cloud Run
  service and PITR-restore Firestore into a throwaway database from a machine that
  is not the primary operator's laptop, following only the runbooks
  (`docs/RELEASE_ROLLBACK.md`, `docs/runbooks/firestore-disaster-recovery.md`,
  `docs/runbooks/functions-break-glass.md`).

## Why this document exists

Diligence reads the gap between configured and operating controls as the single
most predictive signal about a team. The controls in this repo are real; this
policy makes their operation legible — a solo operator with named compensating
controls (an AI verdict on every PR today, and a paid external code-owner on the
sensitive lanes being stood up), including the documented, bounded break-glass
exception — so an external reviewer can audit _adherence_ instead of inferring
intent from toggle history.
