# Hermes Gateway E2EE — all-platforms reviewer audit (2026-06-03)

Branch: `release/cut-builds-20260603`. Scope: end-to-end encryption of the Hermes
Gateway across iOS, macOS, Android, web console, Cloud Functions, Firestore rules,
and the external-agent adapter. Independent reviewer pass (crypto reasoned by the
lead; per-platform recon by adversarial subagents; adapter interop executed).

## Verdict: SHIP. The gateway is genuinely end-to-end for confidentiality. One real
integrity gap (server could FORGE an unsealed reply) was found and FIXED.

## What was verified
- **Crypto primitive** (`OpenBurnBarCore/.../HermesRelayCrypto.swift`): ephemeral-static
  ECIES (P-256 ECDH → HKDF-SHA256 empty-salt → AES-256-GCM, 12B nonce/16B tag,
  `.combined`, X9.63 65B pubkeys), CSPRNG keys, **distinct namespaced AAD per context**
  (gatewayEvent/Message/attachmentManifest/Body/Key) blocking cross-context replay. Sound.
- **Blind server** (`functions/src/hermesGateway.ts` + `callables/hermesGateway.ts`):
  `gatewayPlaintextWriteAllowed`→false; `requireGatewayRelayEnvelope` shape-only +
  `relayKeyVersion===1` clamp; `serializeHermesGatewayEvent` unconditionally strips
  text/senderDisplayName/threadId on sealed/schema≥2 docs; model_switch sealed; attachments
  opaque ciphertext, no fileName in storagePath; server-side pin-only TOFU (immutable agent
  key); oversight gate control-plane-only (server-derived summary, ignores client text);
  `respondHermesGatewayApproval` requires a trusted native device (agent can't self-approve).
- **Firestore rules**: all `hermes_gateway_*` are `write:if false` (Admin-SDK-only) → no
  client can smuggle plaintext past a rule. Reads owner-scoped.
- **iOS client**: fail-closed seal-on-write; TOFU pin rejects silent key-swaps; genuine
  double-confirm re-pair; real safety-number UX (Keychain-pinned, key-faithful); attachments
  AAD-isolated; device-only Keychain; SHA256.Digest.byteCount bug fixed.
- **Adapter** (`tools/hermes-platform-burnbar/adapter.py`): **byte-exact interop with iOS
  executed** (Python opens Swift event/message/model_switch wire vectors; AAD bytes match;
  payload-AAD-as-key-AAD now fails the tag). Pins peer key, fail-closed, no plaintext on
  paired links, no encryption-disable switch.
- **Android**: no gateway message/event/attachment write paths (consumer of subscription
  metadata only); `consentGivenAt` canonical Firestore Timestamp; subscription graph sealed.
- **Honesty**: registry flipped truthfully (no stale "server-readable interim" caveat, no
  overreach); scanner/scrubber cover `hermes_gateway_*`.

## Verification matrix (green)
- functions `tsc --noEmit` clean + gateway vitest (hermesGateway, KeyImmutability, SealedEvent) — exit 0
- iOS build-for-testing + `OpenBurnBarMobileTests`: **84 tests, 0 failures, ** TEST SUCCEEDED ****
  (incl. the 2 new downgrade-protection tests + all existing gateway/pin/attachment/consent/rollback)
- data-domains `registry.test.mjs`: 15/15
- privacy scanner `scan-chat-cloud-plaintext.mjs`: PASS
- Android `:app:testDebugUnitTest` (sealed-fields): 14/14 (subagent)
- adapter crypto interop: executed against `HermesGatewayWireVector.json` (subagent)

## Fix applied (P2 integrity — server-forged unsealed reply / agent impersonation)
`OpenBurnBarMobile/Services/FunctionsRepository.swift` + call site
`OpenBurnBarMobile/Views/Hermes/HermesSettingsView.swift`:
`HermesGatewayMessageRecord.displayText` rendered the server-supplied plaintext `text`
for any unsealed doc — even on a relay-capable client whose agent key this device pinned.
The Cloud is the only writer of `hermes_gateway_messages` (`write:if false`) and cannot READ
a sealed reply, but without this gate it could FORGE an unsealed one the phone renders (and
push-notifies) as a genuine agent reply. Added `requiresSealedReply`, set in `decodedText`
from the **device-local Keychain pin** (a hostile server cannot clear it). Once an agent key
is pinned, an unsealed reply is refused everywhere it renders (`displayText`→nil,
`chatRenderText`→calm "couldn't verify" copy, `isUndecryptableHere`→reconnect affordance,
`presentReplyNotification`→same gated text); genuine un-pinned legacy clients still render
plaintext for migration. Tests: `testGatewayUnsealedReplyOnPinnedClientIsRefusedNotRendered`,
`testGatewayUnsealedReplyWithoutPinStillRendersLegacyPlaintext`. Plus `docs/PRIVACY.md` now
discloses the gateway sealed-content channel.

## Residuals (real but not ship-blocking)
- ECIES is anonymous-sender: confidentiality (the stated goal) holds; cryptographic
  sender-authenticity vs a hostile server does not. Mitigated by the new downgrade gate and
  by supervised oversight (risky actions need trusted-native approval).
- Fork-side (`Ajnunezg/hermes-agent`, not this repo): agent key not chmod-0600 under
  Docker/managed mode; best-effort key persistence (DoS not leak); non-persistent replay
  LRU(4096); no out-of-band SAS on the agent side at first pairing.
- `connected_devices` keeps the conservative `server_readable` tier badge (routing metadata
  is genuinely server-readable; the summary/serverSees/deviceOnly fields carry the sealed-
  content nuance). Under-claims, never over-claims — accepted, not changed.
