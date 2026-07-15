# Alert Triage Sweep — 2026-07-15 (Operation 9, P-OPS-3)

**Scope:** every open `P0 - Critical` / `area: infra` issue as of 2026-07-15,
excluding #1091 (owned by P-OPS-1 — prove the production deploy plane).

**Goal (from `docs/OPERATION_9_PLAN.md` §P-OPS-3):** close the alert→action
loop — zero stale (>30-day) open P0 infra issues without an evidence-backed
disposition.

**Method:** for each issue, pull the original failure run, check the
lane's current `main` run history, and assign one of three dispositions:
`fixed-by-PR` (lane recovered, cite the fixing PRs), `superseded` (a standing
tracker now covers the lane), or `still-failing` (lane is red right now — leave
open with a named owner and blocker). A disposition comment was posted to every
issue; closes used the `completed` state reason.

---

## Evidence table

| Issue | Title | Lane / workflow | Original failure | Disposition | Final state | Evidence |
|-------|-------|-----------------|------------------|-------------|-------------|----------|
| [#304](https://github.com/Imagine-That-Ai/BurnBar/issues/304) | Hosting deploy smoke failed (27346787964) | `deploy-hosting.yml` | [run 27346787964](https://github.com/Imagine-That-Ai/BurnBar/actions/runs/27346787964) 2026-06-11 `failure` | **Superseded** — lane green on `main` | **Closed (completed)** | 4 consecutive `success` runs on `main`: [29372431028](https://github.com/Imagine-That-Ai/BurnBar/actions/runs/29372431028) (07-14), [29208256151](https://github.com/Imagine-That-Ai/BurnBar/actions/runs/29208256151) (07-12), [29208249698](https://github.com/Imagine-That-Ai/BurnBar/actions/runs/29208249698) (07-12), [29186067037](https://github.com/Imagine-That-Ai/BurnBar/actions/runs/29186067037) (07-12). Issue predated per-lane labeling (no `lane:deploy-hosting`), so auto-close never matched it. |
| [#308](https://github.com/Imagine-That-Ai/BurnBar/issues/308) | Nightly E2E launch gate failed (27347248377) | `nightly-e2e.yml` | [run 27347248377](https://github.com/Imagine-That-Ai/BurnBar/actions/runs/27347248377) 2026-06-11 `failure` | **Superseded by #327** — standing tracker covers this lane | **Closed (completed)** | #308 is a one-off (no `lane:nightly-e2e` label, zero recurrence comments). #327 is the standing `lane:nightly-e2e` tracker (21 recurrences, `escalated:72h`). The lane itself remains red — see #327. |
| [#317](https://github.com/Imagine-That-Ai/BurnBar/issues/317) | Firestore deploy gate failed (27396018979) | `deploy-firestore.yml` | [run 27396018979](https://github.com/Imagine-That-Ai/BurnBar/actions/runs/27396018979) 2026-06-12 `failure` | **Fixed-by-PR** (#1572, #1588, #1687) — lane green on `main` | **Closed (completed)** | 4 consecutive `success` runs on `main`: [29372431102](https://github.com/Imagine-That-Ai/BurnBar/actions/runs/29372431102) (07-14), [29256285212](https://github.com/Imagine-That-Ai/BurnBar/actions/runs/29256285212) (07-13), [29256028236](https://github.com/Imagine-That-Ai/BurnBar/actions/runs/29256028236) (07-13), [29255982406](https://github.com/Imagine-That-Ai/BurnBar/actions/runs/29255982406) (07-13). Fixing PRs: #1572 (Firestore rules via firebase-tools + size tripwire), #1588 (repair rules release after 409), #1687 (consolidate rules under backend limit). Issue predated per-lane labeling. |
| [#327](https://github.com/Imagine-That-Ai/BurnBar/issues/327) | Nightly E2E launch gate failed (27414873775) | `nightly-e2e.yml` | 21 recurrences since 2026-06-12 | **Still-failing** — leave open | **Open** | Latest `main` run [29327976769](https://github.com/Imagine-That-Ai/BurnBar/actions/runs/29327976769) (07-14) `failure`; all 5 recent `main` runs red. Failing jobs: `nightly-tests` + `android-e2e` (emulator infra rot). **Owner:** @albertonunez via P-QA-1. **Blocker:** nightly-tests must pass or be split into a required aggregate; android-e2e emulator must boot. |
| [#565](https://github.com/Imagine-That-Ai/BurnBar/issues/565) | Nightly DAST sandbox advisory failed (27763586886) | `nightly-dast-sandbox.yml` | 27 recurrences since 2026-06-18 | **Still-failing** — leave open | **Open** | Latest `main` run [29329821467](https://github.com/Imagine-That-Ai/BurnBar/actions/runs/29329821467) (07-14) `failure`; all 5 recent `main` runs red. Failing jobs: `privileged-socket-redteam` + `dast-functions`. **Owner:** @albertonunez via P-QA-1. **Blocker:** red-team + dast-functions sandbox jobs must be triaged into the required-vs-informational split and root-caused. |
| [#1393](https://github.com/Imagine-That-Ai/BurnBar/issues/1393) | Linux nightly matrix failed (28914776532) | `linux-nightly.yml` | 9 recurrences since 2026-07-08 | **Still-failing** — leave open | **Open** | Latest `main` run [29329918180](https://github.com/Imagine-That-Ai/BurnBar/actions/runs/29329918180) (07-14) `failure`; all `main` runs red. Failing job: `linux-matched-performance` (30-min soak); `linux-surface` skipped as downstream. **Owner:** @albertonunez (Linux port parity; related to P-CQ-1). **Blocker:** `linux-matched-performance` soak must pass on `ubuntu-24.04-arm`. |

---

## Disposition comments posted

Each issue received a structured `## Triage disposition (P-OPS-3 — Operation 9
alert→action sweep, 2026-07-15)` comment with the evidence above. The three
closed issues received an additional closing comment referencing the
disposition. The three open issues received the disposition comment only (no
close) with a named owner and blocker.

| Issue | Comment author | Comment timestamp | Action |
|-------|---------------|-------------------|--------|
| #304 | @Ajnunezg | 2026-07-15T05:50:02Z | Disposition comment |
| #304 | @Ajnunezg | 2026-07-15T05:51:01Z | Closed (completed) |
| #308 | @Ajnunezg | 2026-07-15T05:50:02Z | Disposition comment |
| #308 | @Ajnunezg | 2026-07-15T05:51:02Z | Closed (completed) |
| #317 | @Ajnunezg | 2026-07-15T05:50:02Z | Disposition comment |
| #317 | @Ajnunezg | 2026-07-15T05:51:01Z | Closed (completed) |
| #327 | @Ajnunezg | 2026-07-15T05:51:57Z | Disposition comment (leave open) |
| #565 | @Ajnunezg | 2026-07-15T05:51:57Z | Disposition comment (leave open) |
| #1393 | @Ajnunezg | 2026-07-15T05:51:57Z | Disposition comment (leave open) |

---

## Why three issues were stale (root cause)

Issues #304, #308, and #317 were auto-filed before the per-lane labeling system
(`ops-failure-issue` action with `lane:*` labels) was introduced. When their
lanes recovered, the green-run auto-close step (`mode: close`) matches by lane
label — these issues carried no lane label, so they were never matched and
remained open despite the lane being green. This sweep manually closed them with
per-issue evidence. Going forward, the standing `lane:*` auto-open/close loop
handles each lane.

## Lanes still red (tracked by other packets)

| Lane | Standing issue | Owner packet | Blocker |
|------|---------------|-------------|---------|
| nightly-e2e | #327 | P-QA-1 (Full Harness triage) | nightly-tests + android-e2e emulator infra rot |
| nightly-dast-sandbox | #565 | P-QA-1 (Full Harness triage) | privileged-socket-redteam + dast-functions sandbox |
| linux-nightly | #1393 | Linux port parity (related to P-CQ-1) | linux-matched-performance soak on ubuntu-24.04-arm |

These three issues remain open with a named owner and blocker. The lane
auto-close will fire when the first green run lands.

## Out of scope

- **#1091** (Cloud Functions frozen at 6/18) is owned by P-OPS-1 (prove the
  production deploy plane) and was not triaged here.