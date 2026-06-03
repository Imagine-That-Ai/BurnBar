# Make Hermes Gateway truly end-to-end

Goal ID: `hermes-gateway-e2e-rearchitecture`
Started: 2026-06-03T05:14:34Z
Parent goal: privacy-leak-remediation-2026-06-02
Mode: full
Ledger path: `.agent/runs/hermes-gateway-e2e-rearchitecture/`

## Objective

Retire the open keyless bearer-token gateway adapter and route phone<->agent gateway messaging through the first-party encrypted relay (HermesRelayCrypto) so the server can no longer read gateway message/event text, sender names, or attachment files

## Goal Mode Coupling

When creating or updating the matching `/goal`, include this ledger pointer in the goal objective:

`Maintain the agent-owned ledger at /Users/albertonunez/Documents/Windsurf/BurnBar/.agent/runs/hermes-gateway-e2e-rearchitecture/ and keep implementation-notes.html current at checkpoints, before compaction, and before final handoff.`

## Finishing Criteria

- [todo] Define concrete validation before implementation.
- [todo] Keep `implementation-notes.html` current with status, decisions, tradeoffs, changes, validation, and next action.
- [todo] Link large proof artifacts from `evidence/` when they are too bulky for the HTML notes.

## Escape Hatch

Pause, ask the user, or mark a scoped item `[blocked]` / `[incomplete]` if:
- validation contradicts the goal
- the goal requires a scope change
- the agent is looping without measurable progress
- the next step risks deleting or rewriting durable memory
- the PRD and actual repo disagree
- the ledger itself contaminates validation

