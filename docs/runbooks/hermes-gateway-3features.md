# Hermes Gateway: runtime state, model switching, oversight

Status as of 2026-06-03. Three features shipped end-to-end through the BurnBar
Cloud ↔ Hermes gateway: **(1) runtime state**, **(2) model switching**, and
**(3) human-in-the-loop oversight**. This runbook records exactly what shipped,
what was already there vs newly built, the tests run, the physical-iPhone E2E
procedure, and the readiness verdict for the Hermes plugin PR.

> **Post-merge status:** BurnBar PR #264 was merged to `main` on 2026-06-03.
> Production backfill/cleanup has been run and was idempotent on the second pass.
> The physical-iPhone pairing/connection loop was proven earlier in the release
> pass, but the full approve/deny/expiry hardware scenario was not rerun during
> the final formatting/security audit because the iPhone was offline to Xcode.

---

## 1. What shipped (per feature: already-there vs newly built)

### Feature 1 — Runtime state
- **Already there:** per-client runtime fields (`runtimeModelId/ProviderId/
  runtimeModelOptions/runtimeUpdatedAt/lastSeenAt`) written by `POST /runtime`;
  the monotonic event cursor doc; iOS already derived online/offline and showed a
  rich gateway settings panel.
- **Newly built (server):** a read-only **`GET /state`** route returning a single
  truthful snapshot — event cursor, paired clients with **derived** online/offline
  + in-flight model switch, current model/provider, `agentVersion`, oversight mode,
  connected-client count, schema + protocol version. Presence is derived from
  `lastSeenAt` at read time (never persisted → no write amplification, and a
  stopped gateway reports **offline** with zero writes). New pure helpers
  `isHermesGatewayClientOnline` (fail-closed) + `HERMES_GATEWAY_PROTOCOL_VERSION`.
- **Newly built (adapter):** reports `agentVersion` in the `/runtime` heartbeat.

### Feature 2 — Model switching
- **Already there:** first-class `model_switch` event kind; `enqueueHermesGatewayEvent`
  synthesises `/model <id>`; the adapter applies it; iOS had a full model picker +
  `enqueueHermesGatewayModelSwitch`.
- **Newly built (server):** validates the requested model against the target
  client's advertised `runtimeModelOptions` (rejects `model_not_available` only
  when a non-empty catalog is known — custom ids pass before inventory is
  reported); sets an optimistic `pendingModelId` marker in the same cursor
  transaction; clears it in `handleRuntimeStatus` once the runtime reports the
  applied model (`/state` shows `pendingModelSwitch` until then). New pure helpers
  `clientAdvertisesModel` + `pendingModelSwitchInFlight` (TTL-bounded).
- **Newly built (adapter):** after applying a `model_switch`, forces an immediate
  runtime republish (and resets the heartbeat throttle) so `/state` reflects the
  new model in ~1s instead of up to 30s.

### Feature 3 — Human-in-the-loop oversight
- **Already there:** the hardened CLI-agent mission approval primitive
  (`cli_agent_mission_requests` + `respondMissionApproval`) — trusted native escrow
  device, `approvedByDeviceId`, single transactional resolution. **Reused, not
  forked.** That collection is E2E-sealed and client-created, so a server-armed
  gateway gate cannot be written into it; the same *security model* is applied to a
  dedicated gateway collection instead (this is the one deliberate divergence from
  the most literal reading of the brief — see "Design decisions").
- **Newly built (server):**
  - `users/{uid}/hermes_gateway_approvals/{id}` — owner-read, **Admin-SDK-write-only**
    (no client/agent can self-approve). Firestore rule added + covered by the rules
    emulator test.
  - `POST /approvals` (agent arms a gate; idempotent per `clientId`+`actionId`) and
    `GET /approvals` (agent polls for the decision). Read paths derive `expired`
    so an unanswered gate never blocks the agent.
  - `respondHermesGatewayApproval` callable — **same hardened guard** as
    `respondMissionApproval`: App-Check-bound caller, a trusted native escrow
    device, single transactional resolution, server-stamped `approvedByDeviceId`.
    (`respondMissionApproval` itself is untouched — avoids conflict with its
    in-flight nonce hardening.)
  - `setHermesGatewayOversightMode` callable — per-client toggle
    (`supervised` | `autonomous`), **default supervised** (the safe option).
  - `reapHermesGatewayApprovals` scheduled function — TTL reaper (every 5 min)
    flips stale waiting gates to `expired`.
- **Newly built (adapter):** overrides `send_slash_confirm` — in *supervised* mode
  it arms a BurnBar gate and waits for the phone decision (applied via Hermes'
  own `tools.slash_confirm.resolve`); in *autonomous* mode it auto-approves so the
  agent runs unattended. If the gateway is unreachable it falls back to Hermes'
  built-in text confirm (still gated — **fails safe, not open**). Reads the toggle
  from `/state`.

---

## 2. Files changed

### BurnBar repo — server (`functions/`)
- `functions/src/hermesGateway.ts` — constants (`HERMES_GATEWAY_PROTOCOL_VERSION`,
  `PRESENCE_WINDOW_MS`, `PENDING_MODEL_TTL_MS`, `APPROVAL_TTL_MS`); types
  (`HermesGatewayOversightMode`, `HermesGatewayApprovalStatus`,
  `HermesGatewayApprovalDoc`); new client-doc fields (`agentVersion`,
  `pendingModelId`, `pendingModelRequestedAt`, `oversightMode`); pure helpers
  (`isHermesGatewayClientOnline`, `clientAdvertisesModel`, `effectiveOversightMode`,
  `sanitizeHermesGatewayOversightMode`, `pendingModelSwitchInFlight`,
  `gatewayApprovalExpiryISO`, `isHermesGatewayApprovalExpired`,
  `isHermesGatewayApprovalActionable`, `isHermesGatewayApprovalDoc`,
  `sanitizeHermesGatewayApprovalSummary`); `publicClientView`/`publicApprovalView`.
- `functions/src/callables/hermesGateway.ts` — `handleGatewayState` (`/state`);
  model validation + `pendingModelId` in `enqueueHermesGatewayEvent`; reconcile +
  `agentVersion` in `handleRuntimeStatus`; `handleArmApproval`/`handleListApprovals`
  (`/approvals`); router wiring; `setHermesGatewayOversightMode`,
  `respondHermesGatewayApproval`, `reapHermesGatewayApprovals`.
- `functions/src/index.ts` — exports the three new callables/scheduled fn.
- `firestore.rules` — `hermes_gateway_approvals` matcher (owner-read, `write: false`).
- `tools/schema-sync/emit/generate.mjs` + `typespec/domains/hermes-gateway.tsp` —
  new client fields + `HermesGatewayApprovalDoc` (TS/Swift/Kotlin). Regenerated:
  `functions/src/types/generated/hermes-gateway.ts`,
  `OpenBurnBarCore/Sources/OpenBurnBarFirestoreModels/HermesGatewayModels.swift`,
  `android/app/src/main/java/com/openburnbar/data/models/generated/HermesGatewayModels.kt`.
- `functions/scripts/test-hermes-gateway.mjs` — behavioral + route/guard assertions
  for all three features.
- `functions/scripts/test-firestore-rules.mjs` — `hermes_gateway_approvals` added to
  the server-owned/no-self-approve suite.
- `functions/src/__tests__/hermesGateway.test.ts` — vitest cases per feature.

### BurnBar repo — Hermes plugin mirror (`tools/hermes-platform-burnbar/`)
- `adapter.py` — `agentVersion` in `/runtime`; force-republish after `model_switch`;
  oversight (`send_slash_confirm` override, `_arm_approval`, `_resolve_pending_confirms`,
  `_refresh_oversight_mode`, `_post_confirm_followup`).
- `README.md` — rewritten: terse + factual, oversight/state/model-switch documented,
  stale `tools/hermes-platform-burnbar/smoke_local.py` path fixed to the Hermes-repo
  path, marketing tone removed.
- `test_oversight_local.py` — **new** runnable behavioral test (no network/runtime).

### BurnBar repo — clients
- iOS (`OpenBurnBarMobile/`) — oversight wiring (see §5; compile-pending).
- Mac (`AgentLens/`) — **not modified** in this pass (see §5).

### Hermes repo (`~/.hermes/hermes-agent`) — NOT modified by the agent
The live adapter `plugins/platforms/burnbar/adapter.py` and `gateway/platforms/
api_server.py` are dirty WIP and must not be clobbered. **Sync the mirror →
`plugins/platforms/burnbar/` is your step, after committing that WIP.** Author the
Hermes commit as Ajnunezg.

---

## 3. Tests run + results

Re-run during the post-E2EE-merge review pass (numbers grew as the E2EE agent
added its own cases to the shared files):

| Command (in `functions/`) | Result |
| --- | --- |
| `npm run build` | ✓ pass (after fixing a merge-artifact `eventId` type break + a later duplicate-`eventId` from concurrent churn) |
| `npm run lint` (gateway files) | ✓ 0 errors (pre-existing complexity/max-lines warnings only) |
| `npm run test:hermes-gateway` | ✓ pass — behavioral coverage of all 3 features' pure logic + route/guard/index/rules source assertions |
| `npm run test:firestore-rules` | ✓ **45/45** — includes oversight gate owner-read + **self-approve denied** |
| `npx vitest run src/__tests__/hermesGateway.test.ts` | ✓ **25/25** (3 feature blocks + the E2EE agent's relay/grace-window cases) |
| `test_oversight_local.py` (adapter, Hermes venv) | ✓ 7 cases |

Adapter (Hermes venv):

| Command | Result |
| --- | --- |
| `python3 -m py_compile tools/hermes-platform-burnbar/adapter.py` | ✓ |
| `HERMES_REPO=~/.hermes/hermes-agent .venv/bin/python tools/hermes-platform-burnbar/test_oversight_local.py` | ✓ 7 cases (autonomous auto-approve, supervised arm+wait, approve/deny/expire → slash_confirm, still-waiting stays pending, oversight mirrors /state, unreachable→safe text fallback) |
| `scripts/run_tests.sh tests/gateway/test_burnbar_plugin.py` (baseline, in `~/.hermes`) | ✓ 9/9 |

Swift: regenerated `HermesGatewayModels.swift` type-checks standalone (`swiftc -typecheck`). App-target Swift requires Xcode (compile-pending; SourceKit cannot resolve Firebase modules in this environment).

---

## 4. Physical-iPhone E2E (run on a real connected device — Alberto)

Pre-reqs: deploy the new functions (`burnBarHermesGateway` with `/state` +
`/approvals`, `setHermesGatewayOversightMode`, `respondHermesGatewayApproval`,
`reapHermesGatewayApprovals`) and `firestore.rules`; sync the adapter mirror into
`~/.hermes/hermes-agent/plugins/platforms/burnbar/` (after committing the WIP) and
install the latest BurnBar build on the iPhone.

1. Install latest OpenBurnBar on the iPhone.
2. `hermes gateway restart` → `hermes gateway status`.
3. `hermes gateway setup` → **BurnBar Cloud** → approve the device code in the app.
4. **Runtime state:** confirm the app shows the gateway **online**, the **current
   model**, the **agent version**, and **this client connected**.
5. **Model switch:** pick a different model on the phone; confirm it shows
   "switching…" briefly, then settles to the new model, and the gateway's next
   reply uses it. Try an off-catalog id → expect `model_not_available`.
6. **Oversight ON:** confirm oversight is **supervised** (default). Trigger a risky
   agent action that routes through Hermes' slash-confirm; confirm an approval card
   appears on the phone; **approve** it → the action runs. Repeat and **deny** → the
   action is cancelled. Leave one unanswered past the TTL → it expires.
7. **Oversight OFF:** set **autonomous**; confirm the same action runs without a
   prompt.
8. **Offline truthfulness:** stop the gateway; confirm the phone shows **offline**
   within ~90s (no faking).

---

## 5. iOS / Mac client status

- **iOS:** model picker + online/offline + rich gateway panel already existed.
  Newly wired (files: `OpenBurnBarMobile/Services/FunctionsRepository.swift`,
  `OpenBurnBarMobile/Services/ComputerUse/ComputerUseSecurityCallableClient.swift`,
  `OpenBurnBarMobile/Views/Hermes/HermesSettingsView.swift`,
  `OpenBurnBarMobileTests/OpenBurnBarMobileTests.swift`):
  - `HermesGatewayClientRecord` gained `agentVersion`, `pendingModelId`,
    `pendingModelRequestedAt`, `oversightMode` (all three decode paths) plus
    `isOversightSupervised` / `isSwitchingModel` helpers.
  - New `HermesGatewayApprovalRecord` + a Firestore listener on
    `users/{uid}/hermes_gateway_approvals` in `HermesGatewaySettingsStore`
    (`waitingApprovals`, expiry-aware).
  - `setHermesGatewayOversightMode` + `respondHermesGatewayApproval` repository
    methods; the latter delegates to a `ComputerUseSecurityCallableClient` twin of
    `respondMissionApproval`, sourcing the trusted device via
    `MobileDeviceIdentity.loadOrCreateDeviceId()` — the **same** path
    `CLIAgentMissionDispatcher` uses (no new device-trust path invented).
  - UI: a Supervised/Autonomous toggle + `agentVersion` badge + "Switching…"
    spinner on the gateway client row, and a focused approve/deny approval list
    (intentionally NOT the CLI-mission `ApprovalInboxStrip`, which is a different
    requestID namespace). Test mock updated so the test target compiles.
  - **Compile-pending:** Xcode build + device run required (cannot build here).
    Brace/paren balance verified across all four files; the agent flagged the
    `gatewayClientRow` VStack restructure as the one spot to confirm in a real
    compile.
- **Mac (`AgentLens/`):** intentionally **not** changed in this pass. The audit
  flagged that wiring a remote gateway switch onto the Mac's local model picker is a
  footgun (the local `HermesModelID` override ≠ the gateway switch catalog), and the
  E2E surface is the iPhone. Mac freshness-TTL + gateway-version display remain a
  scoped, documented follow-up.
- **Web console:** has no Hermes gateway surface (nothing to wire).

---

## 6. Design decisions (outside the most literal reading of the brief)

1. **Oversight uses a dedicated `hermes_gateway_approvals` collection, not
   `cli_agent_mission_requests`.** The latter is E2E-sealed (`contentSealed == true`
   + `validSealedPayloadForUser`) and client-created with a constrained `source`
   enum — a server-armed gateway gate cannot produce its sealed payload. The new
   collection **reuses the identical hardened resolution semantics** (trusted native
   escrow device + `approvedByDeviceId` + transaction idempotency + App Check) and
   lights up the same approval UI, without breaking the sealed-mission invariant or
   touching the in-flight `respondMissionApproval` hardening. This is "build on top,
   don't fork," interpreted faithfully given the sealed-collection constraint.
2. **Model-switch validation is advisory-strict:** reject only when a non-empty
   catalog is known and the id is absent; allow custom ids before inventory is
   reported (the runtime is the final authority).
3. **Presence is derived, never persisted** (avoids write amplification on every
   poll; a stopped gateway reads offline with zero writes).
4. **No `respondMissionApproval` / `cli_agent_mission_requests` edits**, so this
   work cannot regress the mid-flight approval-nonce security hardening.

---

## 6a. Post-merge integration with the gateway E2EE re-architecture (review pass)

While this work was in flight, a separate agent landed the **gateway E2EE
re-architecture** (`feat(gateway): end-to-end encrypt the Hermes Gateway`,
commit `edee4da0a`) into the *same* files. Schema + protocol bumped to **2**;
event/message/attachment bodies are now **sealed-only** (`resolveGatewayWriteBody`
rejects plaintext with `ciphertext_required`; `gatewayPlaintextWriteAllowed()`
returns false). The two changesets coexist; the three features survived and all
server suites are green. Review-pass findings + fixes:

All review findings below are now **RESOLVED** (remediation pass, authorized by
Alberto). Final state: build green; `test:hermes-gateway`, `test:firestore-rules`
(45/45), vitest (30/30), the privacy scanner, and the Hermes harness
(`test_burnbar_plugin.py` + `test_relay_e2ee.py`, 62 tests) all pass; the adapter
mirror is byte-identical to the verified-green `~/.hermes` deployment copy.

- **[FIXED] Build break (merge artifact):** the E2EE rewrite of
  `enqueueHermesGatewayEvent` referenced `request.data.eventId` without declaring
  it → `tsc` error; then a duplicate `eventId` appeared from concurrent churn.
  Added the field, de-duplicated. Build green.
- **[RESOLVED] P1b — plaintext approval summary (boundary-enforced).** The oversight
  gate is now **control-plane only**: `handleArmApproval` IGNORES any client-supplied
  `summary` and stores a SERVER-DERIVED, non-sensitive label
  (`"Approve {toolName} action"`). The agent's free-text command never reaches
  Firestore — the human-readable detail flows end-to-end **sealed** over the message
  channel (`_post_confirm_followup` → `_post_message(sealer=…)`, verified in the
  E2EE adapter). Enforced at the trust boundary, so no client (even an older adapter
  that still posts `summary`) can reintroduce server-readable private text. Locked by
  two regression tests in `test-hermes-gateway.mjs` and two new assertions in
  `scan-chat-cloud-plaintext.mjs` (collection is server-only-writer + the
  control-plane invariant). The non-empty derived label means **no iOS change is
  needed** — the approval card still renders meaningfully.
- **[RESOLVED] P1a — sealed confirm follow-up.** The E2EE integration already routed
  `_post_confirm_followup` through the sealed `_post_message(sealer=self._sealer)`
  path (verified); no plaintext follow-up remains.
- **[RESOLVED] P0 — adapter mirror divergence / "cp destroys E2EE" footgun.** The
  `~/.hermes` adapter already fully integrated this work's oversight + features ON
  TOP of the E2EE sealing (every oversight method present; 62 Hermes tests green).
  The stale mirror (891 lines) was synced from the verified-green canonical copy
  (1592 lines) — they are now **byte-identical**, so the footgun is gone (`cp` either
  direction is safe). `plugin.yaml`/`__init__.py` confirmed identical.
- **[RESOLVED] Redundant stopgap retired.** `test_oversight_local.py` (a standalone
  test written when the Hermes harness couldn't run against the mirror) is removed —
  the canonical `test_burnbar_plugin.py` now covers oversight, runtime-status,
  model-switch, and the relay round-trip (62 tests). README repointed to the harness.
- **[OK] `/state`, model-switch validation, `pendingModelId`, the oversight gate
  collection + callable, and the TTL reaper are all unaffected by the seal** (they
  operate on metadata, not sealed bodies) and remain green.

## 7. Readiness verdict

Updated after the gateway E2EE re-architecture landed in the same files AND the
remediation pass closed every review finding (see §6a).

- **Server (functions) — all three features, control- AND data-plane:** **ready**.
  Build, gateway contract tests, focused unit tests, privacy scanner, and the
  post-merge format gates pass. The oversight gate is sealed-consistent
  (control-plane; no server-readable command text).
- **Hermes plugin (adapter):** **ready**. The BurnBar mirror remains covered by the
  canonical Hermes gateway tests (`test_burnbar_plugin.py` + `test_relay_e2ee.py`,
  79 tests in the current harness), including relay E2EE.
- **Hermes plugin PR:** **ready for Nous submission from the verified branch/copy**.
  Keep Hermes commits separate from BurnBar commits and stage only adapter,
  crypto, tests, fixtures, and README material.
- **iOS client:** **unit/compile ready; physical full-flow still needs a fresh
  hardware readback when the iPhone is online.** Simulator `OpenBurnBarMobileTests`
  passed 88/88 during the final audit, including E2EE pinning, sealed replies,
  sealed attachments, sealed model-switch envelopes, and gateway store behavior.
  Xcode listed Alberto's iPhone as offline during this pass, so simulator success
  must not be misrepresented as physical approve/deny/expiry proof.
- **Deploy/backfill:** production cleanup/backfill ran once and the idempotence
  pass reported no remaining updates. Treat future production cleanup as an
  operator readback, not a unit-test substitute.

## 8. Final post-merge audit — 2026-06-03

GitHub Actions after PR #264 merge had two real red gates:

- `Website (types + lint + format)`: Prettier drift in website Astro files.
- `openburnbar-pr`: Prettier drift in `functions/src/callables/privacyBackfill.ts`.

The final audit fixed those gates and found one additional release-script defect:
`scripts/security/scan-publishable-tree.sh` copied tracked files into a temporary
tree but did not pass `.gitleaks.toml`, so the release scan ignored the repo's
reviewed allowlists. The script now passes the repo-root config explicitly. The
policy was also tightened with scoped allowlists for public Firebase web config,
synthetic relay-envelope fixtures, and SHA-256 purchase-token evidence hashes.

Final local evidence:

| Surface | Result |
| --- | --- |
| Website `format:check`, `check`, `build:offline`, `test:integration -- hermes-gateway-promo.test.ts` | pass |
| Functions `format:check`, `build`, focused gateway/privacy vitest, `test:hermes-gateway` | pass |
| `node scripts/privacy/scan-chat-cloud-plaintext.mjs` | pass |
| Hermes adapter gateway tests (`test_burnbar_plugin.py`, `test_relay_e2ee.py`) | 79 passed |
| Android `:app:testDebugUnitTest` | pass |
| iOS simulator `OpenBurnBarMobileTests/OpenBurnBarMobileTests` | 88 passed |
| `bash scripts/security/scan-publishable-tree.sh` | pass (`gitleaks` no leaks, `trufflehog` 0 verified secrets) |
