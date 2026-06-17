# Solo-operator merge & control policy

Two consecutive diligence reviews (2026-06-10, 2026-06-11) made the same core
finding: the repository's configured controls (required review, enforce_admins,
quality gates) were being bypassed in practice — 0 human reviews across every
merged PR, `enforce_admins` toggled around merges, and on 06-11 a coverage gate
relaxed to flip a red check on the team's own diff. The artifacts were strong;
the *process integrity* was not. This document is the written policy those
reviews prescribed: when solo-merging is acceptable, what compensates, and what
is never acceptable.

## The default

- `enforce_admins` stays **on**. It is not toggled to merge.
- `CODEOWNERS` defaults to `* @Ajnunezg @emilio3435`, branch protection
  requires one code-owner approval, and there are **zero** standing PR bypass
  allowances. With two writers, that is the deadlock-free two-person review
  policy: the PR author cannot approve their own change, so the other writer
  must approve routine and sensitive paths alike.
- Every PR runs the required fast merge suite: `Fast Feedback Gate`,
  confidentiality guard, product-license posture, and PR security gates. A red
  required check is fixed, not redefined. **Changing a gate's definition in the
  same PR the gate is failing on is prohibited** — gate changes ship in their
  own PR, with the rationale in the PR description, and apply to the *next*
  change.
- Full-confidence lanes (`openburnbar-pr-harness.yml`, `nightly-e2e.yml`, and
  full CodeQL) run after merge, nightly, or by manual dispatch. They are not
  daily PR blockers, but a red paged nightly older than 24 hours is active
  repair work, not background noise. `nightly-e2e.yml` is the paged core lane:
  production health, full nightly tests, and the commercial launch gate.
- `nightly-dast-sandbox.yml` is an advisory sandbox for hosted-runner-hostile
  DAST and privileged live-socket red-team jobs. It records failures through
  the separate `lane:nightly-sandbox` issue key and can never keep
  `lane:nightly-e2e` red. The blocking peer-auth controls remain the PR-unit
  suites until a self-hosted privileged macOS runner is armed.
- Live governance proof is not a screenshot or memory. Run
  `bash scripts/ops/verify-github-governance.sh` before any release or
  commercial launch gate; it reads GitHub's branch-protection and environment
  APIs and fails if admin enforcement, required status checks, code-owner
  review, stale-review dismissal, latest-push approval, zero-bypass policy, or
  release/production environment protection drift.

## When break-glass solo merge is acceptable

A solo merge is no longer a standing path. It is acceptable only as
break-glass, with branch protection changed temporarily and restored
immediately, when **all** hold:

1. The change does not touch a **sensitive surface**: crypto/E2EE lanes,
   privileged input (daemon/HID/XPC/socket), billing/entitlements
   (`functions/src/callables/stripe.ts`, `shared.ts` entitlement writes),
   Firestore/storage security rules, release/deploy workflows, or the
   provenance manifest (`third_party/hermes-agent/`).
2. All required fast merge checks are green **without any gate definition
   having changed in the same PR**.
3. An AI review (e.g. `/code-review`) ran on the final diff and its findings
   were addressed or explicitly dispositioned in the PR description.
4. A P0 issue is opened before the bypass, the bypass window is bounded to the
   incident, and a postmortem is written within 72 hours.

## Sensitive-surface changes (the list in rule 1)

Require one of, in order of preference:

1. A second human reviewer (when one exists on the project).
2. A security-literate external reviewer (advisor/contractor) within 72h of
   merge — the merge may land first only for an active incident, and the
   review is tracked as a P0 issue opened **before** the merge.
3. For genuinely solo periods: an adversarial AI review pass explicitly
   prompted to refute the change's safety claims, attached to the PR, **plus**
   the relevant red-team/integration suite run green and linked (e.g.
   `privileged-socket-redteam` for privileged-input changes,
   `stripeWebhookOrdering` tests for billing).

## Never acceptable

- Toggling `enforce_admins` or branch protection to land routine work.
- Marking a launch/security gate "cleared" against an artifact that is not
  durably published (e.g. pinning a commit that exists on no remote — the
  exact failure of commit `e0ba632f5`, reverted hours later).
- Weakening a measuring gate (coverage, lint, provenance, size) in response
  to it firing on your own change. If the gate is *wrong*, fix it in a
  separate PR that states what the gate previously measured and what it
  measures after.

## Standing rituals (institutional, not heroic)

- **Monday red-run triage**: every scheduled workflow's latest run is
  reviewed; any paged lane red >7 days becomes P0 work with an owner, not
  background noise. Advisory sandbox failures stay under the advisory-lane
  budget below unless they become release-blocking. Close-on-green automation
  keeps failure issues honest — never close one by hand without a green run or
  a fix.
- **Nightly lane ownership**: `nightly-e2e` is the paged launch lane
  (production health, full nightly tests, commercial launch gate).
  `nightly-dast-sandbox` is the advisory hosted-runner sandbox for public DAST,
  Functions-emulator DAST, and live privileged-socket redteam. It has its own
  `lane:nightly-sandbox` issue dedupe so sandbox failures cannot suppress the
  paged nightly lane. The live privileged-socket redteam returns to the paged
  lane only after a self-hosted privileged macOS runner is armed.
- **Advisory-lane budget**: a quality lane may be advisory for at most 30
  days, then it enforces (ratchet baselines are the house pattern) or it is
  deleted. `nightly-dast-sandbox.yml` counts against this budget; the intended
  enforcement path is a self-hosted privileged macOS runner for the live socket
  red-team and reachable DAST targets for ZAP. A lane that asserts nothing is
  removed rather than left green.
- **Quarterly restore drill**: roll back functions + hosting + one Cloud Run
  service and PITR-restore Firestore into a throwaway database from a machine
  that is not the primary operator's laptop, following only the runbooks
  (`docs/RELEASE_ROLLBACK.md`, `docs/runbooks/firestore-disaster-recovery.md`,
  `docs/runbooks/functions-break-glass.md`).

## Why this document exists

Diligence reads the gap between configured and operating controls as the
single most predictive signal about a team. The controls in this repo are
real; this policy makes their operation legible — including the documented,
bounded exceptions — so an external reviewer can audit *adherence* instead of
inferring intent from toggle history.
