# Hermes Gateway: runtime state, model switching, oversight

Status as of 2026-06-04. Three features shipped end-to-end through the BurnBar
Cloud ↔ Hermes gateway: **(1) runtime state**, **(2) model switching**, and
**(3) human-in-the-loop oversight**. This runbook records exactly what shipped,
what was already there vs newly built, the tests run, the physical-device E2E
procedure, and the readiness verdict for the Hermes plugin PR.

> **Post-merge status:** BurnBar PR #264 was merged to `main` on 2026-06-03.
> Production backfill/cleanup has been run and was idempotent on the second pass.
> The 2026-06-04 E2EE remediation proof is green from a fresh clone of the Hermes
> fork branch (`78b1c7244`, `ajnunezg/burnbar-gateway-e2ee`; code proof commit
> `f79947b9b` plus security-note update). The focused mobile gateway/security
> suite now also passes on Alberto's connected physical iPad
> (`00008132-001158191E9A401C`, iPad Air 11-inch M4, iPadOS 26.5): 95 executed,
> 3 source-inspection checks skipped because the Mac workspace is not mounted in
> the app-host process, 0 failures. Live deployed readback also confirms sealed
> chat, model-switch, attachment, approval, Firestore, Storage, Cloud Logging,
> and Sentry issue/event surfaces. No external proof gate remains open for this
> remediation claim.

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
- `smoke_local.py` — local gateway smoke harness used by the remediation verifier.

### BurnBar repo — clients
- iOS (`OpenBurnBarMobile/`) — oversight wiring and gateway E2EE open/seal
  hardening (see §5).
- Mac (`AgentLens/`) — **not modified** in this pass (see §5).

### Hermes repo (`~/.hermes/hermes-agent`)
The Hermes fork branch `ajnunezg/burnbar-gateway-e2ee` now contains the BurnBar
gateway remediation code commit `f79947b9b` plus security-note commit `78b1c7244`,
and has been pushed to the `ajnunezg` remote. The BurnBar mirror adapter and the Hermes plugin adapter are
byte-identical (`sha256 971fac6de05952ee74aad6078205fc43050f9a4ff349ba0d96b9346218b5a442`).
Keep Hermes commits separate from BurnBar commits and stage only plugin/security/
test/vector material.

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
Adapter (Hermes venv):

| Command | Result |
| --- | --- |
| `python3 -m py_compile tools/hermes-platform-burnbar/adapter.py` | ✓ |
| `python tools/hermes-platform-burnbar/smoke_local.py smoke --hermes-repo ~/.hermes/hermes-agent` | ✓ local gateway smoke |
| External Hermes gateway pytest (`test_relay_e2ee*`, `test_hermes_ratchet.py`, `test_burnbar_plugin*`, `test_burnbar_hpke_v3_vectors.py`) | ✓ 211/211 |

Swift/iOS: `swift test --package-path OpenBurnBarCore --filter 'BurnBarHpkeV3CrossPlatformVectorTests|HermesRelayHPKEv3VectorTests'` passed 9 tests. Focused `OpenBurnBarMobileTests/OpenBurnBarMobileTests` passed 95 tests on simulator and on Alberto's physical iPad. Live deployed readback confirms sealed event/message/attachment storage, approve/reject/expiry approval decisions, Firestore/Storage allowlists, and Cloud Logging traffic.

---

## 4. Physical iOS E2E (run on a real connected device — Alberto)

Pre-reqs: deploy the new functions (`burnBarHermesGateway` with `/state` +
`/approvals`, `setHermesGatewayOversightMode`, `respondHermesGatewayApproval`,
`reapHermesGatewayApprovals`) and `firestore.rules`; sync the adapter mirror into
`~/.hermes/hermes-agent/plugins/platforms/burnbar/` (after committing the WIP) and
install the latest BurnBar build on the trusted iOS device.

1. Install latest OpenBurnBar on the trusted iOS device.
2. `hermes gateway restart` → `hermes gateway status`.
3. `hermes gateway setup` → **BurnBar Cloud** → approve the device code in the app.
4. **Runtime state:** confirm the app shows the gateway **online**, the **current
   model**, the **agent version**, and **this client connected**.
5. **Model switch:** pick a different model on the device; confirm it shows
   "switching…" briefly, then settles to the new model, and the gateway's next
   reply uses it. Try an off-catalog id → expect `model_not_available`.
6. **Oversight ON:** confirm oversight is **supervised** (default). Trigger a risky
   agent action that routes through Hermes' slash-confirm; confirm an approval card
   appears on the device; **approve** it → the action runs. Repeat and **deny** →
   the action is cancelled. Leave one unanswered past the TTL → it expires.
7. **Oversight OFF:** set **autonomous**; confirm the same action runs without a
   prompt.
8. **Offline truthfulness:** stop the gateway; confirm the device shows **offline**
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
  - **Current proof:** focused `OpenBurnBarMobileTests/OpenBurnBarMobileTests`
    passed 95 executed tests on the iOS Simulator and Alberto's physical iPad
    after adding a test-only key-storage seam for unsigned CI/simulator Keychain
    behavior. Production relay, ratchet, and pin private material still uses
    `WhenUnlockedThisDeviceOnly` Keychain storage and fails closed on Keychain
    errors. The 2026-06-04 focused live approval run completed deployed
    approve/reject/expiry readback against the unlocked trusted iPad.
- **Mac (`AgentLens/`):** intentionally **not** changed in this pass. The audit
  flagged that wiring a remote gateway switch onto the Mac's local model picker is a
  footgun (the local `HermesModelID` override ≠ the gateway switch catalog), and the
  remote approval E2E surface is the trusted iOS device. Mac freshness-TTL +
  gateway-version display are Mac-local visibility polish outside this gateway
  E2EE acceptance surface.
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
Alberto). Final state at that checkpoint: build green; `test:hermes-gateway`,
`test:firestore-rules` (45/45), vitest (30/30), the privacy scanner, and the
then-current Hermes harness (`test_burnbar_plugin.py` + `test_relay_e2ee.py`, 62
tests) all passed; the adapter mirror was byte-identical to the verified-green
`~/.hermes` deployment copy. Superseding 2026-06-04 proof is in §9.

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
- **[RESOLVED] P1a — sealed confirm detail.** The E2EE integration already routed
  `_post_confirm_followup` through the sealed `_post_message(sealer=self._sealer)`
  path (verified); no plaintext command detail remains.
- **[RESOLVED] P0 — adapter mirror divergence / "cp destroys E2EE" footgun.** The
  `~/.hermes` adapter already fully integrated this work's oversight + features ON
  TOP of the E2EE sealing (every oversight method present; 62 Hermes tests green).
  The stale mirror (891 lines) was synced from the verified-green canonical copy
  (1592 lines) — they are now **byte-identical**, so the footgun is gone (`cp` either
  direction is safe). `plugin.yaml`/`__init__.py` confirmed identical.
- **[RESOLVED] Redundant stopgap retired.** `test_oversight_local.py` (a standalone
  test written when the Hermes harness couldn't run against the mirror) is removed —
  the canonical `test_burnbar_plugin.py` now covers oversight, runtime-status,
  model-switch, and the relay round-trip. The current external harness has grown
  to 211 tests; see §9.
- **[OK] `/state`, model-switch validation, `pendingModelId`, the oversight gate
  collection + callable, and the TTL reaper are all unaffected by the seal** (they
  operate on metadata, not sealed bodies) and remain green.

## 7. Readiness verdict

Updated after the gateway E2EE re-architecture landed in the same files and the
2026-06-04 remediation proof closed the code/verifier findings (see §6a and §9).

- **Server (functions) — all three features, control- AND data-plane:** **ready**.
  Build, gateway contract tests, focused unit tests, privacy scanner, and the
  post-merge format gates pass. The oversight gate is sealed-consistent
  (control-plane; no server-readable command text).
- **Hermes plugin (adapter):** **ready**. The BurnBar mirror remains covered by the
  canonical Hermes gateway tests (`test_relay_e2ee.py`,
  `test_relay_e2ee_v2.py`, `test_relay_e2ee_v3.py`,
  `test_hermes_ratchet.py`, `test_burnbar_plugin.py`,
  `test_burnbar_plugin_v3.py`, `test_burnbar_hpke_v3_vectors.py`) with 211 tests
  in the current external harness, including v2/v3 relay E2EE and ratchet proof.
- **Hermes plugin PR:** **ready for Nous submission from the verified branch/copy**.
  Keep Hermes commits separate from BurnBar commits and stage only adapter,
  crypto, tests, fixtures, and README material.
- **iOS client:** **unit/compile ready on simulator and physical iPad; deployed
  approval decisions now have live trusted-device readback.** `OpenBurnBarMobileTests/
  OpenBurnBarMobileTests` passed 95 executed tests on simulator and on Alberto's
  physical iPad (`00008132-001158191E9A401C`), including E2EE pinning, sealed
  replies, destination-bound sealed attachments, sealed model-switch envelopes,
  gateway store behavior, and the app-host ratchet phone-event/agent-reply
  round trip. The focused live approval test separately armed approve/reject/
  expiry cases on the deployed gateway and proved trusted-device resolution,
  public expiry, late-response fail-closed behavior, and no plaintext command
  detail in approval docs.
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

## 9. E2EE remediation proof — 2026-06-04

Fresh-clone verifier:

```bash
HERMES_AGENT_CHECKOUT=/tmp/.../hermes-agent \
HERMES_PYTHON=/Users/albertonunez/.hermes/hermes-agent/venv/bin/python \
bash scripts/ci/verify-hermes-gateway-e2ee-remediation.sh
```

| Surface | Result |
| --- | --- |
| Privacy plaintext scanner | pass |
| Functions Hermes Gateway contract | pass |
| Focused Functions Hermes/privacy vitest | 6 files, 96 tests passed |
| Firestore rules emulator suite | 45/45 passed |
| Schema sync drift, hand mirror, and budget gate | pass |
| Gateway vector mirror diff | pass; v2 hash `e48f1b6accd295988fcd2397cf762fab7354c884ecf5eea192dc3099decc8020`, v3 hash `04ebb743b0f6df75cfa5602c18f311fe289aa6186a6e3fa86ddc39021aae936f` |
| BurnBar adapter mirror diff | pass; adapter hash `971fac6de05952ee74aad6078205fc43050f9a4ff349ba0d96b9346218b5a442` |
| BurnBar adapter local gateway smoke | pass (`eventsReceived=2`, `messagesSent=4`, `attachmentUploads=3`, `attachmentFinalizes=3`, `typingEvents=1`) |
| External Hermes gateway pytest | 211 passed |
| iOS simulator `OpenBurnBarMobileTests/OpenBurnBarMobileTests` | 95 passed |
| Physical iPad `OpenBurnBarMobileTests/OpenBurnBarMobileTests` | pass; 95 executed, 3 source-inspection checks skipped, 0 failures; UDID `00008132-001158191E9A401C`; telemetry `.derived-data/test-openburnbar-mobile-attempts.jsonl`; xcresult `/var/folders/dp/my0vtv691tb7sm48kktgry2w0000gn/T/openburnbar-mobile-tests/openburnbar-mobile-tests.2gQdGa/OpenBurnBarMobileTests-attempt-1.xcresult` |
| Physical iPad live approval E2E | pass; `OpenBurnBarMobileTests/HermesServiceTests/testLiveHermesGatewayApprovalResponseE2E` on `00008132-001158191E9A401C` armed approve/reject/expiry cases, trusted the iPad through native device escrow, resolved approve/reject from the trusted device, observed public expiry, and proved late expired responses fail closed |
| Live Firestore gateway clients | pass; active client `hgw_e16e63911798c721125ada4c` has relay, HPKE v3, and ratchet public capability fields and fresh `lastSeenAt`/runtime metadata |
| Live Firestore gateway events/messages | pass; recent message, model-switch, and agent-message docs for `hgw_e16e63911798c721125ada4c` carry `relayEnvelope` v2 / `payloadCiphertext` and no top-level plaintext `text`, `body`, or `message` fields |
| Live Firestore/Storage attachments | pass; 2 uploaded attachment manifests in `hermes_gateway_attachments` store `application/octet-stream`, no plaintext `fileName`, destination-bound sealed `relayEnvelope` v2, and matching opaque Storage objects in the deployed bucket |
| Cloud Logging | pass; Cloud Run revision `burnbarhermesgateway-00014-yoc` shows successful `/approvals` traffic, and callable logs show `hermes_gateway.approval_resolved` for approved and rejected decisions; the expiry late-response callable error is expected fail-closed proof |
| Live approvals | pass; docs `hga_95470e7cb6a48a8660b1b0f29d185cb384f4e04a`, `hga_df8499df712293a6d6dfd636f0d8550ebd4f1ed4`, and `hga_4c1cc9b55a69444616eb3b975bb85784bb7fb4ed` have only server-derived labels and allowlisted routing/status fields, no plaintext prompt/body/message/detail fields; trusted iPad device `6566F689-F2FA-4A57-8A0F-4B38D47A76C0`, Mac approver `23AA015D-B6C5-434C-8EBA-E33B8B8E4AAA` |
| Sentry readback | pass; transferred project `openburnbar-functions` in org `imagine-that-ai-qh` matches deployed DSN project id `4511485521362944`; browser-authenticated Sentry API readback returned `hasAccess: true`, platform `node-gcpfunctions`, first event `2026-06-01T06:52:10.682000Z`, and production issues/events including `OPENBURNBAR-FUNCTIONS-B` / `Error: Oversight request has expired.` from `2026-06-04T17:51:03.841000Z` |

Remaining non-code proof gate: none for this remediation claim. The deployed
proof is complete for live chat, model-switch, attachments, approvals,
Firestore, Storage, Cloud Logging, and Sentry.

## 10. Final adversarial audit — 2026-06-04

Verdict: **code, deployed live proof, and Sentry observability proof are
green.** The code, contract, cross-language vector, external Hermes fork,
physical iPad unit surface, live approval decisions, live cloud ciphertext
readback, and Sentry issue/event readback are green.

Final verifier rerun from the current BurnBar worktree and clean Hermes fork
checkout:

```bash
HERMES_AGENT_CHECKOUT=/Users/albertonunez/.hermes/hermes-agent \
HERMES_PYTHON=/Users/albertonunez/.hermes/hermes-agent/venv/bin/python \
bash scripts/ci/verify-hermes-gateway-e2ee-remediation.sh
```

| Surface | Result |
| --- | --- |
| `git diff --check` | pass |
| Stale status-language search | pass; no remaining stale old-device, approval-open, or cloud-log-open wording in the gateway proof docs |
| External Hermes checkout | clean at `78b1c7244` on `ajnunezg/burnbar-gateway-e2ee` |
| Full E2EE remediation verifier | pass; scanner, Functions contract, 96 focused Functions tests, 45 Firestore rule tests, schema drift, vector/mirror diffs, local smoke, and 211 external Hermes tests |
| SOTA source check | pass for current claim boundary; HPKE is a good sealed-envelope primitive, while broad SOTA claims still require externally reviewed attachment/PQXDH/MLS-grade coverage documented in `docs/HERMES_GATEWAY_E2EE_REMEDIATION_PLAN.md` |

No open implementation or external admin-readback gate remains for this
remediation claim. For repeatable headless Sentry automation, create a personal
or internal-integration token with `org:read`, `project:read`, and `event:read`;
the proof above used the authenticated Sentry browser session and did not commit
or persist a secret.
