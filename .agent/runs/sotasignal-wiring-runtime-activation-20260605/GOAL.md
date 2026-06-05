# SOTASIGNAL items 3-5: production wiring, L41 runtime, activation prep

Goal ID: `sotasignal-wiring-runtime-activation-20260605`
Started: 2026-06-05T14:10:47Z
Parent goal: sotasignal-full-ship-20260605
Mode: full
Ledger path: `.agent/runs/sotasignal-wiring-runtime-activation-20260605/`

## Objective

Wire every real production write path (Pensieve, mobile chats, CLI missions) to produce Signal-sealed payloads; build the L41 runtime (publish/claim prekeys, session metadata, rotation, revocation/rewrap); prepare ring rollout + rollback drill WITHOUT flipping production flags

## Completion Directive (2026-06-05): finish ALL remaining parts, then adversarial audit

Drive every remaining item to `[done]` (or honest `[incomplete]`/`[blocked]` with reason), then run a final adversarial audit over the whole change set. STATUS:
- [done] Item 3 Android CHAT producer + persistent identity store (compile + JVM verified, regression-clean).
- [done] Item 3 Android CLI mission producer (single + fan-out write + Signal-first read + observe; iOS-parity surfaces only) — compile + full JVM suite green.
- [done] Item 4 server L41 runtime (publish/claim/session/rotation + revocation) — adversarially reviewed + 4 fixes; tsc/vitest/rules green.
- [done] Item 5 fail-closed verification: `verify-signal-activation-parity.sh` GREEN — all Signal levers at default, no domain has a signal sealingScheme, no RC flag set (my changeset did NOT flip activation). "Ready, not activated."
- [done] Item 3 Mac (AgentLens) producers — `MacCloudVaultSignalPayloads` + dual-write in `ChatThreadSyncService` (chat_threads) AND `ConversationSyncService` (conversations, via new `ConversationCloudSealer.encodePlaintext`) + Signal-first conversation READ (`ConversationCloudSealer.open` + `DownloadSyncService`) + `keyForReading` now populates signalIdentity. ALL compile-verified in the full macOS app build (xcodebuild BUILD SUCCEEDED x3). Evidence: evidence/mac-producers.md.
- [done] Item 3 on-device Android proof — `AndroidSignalProducerInstrumentedTest` (real libsignal ARM round-trip + Android Keystore identity persistence) PASSED on Galaxy SM-S921U: `connectedDebugAndroidTest` "Finished 2 tests" + BUILD SUCCESSFUL + exit 0 (gradle fails the build on any instrumented-test failure). Apple on-device remains [blocked] (devices offline to Xcode; owned by Codex item 1).
- [done] Item 4 native L41 client stores (IdentityKey/PreKey/SignedPreKey/KyberPreKey/Session) — `OBBSignalProtocolStore` + `OBBSignalPreKeyGenerator` (OpenBurnBarSignalCore). Unblocked via symlinking Vendor/libsignal + xcframeworks from main. swift test 2/2: full X3DH+PQXDH session bidirectional + persistence round-trip. Evidence: evidence/native-l41-stores.md.
- [done] Item 4 low-watermark: `signalPrekeyWatermark` callable + `prekeyReplenishStatus` pure helper (recipient device polls remaining unexpired prekeys). tsc 0, 18 vitest. (claim concurrency emulator test still [incomplete] — admin-SDK emulator harness; device gets counts from publish/claim/watermark.)
- [done] On-device Android instrumented proof PASSED (Galaxy SM-S921U).
- [done] COMMITTED (user said "commit to the branch"): wiring changeset 0766a4e7b on signal/phase2-wiring-runtime (39 files, +3328; gated/inert; parity GREEN).
- [done] ACTIVATION FLIP PREPARED, NOT DEPLOYED (user said "prepare flip commit, don't deploy"): 777781d13 on separate branch signal/phase2-activation-flip — flips conversations_chat + pensieve to signal-hpke-identity-seal-v1 + regen codegen + synced Android copy + evolved guards to a precise allowlist (transport + RC still fail-closed). registry tests 19/19; parity GREEN.
- [blocked] Apple on-device proof (devices offline; Codex item 1) + Item 5 LIVE deploy/ring-rollout/rollback drill — owner-gated; agent will NOT deploy. Deploy target = the flip branch after sign-off.
- [done] Adversarial audits (3 total, 15 confirmed findings, ALL fixed + re-verified):
  - `wf_0fe94bbd-e65` server L41 runtime — 4 fixed (evidence/l41-server-runtime.md).
  - `wf_507333cb-f6c` Android producers — 7 fixed (evidence/android-producer-audit.md).
  - `wf_a7805973-0fb` native L41 stores + Mac producer + watermark — 4 fixed incl. a MAJOR pre-existing iOS self-exclusion bug (evidence/final-audit-fixes.md).

## Goal Mode Coupling

When creating or updating the matching `/goal`, include this ledger pointer in the goal objective:

`Maintain the agent-owned ledger at /private/tmp/burnbar-signal-wiring-20260605/.agent/runs/sotasignal-wiring-runtime-activation-20260605/ and keep implementation-notes.html current at checkpoints, before compaction, and before final handoff.`

## Scope split (coordination)

- This goal owns SOTASIGNAL **items 3, 4, 5 ONLY**.
- A separate gpt-5.5 Codex agent owns items **1 (Apple device proof)** and **2 (native Apple packaging / Vendor/libsignal vendoring)** in worktree `/private/tmp/burnbar-signal-phase2-continue-20260605` on `signal/phase2`.
- This goal runs in an isolated worktree `/private/tmp/burnbar-signal-wiring-20260605` on branch `signal/phase2-wiring-runtime` (off `signal/phase2`@e543dac2) to avoid the proven checkout-collision hazard. Do NOT edit the Codex worktree.
- Shared artifact hazard: `signal-activation-evidence.json` is edited by BOTH agents (Codex: nativePackaging/physicalDeviceE2E; this goal: productionProducerWiring/l41/phaseEActivation). Keep my evidence under THIS ledger; final manifest reconciliation is an explicit handoff, not a unilateral overwrite.

## Finishing Criteria

### Item 3 — Production wiring
- [todo] Every production write path for the 3 target domains produces a Signal at-rest `signalEnvelope` behind the data-domain sealing flag, with Signal-first read + legacy fallback:
  - [todo] Pensieve / knowledge memory (server admin + Mac producer + mobile reader)
  - [todo] Mobile assistant chats (iOS + Android producers/readers)
  - [todo] CLI agent mission requests (producer/reader)
- [todo] Admin validator (`validateSignalAtRestEnvelopeForWrite` or equiv) invoked at every server-side write site, fail-closed.
- [todo] Validation: focused unit + Firestore-emulator tests green; wiring audit doc in `evidence/`.

### Item 4 — L41 runtime
- [done] Server runtime callables: publish public prekeys, claim one-time/Kyber prekeys atomically, record session metadata, record rotation events. `functions/src/callables/signalPrekeyDirectory.ts` (registered in index.ts). Adversarially reviewed (wf_0fe94bbd-e65) + 4 findings fixed.
- [done] Revocation: revoked device's Signal sessions flipped active->revoked (`functions/src/signalDirectoryRuntime.ts`) wired into revokeEscrowDeviceTrust + panic. Rewrap PLANNING (rewrapJobId mint + revocation_rewrap event) via recordSignalRotation.
- [blocked on item 2] Native client stores (PreKeyStore/SignedPreKeyStore/KyberPreKeyStore/SessionStore) + native prekey GENERATION + rewrap EXECUTION — need native libsignal (Vendor/libsignal empty here). Mitigation available: prebuilt xcframework exists in main checkout. Exclude-from-future-wraps is the producer trust-filter (item 3).
- [done] Validation: tsc 0 err; full functions vitest 344 pass/0 fail; rules emulator 50/50. Evidence: `evidence/l41-server-runtime.md`.
- [todo] (P5) low-watermark scheduled job (pure TS); emulator concurrency test for claim double-claim-prevention.

### Item 5 — Activation (DO NOT FLIP FLAGS)
- [todo] Ring rollout + rollback drill tooling verified in dry-run only; production flags remain OFF/fail-closed.
- [todo] Activation evidence for items 3/4/5 sections recorded; final flip explicitly deferred to owner + after items 1-4 complete.

### Cross-cutting
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

