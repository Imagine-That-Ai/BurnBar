# P-20 Linux Missions Parity

## Scope

The Linux missions surface consumes the canonical BurnBar mission-control
contracts from `OpenBurnBarCore`. The list, detail, approval, create, and
cancel paths are daemon-owned; the renderer never fabricates mission state or
history records.

## Canonical coverage

| Contract | Linux surface | Notes |
| --- | --- | --- |
| `daemon.mission.list` | Mission runway, filters, approvals | Snapshot approvals are projected into pending approval cards when the list response does not carry a separate approval array. |
| `daemon.mission.get` | Expandable mission detail | Uses `missionID`; detail is refreshed on expansion and falls back to the last list snapshot if the refresh fails. |
| `daemon.mission.health` | Runtime health and controller history | Reads authoritative projection state, active packet and failed result counts, last activity, and deterministically ordered packet/result/burn/takeover history. |
| `daemon.mission.create` | File new mission | Existing P06 create sheet remains unchanged. |
| `daemon.mission.approve` | Approval card | Existing two-step confirmation for high-risk fixture approvals is preserved. |
| `daemon.mission.cancel` | Explicit cancel action | Requires a second confirmation and sends actor `linux-shell`; terminal missions do not expose the action. |
| `daemon.mission.packet.dispatch` | Daemon/controller execution record | The installed proof dispatches typed packets through the daemon; Linux displays the resulting packet/task state without fabricating a renderer-side lifecycle. |
| `daemon.mission.result.record` | Results, evidence, burn, and PR linkage | The installed proof records successful and failed results and verifies their exact persisted evidence references after daemon restart. |
| `daemon.question.list` | Pending operator questions | Linux requests the canonical pending-question projection, validates bounded typed fields, and presents project, priority, context, evidence, due date, and suggested answers. |
| `daemon.question.answer` | Operator answer workflow | Free-form and suggested answers are committed with actor `linux-shell`; the UI reloads only after the daemon accepts the mutation and surfaces failures without optimistic removal. |

## Snapshot fields

The typed mapper preserves fields present in `BurnBarMissionSnapshot`:

- identity and lifecycle: `id`, `projectSlug`, `title`, `summary`, `status`,
  `recommendation`, `createdAt`, `updatedAt`;
- approval: `approved`, `approvedAt`, `approvedBy`, `note`;
- execution: packet/task identity, worker, objective, status, run IDs, and
  dispatch/completion timestamps;
- results: status, summary/detail, burn delta, result timestamp, evidence
  references, and PR linkage;
- operational records: burn records, takeover history, and metadata.

Freshness is a renderer-derived label from `updatedAt` (`fresh` for updates in
the last five minutes, `stale` otherwise, `unknown` for an invalid/missing
timestamp). Runtime health is separate daemon-owned state from
`daemon.mission.health`; the Linux renderer never infers health from freshness.

## Honest limitations

- Mission health and ordered operational history are canonical daemon RPC
  output. Evidence remains a reference carried by mission results rather than
  a separate download RPC. Controller questions use their canonical
  `daemon.question.*` contracts and are shown alongside mission approvals.
- Packet/result metadata is shown as daemon-provided summaries; Linux does not
  invent task execution or evidence links.
- Start/resume/takeover execution remains controller-owned. Linux presents
  disabled guidance for those controls while supporting its canonical mission
  create, approve, cancel, inspect, health, and history operations.
- P-20 remains open until one exact installed candidate proves active, failed,
  terminal, restart/reconnect, UI accessibility, and screenshot evidence.

## QA

1. Run `npx vitest run src/tauriBridge.test.ts src/bridgeRpcBehavior.test.ts src/bridgeRpcContract.test.ts src/surfaces/missions/MissionsSurface.test.tsx --reporter=dot`.
2. Run `npx tsc --noEmit` and `npm run build` from `apps/linux-desktop`.
3. Run `cargo fmt --all -- --check` and `cargo test --all-targets` from
   `apps/linux-desktop/src-tauri`.
4. In a packaged shell backed by a live daemon, open Missions, expand a
   mission, verify packets/results/evidence/timestamps and daemon-owned
   health/history, force a detail or health refresh error, and confirm the last
   list snapshot remains available with an explicit error.
5. Cancel a non-terminal mission and verify the second confirmation, actor
   `linux-shell`, daemon state transition, and refreshed list. Verify completed,
   failed, and cancelled missions do not show a cancel action.
6. Restart the daemon and shell, then verify active, failed, completed, and
   cancelled mission snapshots, evidence references, health counters, and
   ordered history are unchanged.
7. Create a pending controller question with context, evidence, due date, and a
   suggested option; answer it from Linux, verify actor and selected-option
   persistence, confirm it leaves the pending inbox, and verify empty,
   oversized, stale, and concurrent answers fail closed.
