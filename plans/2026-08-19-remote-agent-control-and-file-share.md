# Remote Agent Control + Two-Way File Share — Implementation Plan (v3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Do not open ~25 slice PRs. Ship the three themed PRs below. Fast checks stay on the door; the Mac app build is nightly, not a merge ticket.

**Goal:** A trusted phone can drive every executable Mac agent, share files both ways, and approve or interrupt work — without the live mission pipeline remaining forgeable, unthrottled, or last-writer-wins.

**Architecture:** The Mac daemon remains the sole attenuation authority (`BurnBarRemoteMissionAuthorizationPolicy.evaluate`). Firestore is a sealed courier, not a policy engine. Create, claim, host status, and cancel become Admin-SDK callables with transactional preconditions. The file plane is a new `burnbar_attachments` collection with OBFS1 chunked AEAD, Storage finalize-once, and quotas from GCS object metadata. New backends ship only after an ACP-vs-argv decision record.

**Tech Stack:** Firestore + Cloud Functions (`onCallProduction`), Firestore emulator rules tests, GCS compose, CryptoKit / Android AEAD KATs, Swift/Kotlin/C# catalog fixture, iroh P2P, iOS background `URLSession`, Android `CoroutineWorker` + `dataSync` FGS, existing `respondMissionApproval` / `requireTrustedDeviceActionProof` stack.

**Spec:** This document is the spec. It supersedes Claude’s v2 (`~/.claude/plans/extend-the-wonderful-and-purrfect-cocoa.md`, SHA `4e64d608…`) and the revised v2 that was adversarially audited on 2026-08-19. It also absorbs the independent Codex HOLD of that Claude plan (session `17321198-e7e1-4fde-91ae-2c74a4cb7537`) where Codex was right, and rejects Codex where it overbuilds. Grounded in the current tree, not in seeded “trust these facts.”

**Lane:** Structured large. Each of PR-A / PR-B / PR-C is one reviewable coherent unit. The PR body must include a review map, invariants, validation matrix, and rollback notes.

## Global Constraints

- Cheap + fast + quality (2026-08-15): fewer fatter PRs, one theme per PR, fast checks on the door, Mac app build is nightly.
- No new lint/type suppressions without an inline `reason:` token.
- TypeSpec-first for new Firestore models (`tools/schema-sync/`). Existing stub: `tools/schema-sync/typespec/domains/missions.tsp`.
- Every new Firestore collection and Storage prefix is registered in `functions/src/callables/dataExport.ts` `DATA_DOMAIN_PATHS` **and** `packages/data-domains/registry.json` in the same PR. Objects live under `users/{uid}/` or they survive erase.
- Do not write “server learns nothing,” “server never saw,” or “zero-knowledge.” Signal-honesty CI already rejects that phrase (`docs/signalification/REMAINING_SIGNAL_WORK_HANDOFF.md`). Size, timing, chunk count, and generation still leak.
- Do **not** implement on the `#2356` worktree. That PR is an open dirty draft (nav / inbox / fleet). Build from latest `main`. `#2356` is rebase hygiene after it lands, not a launch pad.
- Daemon `evaluate` never-widens. Functions must not recompute `grantCeiling`.
- Loopback is not authentication.
- File-chunk AEAD uses **random 12-byte IVs stored with the chunk** (same as `MediaFrameAEAD` / CloudVault). Do not HKDF-derive AES-GCM nonces from content hash. KATs freeze the nonce. A retry of a chunk mints a new IV.
- Quotas and integrity come from GCS `getMetadata`, never from client-declared manifest fields.
- Tolerant relay decode ships before any new wire kind is emitted.
- `canceled` (callable deny path) and `cancelled` (mobile cancel path) stay distinct spellings. Do not “normalize” them into one wire value without a dual-read migration.
- Do not treat Cursor Approval Agent output as merge evidence.

---

## 0. What v3 changes and why

The v2 draft named the right failure modes and then prescribed closes that do not close them. v3 keeps the product decisions and replaces the broken closes.

| # | v2 said | Live fact | v3 close |
|---|---------|-----------|----------|
| 1 | Client `runTransaction` makes claim exactly-once | Claim is `setData(merge:)` with no pending precondition (`CLIAgentMissionRequestListener+Handling.swift:368-388`). `allow update` is `ownerWritableNonSecret` plus `validTrustedMissionHostUpdate`, which only requires the *document’s* `claimedBy` to name some trusted Mac — not that the writer is that Mac (`firestore.rules:2557-2709`) | Admin-SDK `claimCliAgentMission` / `updateCliAgentMissionStatus` behind `requireTrustedDeviceActionProof`. Drop client host updates. Transaction: status `pending` and `claimedBy` absent |
| 2 | Losing Mac `fail()` is a race footnote | `fail()` merges `status:"failed"` without sending `claimedBy` (`+ApprovalFlow.swift:72-88`). After a winner has claimed, merge keeps the winner’s `claimedBy` and overwrites `status`. Any owner token can do this, not only a sibling Mac | Host status writes are callable-only. Losing `fail()` without the claim nonce / attested device id is denied. Emulator: two-Mac race + post-claim owner `fail()` |
| 3 | Copy `publicRateLimit.ts` onto `users/{uid}/_rate_limits` and `get()` it from rules | `incrementRateLimitsAtomically` writes `public_rate_limits/{docId}` (`publicRateLimit.ts:166-169`). `users/{uid}/_rate_limits` is Admin-only (quota / provider-connect). Rules cannot increment. There is no `mission_create` action | `createCliAgentMission` callable increments `mission_create_burst` (10/min) and `mission_create_hourly` (60/hour) on `public_rate_limits`. Client `allow create` becomes false in the same PR |
| 4 | `writeSignalAtRestDocument` is out of scope | That callable Admin-SDK `batch.set`s `cli_agent_mission_requests` with no pending precondition, no rate limit, and `claimedBy` / `approvalStatus` in the allowed key set (`writeSignalAtRestDocument.ts:17-125`). It can overwrite a live mission | Mission writes leave this callable. Create with an optional `signalEnvelope` goes through `createCliAgentMission` only |
| 5 | Cancel precondition `{pending, accepted, running, waiting_for_approval}` | Mac writes `status:"starting"` after claim (`+Handling.swift:425`). `validMobileMissionCancel` never inspects current status (`firestore.rules:2656-2666`). T10 only cancels a fresh pending doc (`test-firestore-rules.mjs:4673-4709`) | Cancel callable (or rules + callable) requires current status ∈ `{pending, accepted, starting, running, waiting_for_approval}`. Emulator: cancel-after-completed/failed/canceled deny |
| 6 | Functions recompute `attenuatedCapabilityDigest` at redeem | Grant ceilings live only in daemon `grantCeiling` (`MissionControlRemoteAuthorization.swift:128-140`). Functions have no policy replica | Pre-auth is Mac-signed. Server verifies the signature against the pinned Mac key and compares hashes. It does not re-evaluate |
| 7 | Catalog-generated allowlists in PR-1; catalog in PR-9 | That is a cycle. Standing rule forbids ~25 slices | One catalog JSON fixture in PR-A. Generated allowlists for create + events + mirrors + receipts ship in the same PR. A catalog row is not a launch path |
| 8 | Wire five `scripts/mobile-parity/*.mjs` into `fast-feedback.yml` | `schema-drift` already runs `check-drift.sh`, which already invokes those validators plus `validate-mobile-parity.mjs --allow-blocked` | Do not add a redundant job. `--allow-blocked` means blocked ledger rows do not fail the door — do not claim they do |
| 9 | PR #2356 is the v1 vehicle this work rebases onto | #2356 is nav / AI Inbox / read-only fleet — not mission integrity | Rebase hygiene only. Not a functional gate for PR-A |
| 10 | `blobHash` as landing / quota key | Live P2P `blobHash` is the iroh ticket string (`MediaFileTransferService`). Rules only require a string | New field `contentBlake3`. Treat as client-declared until a Mac-side verifier exists |
| 11 | Copy gateway finalize | Second finalize of an already-`uploaded` manifest returns 200 without re-checking the object (`hermesGatewayAttachmentRoutes.ts:265-270`). Signed PUT remains valid after “finalize” | `ifGenerationMatch: 0` on compose/finalize. Uploaded + generation pin is the only idempotent success. Part URLs die at finalize |
| 12 | Deterministic per-chunk nonces derived from `(key ‖ attachmentId ‖ chunkIndex)` | Production seal paths (`MediaFrameAEAD`, CloudVault) use **random** 12-byte IVs. HKDF-derived IVs add a retry-reseal footgun and diverge from every live AEAD | Random IV per chunk, stored with ciphertext. New `begin` ⇒ new `attachmentId` + new content key. KATs freeze the nonce like `MediaFrameAEADVector.json` |
| 13 | Raise P2P to 2GB after OBFS1 in a later PR | Seal cap is 64MiB in memory (`MacFileTransferService.swift:33`). Fetch cap is 512MiB (`IrohBlobBackend.swift:81`). A blob in (64MiB, 512MiB] fetches then dies at seal | Streaming seal, both constants, and the 2GB raise live in PR-B. No raise without streaming seal |
| 14 | Swift-only fx rebase | Windows `SwitcherCLIProfileType` ends at `Pi` (`SwitcherModels.cs:35-49`). Swift has 15 cases including `junie`, `prime-agent`, `fx` | Pre-flight asserts all six vocabularies **plus** the Windows switcher enum |
| 15 | Invent Android `CLIAgentTranscriptView` | Mirrored CLI history already renders in Hermes Square | Extend that surface or document a ledger divergence row. Do not invent a second transcript |

---

### What this v3 took from the Codex HOLD of Claude’s v2 — and what it rejects

Codex’s audit of `extend-the-wonderful-and-purrfect-cocoa.md` (Claude session `17321198…`, PR head `e88ef3e563`) is **HOLD / NO-GO** on that 24-PR plan. Most of that HOLD is correct. This document is the rewrite they asked for, not a defense of Claude’s DAG.

**Taken (Codex was right):**

- Claim/authorize order: exclusive ownership **then** daemon evaluate. Claude and the first v3 draft left evaluate-before-claim in place.
- Relay timeout fallback (`CLIAgentMobileChatService` `:148-203`) starts a **second** execution. Shared `remoteCommandID`; no automatic fallback after an ambiguous timeout.
- `approvedByDeviceId` (callable) vs `approverDeviceID` (daemon read) is a live nil. One wire name.
- Device proofs are **possession**, not presence. Do not write “user is provably present.”
- `clientThreadID` is a GUI thread, not a provider session. `resumeAction:"continue"` is not native resume for grok/kimi/gemini.
- GCS compose is 32 sources; Storage emulator **omits compose**; lifecycle can lag 24h; signed URLs are bearer tokens.
- 20GiB/file vs 10GiB/day is a contradiction. File cap is 10GiB until a reservation ledger exists.
- Android 16: UIDT for user-started large transfers. `ACTION_SEND` is an Activity. iOS user force-quit **cancels** background `URLSession` work.
- DSR: new collections/prefixes in `dataExport.ts` + `registry.json` in the same PR.
- Signal-honesty: never “server learns nothing.”
- Kimi `-p` auto-approves tools. Gemini `-p` requires the prompt. Official grok is `grok -p`, not `--prompt-file`.
- Claude’s 24-PR DAG and “v1 landed” are false. `#2356` is an open dirty draft, not a baseline.

**Rejected (Codex overbuilt or sequenced wrong):**

- A new **command-ledger collection** replacing `cli_agent_mission_requests`. Server-owned callables + `remoteCommandID` on the existing doc close LWW without a second state machine. A sibling ledger is a migration, not a security primitive.
- **Fourteen sequential land steps.** Standing rule is fewer fatter PRs. The extra invariants live *inside* A/B/C, not as 14 tickets.
- **Wait for `#2356` to go green** before integrity work. That PR is nav/inbox/fleet. Do not implement *on* its worktree. Do not block PR-A on it.
- **Biometrics on every approval mint.** High-risk (`commandsAllowed || fileEditsAllowed`) only. Routine read-only stays device-possession, labeled honestly.
- **Porting `evaluate` to Functions** was already rejected; Codex agrees. Keep that.
- Treating “never last-write-wins” as requiring Firestore offline to become a queue. Once client writes are denied, LWW among phones is gone. The remaining race is two callables, which transactions already serialize.

---

## 1. Trust model (non-negotiable)

```
phone (trusted escrow, App Check, Pro)
        │  sealed create / cancel / approval
        ▼
Cloud Functions (Admin SDK)
        │  courier + rate limit + claim lock + Storage tickets
        ▼
Firestore / GCS          (not a policy engine)
        │
        ▼
Mac listener ──► daemon evaluate() ──► grantCeiling (never wider)
        │
        ▼
CLI / ACP session        (daemon owns approvals; no --yolo / allow_always)
```

Docs and the threat model must say: **the server trusts the attested Mac and never re-evaluates daemon policy.** ADR 009 already made the Mac the control-plane trust root for Computer Use. This program extends that to mission dispatch and file landing.

Honest residual: a compromised trusted Mac can run what the daemon would allow that Mac to run. That is in-scope for the product. A compromised owner token, a second Mac, or Firestore tamper must not be able to steal, cancel-after-complete, or self-approve a mission.

---

## 2. Ground truth (verified in-tree)

### 2.1 Mission collection

`users/{uid}/cli_agent_mission_requests/{requestId}` (`firestore.rules:2326-2709`).

- Create: `ownerWritableNonSecret` + sealed payload v2 + `status == "pending"` + no `claimedBy` / approval / started fields (`validCliAgentMissionCreate`).
- `requestedRuntime` is any non-empty ≤80-character token (`validCliMissionRuntime` → `validCliMissionMetadataToken`).
- Update is the disjunction of four predicates: `validTrustedMissionHostUpdate`, `validMobileMissionApprovalResponse`, `validMissionRefusalOrFailureUpdate`, `validMobileMissionCancel`.
- Host update may not write `approvalStatus` in `{approved, rejected}`. That is reserved for `respondMissionApproval`.
- Cancel does not read current status.
- `resumeAction` already allows `"continue"` in rules (`firestore.rules:2383-2385`). The TS union in `functions/src/types/legacy/media.ts:470` does not.

### 2.2 Writers today

| Writer | Path | Integrity |
|--------|------|-----------|
| iOS `CLIAgentMissionDispatcher.dispatch` | client `batch.setData` of request + `events/000001`; or `writeSignalAtRestDocument` when Signal-at-rest is on | Unthrottled |
| Android `CLIAgentMissionDispatcher` | same collection; Signal path comments say direct `signalEnvelope` batch writes are never attempted | Unthrottled |
| Mac `CLIAgentMissionRequestListener` | `setData(merge:)` claim / starting / fail / approval-request | Non-transactional; `fail()` omits `claimedBy` |
| iOS `cancelMission` | client merge `status:"cancelled"` + sealed state | No current-status check |
| `respondMissionApproval` | Admin-SDK transaction; requires `status == waiting_for_approval` and `approvalStatus` pending | Sound for *resolution*; does not mint pre-auth |
| `writeSignalAtRestDocument` | Admin-SDK `batch.set` of up to 100 mission docs | Overwrite, unthrottled, allows `claimedBy` / `approvalStatus` |
| Windows `FirestoreMissionDispatchHost.RespondToApprovalAsync` | client merge `approvalStatus` approved/rejected and `status` running/rejected | Live rules mismatch — `validTrustedMissionHostUpdate` forbids those approval values |

### 2.3 Claim contrast

Hermes relay no-ops unless `status == pending`, then claims inside `db.runTransaction` (`HermesRelayHostService.swift:807-825`). Mission dispatch does not.

`requestApproval` already writes `claimedBy` (`+ApprovalFlow.swift:164-177`). Waiting-for-approval is a claim, not a pre-claim state.

Live statuses the Mac actually writes include `starting` (`+Handling.swift:425`).

### 2.4 Rate-limit surfaces

- `public_rate_limits/{docId}` — `publicRateLimit.ts`. Actions exist for VoIP, knowledge search, agent-notification reply, Hermes gateway attach init, approval-fail. **No `mission_create_*`.**
- `users/{uid}/_rate_limits/*` — Admin-SDK only (hosted quota, provider-connect refresh). No client match block.

### 2.5 Approvals

`respondMissionApproval` (`agentGrantCallables.ts:593-683`): nonce + `enforceHighRiskComputerUseCallableWithNonce` + Pro entitlement + `requireTrustedDeviceActionProof` (`computer_use_mission_approval`, phone platforms) + transaction. App Check is config-gated (`enforceAppCheck: getConfig().enforceAppCheck`). There is no `mission_approval_answers` collection.

Daemon `grantCeiling` ANDs requested flags with persona scope and filters `additionalCapabilities` against an empty recognized set (`MissionControlRemoteAuthorization.swift:128-140`).

Session actions are `resume` / `handoff` / `package_only` (`HermesConnectionTypes.swift:444-448`). The only halt is Computer Use `panicHalt`.

Mobile OS policy allowlists host `mission` and push types `mission` / `mission_update` — not host `approvals` or type `mission_approval` (`MobileOsIntegrationPolicy.swift:124-139`).

Linux desktop already has `missionApprovalDecision` → `mission_approval_decision` (`apps/linux-desktop/src/tauriBridge.ts:307-308`).

iOS keys `localApprovalResolutions` by mission id and drops the entry when `approvalRequestId` changes (`MobileMissionConsoleHost.swift:463-478`). Android rebuilds the approval queue from `dismissedTerminalIDs` only (`MobileMissionConsoleHost.kt:221-229`). Re-show on listener re-emission is a live Android bug.

### 2.6 Catalog drift

| Vocabulary | Membership (current tree) | Missing vs the others |
|------------|---------------------------|------------------------|
| `SwitcherCLIProfileType` (Swift) | 15: codex, claude, opencode, droid, forge, antigravity, grok, cursoragent, omp, gemini, kimi, pi, junie, prime-agent, fx | — |
| `SwitcherCLIProfileType` (Windows) | 12: ends at `Pi` | junie, prime-agent, fx |
| `ChatBackendID` | 13: no grok / kimi / gemini / opencode / ollama | grok, kimi, gemini |
| `AssistantRuntimeID` (Swift) | 14: has grok, openclaude, omp, junie, fx; no kimi / gemini | kimi, gemini |
| `AssistantRuntimeID` (Android `PiConnectionModels.kt`) | 12: no OPEN_CLAUDE, OMP, KIMI, GEMINI | openclaude, omp, kimi, gemini |
| `BurnBarFleetAgentID` | 10 declared: claude-code, factory-droid, codex, hermes, grok-bot, grok-cli, pi, cursor, kimi, gemini-cli | not a chat-backend roster |
| `CLIAgentRuntime` | 11: no hermes / pi (intentional), no kimi / gemini | kimi, gemini |

`CLIAgentRelayChatExecutor.backend(for:)` maps antigravity/agy/fx/junie/omp and returns nil for grok / kimi / gemini / openclaude (`CLIAgentRelayChatExecutor.swift:674-702`).

Planner `resolve` maps `grok|grok-build|xai|grok-agent` to a raw `"grok"` backend (`+Planner.swift:39-40`). `directLaunchPlan` has no grok / kimi / gemini case and returns nil.

Event / mirror / receipt allowlists include grok and omit openclaude / omp / junie / kimi / gemini (`firestore.rules:2160, 2206, 2797, 3559, 3998`). Creates succeed; later writes drop.

`ALLOWED_GRANT_RUNTIMES` in `agentGrantCallables.ts:60-73` is a sixth list and also omits the new tokens.

### 2.7 File plane

- P2P fetch cap: 512MiB (`IrohBlobBackend.swift:80-81`).
- Mac at-rest seal cap: 64MiB, `Data(contentsOf:)` one-shot (`MacFileTransferService.swift:33`).
- `PlatformCrypto.sealAESGCMDetached` can take a caller nonce (`PlatformSupport.swift:210-223`) but the default path lets CryptoKit pick the IV.
- No `FileSealAEAD.swift`. No `MacAttachmentLandingService`.
- `AgentContextTargetReceiver` hardcodes `attachments: []` (line 212).
- Gateway attachments: 50MiB (`hermesGatewayCore.ts:22`). Finalize of `uploaded` returns 200 without `assertFinalizedObjectMatchesManifest`. Reaper `reapHermesGatewayApprovals` sweeps approvals, not attachment objects. Storage delete is revoke-path only.
- `storage.rules` do not allow client uploads of these bodies; signed URLs only.
- KAT machinery exists: `OpenBurnBarCore/Tests/OpenBurnBarMediaTests/Fixtures/MediaFrameAEADVector.json` + Kotlin twin. MediaFrameAEAD is single-shot, not chunked.
- iOS: no `URLSessionConfiguration.background` in the product surface.
- Android workers: `NetworkType.CONNECTED` only; no `FOREGROUND_SERVICE_DATA_SYNC`.

### 2.8 Relay decode

`CLIAgentRelayChatEventKind` is `{assistantSnapshot, completed, failed}`. `CLIAgentRelayChatTransport` latches the first JSON decode failure and kills the stream (`OpenBurnBarMobile/Services/CLIAgentRelayChatTransport.swift:148-159`).

### 2.9 CI

`.github/workflows/fast-feedback.yml` `schema-drift` → `./tools/schema-sync/check-drift.sh` already runs the mobile-parity scripts listed in v2 PR-0b, with `--allow-blocked`. `check-mobile-product-vectors.mjs` is local-only.

A11y `PRIMARY_SURFACES` are Pulse / Burn / Hermes / Inbox / Store (`check-mobile-a11y-performance.mjs:20-35`). MissionControl and CLIAgents dirs are absent.

---

## 3. Product decisions (owner-locked)

Unchanged from v2:

1. Full drive from a trusted phone.
2. Offline-first: commands and approval intents queue durably; multi-GB files use the chunked cloud path.
3. File share both ways.
4. Trusted-phone + daemon attenuation. No silent auto-pilot.
5. Every executable backend, after the ACP decision record.

Census is taken from the catalog fixture in PR-A, not from a remembered “18”.

---

## 4. Scope inventory

### In scope

- Mission create / claim / cancel / host-status integrity.
- One generated runtime catalog consumed by rules, Functions, Swift, Kotlin, C#.
- Honest `mac_interactive_cli` routing and typed unknown-mode failure.
- Windows approval path aligned with `respondMissionApproval`.
- OBFS1 + `burnbar_attachments` callables + GCS compose hierarchy + reaper (including existing gateway leak).
- Mac landing service + wire `attachments: []`.
- iOS background uploads + Android long-running `dataSync` worker.
- P2P cap raise to 2GiB only after streaming seal.
- Artifact return phone ← Mac.
- Share targets last.
- Tolerant relay decode, then `interrupt`, then new event kinds.
- grok / kimi-code / gemini-or-antigravity backends per the ACP record.
- Bonus backends as catalog rows + quirk notes, not extra PRs.
- Agent Control embeds existing chat views.
- Android approval-request dedupe port.
- Approvals host + `mission_approval` push + policy UI on existing stores.
- Mac-signed pre-auth queue.
- Authenticated grok-bot input.
- Delete app-side dead directive lane only.
- Docs: threat model honesty, ADR, CHANGELOG, mobile-parity ledger / route-map / OS matrix.

### Explicitly out of scope

- Replacing iroh or Mercury with this file plane.
- Making Functions a second policy engine.
- Computer Use Path C / MAS changes.
- Raising Hermes gateway’s 50MiB agent→phone lane to 20GiB (separate collection, separate threat).
- Unauthenticated loopback “for convenience.”
- Inventing a second Android transcript surface.
- Making blocked mobile-parity ledger rows fail CI while `--allow-blocked` is on.
- Waiting on PR #2356 to start PR-A.
- `--always-approve`, `--yolo`, Gemini `--approval-mode=yolo`, ACP `allow_always`, `session/set_mode` auto-accept.

### Deferred only if the ACP spike fails

If `session/new` + `session/prompt` + streaming `session/update` + `session/request_permission` do not round-trip on a named binary, that binary ships argv+parser using the existing 6-point pattern. The decision record names the binary, version, and flags actually tested. Consumer Gemini CLI sunset (2026-06-18) means “gemini-cli” is Antigravity unless the spike proves leftover `gemini --acp` on an enterprise key the product still supports.

---

## 5. VAL contracts

Each assertion is independently falsifiable. PR-A owns VAL-CTL-*, PR-B owns VAL-FILE-*, PR-C owns VAL-AGT-*. Cross-flow assertions are VAL-CROSS-*.

### VAL-CTL-001 — Unthrottled create is gone

- **Surface:** api
- **Needs:** Functions emulator + `publicRateLimit` counters
- **Behavior:** The 11th `createCliAgentMission` in 60s for one uid returns `resource-exhausted` and does not leave a 11th `pending` doc. The 61st in one hour does the same. A client `setDoc` to `cli_agent_mission_requests` is denied. `writeSignalAtRestDocument` with this collection is denied (or delegated through the same limiter and pending-only validator).
- **Evidence:** emulator traces + Firestore get of the 11th id is not-found + `public_rate_limits/mission_create_burst_*` count.

### VAL-CTL-002 — Claim is transactional, device-bound, and happens *before* authorize

- **Surface:** api
- **Needs:** two attested Mac device ids, one pending mission
- **Behavior:** Exactly one `claimCliAgentMission` succeeds. The loser receives `failed-precondition`. A later owner `setDoc` of `status:"failed"` without the winner’s attested device is denied. A loser `updateCliAgentMissionStatus(failed)` is denied. Daemon `evaluate` runs **after** exclusive ownership. Today authorization is at `+Handling.swift:330-342` and claim is at `:361-388` — two Macs can both authorize, then race the merge.
- **Evidence:** emulator transaction logs; final doc `claimedBy` equals winner; status not `failed`; unit that `evaluate` is not invoked until claim returns the nonce.

### VAL-CTL-003 — Cancel cannot clobber terminal states

- **Surface:** api
- **Needs:** fixtures in `{pending, accepted, starting, running, waiting_for_approval, completed, failed, canceled, cancelled}`
- **Behavior:** Cancel allowed only from the five live states. Cancel-after-completed / failed / canceled / cancelled is denied. Spelling `cancelled` (client cancel) vs `canceled` (callable deny) is preserved.
- **Evidence:** emulator T10-replacement cases; iOS/Android unit tests of the cancel callable client.

### VAL-CTL-004 — Catalog allowlists persist previously dropped runtimes

- **Surface:** api + data
- **Needs:** catalog fixture including kimi, gemini, openclaude, omp, junie
- **Behavior:** Event / `cli_sessions` / `mobile_assistant_chats` / receipt writes with those runtimes persist. Create of an unknown 80-char token is denied. Windows switcher enum contains junie, prime-agent, fx.
- **Evidence:** emulator tests; catalog contract test output; Windows compile of the new cases.

### VAL-CTL-005 — `mac_interactive_cli` is honest

- **Surface:** library
- **Needs:** `InteractiveTerminalLauncher` test double
- **Behavior:** `presentationMode == mac_interactive_cli` calls `InteractiveTerminalLauncher.launchInteractive`. `mac_visible_cli` stays on the visible-terminal path. Unknown mode writes a typed terminal event and does not silently become headless.
- **Evidence:** unit test of `+DirectExecution.swift` switch; no fall-through to `directLaunchPlan` for interactive.

### VAL-CTL-006 — Windows cannot client-merge approvalStatus

- **Surface:** api + library
- **Needs:** rules emulator + Windows host tests
- **Behavior:** `RespondToApprovalAsync` calls `respondMissionApproval`. A raw client merge of `approvalStatus:"approved"` is denied.
- **Evidence:** updated `FirestoreMissionDispatchHostTests`; emulator deny.

### VAL-CTL-007 — Signal-at-rest cannot overwrite a live mission

- **Surface:** api
- **Needs:** an already-claimed mission
- **Behavior:** `writeSignalAtRestDocument` targeting that id fails. Create-with-signal only succeeds for a new pending id through `createCliAgentMission`.
- **Evidence:** callable unit test + emulator.

### VAL-CTL-008a — Android cancel carries path-bound AAD

- **Surface:** api + library
- **Needs:** Android cancel payload captured in a unit test
- **Behavior:** `sealedStatePayload.aad` equals `cloudVaultAADContext(uid, "cli_agent_mission_requests", requestId, "sealedStatePayload")`. A null-AAD cancel is denied by rules (T10 already denies plaintext; add T10g for global-AAD / missing AAD).
- **Evidence:** Android JVM + emulator T10g.

### VAL-CTL-009 — Relay timeout does not start a second execution

- **Surface:** library
- **Needs:** a live relay stream that throws after the Mac has already begun the turn
- **Behavior:** `CLIAgentMobileChatService` today catches relay errors and `dispatch()`s a **new** mission (`:148-203`) with no shared command id. Ambiguous timeout / stream death is **unknown**, not “retry on another plane.” A shared `remoteCommandID` (client-minted, stored on the relay request and on the mission doc) is the only way a later durable send is the same command. Automatic fallback after timeout is forbidden.
- **Evidence:** unit: timeout → no `createCliAgentMission`. Unit: explicit user “send while Mac asleep” → one create. Two-plane race test with the same `remoteCommandID` is a no-op on the second plane.

### VAL-CTL-010 — Approver field names match

- **Surface:** library + api
- **Needs:** a mission approved via `respondMissionApproval`
- **Behavior:** Callable writes `approvedByDeviceId`. Daemon context today reads `approverDeviceID` (`MissionRemoteAuthorizationEnforcement.swift:64`) and therefore always sees nil. One wire name. Daemon `evaluate` is given the attested approver id. A Mac cannot treat `approvalStatus == "approved"` as sufficient if the approver field is missing.
- **Evidence:** unit that a post-approve authorize request carries the phone device id; grep that `approverDeviceID` is not a second Firestore key.

### VAL-CTL-008 — Only the claiming Mac can append events

- **Surface:** api
- **Needs:** a claimed mission and a second owner client
- **Behavior:** Client `setDoc` to `events/{id}` is denied. `appendCliAgentMissionEvent` without the winner’s `hostWriteNonce` or attested device is denied. The winner’s next sequence appends. A duplicate `eventId` is denied.
- **Evidence:** rules T17 + callable tests.

### VAL-FILE-001 — OBFS1 KATs including nonce misuse

- **Surface:** library
- **Needs:** `FileSealAEADVector.json` checked in Swift + Kotlin
- **Behavior:** Byte-identical seal/open across Swift and Kotlin on frozen-nonce fixtures. Flipped `chunkIndex` or `attachmentId` fails authentication. Production `sealChunk` without an explicit nonce draws a fresh random IV. Reusing a fixture nonce with different plaintext under the same key is a KAT negative (must fail open / must not be the production default).
- **Evidence:** both language suites green on the same fixture.

### VAL-FILE-002 — Finalize-once against Storage

- **Surface:** api
- **Needs:** Storage emulator or mocked GCS with generation
- **Behavior:** First finalize with `ifGenerationMatch: 0` succeeds and persists generation + size from `getMetadata`. Second finalize of mutated bytes fails. Second finalize of the same generation+size returns 200. Part PUT after finalize is 403.
- **Evidence:** `burnbarAttachments` tests; no `uploaded` short-circuit that skips the object.

### VAL-FILE-003 — Quota is GCS-stat, not manifest

- **Surface:** api
- **Needs:** a begin that lies about `byteCount`
- **Behavior:** Finalize meters `metadata.size`. A lie that under-reports does not shrink the daily counter. Abandoned `pending_upload` parts are reaped and counted or deleted so they cannot be a free side channel.
- **Evidence:** quota doc after finalize; reaper test for leftover parts and for `hermes_gateway_attachments`.

### VAL-FILE-004 — Compose hierarchy for >32 parts

- **Surface:** api
- **Needs:** 33 parts (or a test double of compose that records source counts)
- **Behavior:** No compose call has more than 32 sources. 20GiB / 64MiB = 320 parts compose 320→10→1.
- **Evidence:** call trace in the unit test.

### VAL-FILE-005 — Landing is digest-idempotent and contained

- **Surface:** library
- **Needs:** two refs with the same verified `contentBlake3` via P2P and cloud
- **Behavior:** One landing. Path traversal filenames are sanitized. Landing stays inside the target workspace / Drop folder. `AgentContextTargetReceiver` receives the landed URLs, not `[]`.
- **Evidence:** `MacAttachmentLandingService` tests; receiver test.

### VAL-FILE-006 — Streaming seal unblocks the 2GiB raise

- **Surface:** library
- **Needs:** a >64MiB fixture (can be sparse / synthetic)
- **Behavior:** Seal and open succeed without loading the whole plaintext as one `Data`. `IrohBlobTransferLimits.maxExpectedFetchBytes` and `maxAtRestSealPlaintextBytes` are both 2GiB. A 65MiB blob no longer fails the seal gate.
- **Evidence:** unit test + constant assertions.

### VAL-AGT-001 — Tolerant decode before new kinds

- **Surface:** library
- **Needs:** a fixture event with `kind: "approvalRequest"`
- **Behavior:** Old clients map it to `.unknown` and keep the stream. After the emitter ships, new clients decode the new case. First unknown kind does not latch `decodeError`.
- **Evidence:** `CLIAgentRelayChatTransport` tests.

### VAL-AGT-002 — Interrupt ≠ panicHalt

- **Surface:** library + cli
- **Needs:** one running CLI session and CU panicHalt tests
- **Behavior:** `CLIAgentSessionActionKind.interrupt` stops that session only. Existing CU `panicHalt` tests remain green and still arm the global privileged-input kill switch.
- **Evidence:** new session-action test + unchanged CU suite.

### VAL-AGT-003 — Backends launch only per the ACP record

- **Surface:** cli + library
- **Needs:** decision record with pinned `grok --help` / `kimi acp` / Antigravity flags
- **Behavior:** `backend(for:)` and `directLaunchPlan` have cases for the chosen protocol. Forbidden flags are absent. `allow_always` / `session/set_mode` auto-accept are refused.
- **Evidence:** argument-builder tests; decision record quoted in the test comments.

### VAL-AGT-004 — A later ask on the same mission is a new card

- **Surface:** library
- **Needs:** Mac `requestApproval` called twice on one mission
- **Behavior:** Each park mints a **new** `approvalRequestId` (today Mac reuses the existing id at `+ApprovalFlow.swift:154`, which makes the iOS “later id is a new ask” comment a lie). Mobile keys hide-state by `(missionID, approvalRequestId)`. Re-emission of the resolved id stays hidden. A new id shows. Android `respond()` rebuilds immediately (today it waits for the listener and the Deny card comes back).
- **Evidence:** Mac unit that the second park has a different id; iOS + Android host tests for reuse vs new id.

### VAL-AGT-005 — Pre-auth is Mac-signed and single-use

- **Surface:** api
- **Needs:** a Mac-signed scope blob
- **Behavior:** Replay, expiry, cross-device, mutated grant, missing signature, and prompt-hash mismatch all fail closed. Happy path consumes `consumedAt` once. Functions never call a JS port of `evaluate`.
- **Evidence:** callable tests listed by name in PR-C.

### VAL-AGT-006 — grok-bot input is authenticated

- **Surface:** other (loopback)
- **Needs:** peer-credential or 0600 token
- **Behavior:** Unauthenticated loopback is rejected. Accepted input passes `BurnBarFleetControlStore` fence + daemon `evaluate`. CU / fleet probe `kill -0` path is unchanged.
- **Evidence:** probe + listener tests.

### VAL-CROSS-001 — Offline queue survives Mac sleep

- **Surface:** other
- **Needs:** airplane-mode Mac; queued command + file + one pre-auth
- **Behavior:** On wake: one run, one landing, one redeem, late cancel cannot clobber terminal.
- **Evidence:** manual / device script notes in the PR-C validation matrix. Automated pieces (cancel-after-terminal, single redeem) stay in emulator.

### VAL-CROSS-002 — Phone → Mac → phone file identity

- **Surface:** artifact
- **Needs:** PR-B callables + landing
- **Behavior:** A file whose plaintext blake3 is `H` lands on the Mac with `contentBlake3 == H` and returns to the phone with the same `H`. Server-visible metadata never contains plaintext.
- **Evidence:** hash of landed file; manifest inspection.

---

## 6. File / component map

### New

| Path | Responsibility |
|------|----------------|
| `tools/schema-sync/typespec/domains/mission-runtime-catalog.tsp` + `fixtures/mission-runtime-catalog.json` | Single census |
| `scripts/gen/mission-runtime-catalog.mjs` | Emits Swift/Kotlin/C#/rules snippets + Functions allowlist |
| `functions/src/callables/cliAgentMissions.ts` | create / claim / status / cancel / append event |
| `functions/src/callables/burnbarAttachments.ts` | begin / part-url / compose / finalize / download / delete |
| `functions/src/scheduled/reapBurnbarAttachments.ts` | Hourly reaper; also sweeps `hermes_gateway_attachments` |
| `OpenBurnBarCore/Sources/OpenBurnBarMedia/FileSealAEAD.swift` | OBFS1 |
| `android/app/src/main/java/com/openburnbar/data/media/FileSealAEAD.kt` | OBFS1 twin |
| `AgentLens/Services/Media/MacAttachmentLandingService.swift` | P2P-first land + quarantine |
| `docs/architecture/016-remote-mission-integrity.md` | Trust-model ADR |
| `docs/decisions/2026-08-xx-acp-vs-argv.md` | Spike record (pre-flight) |

### Modified (control plane)

- `firestore.rules` — deny client create; deny client host update; cancel precondition; generated runtime lists
- `functions/src/callables/publicRateLimit.ts` — `mission_create_burst` / `mission_create_hourly` / `mission_approval_fail`
- `functions/src/callables/writeSignalAtRestDocument.ts` — stop mission writes
- `functions/src/callables/agentGrantCallables.ts` — generated `ALLOWED_GRANT_RUNTIMES`
- `functions/scripts/test-firestore-rules.mjs` — T10 expansion + claim/create denies
- `OpenBurnBarMobile/Services/CLIAgentMissionDispatcher.swift` + Android twin — callable create
- `OpenBurnBarMobile/Services/CLIAgentMissionDispatcher+MissionControl.swift` — callable cancel
- `AgentLens/Services/CloudSync/CLIAgentMissionRequestListener+Handling.swift` + `+ApprovalFlow.swift` + `+DirectExecution.swift` + `+Planner.swift`
- `AgentLens/Services/ComputerUse/ComputerUseSecurityCallableClient.swift` + mobile twin
- `windows/app/OpenBurnBar.App/MissionControl/FirestoreMissionDispatchHost.cs`
- `windows/app/OpenBurnBar.App.Presentation/Switcher/SwitcherModels.cs`
- `android/app/src/main/java/com/openburnbar/data/hermes/PiConnectionModels.kt`
- `functions/src/types/legacy/media.ts` — `resumeAction` includes `"continue"`

### Modified (file plane)

- `AgentLens/Services/Media/MacFileTransferService.swift`
- `OpenBurnBarCore/Sources/OpenBurnBarIrohRelay/IrohBlobBackend.swift`
- `AgentLens/Services/ComputerUse/AgentContextTargetReceiver.swift`
- `functions/src/callables/hermesGatewayAttachmentRoutes.ts` — do **not** copy its finalize short-circuit; do sweep its objects
- Android WorkManager workers + manifest FGS type
- iOS app delegate background session hook

### Modified (agent control)

- `OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/HermesConnectionTypes.swift`
- `OpenBurnBarMobile/Services/CLIAgentRelayChatTransport.swift`
- `OpenBurnBarMobile/Views/MissionControl/*` + Android `MobileMissionConsoleHost.kt`
- `OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/MobileOsIntegrationPolicy.swift` + Kotlin twin
- `scripts/mobile-parity/check-mobile-a11y-performance.mjs` `PRIMARY_SURFACES`
- `docs/mobile-parity/mobile-os-integration-matrix.json` + ledger + route-map

---

## 7. Sequencing

```
Pre-flight (small PR, no product surface)
    │
    ├──────────────► PR-A Mission integrity  (theme: the live pipeline cannot be trusted)
    │                      │
    │                      ▼
    ├──────────────► PR-B Drive + file plane (can start in parallel with A after catalog fixture exists;
    │                      │                  merge after A if it touches mission sealedPayload refs)
    │                      ▼
    └─ ACP record ─► PR-C Agent Control + backends (depends on A + ACP record; file-attach needs B)
```

No new remote capability in PR-A. PR-B adds file movement but not new agent control. PR-C is the product surface.

Do not split these into 25 PRs.

---

## 8. Pre-flight

**Theme:** rebase hygiene + vocabulary assert + ACP evidence. No product surface.

### Task P0: Windows switcher enum + catalog skeleton

**Files:**
- Modify: `windows/app/OpenBurnBar.App.Presentation/Switcher/SwitcherModels.cs:35-49`
- Create: `tools/schema-sync/fixtures/mission-runtime-catalog.json` (can be PR-A if you want zero product risk here)
- Test: Windows switcher parity test that `Enum.GetNames(typeof(SwitcherCLIProfileType))` contains `Junie`, `PrimeAgent`, `Fx`

- [ ] Add `Junie`, `PrimeAgent`, `Fx` to the Windows enum in Swift order, after `Pi`.
- [ ] Add a C# test that fails if Swift `SwitcherCLIProfileType.allCases` (exported via the JSON fixture, or a checked-in name list) is not a superset.
- [ ] Do **not** add a new `fast-feedback.yml` job. `schema-drift` already runs the five validators.
- [ ] Optional only if product-vector gating is the actual gap: invoke `scripts/mobile-parity/check-mobile-product-vectors.mjs` from `check-drift.sh`. Do not claim `--allow-blocked` fails blocked rows.
- [ ] Rebase onto latest `main`. If #2356 has merged, include it. If it is still a dirty draft, do not wait.
- [ ] Commit: `fix(windows): align SwitcherCLIProfileType with Swift (junie, prime-agent, fx)`

### Task P1: ACP spike + decision record (gates PR-C only)

**Files:**
- Create: `docs/decisions/2026-08-19-acp-vs-argv.md`
- Spike code may live in a throwaway branch or `OpenBurnBarDaemon` test harness; it does not have to merge.

Must pin, by running the installed binaries:

| Binary | Prove |
|--------|--------|
| `grok --help` | Whether `--prompt-file` exists. xAI docs list `-p/--single` and `--output-format streaming-json`. Repo resume still emits `--prompt-file` (`BurnBarResumeService`). Do not emit it unless the binary has it |
| `grok agent stdio` | `session/new`, `session/prompt`, streaming `session/update`, `session/request_permission`, optional `session/load` |
| `kimi acp` | Same five; record the actual binary name (`kimi` vs leftover `kimi-cli`) |
| Antigravity / leftover Gemini | Consumer Gemini CLI stop-serve for Pro/Ultra and free Code Assist was 2026-06-18. Decide: Antigravity only, leftover `gemini --acp` on enterprise, or both |

Hard refuses if the daemon owns approvals:

- `--always-approve`, `--yolo`, Gemini `--approval-mode=yolo`
- ACP `allow_always` (“Yes, and auto-accept all actions”)
- `session/set_mode` into an auto-accept mode

Decision record template (fill with measured values, no TBDs):

```markdown
# ACP vs argv (DATE)

## Binaries
| id | path | version | protocol | launch argv | resume | permission | refused flags |
|----|------|---------|----------|-------------|--------|------------|---------------|

## Verdict
- grok: acp | argv
- kimi-code: acp | argv
- gemini-or-agy: acp | argv | unsupported

## Implications for PR-C
- One stdio JSON-RPC client: yes/no
- Argv parsers still required for: …
```

- [ ] Run the binaries. Paste `--help` excerpts into the record.
- [ ] Commit the record even if the spike client does not merge: `docs(decisions): ACP vs argv for grok/kimi/gemini`.

PR-A and PR-B must not wait on this record. PR-C must not start without it.

---

## 9. PR-A — Mission integrity

**Theme:** the live pipeline cannot be trusted until this lands.

**Review map:** (1) catalog + generated allowlists, (2) callables + rate limit + Signal-write close, (3) rules denials, (4) Mac listener claim/fail, (5) mobile/Windows clients, (6) emulator suite, (7) ADR.

### Task A1: Catalog fixture and generator

**Files:**
- Create: `tools/schema-sync/fixtures/mission-runtime-catalog.json`
- Create: `scripts/gen/mission-runtime-catalog.mjs`
- Create: `OpenBurnBarCore/Tests/OpenBurnBarCoreTests/MissionRuntimeCatalogTests.swift`
- Create: `android/app/src/test/java/com/openburnbar/data/catalog/MissionRuntimeCatalogTest.kt`
- Create: `windows/tests/catalog/MissionRuntimeCatalogTests.cs`
- Modify: `tools/schema-sync/typespec/domains/missions.tsp` (expand the stub)
- Modify: `firestore.rules` (replace the five hand lists with `// BEGIN GENERATED MISSION_RUNTIMES` … `// END`)
- Modify: `functions/src/callables/agentGrantCallables.ts` `ALLOWED_GRANT_RUNTIMES`

**Interfaces:**

```ts
// mission-runtime-catalog.json
type CatalogRow = {
  id: string;                       // canonical, e.g. "grok"
  wireAliases: string[];            // all accepted tokens, lowercase
  displayName: string;
  surfaces: Array<
    | "switcher" | "assistant" | "fleet" | "chat_backend"
    | "cli_runtime" | "resume_target" | "mission_create" | "mission_event"
    | "mission_mirror" | "mission_receipt" | "grant_runtime"
  >;
  launch: "none" | "argv" | "acp";  // "none" is allowed — row ≠ launch
  platforms: Array<"macos" | "ios" | "android" | "windows" | "linux">;
};
```

Generator outputs:

- `validCliMissionRuntime` becomes `value in [generated]` **for create** (no more any-token).
- Event / `cli_sessions` / `mobile_assistant_chats` / receipt / grant lists from `surfaces`.
- Swift `MissionRuntimeCatalog` with `aliases → id` and `contains(_:)`.

Contract test (must fail if someone adds an enum case and forgets the fixture):

```swift
func testCatalogCoversEverySwiftEnum() {
    let catalog = MissionRuntimeCatalog.loadFixture()
    XCTAssertTrue(catalog.covers(SwitcherCLIProfileType.allCases.map(\.rawValue)))
    XCTAssertTrue(catalog.covers(AssistantRuntimeID.allCases.map(\.rawValue)))
    XCTAssertTrue(catalog.covers(CLIAgentRuntime.allCases.map(\.rawValue)))
    XCTAssertTrue(catalog.covers(ChatBackendID.allCases.map(\.rawValue)))
    XCTAssertTrue(catalog.covers(BurnBarFleetAgentID.declaredRoster.map(\.wireValue)))
}
```

Android test asserts `AssistantRuntimeID` tokens ⊆ catalog, and that `OPEN_CLAUDE` / `OMP` exist as cases (add them in this task). Windows test asserts junie / prime-agent / fx (from P0) ⊆ catalog.

The fixture **must** list Cursor aliases as first-class (`cursorAgent`, `cursoragent`, `cursor_agent`, `cursor`). A contract test fails if any of these remaps still exist: Android `fromToken` unknown → HERMES; Windows switcher unknown → Pi; Android session-action unknown → RESUME; planner `kimi`/`gemini` → first enabled backend; `assistantRuntimeID(for:)` unknown → `.codex`. Fail closed.

Also absorb `CLIAgentResumeTarget`, both `backend(for:)` functions, `AgentContextTargetReceiver`’s alias switch, and the four `runtimeIDGuess` copies (Mac has `gpt`/`openai`/`claw` the phones lack; `"pi-agent"` is the inverse).

- [ ] Write the failing catalog tests.
- [ ] Add the fixture with every live alias, including `grok-build`, `cursor_agent`, `piagent`, `open-claude`.
- [ ] Add Android `OPEN_CLAUDE` and `OMP` to `PiConnectionModels.kt`.
- [ ] Generate rules + `ALLOWED_GRANT_RUNTIMES`.
- [ ] Run: `node scripts/gen/mission-runtime-catalog.mjs && npm --prefix functions test -- --testPathPattern callableRateLimits` is not enough — run the new catalog tests.
- [ ] Commit: `feat(catalog): single mission runtime census with generated allowlists`

### Task A2: Rate-limit actions

**Files:**
- Modify: `functions/src/callables/publicRateLimit.ts`
- Modify: `functions/src/__tests__/callableRateLimits.test.ts`

```ts
type CallableRateLimitAction =
  | /* existing */
  | "mission_create_burst"
  | "mission_create_hourly"
  | "mission_approval_fail";

// 10 / 60s and 60 / 3600s, keyed per uid, public_rate_limits/
// mission_approval_fail: 10 / 900s, analog of hermes_gateway_approve_fail
```

- [ ] Write the failing rate-limit tests (burst then hourly).
- [ ] Implement the actions.
- [ ] Commit: `feat(functions): mission create and approval-fail rate limits`

### Task A3: Create / claim / status / cancel callables

**Files:**
- Create: `functions/src/callables/cliAgentMissions.ts`
- Create: `functions/src/__tests__/cliAgentMissions.test.ts`
- Modify: `functions/src/index.ts` exports
- Modify: `functions/src/security/endpointAuthorizationCatalog.generated.ts` (via the existing catalog generator, not by hand if a generator exists)
- Modify: `functions/src/callables/writeSignalAtRestDocument.ts`

**Interfaces:**

```ts
// createCliAgentMission
type CreateMissionRequest = {
  requestId: string;                 // client-chosen, == doc id
  remoteCommandID: string;           // shared with the relay turn; create is idempotent on this
  publicFields: MissionPublicShape;  // status must be omitted; server sets pending
  sealedPayload: CloudSealedPayload;
  signalEnvelope?: SignalEnvelope;   // optional; replaces writeSignalAtRestDocument for this collection
  initialEvent: SealedQueuedEvent;   // events/000001
  siblings?: CreateMissionRequest[]; // fan-out, max 16 including parent
  nonce: string;
  actionProof: unknown;
};

// claimCliAgentMission  (Mac, platform macOS)
type ClaimMissionRequest = {
  requestId: string;
  deviceId: string;
  nonce: string;
  actionProof: unknown;
  nextStatus: "accepted" | "waiting_for_approval";
  selectedRuntime: string;
  selectedRuntimeName: string;
  selectedModelID?: string;
  approvalRequestId?: string;        // required if nextStatus is waiting_for_approval
  sealedStatePayload: CloudSealedPayload;
};

// updateCliAgentMissionStatus  (Mac)
type UpdateMissionStatusRequest = {
  requestId: string;
  deviceId: string;
  nonce: string;
  actionProof: unknown;
  status: "starting" | "running" | "completed" | "failed" | "canceled";
  hostWriteNonce: string;            // returned by claim; binds event writers
  sealedStatePayload: CloudSealedPayload;
};

// cancelCliAgentMission  (phone)
type CancelMissionRequest = {
  requestId: string;
  deviceId: string;
  nonce: string;
  actionProof: unknown;
  sealedStatePayload: CloudSealedPayload;
};

// appendCliAgentMissionEvent  (Mac)
// Default close for events: this collection is already near Firestore's
// 1000-expression budget, so do not add a parent get() of hostWriteNonce
// to event create rules. Server-write events only.
type AppendMissionEventRequest = {
  requestId: string;
  deviceId: string;
  nonce: string;
  actionProof: unknown;
  hostWriteNonce: string;
  eventId: string;                   // zero-padded sequence, e.g. "000002"
  sealedEvent: CloudSealedPayload;
  publicEventShape: {                // no plaintext title/message
    sequence: number;
    kind: string;
    phase: string;
    runtime: string;
    source: "mac";
    isError?: boolean;
  };
};
```

Server invariants (all in Admin-SDK transactions):

1. **create:** App Check on. **Do not newly require Pro** — today's dispatcher is a client write with no entitlement gate; `respondMissionApproval` is the Pro-gated step and stays that way. Increment both rate limits **before** the write; validate catalog runtime; validate sealed path-binding the same way rules do; write `status:"pending"` and forbid `claimedBy` / approval / started keys; write `events/000001`; count each sibling as one create. If `remoteCommandID` already exists on a non-terminal mission, return that `requestId` and do not create a second execution.
2. **claim:** `requireTrustedDeviceActionProof` with `allowedPlatforms: {"macOS"}`; require current `status == "pending"` and `claimedBy` absent; set `claimedBy` to the attested `deviceId`; mint `hostWriteNonce` (32 random bytes, stored hashed); `nextStatus` ∈ `{accepted, waiting_for_approval}`.
3. **status:** attested `deviceId == claimedBy`; `hostWriteNonce` matches; legal transitions only:

```
pending → (only via claim)
accepted → starting | waiting_for_approval | failed | canceled
starting → running | failed | canceled
running → completed | failed | canceled | waiting_for_approval
waiting_for_approval → accepted | starting | running | canceled | failed
                  (claimedBy already set; this is continue-after-approve, not a second claim)
terminal → ∅
// Host cannot revive cancelled/completed/failed. Today's validTrustedMissionHostUpdate
// has no current-status check, so an in-flight handle() can overwrite cancelled → accepted.
```

4. **cancel:** phone platforms; current status ∈ `{pending, accepted, starting, running, waiting_for_approval}`; write `status:"cancelled"` (double-l). Deny otherwise.
5. **append event:** attested `deviceId == claimedBy`; `hostWriteNonce` matches; `eventId` is the next sequence and not already present; runtime ∈ catalog `mission_event` surface; no plaintext title/message.
6. **writeSignalAtRestDocument:** if `collection === "cli_agent_mission_requests"`, throw `failed-precondition` (“use createCliAgentMission”). Client `allow create` on `events/{eventId}` becomes false except the queued `000001` written by create (Admin SDK). A losing Mac cannot append.

Use `onCallProduction` (`logging.ts:287`). Region `FUNCTIONS_REGION`. `enforceAppCheck: getConfig().enforceAppCheck` to match `respondMissionApproval`, and keep nonce + trusted-device proof unconditional.

- [ ] Write failing callable tests: flood, two-claim race, loser fail, Signal overwrite, cancel-after-completed, create unknown runtime.
- [ ] Implement the five callables (create, claim, status, cancel, append event).
- [ ] Close the Signal write hole.
- [ ] Run: `npm --prefix functions test -- --testPathPattern 'cliAgentMissions|writeSignalAtRest|callableRateLimits'`
- [ ] Commit: `feat(functions): server-owned mission create, claim, status, and cancel`

### Task A4: Rules — client create and host update die

**Files:**
- Modify: `firestore.rules` `match /users/{userId}/cli_agent_mission_requests/{requestId}`
- Modify: `functions/scripts/test-firestore-rules.mjs`

New allow:

```
allow create: if false;  // createCliAgentMission (Admin SDK)
allow update: if ownerWritableNonSecret(userId)
  && validCliAgentMissionUpdateEnvelope()
  && (
    validMobileMissionApprovalResponse()          // cancel a pending approval only
    || validMobileMissionCancel()                 // now status-preconditioned
  );
```

Delete or keep-as-dead `validTrustedMissionHostUpdate` / `validMissionRefusalOrFailureUpdate` for this collection. Do not leave a comment that says “unused” without a test that a host-shaped client update is denied.

`validMobileMissionCancel`:

```
return resource.data.status in [
     "pending", "accepted", "starting", "running", "waiting_for_approval"
   ]
   && request.resource.data.status == "cancelled"
   && /* existing affectedKeys hasOnly */
```

Event creates: `allow create: if false` on `events/{eventId}`. The initial `000001` and every later event are Admin-SDK (`createCliAgentMission` / `appendCliAgentMissionEvent`). This collection is already near the 1000-expression budget (see the rules comment on repeating deny helpers); do not add a parent `get()` of `hostWriteNonce` to the event rule. A losing Mac without the claim nonce cannot append.

Emulator cases to add (names are the test titles):

```
T10a cancel from pending succeeds
T10b cancel from running succeeds
T10c cancel from starting succeeds
T10d cancel after completed denied
T10e cancel after failed denied
T10f cancel after canceled/cancelled denied
T12  client create denied
T13  client host claim denied
T14  client fail() after claimed denied
T15  kimi / gemini / openclaude event create succeeds
T16  unknown runtime event denied
T17  client event create denied
```

- [ ] Write the new emulator tests first. Confirm T12/T13/T14 fail on current rules.
- [ ] Flip the rules.
- [ ] Run: `node functions/scripts/test-firestore-rules.mjs` (or the repo wrapper that boots the emulator).
- [ ] Commit: `fix(rules): deny client mission create/host-update; precondition cancel`

### Task A5: Mac listener uses the callables

**Files:**
- Modify: `AgentLens/Services/CloudSync/CLIAgentMissionRequestListener+Handling.swift`
- Modify: `AgentLens/Services/CloudSync/CLIAgentMissionRequestListener+ApprovalFlow.swift`
- Modify: `AgentLens/Services/ComputerUse/ComputerUseSecurityCallableClient.swift`
- Test: `AgentLensTests/Active/` new `CLIAgentMissionClaimCallableTests.swift` with a fake Functions client

**Reorder `handle()`:** claim first (exclusive ownership + `hostWriteNonce`), **then** `resolveRemoteMissionAuthorization`. Today evaluate is at `+Handling.swift:330-342` and claim at `:361-388`. Two Macs can both get `.authorized` and then race. After the flip, the loser never evaluates.

Replace `document.reference.setData(..., merge: true)` for claim / fail / starting / requestApproval with the callables. Replace `recordEvent`’s client `setData` on `events/{id}` with `appendCliAgentMissionEvent`.

Pass `approvedByDeviceId` (the callable’s field) into the daemon context. Delete the `approverDeviceID` read of a key the server never writes.

`CLIAgentMobileChatService.dispatchMissionFallback` after an ambiguous relay error is deleted. Explicit offline send (user tapped send knowing the Mac is down, or `shouldFallBackToMission` only for `notConnected` / `macOffline`, never timeout-after-bytes) may create a mission **with the same `remoteCommandID`**. The create callable is idempotent on that id.

```swift
func fail(document: QueryDocumentSnapshot, message: String) async {
    // If we do not hold a claim, do not attempt a status write.
    guard claimedMissions[document.documentID] != nil else {
        logger.warning("refusing unclaimed fail() for \(document.documentID, privacy: .public)")
        return
    }
    try await ComputerUseSecurityCallableClient.updateCliAgentMissionStatus(
        requestId: document.documentID,
        status: "failed",
        hostWriteNonce: claimedMissions[document.documentID]!.hostWriteNonce,
        …
    )
}
```

Two-Mac race: the loser’s `claimCliAgentMission` throws `failed-precondition`; the listener returns without `fail()`.

- [ ] Write the fake-client test that a failed claim does not call status-failed.
- [ ] Implement.
- [ ] Commit: `fix(mac): claim and status missions through trusted-device callables`

### Task A6: Honest presentation-mode routing

**Files:**
- Modify: `AgentLens/Services/CloudSync/CLIAgentMissionRequestListener+DirectExecution.swift:94`
- Modify: `AgentLens/Services/CLIBridge/InteractiveTerminalLauncher.swift` (use existing `launchInteractive`)
- Test: new cases in the existing DirectExecution tests

```swift
switch CLIAgentMissionRuntimePlanner.presentationMode(from: data) {
case .macVisibleCLI:
    return await runVisibleTerminalMission(...)
case .macInteractiveCLI:
    return await runInteractiveTerminalMission(...) // InteractiveTerminalLauncher.launchInteractive
case .nativeChat:
    break
}
if let plan = CLIAgentMissionRuntimePlanner.directLaunchPlan(...) { ... }
return typedFailure("unknown or unsupported presentationMode")
```

Grok remains a typed terminal failure in this PR (`directLaunchPlan` still nil). Do not add a grok launch path here.

`resolve` must **fail closed** for `kimi` / `gemini` / unknown tokens instead of falling through to `enabledBackends.first`. Today those tokens silently remap to another backend (`+Planner.swift` after the explicit switch). Raw `"grok"` also skips Mac CLI-assistant consent — leave that hole closed in C when grok launches, and document it in A.

- [ ] Failing test: `mac_interactive_cli` invokes the interactive launcher.
- [ ] Failing test: unknown mode does not call `directLaunchPlan`.
- [ ] Implement.
- [ ] Commit: `fix(mac): route mac_interactive_cli to InteractiveTerminalLauncher`

### Task A7: Mobile + Windows clients

**Files:**
- Modify: `OpenBurnBarMobile/Services/CLIAgentMissionDispatcher.swift` (replace `batch.setData` / Signal callable with `createCliAgentMission`)
- Modify: `OpenBurnBarMobile/Services/CLIAgentMissionDispatcher+MissionControl.swift` `cancelMission`
- Modify: `OpenBurnBarMobile/Services/ComputerUse/ComputerUseSecurityCallableClient.swift`
- Modify: `android/app/src/main/java/com/openburnbar/data/assistants/CLIAgentMissionDispatcher.kt` + Support
- Modify: `windows/app/OpenBurnBar.App/MissionControl/FirestoreMissionDispatchHost.cs:85-105`
- Modify: `windows/tests/missioncontrol/FirestoreMissionDispatchHostTests.cs`
- Modify: `functions/src/types/legacy/media.ts:470` add `"continue"`

Offline queue: persist `{CreateMissionRequest}` in the existing mobile outbox / pending-dispatch store and replay the callable. Do not fall back to client `setDoc`.

Windows `RespondToApprovalAsync` must call the existing `respondMissionApproval` callable (or the Windows Functions wrapper already used for other high-risk actions). It must **not** write `approvalStatus` via `SetAsync`. Approve stays `waiting_for_approval` on the server (`missionApprovalResolutionWrite`). Deny writes `status:"canceled"`.

- [ ] iOS unit: dispatch payload is sent to the callable mock; no Firestore set.
- [ ] iOS unit: cancel after a completed snapshot is not sent (client guard) and the callable would deny.
- [ ] Android JVM: same.
- [ ] **Android cancel AAD:** `sealedMissionStateUpdate` currently seals with `aadContext = null`. Rules require path-bound AAD for `sealedStatePayload`. Wire the unused `missionStateAadContext()` into cancel **and** into the cancel callable payload. This is a live production-deny, not polish.
- [ ] Windows: `RespondToApprovalAsync` invokes the callable; the old merge test is inverted to expect no merge of `approved`.
- [ ] Windows **create** today would not pass rules (`source: "windows"`, plaintext, `schemaVersion: 1`). Either add `"windows"` to `validCliMissionSource` **and** send a sealed v2 payload through `createCliAgentMission`, or stop treating `FirestoreMissionDispatchHost` as a writer of this collection (demo/empty host only). Do not leave a half-broken Windows create.
- [ ] Commit: `fix(clients): create/cancel/approve missions only through callables`

### Task A8: ADR + threat-model honesty + CHANGELOG

**Files:**
- Create: `docs/architecture/016-remote-mission-integrity.md`
- Modify: `docs/architecture/README.md` table
- Modify: `docs/THREAT_MODEL.md` (mission collection section)
- Modify: `CHANGELOG.md`

ADR must state: daemon evaluate is the only attenuation; server trusts attested Mac; owner token is not a host.

- [ ] Write the ADR.
- [ ] CHANGELOG under Unreleased: mission create/claim/cancel are server-owned.
- [ ] Register any new collection/prefix in `dataExport.ts` + `packages/data-domains/registry.json` even if PR-A adds none yet (claim/status stay on the existing mission collection). PR-B/C must not ship `burnbar_attachments` / `mission_approval_ceilings` / `mission_approval_answers` without this pair.
- [ ] Commit: `docs: ADR 016 remote mission integrity`

### PR-A validation (not optional)

```bash
node tools/schema-sync/check-drift.sh
node functions/scripts/test-firestore-rules.mjs
npm --prefix functions test -- --testPathPattern 'cliAgentMissions|writeSignalAtRest|callableRateLimits'
# cheapest relevant app tests:
./scripts/test-openburnbar-app.sh OpenBurnBarTests/CLIAgentMissionClaimCallableTests
cd android && ./gradlew :app:testDebugUnitTest --tests 'com.openburnbar.data.catalog.*' --tests 'com.openburnbar.data.assistants.CLIAgentMissionDispatcher*'
```

Mac app build is nightly. Do not open a PR whose only job is to wake a rented Mac.

**Rollback:** revert the PR. Rules go back to client create; callables 404; old clients start working again. That is acceptable only as an emergency. Forward-fix is preferred because the holes are live.

**Known residual after A:** grok/kimi/gemini still do not launch. File plane unchanged. Events are server-written only.

---

## 10. PR-B — Drive + file plane

**Theme:** both directions, crypto-sound, metered. No Agent Control UI.

### Task B1: OBFS1 + KATs

**Files:**
- Create: `OpenBurnBarCore/Sources/OpenBurnBarMedia/FileSealAEAD.swift`
- Create: `android/app/src/main/java/com/openburnbar/data/media/FileSealAEAD.kt`
- Create: `OpenBurnBarCore/Tests/OpenBurnBarMediaTests/Fixtures/FileSealAEADVector.json`
- Create: `OpenBurnBarCore/Tests/OpenBurnBarMediaTests/FileSealAEADVectorTests.swift`
- Create: `android/app/src/test/java/com/openburnbar/data/media/FileSealAEADVectorTest.kt`
- Copy fixture to `android/app/src/test/resources/media-aead/FileSealAEADVector.json` (same workflow as MediaFrameAEAD)

**Interfaces:**

```swift
public enum FileSealAEAD {
    public static let chunkPlaintextBytes = 32 * 1024 * 1024
    public static let nonceSize = 12

    public struct Header: Equatable {
        public var attachmentId: String
        public var totalChunks: Int
        public var plaintextSize: Int64
        public var contentBlake3: String
    }

    /// Mint once per begin(). Never reuse across attachments or retries.
    public static func mintContentKey() -> Data // 32 bytes

    /// Random 12-byte IV via PlatformCrypto.randomBytes. Stored with the chunk.
    /// Tests / KATs pass an explicit nonce through sealChunk(nonce:).
    public static func mintNonce() throws -> Data

    public static func sealChunk(
        plaintext: Data,
        contentKey: Data,
        header: Header,
        chunkIndex: UInt64,
        nonce: Data
    ) throws -> (ciphertext: Data, tag: Data)

    public static func openChunk(...) throws -> Data
}
```

Do **not** HKDF-derive the IV from the content key. A retry of a chunk calls `mintNonce()` again. A retry of `begin` mints a new `attachmentId` and content key on the server — the client must discard the old key.

AAD = `attachmentId || be64(chunkIndex) || be64(totalChunks) || be64(plaintextSize)`. Wire layout per chunk: `nonce(12) || ciphertext || tag(16)` (same shape as `MediaFrameAEAD` after the magic).

`contentKey` is wrapped with the existing CloudVault wrap (`CloudVaultCrypto` / HPKE-ECIES). Rotation rewraps the ~300-byte wrap only.

- [ ] Check in a fixture generated by a tiny Swift command-line snippet; do not hand-wave bytes.
- [ ] Include negative vectors: flipped index, flipped attachmentId, truncated tag, reseal attempt.
- [ ] Run both language suites.
- [ ] Commit: `feat(media): OBFS1 chunked AEAD with cross-language KATs`

### Task B2: Attachment TypeSpec + callables

**Files:**
- Modify: `tools/schema-sync/typespec/domains/missions.tsp` or new `burnbar-attachments.tsp`
- Create: `functions/src/callables/burnbarAttachments.ts`
- Create: `functions/src/__tests__/burnbarAttachments.test.ts`
- Create: `functions/src/scheduled/reapBurnbarAttachments.ts`
- Modify: `firestore.rules` (new collection: client read of metadata only; no client write)
- Modify: `storage.rules` (still no client write — signed URLs only)

Collection: `users/{uid}/burnbar_attachments/{id}`

Do **not** reuse `blobHash`. Fields:

```
id, contentBlake3, byteCount, chunkCount, transport ∈ {p2p, cloud},
state ∈ {pending_upload, composing, uploaded, expired, deleted},
sealedMeta, sealedContentKey, storagePath, storageGeneration,
meteredBytes, expiresAt, customTime, createdAt, updatedAt
```

Callables (all `onCallProduction`, App Check, Pro / `hosted_media_sync` entitlement, phone or Mac trusted-device proof as appropriate):

| Callable | Does |
|----------|------|
| `beginBurnbarAttachment` | Server-mints `id`. Caps 20GiB. Entitlement: Pro ≤200MB unless `hosted_media_sync`. Returns part count and wrapped-key slot |
| `mintBurnbarAttachmentPartURL` | v4 signed PUT, `content-length` pinned to the sealed chunk size, 10 min, one part index |
| `composeBurnbarAttachment` | Hierarchical compose, ≤32 sources per call, `ifGenerationMatch: 0` on each intermediate and on the final object |
| `finalizeBurnbarAttachment` | Transaction: state in `{pending_upload, composing}`. `getMetadata` size + generation. Persist `meteredBytes = metadata.size`. Increment daily quota from that size. Rotate/expire part URLs. Idempotent only if generation+size match |
| `ticketBurnbarAttachmentDownload` | octet-stream + attachment disposition; generation pin on GET |
| `deleteBurnbarAttachment` | deletes object + tombstones doc |

Quotas (Remote Config tunable, defaults):

- 10GiB/day outbound, 10GiB/day inbound, per uid
- **10GiB/file** (not 20GiB). A 20GiB file and a 10GiB/day cap are contradictory without multi-day reservation, which this program does not invent. If product later wants 20GiB, it ships a reservation ledger in the same PR as the raise.
- `begin` **reserves** `byteCount` against the remaining daily budget (GCS-stat usage + outstanding reservations). Finalize settles to `metadata.size` and releases unused reservation. A lie that under-reports is caught at finalize and charged the real size; over-budget finalize deletes the object and fails.
- Counters live in Admin-written `users/{uid}/_rate_limits/burnbar_attach_{day}_{dir}` — **written only after GCS stat** (reservation is a separate pending doc).

Compose tests run against a **real GCS bucket** (or the production-shaped test project). The Firebase Storage emulator supports copy/delete/get/insert/list/patch/rewrite/update — **not compose**. Emulator tests may cover begin/finalize state, not the 33-part tree.

Signed PUT URLs are bearer capabilities. TTL ≤ 15 minutes, `content-length` pinned, `x-goog-if-generation-match: 0` on first write, revoked/rotated at finalize. Possession of a stale URL after finalize must 403.

GCS lifecycle / `customTime` can take up to 24 hours to apply. The hourly reaper is the GC. Lifecycle is a backstop, not the delete path.

Do not claim the server is blind. Docs say: ciphertext is opaque; size, timing, chunk count, and generation are visible to the operator of the project.

Compose math: 64MiB sealed parts, 20GiB ≈ 320 parts → 10 groups of 32 → 1 final. Test with 33 parts minimum.

Reaper (hourly, `onSchedule`):

- Delete `pending_upload` / `composing` older than 24h.
- Stat leftover parts and either meter or delete so they are not a free side channel.
- Sweep `users/{uid}/hermes_gateway_attachments` past `expiresAt` and delete the Storage objects. This is the existing leak.

- [ ] Tests: lie-about-size, second finalize with swapped bytes, 33-part compose source counts, quota from `metadata.size`, reaper on gateway + new parts.
- [ ] Commit: `feat(functions): burnbar_attachments finalize-once and GCS-stat quotas`

### Task B3: Streaming seal + 2GiB constants + Mac landing

**Files:**
- Modify: `AgentLens/Services/Media/MacFileTransferService.swift` (delete the 64MiB one-shot path)
- Modify: `OpenBurnBarCore/Sources/OpenBurnBarIrohRelay/IrohBlobBackend.swift:81`
- Create: `AgentLens/Services/Media/MacAttachmentLandingService.swift`
- Modify: `AgentLens/Services/ComputerUse/AgentContextTargetReceiver.swift:212`
- Test: landing + receiver

Landing algorithm:

1. Fail closed if there is no file/session key. Do **not** keep today’s no-key path that lands up to 512MiB plaintext in `Caches/Mercury/Inbox`.
2. If P2P inbox has a blob whose **verified** plaintext blake3 equals `contentBlake3`, use it.
3. Else download via ticket, stream-open OBFS1, verify blake3.
4. If digest does not match, delete and fail. Do not “idempotent skip” on an unverified file.
5. Sanitize filename (no `/`, `..`, NULs). Canonicalize. Require prefix of the target workspace, `{project}/.burnbar/attachments/`, or Drop.
6. Quarantine (`com.apple.quarantine`) on macOS.
7. Return `URL`s to `AgentContextTargetReceiver` instead of `[]`. `ChatMessageRecord.attachments` is `[HermesAttachment]` with `workspaceRelativePath` — fill it; do not leave the field unused.

Idempotence key is the **verified** digest, not the ticket string.

- [ ] Test a synthetic >64MiB seal (stream).
- [ ] Assert both caps == 2 * 1024 * 1024 * 1024.
- [ ] Test path traversal rejection and double-delivery dedupe.
- [ ] Commit: `feat(mac): stream OBFS1, land attachments, raise P2P cap to 2GiB`

### Task B4: Mobile transfer clients

**Files:**
- iOS: new `BurnbarAttachmentTransferSession.swift` using `URLSessionConfiguration.background(withIdentifier:)`
- iOS: app delegate / scene hook for `handleEventsForBackgroundURLSession`
- Android **user-started** multi-GB transfers: **UIDT** (`UserInitiatedDataTransfer`) jobs, not a quota-burning WorkManager FGS. Android 16 charges regular/expedited JobScheduler/WorkManager runtime against the App Standby bucket, including work that is already in a foreground service. UIDT is the documented exemption for user-initiated large transfers. WorkManager remains fine for small/retryable parts under a few minutes.
- Android manifest still needs `FOREGROUND_SERVICE_DATA_SYNC` if a short FGS is shown; it is not the large-file engine.
- Reuse existing pickers / `AttachmentSaver`

Do not raise any UI Agent Control surface here. Composer wiring is PR-C.

- [ ] iOS: background session identifier is stable; resume-data is stored.
- [ ] Android 14: starting the worker without the FGS type is a test-time assertion on the `ForegroundInfo`.
- [ ] Commit: `feat(mobile): background chunked burnbar attachment transfers`

### Task B5: Artifact return + share targets

Artifact return: on mission `completed`, if `artifactPath` is containment-checked, OBFS1 → same pipeline → `artifact_published` event → push `mission_update` (already allowlisted) → existing saver. P2P first when paired.

Share targets last:

- iOS Share Extension → App Group container → main app `beginBurnbarAttachment`
- Android `ACTION_SEND` is an **Activity**, not a BroadcastReceiver. Copy the granting app’s URI into durable app storage **before** returning; temporary share URIs die with the grantor.
- iOS background `URLSession`: file-backed uploads only. If the **user** force-quits from the app switcher, the system **cancels all** background transfers and will not relaunch. The UI must say the transfer was cancelled, not “will resume.” Ordinary signed PUT parts are not automatically resumable; persist resume state per part and restart the part, or begin again with a new content key.

- [ ] Containment failure does not publish.
- [ ] Share-extension large file does not load the whole blob into a memory `Data`.
- [ ] Commit: `feat: artifact return and share targets for burnbar attachments`

### PR-B validation

```bash
# KATs
# Swift: FileSealAEADVectorTests
# Android: FileSealAEADVectorTest
npm --prefix functions test -- --testPathPattern burnbarAttachments
node tools/schema-sync/check-drift.sh
```

**Rollback:** leave objects in GCS; reaper deletes pending. Downgrade clients stop calling begin. Do not lower the P2P cap in a follow-up without a migration note — old peers advertising 2GiB would break.

**Do not merge PR-B if finalize can succeed without a GCS generation pin.**

---

## 11. PR-C — Agent Control + backends

**Theme:** every executable agent, after A and the ACP record. File-attach to a mission needs B merged.

### Task C1: Tolerant relay decode (first commits of this PR)

**Files:**
- Modify: `OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/HermesConnectionTypes.swift`
- Modify: `OpenBurnBarMobile/Services/CLIAgentRelayChatTransport.swift:148-159`
- Test: transport + contract tests

```swift
public enum CLIAgentRelayChatEventKind: String, Codable, Sendable, Equatable {
    case assistantSnapshot
    case completed
    case failed
    case unknown          // decode fallback
    // after this commit is released, a later commit in THIS PR may add:
    // case approvalRequest, approvalResolved, interrupted, sessionStatus
}
```

Unknown `kind` → `.unknown`, stream continues. Do not latch `decodeError` on an unknown kind. Malformed JSON may still fail the stream.

Ship the decoder commit conceptually before the emitter commit. Same PR is allowed; do not emit new kinds from Mac builds that can reach old phones until the decoder is on the previous App Store / Play train **or** old phones already ignore unknown kinds via this change and you accept that in-flight mixed versions will show `.unknown`. Prefer: decoder-only TestFlight/Play roll, then emitter. If that violates “one PR,” keep the emitter behind a Remote Config flag default off for one release.

- [ ] Test: unknown kind does not throw.
- [ ] Test: truly malformed JSON still throws.
- [ ] Commit: `fix(relay): tolerate unknown CLIAgentRelayChatEventKind`

### Task C2: Per-session interrupt

**Files:**
- Modify: `HermesConnectionTypes.swift` `CLIAgentSessionActionKind`
- Modify: Mac session action handler
- Test: CU `panicHalt` suite still green; new interrupt test

```swift
public enum CLIAgentSessionActionKind: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case resume
    case handoff
    case packageOnly = "package_only"
    case interrupt
}
```

`interrupt` stops one `sessionID`. It must not call `revokeDaemonBrowserSession` / CU panic paths.

- [ ] Commit: `feat: per-session interrupt distinct from computer-use panicHalt`

### Task C3: Backends per the decision record

**Files:**
- Modify: `AgentLens/Models/ChatBackendID.swift` (add grok / kimi / gemini-or-agy if the record says they launch)
- Modify: `CLIAgentRelayChatExecutor.backend(for:)`
- Modify: `CLIAgentMissionRequestListener+Planner.swift` `directLaunchPlan` + `resolve`
- Modify: `AgentLens/Services/CLIBridge/CLIArgumentBuilder.swift`
- Modify: catalog `launch` field from `none` → `acp` or `argv`
- Test: argument builder forbids the refused flags

If the record says ACP:

- One stdio JSON-RPC client in the daemon.
- Map `session/request_permission` onto the existing approval plane (`respondMissionApproval` / Mac-signed pre-auth).
- Refuse `allow_always` and auto-accept modes.

If argv:

- grok: `-p/--single --output-format streaming-json` plus the session flags the binary actually has.
- Never `--prompt-file` unless P1 proved it. Resume today emits `--prompt-file` (`BurnBarResumeService.swift:557-561`); interactive launcher is bare `grok`.
- kimi / agy: the flags in the record.

Forbidden-flag honesty: `--always-approve` and `--yolo` have **no** current production call sites (`isYOLOGrant` is defined and uncalled). The live cousin is OMP `--auto-approve` when tools are enabled (`+Planner.swift:232`) or `trustMode == .trusted`. Do not add `--yolo`. Treat new OMP `--auto-approve` as daemon-owned-approvals-incompatible unless the decision record explicitly keeps it for trusted-desktop only.

Vendor-doc locks for P1 (do not copy `BurnBarResumeService` fossils):

- Official grok headless is `grok -p`. There is no `--prompt-file` on the current xAI scripting page. Resume still emits `--prompt-file`; the spike must measure the installed binary and stop emitting the flag if `--help` lacks it.
- Gemini `-p` **requires the prompt text**. `gemini -p --output-format json` is not a complete invocation.
- Kimi non-interactive `-p` **auto-approves regular tool calls** (Moonshot docs). That is a policy hole, not a 1-day argv spike. If the daemon owns approvals, Kimi `-p` is incompatible unless ACP `session/request_permission` works or tools are disabled.
- Consumer Gemini CLI sunset for Pro/Ultra and free Code Assist was 2026-06-18. Default “gemini” to Antigravity unless the spike proves leftover `gemini --acp` on an enterprise key the product still supports.

Bonus backends (openclaw, openclaude, omp, forge, antigravity, junie, opencode, ollama): catalog rows + quirk notes in the decision record. No extra PRs.

- [ ] Commit: `feat: launch grok/kimi/gemini-or-agy per ACP decision record`

### Task C4: Agent Control surfaces

**Files:**
- Agent Control chat today is `AgentLiveStageChatPuck`, **not** `CLIAgentChatThreadView` / `CliAgentChatView`. Those CLI views are Codex/Claude/… chat. The only already-shared piece is `AgentPermissionGrantSheet`. Do not pretend the CLI thread is Agent Control. Either embed the puck + permission sheet, or write a thin glue layer. `CLIAgentTranscriptView` is iOS-compiled and **unused** (zero call sites); Square already routes to `CLIAgentChatThreadView`. Do not revive it.
- Android: add `localApprovalResolutions` keyed by `(missionID, approvalRequestId)`. `respond()` must `rebuildSnapshot()` immediately.
- Mac `requestApproval` must mint a **new** `approvalRequestId` every park (`approval-\(UUID())`), never reuse.
- Extend `PRIMARY_SURFACES` with MissionControl, ComputerUse / Agent Control, and Hermes Square dirs (today Square is not scanned; only `HermesTabView.swift` is).
- Live deep link is `burnbar://mission/{id}` (host `mission`, push `mission` / `mission_update`). Do **not** invent `burnbar://approvals` unless the OS policy + route-map + vector land in the same PR. `#2356` adds `burnbar://fleet`, not approvals. Linux `mission_approval_decision` is a **local daemon** approve/deny (high-risk refused); it is not `respondMissionApproval`.
- `ApprovalPolicyStore` exists on both platforms; **hosts never call `resolve()`** on incoming asks. Always… records a runtime-only class and immediately responds the current ask. Android store has **no** cloud mirror. Management UI is new. Auto-apply of stored policy to a later ask is a product decision — default **off** until there is a revoke list and a test. Do not ship silent auto-approve.
- Push trigger: follow `agentNotifications.ts` template; copy must not claim App Check is always on.

- [ ] Android test: second `approvalRequestId` re-prompts; first does not re-show.
- [ ] a11y check includes the new dirs.
- [ ] Commit: `feat(mobile): Agent Control embed, approval host, Android dedupe`

### Task C5: Mac-signed pre-auth queue

**Files:**
- Create: `functions/src/callables/missionApprovalAnswers.ts`
- Create: `users/{uid}/mission_approval_answers/{id}` (callable-written only)
- Mac signer in the daemon or app Keychain
- Test: replay, expiry, cross-device, mutated grant, missing signature, prompt mismatch, double-consume

At park, Mac already has `grantCeiling` from `.requiresApproval`. Persist it on an **Admin-only sibling** `users/{uid}/mission_approval_ceilings/{requestId}` (do not stuff more keys into the mission `hasOnly` budget).

Canonical bytes (sorted keys):

```
missionID, requestedGrant, grantCeiling, promptSHA256,
personaDigest, requestedRuntime, approvalMode, issuedAt
```

`ceilingDigest = SHA-256(canonical)`. Sign with the **executor Mac** trusted escrow identity.

Functions **never-widen check only** (not `evaluate`):

- `!ceiling.commandsAllowed || requested.commandsAllowed`
- `!ceiling.fileEditsAllowed || requested.fileEditsAllowed`
- `ceiling.additionalCapabilities ⊆ requested.additionalCapabilities`
- digest matches; signature verifies against that Mac’s published identity

Phone proof binds `requestId + ceilingDigest + approve` (extend `requireTrustedDeviceActionProof` canonical fields). Replay of an old approve against a new ceiling fails.

**Honesty about presence:** today’s iOS/Android clients auto-sign device proofs. There is **no** `LocalAuthentication` / `BiometricPrompt` on `respondMissionApproval`. The server verifies possession of a trusted device key, not that a human is looking at the phone. Do not document this as “user is provably present.” Product lock: biometric step-up is required only for `commandsAllowed || fileEditsAllowed` pre-auth (high-risk). Routine read-only approvals stay device-possession, labeled honestly. Unknown future gates are not approvals — the blob binds this mission’s `ceilingDigest` and `approvalRequestId`.

`respondMissionApproval` persist: keep parking `waiting_for_approval` on approve; write `approvedCeilingDigest`. Add `mission_approval_fail` 10/900s (today this callable has **no** analog of `hermes_gateway_approve_fail`) and `appendAuditEventRequired`. Switch the export to `onCallProduction`.

At claim, Mac re-evaluates local policy, then requires computed ceiling digest **equal** to the approved digest or a **strict subset**. Wider than approved → fail closed.

`consumedAt` is transactional. At most one outstanding pre-auth per `(missionID, gateKind)`. TTL 1h default / 24h max.

Do **not** invent a Functions port of `BurnBarRemoteMissionAuthorizationPolicy`. `attenuatedCapabilityDigest` does not exist in the repo — do not pretend it does.

Linux `mission_approval_decision` stays local-daemon-only. High-risk cannot be approved from the Linux shell. Do not copy the gateway platform set (which includes macOS) onto mission approval (phone-only).

- [ ] Commit: `feat: Mac-signed single-use mission pre-auth`

### Task C6: grok-bot input + dead-lane deletion

**Files:**
- Modify: `BurnBarFleetGrokBotProbe` (keep watch-only `kill -0`)
- Create: authenticated input listener (peer-credential on loopback **or** 0600 token file)
- Every accepted input: `BurnBarFleetControlStore` fence + daemon `evaluate`
- Grant ceiling may gain `input.grok_bot` in the daemon recognized set (today the additional-capability set is empty — adding it is a real policy change, test it)
- Delete app-side `BurnBarFleetDirectiveChannel` / `BurnBarFleetDeliveryRunner` / unused `fleetDirectiveRecord` **client** only. Daemon `directive.record` RPC and tests stay.
- Orchestrator designation becomes a routing default that pre-fills `requestedRuntime` / `targetBodyID`. No new authority.

- [ ] Unauthenticated loopback test fails.
- [ ] Commit: `feat(fleet): authenticated grok-bot input; remove app-side dead directive lane`

### Task C7: File-attach composer (needs B)

Wire landed / uploaded attachment refs into `CLIAgentMissionAttachmentRef` inside `sealedPayload` (rules already cannot see inside). Mac landing already wired in B. Composer chips on the embedded chat views.

- [ ] Commit: `feat: attach files to remote missions`

### PR-C validation

```bash
node tools/schema-sync/check-drift.sh
# transport + interrupt + Android dedupe + argument-builder forbidden-flag tests
# emulator: pre-auth adversarial suite
# CU panicHalt suite must stay green
```

**Rollback:** Remote Config flag off for new backends and pre-auth. Interrupt is additive. Decoder stays (safe).

---

## 12. Standing merge gates

A PR is not mergeable if any of these is false:

1. Finalize-once is enforced against Storage generation, not a status string.
2. File-chunk GCM uses a stored random IV; never a derived nonce. A `(content-key, IV)` pair is still one-use.
3. Quotas and integrity come from GCS metadata.
4. Every writer to `cli_agent_mission_requests` or `burnbar_attachments` updates the catalog / rules fixture in the **same** PR.
5. Loopback is authenticated.
6. Docs say the server trusts the attested Mac and never re-evaluates.
7. Tolerant decode is on the wire before new kinds are emitted (or RC-gated).
8. Fast checks are green. Mac app build is not the merge ticket.
9. `writeSignalAtRestDocument` cannot overwrite a mission.
10. No `--yolo` / `allow_always` / `--always-approve` in any new launch path.
11. New collections/prefixes are in the DSR registry in the same PR.
12. Compose is proven on a real bucket, not the Storage emulator.
13. No “server learns nothing” copy.
14. Relay timeout cannot create a second mission.

---

## 13. Verification matrix

| Assertion | PR | Command / surface |
|-----------|----|-------------------|
| VAL-CTL-001 create throttle + client deny | A | Functions tests + rules T12 |
| VAL-CTL-002 two-Mac claim + loser fail | A | `cliAgentMissions.test.ts` + rules T13/T14 |
| VAL-CTL-003 cancel precondition | A | rules T10a–T10f |
| VAL-CTL-004 catalog persist | A | rules T15/T16 + catalog tests |
| VAL-CTL-005 interactive routing | A | DirectExecution unit |
| VAL-CTL-006 Windows approval | A | `FirestoreMissionDispatchHostTests` + rules |
| VAL-CTL-007 Signal overwrite | A | `writeSignalAtRestDocument` test |
| VAL-CTL-008 event append binding | A | rules T17 + append callable tests |
| VAL-CTL-009 relay no double-exec | A | `CLIAgentMobileChatService` timeout unit |
| VAL-CTL-010 approver field | A | daemon context after approve |
| VAL-FILE-001 OBFS1 KATs | B | Swift + Kotlin vector tests |
| VAL-FILE-002 finalize-once | B | `burnbarAttachments.test.ts` |
| VAL-FILE-003 quota-by-stat | B | same + reaper test |
| VAL-FILE-004 compose ≤32 | B | 33-part test |
| VAL-FILE-005 landing | B | Mac landing unit |
| VAL-FILE-006 2GiB constants | B | constant + stream seal test |
| VAL-AGT-001 tolerant decode | C | transport test |
| VAL-AGT-002 interrupt | C | session action + CU suite |
| VAL-AGT-003 backends | C | argv/ACP tests vs decision record |
| VAL-AGT-004 Android dedupe | C | Android JVM |
| VAL-AGT-005 pre-auth | C | callable adversarial suite |
| VAL-AGT-006 grok-bot auth | C | listener unit |
| VAL-CROSS-001 offline queue | C | emulator pieces + device note |
| VAL-CROSS-002 blake3 round-trip | B/C | landing + download ticket |

Per-backend (after C): phone dispatch → running event → terminal event → readable transcript mirror, including the runtimes the old allowlists dropped (kimi, gemini, openclaude). That is the point of A’s generated lists.

---

## 14. Residual risks (named, not wished away)

| Risk | Why it remains | Containment |
|------|----------------|-------------|
| Compromised trusted Mac | Product trust root | Daemon evaluate + local CU panicHalt + attested device proof |
| App Check config-gated | `respondMissionApproval` already works this way; production refuses start if disabled in config, but Firebase Console enforcement is outside the repo | Nonce + Pro + trusted-device proof stay unconditional; docs must not claim App Check is a guarantee |
| Mixed `canceled` / `cancelled` | Two live spellings | Dual-read forever in this program; do not silently unify |
| Android cancel AAD | `sealedMissionStateUpdate` defaults `aadContext = null` | Fixed in A7; T10g |
| Mac `approvalRequestId` reuse | `requestApproval` keeps the existing id | C4 mints a new UUID every park |
| `kimi`/`gemini` silent remap | planner falls through to first enabled backend | A6 fail-closed |
| CLI thread ≠ Agent Control | Agent Control is `AgentLiveStageChatPuck` | C4 does not embed CLI chat as CU |
| No-key 512MiB plaintext inbox | `frameSealKeyProvider` defaults nil | B3 fail-closed without a key |
| In-flight old phones after A | Old clients `setDoc` create → denied | Ship A behind a short dual-read only if a phased cutover is required; preferred is same-day client + rules because the holes are live. If phased: callable first (still allow client create) **then** deny client create once crashlytics shows the old build is gone — that leaves the hole open during the window. Prefer hard cut |
| GCS componentCount on hierarchical compose | Current GCS docs no longer state the historical 1024 component cap | 32-wide hierarchy stays under any plausible cap; pin generation+size, do not SHA-256-stream 20GiB composites |
| Installed `grok` may still accept undocumented `--prompt-file` | P1 must measure | Do not emit unless `--help` has it |
| Vault/HPKE wrap rotation vs ADR-001 | Track B wrap is CloudVault; ADR-001 describes at-rest HPKE | PR-B uses the existing wrap helper; rotation rewraps the content-key wrap only. Do not invent a second wrap |
| Windows host vs rules was not executed end-to-end in this planning pass | `RespondToApprovalAsync` is source-incompatible with current rules | A6/A7 tests are the close |
| `schema-drift` required vs optional GitHub check | Not verified against branch-protection JSON | Fast checks still run in `fast-feedback.yml`; do not add a duplicate |

---

## 15. What “done” looks like

A reviewer can:

1. Point at Admin-SDK transactions for create, claim, cancel, host status, and event append.
2. Point at a failing-then-passing two-Mac race test, with evaluate **after** claim.
3. Point at `writeSignalAtRestDocument` refusing this collection.
4. Point at one catalog fixture that generated every allowlist in the same PR.
5. Point at OBFS1 KATs with stored random IVs, plus finalize that pins GCS generation on a **real** bucket.
6. Point at an ACP decision record whose flags match the launch tests (including Kimi `-p` auto-approve incompatibility).
7. Point at Android dedupe covering a second `approvalRequestId` that Mac actually minted.
8. Read the ADR and see the sentence: the server trusts the attested Mac and never re-evaluates.
9. Point at a timeout-after-bytes test that does **not** dispatch a fallback mission.
10. Point at DSR export/delete covering `burnbar_attachments`.

If any of those is missing, the program is not done.

---

## 16. Execution handoff

Plan saved to `plans/2026-08-19-remote-agent-control-and-file-share.md`.

Implement in this order: **P0 → A (whole) → B (whole, parallelizable after A1) → P1 before C → C (whole).**

Two execution options:

1. **Subagent-driven (recommended)** — one subagent per task above, review between tasks.
2. **Inline** — execute tasks in one session with checkpoints at each commit listed.

Do not open a 25-PR stack. Do not start C without the ACP record. Do not raise the P2P cap without streaming seal. Do not call the pipeline exactly-once until A’s emulator suite is green.
