# Kotlin generate-and-consume for relay payload types

Goal ID: `kotlin-relay-codegen-2026-06-15`
Started: 2026-06-15T12:41:02Z
Parent goal: none
Mode: full
Ledger path: `.agent/runs/kotlin-relay-codegen-2026-06-15/`

## Objective

Make the Android Kotlin relay payload types schema-generated from relay-message-types.json so Swift<->Kotlin drift is structurally impossible, completing all phases (A: byte-faithful safe types; B: enum-case fixes; C: date-regime flips; D: @EncodeDefault breadth) with gradle + prover verification.

## Goal Mode Coupling

When creating or updating the matching `/goal`, include this ledger pointer in the goal objective:

`Maintain the agent-owned ledger at /private/tmp/bb-kotlin/.agent/runs/kotlin-relay-codegen-2026-06-15/ and keep implementation-notes.html current at checkpoints, before compaction, and before final handoff.`

## Finishing Criteria

- [done] Phase A: emitKotlinRelayTypes generates byte-faithful Kotlin for the ~52 safe types; kotlin-roundtrip prover reports faithful; generate-and-consume (hand-written replaced); `:openburnbar-iroh-relay:testDebugUnitTest` green + `:app:compileDebugKotlin` green.
- [done] Phase B: 3 missing enum cases (RemoteUnlockBackend, SystemPermissionKind) generated + atomic consumer `when` arms; gradle green.
- [todo] Phase C: 3 date-regime flips + producer/consumer migration + intent-hash-unchanged resign test; gradle green.
- [todo] Phase D: @EncodeDefault breadth + encode-byte prover (Kotlin key-set == Swift key-set).
- [todo] codegen idempotent (node codegen.mjs && git diff --exit-code) + drift gate wired (incl. Swift Generated dir gap).
- [todo] Keep implementation-notes.html current at each phase checkpoint.

## Escape Hatch

Pause, ask the user, or mark a scoped item `[blocked]` / `[incomplete]` if:
- validation contradicts the goal
- the goal requires a scope change
- the agent is looping without measurable progress
- the next step risks deleting or rewriting durable memory
- the PRD and actual repo disagree
- the ledger itself contaminates validation

