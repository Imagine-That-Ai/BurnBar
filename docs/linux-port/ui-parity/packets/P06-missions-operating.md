# P06 — Missions / operating controller

**Wave 1 · Route: `missions`.**

## Mission

Mission-control surface: controller summary, mission list with lifecycle states, pending approvals with explicit approve/deny, and the operating action bar. Approval semantics are safety-critical: the UI must render exactly what the daemon reports and never synthesize an approval state.

## Read first

- README §1–§2.
- macOS oracle: `AgentLens/Views/Components/Operating/` (`OpenBurnBarDashboardOperatingSection.swift`, `OpenBurnBarControllerWorkbenchPanel.swift`, `OpenBurnBarOperatingActionBar.swift`, `OpenBurnBarCompactOperatingHomeCard.swift`, `OpenBurnBarOperatingPresentation.swift`).
- Daemon: `BurnBarDaemonServer+RPCMissionControl.swift`, `+RPCRunWorkspaceApproval.swift`.

## Data contract

1. Bridge: `mission_list` → `{ missions: {id,title,state,updatedAt,laneCount}[], pendingApprovals: {id,missionId,summary,requestedAt,risk}[] }`; `mission_approval_decision` (`approve|deny`) mapped to the real approval RPC.
2. Decisions are optimistic-UI **forbidden**: show a pending spinner on the decided row until the daemon confirms, then re-fetch.
3. Fixture: missions in ≥4 lifecycle states + 2 pending approvals (one high-risk).

## Files

`src/state/missionsStore.ts`; `src/surfaces/missions/` (`MissionsSurface.tsx`, `MissionRow.tsx`, `ApprovalCard.tsx`, `ControllerSummary.tsx`) + tests; one-line `SurfaceRouter` edit; `app.css` `/* ---- P06 missions ---- */`.

## Build steps

1. `ApprovalCard` first (highest stakes): summary, risk badge (tier tokens; high-risk uses `--color-seal-crimson` accents), requested-at, Approve (`.primary`) / Deny (`.ghost`) with confirmation for high-risk ("Type the mission id to approve" is NOT needed — a two-step confirm button is).
2. `MissionRow`: state badge (`StatusPill` tones), title, lane count, relative time; rows group by state (Active / Blocked / Done).
3. `ControllerSummary`: compact stat strip (active, pending approvals, blocked) at the top.
4. Poll pending approvals every 30s while the route is visible; stop on unmount and when `document.hidden`.

## Required states

Populated / Loading / Empty ("No missions — dispatch from the daemon or a paired device") / Error + retry / Offline; approval sub-states: pending-decision spinner, confirmed, decision-failed banner (with the daemon's error text).

## A11y / Perf / Tests

- Approve/Deny are real buttons with names including the mission title; decision results announced `aria-live="assertive"` (safety event).
- Tests: decision flow with fake bridge (success + failure), no optimistic state, poll lifecycle start/stop, grouping, five states.

## Done / Forbidden

README §4. Forbidden: optimistic approval state; auto-approve defaults; polling while hidden; synthesizing mission states not in the daemon vocabulary.
