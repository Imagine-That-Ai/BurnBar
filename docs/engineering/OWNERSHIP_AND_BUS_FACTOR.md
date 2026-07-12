# Ownership & Bus-Factor De-Risking

> Status: **PLAN / LIVING DOC** (follow-up to the 2026-07-08 diligence review, improvement #1).
> The code-side controls below are shippable now; the residual action (hiring / a second reviewer)
> is an org decision owned by Alberto. This doc exists so that decision is deliberate, not implicit.

## Why this is the #1 diligence risk

The technical foundation scored well (81/100), but the single biggest thing a Series-A technical
diligence team would flag is **not in the code — it's around it**:

| Signal (measured on the repo) | Value |
|---|---|
| Share of commits from the top author | ~86% |
| `fix:` commits (rework of prior work) | ~25.7% |
| Recent commit velocity | 700+ commits/week (AI software-factory) |
| Historical merges to `main` with 0 human reviews | 206 (since structurally addressed) |

Concentration this high is a **key-person dependency**: continuity, knowledge, and judgment sit
with one person plus an agent fleet. That is survivable at this stage but must be a *chosen,
managed* risk with a mitigation plan — which is what an investor wants to see.

## What already reduces the risk (keep + point to in diligence)

- **Governance-as-code**: `governance/branch-protection.main.json` (23 required contexts,
  `enforce_admins: true`), applied as an org-level ruleset with admin escrow held by a *second*
  org owner — this removes the self-serve `enforce_admins` toggle that history shows was abused.
- **Self-testing CI gates** and adversarial rules tests mean a lot of judgment is *encoded*, not
  tribal — a new engineer inherits guardrails, not just prose.
- **Honest, current engineering docs** (`AGENTS.md`, the tech-debt audits, this `docs/engineering/`
  set) lower the onboarding cliff.
- Drift-checks now wired (improvement #10) so "live == committed" for protection + alerting.

## Ownership map (fill in — this is the actionable artifact)

Assign a **primary** and a **backup** human for each subsystem. `backup: —` is a bus-factor hole.

| Subsystem | Path(s) | Primary | Backup |
|---|---|---|---|
| Firestore rules / access control | `firestore.rules`, `firestore-rules-tests/` | Alberto | — |
| E2EE / crypto (CloudVault, libsignal) | `packages/libsignal-*`, `OpenBurnBarCore/.../*Crypto*` | Alberto | — |
| Cloud Functions / billing / entitlements | `functions/` | Alberto | — |
| Swift daemon / MissionControl | `OpenBurnBarDaemon/` | Alberto | — |
| Apple apps (macOS/iOS) | `AgentLens/`, `OpenBurnBarMobile/` | Alberto | — |
| Android | `android/` | Alberto | — |
| Rust remote / iroh | `crates/` | Alberto | — |
| Console (Next.js) | `apps/console/` | Alberto | — |
| Release / deploy / ops plane | `.github/workflows/`, `scripts/ops/` | Alberto | — |

> Every `backup: —` is a named risk. The goal of the next two quarters is zero `—` in the backup
> column for the four **highest-severity** rows (rules, crypto, functions/billing, deploy).

## Plan to close the gap

1. **Hire / assign a second senior engineer** (Alberto — the only step an agent cannot do). Target:
   a second human who can independently review + own at least the four highest-severity subsystems.
2. **Institute mandatory second-human review on the highest-severity paths.** The CI gates already
   block a lot; add a CODEOWNERS entry so `firestore.rules`, `functions/` billing, crypto, and
   `deploy-*.yml` require a review from someone other than the author. (Ships as code — see
   follow-up PR; needs ≥2 humans to be meaningful.)
3. **Onboarding runbook**: a "day-1 to first-safe-merge" guide per subsystem, seeded from
   `AGENTS.md` + `QUICKSTART.md` + this doc. Prove it by having the next hire follow it verbatim.
4. **Bus-factor drill**: quarterly, the backup owner ships one non-trivial change in their subsystem
   unaided. Record it here as evidence the backup is real, not nominal.
5. **Reduce `fix:` rate**: 25.7% rework suggests the fast lane sometimes merges too early. Track the
   `fix:`-to-`feat:` ratio as an ops metric; a falling ratio is evidence review depth is improving.

## Definition of done
Zero `backup: —` on the four highest-severity subsystems; CODEOWNERS enforces cross-person review on
them; the onboarding runbook has been executed by a real second engineer; the bus-factor drill has
run at least once with recorded evidence.
