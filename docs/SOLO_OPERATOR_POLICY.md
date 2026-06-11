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
- Every PR runs the full required-check suite. A red required check is fixed,
  not redefined. **Changing a gate's definition in the same PR the gate is
  failing on is prohibited** — gate changes ship in their own PR, with the
  rationale in the PR description, and apply to the *next* change.

## When a solo merge is acceptable

A solo merge (no second human review) is acceptable only when **all** hold:

1. The change does not touch a **sensitive surface**: crypto/E2EE lanes,
   privileged input (daemon/HID/XPC/socket), billing/entitlements
   (`functions/src/callables/stripe.ts`, `shared.ts` entitlement writes),
   Firestore/storage security rules, release/deploy workflows, or the
   provenance manifest (`third_party/hermes-agent/`).
2. All required checks are green **without any gate definition having changed
   in the same PR**.
3. An AI review (e.g. `/code-review`) ran on the final diff and its findings
   were addressed or explicitly dispositioned in the PR description.

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

- Toggling `enforce_admins` or branch protection to land a change.
- Marking a launch/security gate "cleared" against an artifact that is not
  durably published (e.g. pinning a commit that exists on no remote — the
  exact failure of commit `e0ba632f5`, reverted hours later).
- Weakening a measuring gate (coverage, lint, provenance, size) in response
  to it firing on your own change. If the gate is *wrong*, fix it in a
  separate PR that states what the gate previously measured and what it
  measures after.

## Standing rituals (institutional, not heroic)

- **Monday red-run triage**: every scheduled workflow's latest run is
  reviewed; any lane red >7 days becomes paged work (a P0 issue with an
  owner), not background noise. Close-on-green automation keeps failure
  issues honest — never close one by hand without a green run or a fix.
- **Advisory-lane budget**: a quality lane may be advisory for at most 30
  days, then it enforces (ratchet baselines are the house pattern) or it is
  deleted. A lane that asserts nothing is removed rather than left green.
- **Quarterly restore drill**: roll back functions + hosting + one Cloud Run
  service from a machine that is not the primary operator's laptop, following
  only the runbooks (`docs/RELEASE_ROLLBACK.md`,
  `docs/runbooks/functions-break-glass.md`).

## Why this document exists

Diligence reads the gap between configured and operating controls as the
single most predictive signal about a team. The controls in this repo are
real; this policy makes their operation legible — including the documented,
bounded exceptions — so an external reviewer can audit *adherence* instead of
inferring intent from toggle history.
