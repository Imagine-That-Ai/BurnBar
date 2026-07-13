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
| `daemon.mission.create` | File new mission | Existing P06 create sheet remains unchanged. |
| `daemon.mission.approve` | Approval card | Existing two-step confirmation for high-risk fixture approvals is preserved. |
| `daemon.mission.cancel` | Explicit cancel action | Requires a second confirmation and sends actor `linux-shell`; terminal missions do not expose the action. |

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
timestamp). The canonical mission snapshot does not expose runtime health, so
the detail view says that health is unavailable rather than inferring health
from freshness.

## Honest limitations

- There is no separate mission history, evidence download, question, or runtime
  health RPC in the canonical mission contract. The UI displays snapshot
  records when present and explicitly labels missing capabilities.
- Packet/result metadata is shown as daemon-provided summaries; Linux does not
  invent task execution or evidence links.
- Live device, connector, and provider execution remain daemon/integration
  concerns and require installed-environment evidence before P-20 can be
  promoted in the parity ledger.

## QA

1. Run `npx vitest run src/tauriBridge.test.ts src/bridgeRpcBehavior.test.ts src/bridgeRpcContract.test.ts src/surfaces/missions/MissionsSurface.test.tsx --reporter=dot`.
2. Run `npx tsc --noEmit` and `npm run build` from `apps/linux-desktop`.
3. Run `cargo fmt --all -- --check` and `cargo test --all-targets` from
   `apps/linux-desktop/src-tauri`.
4. In a packaged shell backed by a live daemon, open Missions, expand a
   mission, verify packets/results/evidence/timestamps, force a detail refresh
   error, and confirm the last list snapshot plus the unavailable-health copy.
5. Cancel a non-terminal mission and verify the second confirmation, actor
   `linux-shell`, daemon state transition, and refreshed list. Verify completed,
   failed, and cancelled missions do not show a cancel action.
