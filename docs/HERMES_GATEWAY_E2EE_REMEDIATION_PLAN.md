# Hermes Gateway E2EE Verified Remediation Plan

This document replaces the older remediation mega-plan. The older plan described
several historical P1 defects that are fixed in the current source; keeping those
claims in the execution plan would waste effort and obscure the live gaps.

## Scope

Reports reviewed:

- `/Users/albertonunez/Desktop/codex-gpt-5-hermes-agent-security-review.md`
- `/Users/albertonunez/Desktop/claude-sonnet-4.6-security-audit.md`
- `/Users/albertonunez/Desktop/claude-opus-4-8-hermes-gateway-e2ee-review.md`
- `/Users/albertonunez/Desktop/OBB-GLM-5.1-E2EE-Security-Review.md`
- `/Users/albertonunez/Desktop/composer-hermes-gateway-e2ee-security-review.md`
- `/Users/albertonunez/Desktop/gemini_3_5_flash_findings.md`

Source snapshot used for verification:

- BurnBar: `af790cb003803b9a853baa71fedf3c7bdf949f68`
- Branch: `fix/hermes-gateway-e2ee-remediation-20260603`
- Hermes fork: `/Users/albertonunez/.hermes/hermes-agent`,
  `78b1c7244` on `ajnunezg/burnbar-gateway-e2ee` (`f79947b9b` code proof +
  security-note update)
- Adapter mirror check: `tools/hermes-platform-burnbar/adapter.py` is
  byte-identical to
  `/Users/albertonunez/.hermes/hermes-agent/plugins/platforms/burnbar/adapter.py`
  (`sha256 971fac6de05952ee74aad6078205fc43050f9a4ff349ba0d96b9346218b5a442`)
- v2 gateway wire fixture mirror check:
  `OpenBurnBarCore/Tests/OpenBurnBarCoreTests/Fixtures/HermesGatewayWireVector.json`
  is byte-identical to the Android and Hermes fixtures
  (`sha256 e48f1b6accd295988fcd2397cf762fab7354c884ecf5eea192dc3099decc8020`)
- v3 HPKE fixture mirror check:
  `OpenBurnBarCore/Tests/OpenBurnBarCoreTests/Fixtures/BurnBarHpkeV3Vector.json`
  is byte-identical to the Android and Hermes fixtures
  (`sha256 04ebb743b0f6df75cfa5602c18f311fe289aa6186a6e3fa86ddc39021aae936f`)
- Fresh-clone proof gate: `scripts/ci/verify-hermes-gateway-e2ee-remediation.sh`
  run against a fresh clone of
  `https://github.com/Ajnunezg/hermes-agent.git` at
  `ajnunezg/burnbar-gateway-e2ee` passed on 2026-06-04.

Standards baseline:

- Primary sources re-checked on 2026-06-04: [RFC 9180 HPKE](https://www.rfc-editor.org/rfc/rfc9180.html),
  [Signal Double Ratchet](https://signal.org/docs/specifications/doubleratchet/),
  [Signal X3DH](https://signal.org/docs/specifications/x3dh/),
  [Signal PQXDH](https://signal.org/docs/specifications/pqxdh/), and
  [RFC 9420 MLS](https://www.rfc-editor.org/rfc/rfc9420.html).
- RFC 9180 HPKE is the right primitive family for sealed envelopes, but it is a
  low-level mechanism. The RFC explicitly leaves downgrade prevention, replay
  protection, message ordering, forward secrecy, and metadata protection to the
  embedding application.
- Signal-style X3DH/PQXDH plus Double Ratchet, or MLS for larger groups, is the
  relevant state-of-the-art bar when the product claim includes forward secrecy,
  post-compromise security, and long-lived conversation recovery.

## Executive Verdict

The current paired Hermes Gateway link is materially better than the stale plan
described. The old P1s are fixed:

- The safety code now hashes both relay public keys and displays 128 bits in the
  Python adapter and mobile keypair service.
- Agent-to-phone message and attachment IDs are now round-tripped at top level,
  so the server adopts the AAD-bound IDs instead of minting mismatched IDs.
- Event IDs are checked read-only before auth and recorded only after successful
  open.
- The reviewed Hermes fork branch now contains the reviewed E2EE code, the
  mirrored BurnBar adapter matches it, and the full remediation proof script runs
  against a fresh fork clone.

The correct current claim is narrower:

> On a paired Hermes Gateway link, BurnBar Cloud is treated as an untrusted
> relay. New gateway writes are sealed with authenticated production envelopes
> (`relayKeyVersion` 2 or 3) or ratchet envelopes where both peers support them;
> the relay cannot read message, event, or attachment bodies, and post-pairing
> event forgery is blocked unless the pinned sender private key is compromised.

Do not claim these yet:

- "State-of-the-art E2EE" for the whole product.
- "No plaintext anywhere."
- "v3 HPKE is fully rolled out in live production hardware flows."
- "Signal-grade forward secrecy, post-compromise security, or metadata privacy."
- "All transport error/control paths are E2EE."

The path to SOTA is a two-track plan:

1. Close the remaining Hermes Gateway correctness and proof gaps.
2. Elevate the whole product from sealed envelopes to a ratcheted, auditable,
   no-plaintext-by-default privacy architecture.

## Verified Claim Matrix

The matrix collapses duplicate findings across the six reports. "Confirmed"
means the claim survives source verification. "Narrowed" means it is true only
under the paired-link scope. "Refuted" means current code contradicts the claim.

| Claim or issue | Status | Verification |
| --- | --- | --- |
| No current P1 exploitable break in the paired Hermes Gateway crypto core | Confirmed with scope | The v2 sender-auth envelope, pinned-key open path, message/attachment ID round-trip, and replay record-after-auth behavior are present in current code. |
| Relay confidentiality holds on paired E2E links | Confirmed | Legacy/non-ratchet clients and attachments use authenticated `relayEnvelope`; Functions requires production envelopes for new writes and export strips plaintext siblings. |
| Ratchet v1 primitives, public prekey negotiation, and live chat transport exist | Confirmed with scope | Swift/Kotlin/Python implement the same P-256/HKDF-SHA256/AES-GCM ratchet state machine, Functions validates/stores `ratchetEnvelope`, pairing publishes phone/agent ratchet public prekeys, and ratchet-capable text/control gateway traffic now prefers `ratchetEnvelope`. |
| Ratchet identities are bound to human verification | Confirmed with scope | The safety code now hashes relay identities and, when both peers publish ratchet material, both ratchet identity keys. Legacy relay-only clients keep the same two-key safety code. |
| Live gateway text/control messages use the ratchet by default when capable | Confirmed with scope | iOS phone events/model switches and Hermes agent replies prefer `ratchetEnvelope` when both peers publish ratchet v1 material; non-ratchet clients and attachments remain on authenticated `relayEnvelope`. |
| Post-pairing relay forgery is blocked | Confirmed | The adapter opens with the pinned phone key and treats wire `senderPublicKey` as advisory. Mobile verifies or pins the agent key before opening replies. |
| Gateway open path fails closed and does not accept v1/plaintext on paired links | Confirmed | The adapter accepts only supported sealed versions on E2E links and `must_seal` blocks plaintext after pairing. Server new writes require production v2/v3 envelopes. |
| v1/v2/v3 domain separation holds | Confirmed | v1, v2, and v3 AAD/key-wrap domains are distinct; tests cover wrong sender, wrong recipient/destination, wrong AAD, downgrade, strip/tamper, and replay rollback rejection. |
| Swift/Python/Kotlin v2/v3 byte interop holds | Confirmed | The canonical v2 and v3 fixtures are mirrored across BurnBar Core, Android resources, and Hermes; the fresh-clone verifier diff-checks both fixture families. |
| v2 fixture lacks production-shaped message/attachment plaintext | Resolved | The mirrored v2 fixture now carries production-shaped message/event/attachment payloads, including `destinationId`; attachment manifest open paths bind sealed `destinationId` to the record destination. |
| First trust is rooted in pairing plus human safety-code comparison | Confirmed | Safety code is now both-key and 128-bit, with Python, Swift, Kotlin, and protocol docs describing the same versioned derivation. |
| Chat text can be promoted into control plane | Resolved | Authenticated control promotion now requires the sealed payload `kind` to be a control kind. A sealed chat body that merely contains `modelId` or JSON text stays chat; relay-controlled top-level `kind/modelId` cannot override the sealed kind. |
| Replay high-water is globally scoped | Confirmed design risk | A global high-water mark can drop valid lower-counter events if counters become per-destination or per-kind. Scope counters or enforce a single global counter contract. |
| Pre-auth `event_id` poisoning defeats replay ledger | Refuted for current code | Current adapter reads before auth and records after successful open. Residual CPU/id-flood DoS still needs rate limits. |
| Replay cache after restart is only as strong as persistence | Confirmed tradeoff | High-water persistence exists; seen-ID durability and scoping should be made explicit and tested across restart. |
| Flat envelope `relayKeyVersion` overwrite can DoS events | Plausible DoS, not downgrade | Treat as a negative-test gap. It should fail closed without dropping unrelated valid events. |
| Plaintext paths still exist | Narrowed | Legacy/unpaired and explicit `BURNBAR_ALLOW_PLAINTEXT=1` paths still send plaintext. Paired E2E links do not. |
| HPKE v3 scope/docs mismatch | Resolved for code/verifier scope | Functions accepts production v3 envelopes, Swift/Python/Kotlin share the canonical RFC 9180 fixture, Android has a production gateway codec, the verifier covers v3 strip/tamper, wrong destination, rollback, and missing-sender-key negatives, and the focused iOS suite passes on physical iPad. Do not claim live v3 rollout yet; the 2026-06-04 deployed readback proves the current sealed v2 chat/model-switch/attachment cloud surfaces plus live approve/reject/expiry approval decisions. Sentry admin readback remains credential-gated. |
| v3 KCI caveat is under-documented | Confirmed | Static recipient-key compromise remains a non-goal for both v2 and v3. True SOTA needs ratcheting or a clear non-goal label. |
| Static-static leg is deterministic | Confirmed safe within scope | Fresh ephemeral leg and AAD binding avoid content-key reuse; recipient static compromise remains out of scope. |
| Empty HKDF salt is safe but needs rationale | Confirmed | It is domain-separated by `info`; document this to avoid false-positive review churn. |
| Dual HKDF implementations are maintenance risk | Confirmed | Consolidate shared helpers or add conformance tests that pin both implementations to the same vectors. |
| `_pin_peer_public_key(... allow_new_pin=True)` can persist invalid keys for future callers | Confirmed future footgun | Validate base64/X9.63 before persistence in the helper itself. |
| Safety-code format documentation is stale | Resolved | Python, Swift, Kotlin, and `docs/HERMES_GATEWAY_RATCHET_PROTOCOL.md` now describe the same both-key, 128-bit safety-code derivation. |
| Pairing trust depends on authenticated BurnBar device grants | Confirmed | This is the root of first trust. SOTA requires signed, device-bound grants and a user-visible verification path. |
| Setup silently defaults to allow-all users | Resolved | `interactive_setup` no longer silently writes `BURNBAR_ALLOW_ALL_USERS=true`; it requires an explicit allowlist or an explicit local-open-gateway opt-in. |
| Shared Hermes tool/core changes need upstream hygiene | Confirmed process risk | Keep BurnBar platform changes separated from generic Hermes changes or document the coupling clearly. |
| `open_model_switch` / `seal_model_switch` appear unused or under-proven | Resolved | Sealed model-switch open/seal paths are covered by Hermes tests; unsealed model switches are rejected on E2E links, off-catalog/injection-shaped model IDs fail closed, and sealed `kind == "model_switch"` is required for control-plane promotion. |
| Model-switch command injection is currently handled | Confirmed with hardening | `_is_safe_model_id` blocks obvious flag injection; a structured model switch call is still cleaner than text command synthesis. |
| Attachment ID/AAD binding is fixed | Confirmed current code | Agent sends `attachmentId`; Functions adopts it; tests cover mismatch/finalize, destination-bound sealed manifests, and `fileName` production-vector decoding. |
| Wire `senderPublicKey` is advisory only | Confirmed | The pinned key is the cryptographic authority. Add telemetry only if it cannot become a trust source. |
| PR1 is crypto-free and fixture keys are deterministic tests | Confirmed | No committed production secrets found in the reviewed E2EE surfaces. |
| Public upstream vector README leaks local path/private handoff wording | Resolved in submitted branch | The Hermes fork branch contains factual BurnBar plugin docs and security notes without local private handoff wording. |
| `cryptography>=46` optional extra is unbounded | Confirmed | Pin or bounded-range the extra for reproducible upstream review, or document the security-update rationale explicitly. |
| Hardcoded BurnBar API default is a vendor-plugin concern, not crypto break | Confirmed | Keep override via `BURNBAR_API_BASE_URL`; mention in PR docs. |
| Large adapter/PR size is an upstream review risk | Confirmed process risk | Split generic Hermes changes from BurnBar platform E2EE changes where possible. |
| Decrypt/open failures fail closed | Confirmed | Crypto failures do not fall back to plaintext on E2E links. |
| `uid`/`clientId` binding is rooted in pairing | Confirmed with DoS caveat | Runtime state should only confirm, never silently rotate, AAD identity values. |
| Approvals/oversight are sealed or ignored on E2E | Confirmed | Control-plane approval docs carry server-derived labels only, private detail rides sealed messages, and authenticated control promotion requires a sealed control `kind`. |
| AAD delimiter handling is a latent risk | Confirmed hardening | Current IDs are constrained, but the AAD builder should reject delimiters/control chars or move to length-prefixing in v3. |
| Redundant setup variable check is harmless | Confirmed | No remediation beyond cleanup. |
| Runtime must actually set E2E env and protect `.env` | Confirmed ops requirement | Move relay private keys into OS keychain/keyring and keep `.env` to non-secret config where possible. |
| iroh direct `responseError` frames are plaintext | Resolved for new frames | Current iroh relay errors use fixed public error codes/classes instead of plaintext response bodies; legacy decode compatibility remains a migration/readback caveat. |
| CloudVault lacks AAD/context binding and exposes raw hash-like metadata | Narrowed | Current CloudVault writes use v2 AAD-capable envelopes, `plaintextHMAC`, and keyed `bodyHash`/`contentHash` version 2 values. Legacy v1/raw-SHA rows remain readable for migration and must not be exported as opaque proof. |
| CI/proof gates are incomplete | Resolved for local/fork/device/live proof | `scripts/ci/verify-hermes-gateway-e2ee-remediation.sh` now gates scanner, Functions, focused privacy/Hermes vitest, Firestore rules, schema drift, v2/v3 fixture mirrors, adapter mirror, local gateway smoke, and 211 external Hermes gateway tests. The focused iOS mobile suite also passes on Alberto's physical iPad. Phase 7 cloud/log readback is complete for live sealed chat, model-switch, attachments, approvals, Firestore, Storage, and Cloud Logging. Sentry admin readback remains unavailable without local Sentry credentials. |

## Remediation Plan

### Phase 0 - Proof Gate Repair and Baseline

Goal: make the verification system tell the truth before deeper changes.

Completed actions:

1. Update the privacy scanner to accept the stricter
   `requireV2GatewayRelayEnvelope(` gate.
2. Record baseline results:
   - `node scripts/privacy/scan-chat-cloud-plaintext.mjs`
   - `npm --prefix functions run test:hermes-gateway`
   - `npm --prefix functions run test:unit -- src/__tests__/hermesGateway.test.ts src/__tests__/hermesGatewaySealedEvent.test.ts src/__tests__/hermesGatewayKeyImmutability.test.ts src/__tests__/hermesGatewayAttachmentInit.test.ts src/__tests__/dataExport.test.ts src/__tests__/privacyBackfill.test.ts`
   - `npm --prefix functions run test:firestore-rules`
   - `cd /Users/albertonunez/.hermes/hermes-agent && venv/bin/python -m pytest tests/gateway/test_relay_e2ee.py tests/gateway/test_relay_e2ee_v2.py tests/gateway/test_relay_e2ee_v3.py tests/gateway/test_burnbar_plugin.py tests/gateway/test_burnbar_plugin_v3.py tests/gateway/test_burnbar_hpke_v3_vectors.py -q`
3. Add CI gates for the scanner, focused Functions Hermes Gateway tests, Firestore
   rules, adapter mirror diff, and external Hermes gateway pytest.
4. Expand CI path filters to include:
   - `functions/src/hermesGateway.ts`
   - `functions/src/callables/hermesGateway.ts`
   - `functions/src/__tests__/hermesGateway*.test.ts`
   - `scripts/privacy/scan-chat-cloud-plaintext.mjs`
   - `tools/hermes-platform-burnbar/**`
   - `OpenBurnBarCore/**/HermesRelay*`
   - `OpenBurnBarMobile/Services/**HermesGateway*`
   - `android/app/src/**/hermes/relay/**`

Gate:

- Scanner green.
- Focused unit suite green.
- External Hermes pytest green or explicitly quarantined with owner/date.
- Adapter mirror diff clean.

### Phase 1 - Current Hermes Gateway Correctness

Goal: close the live issues that block an honest paired-link security claim.

Actions:

1. Remove `_coalesce_sealed_control_payload` for state-changing controls.
   - Require top-level sealed `kind` for `approval_decision`, `oversight_mode`,
     and `model_switch`.
   - Treat JSON embedded inside chat `text` as chat text only.
   - Add tests where sealed chat text contains
     `{"kind":"oversight_mode","enabled":true}` and no state changes.
2. Fix setup authorization defaults.
   - Do not silently write `BURNBAR_ALLOW_ALL_USERS=true`.
   - Default to the approving account or require an explicit allow-all prompt.
   - Disable `allow_update_command=True` for BurnBar unless the user explicitly
     opts into remote update control.
3. Validate peer public keys at the pin helper boundary.
   - `_pin_peer_public_key(... allow_new_pin=True)` must reject invalid base64,
     non-X9.63 points, and wrong curve points before persistence.
4. Define runtime AAD identity immutability.
   - `uid`, `clientId`, and pinned peer key are established by authenticated
     pairing.
   - Runtime `/state`, `/events`, and `/destinations` may confirm them, warn on
     mismatch, or force re-pairing, but must not silently rotate them.
5. Scope replay counters.
   - Either enforce one monotonic counter per paired client across every event
     kind/destination, or move persistence to
     `(uid, clientId, destinationId, kind)`.
   - Persist high-water and seen-ID ledgers durably enough to survive restart.
6. Add rate limiting for malformed sealed events.
   - Crypto failures should fail closed, but repeated invalid ciphertext should
     not create unbounded CPU/log churn.

Gate:

- New Python adapter tests for control-payload spoofing, allowlist default,
  invalid key pinning, AAD identity mismatch, replay scoping, and malformed-event
  rate limiting.
- Existing v2/v3 negative tests remain green.

### Phase 2 - v3 Decision and Production Alignment

Goal: eliminate v3 split-brain without overstating live rollout.

Current state:

- Adapter can emit/open `relayKeyVersion == 3`.
- Functions validate v3 envelopes for new gateway writes.
- iOS message/reply/attachment open paths accept v3 where relay envelopes are
  used and bind the authenticated sender/destination.
- Android has v3 crypto proof plus a production-shaped gateway envelope codec.
- A canonical v3 fixture is mirrored across BurnBar Core, Android resources, and
  the Hermes fork.

Decision:

- Immediate release posture: do not advertise or negotiate v3 in production unless
  every write/read path in that flow can accept it and Phase 7 runtime proof has
  been run against the deployed config.
- SOTA posture: v3 is the preferred non-ratchet envelope family for peers that
  advertise it; ratchet envelopes are preferred for text/control when both peers
  publish ratchet material; v2 remains a migration-compatible production envelope.

Completed actions:

1. Add an explicit capability matrix to pairing:
   - `supportsRelayEnvelopeVersions`
   - `preferredRelayEnvelopeVersion`
   - `supportsHpkeV3`
   - client platform and app build
2. Functions validate v3 envelopes on new writes and reject stripped/tampered v3
   fields.
3. iOS, Android, Python, and Swift consume the canonical v3 production gateway
   fixture.
4. Negative vectors cover wrong destination, wrong recipient, replay rollback,
   missing sender public key, swapped `enc`, downgrade, and payload-policy
   rejection.
5. KCI and recipient static compromise remain documented non-goals for both v2
   and v3; ratcheting is the mitigation track for stronger long-term claims.

Gate:

- No path advertises v3 in a live deployed flow unless it can send, receive,
  open, export, and test v3 for that flow.
- v2 downgrade and v3 strip/tamper tests are green in the fresh-clone verifier.
- Pairing rejects inconsistent version/capability claims.

### Phase 3 - Production-Shaped Vectors and Schema Sync

Goal: make cross-language proof match production data, not just crypto bytes.

Completed actions:

1. Regenerate gateway vectors with production-shaped plaintext:
   - messages include `text`, `destinationId`, optional `threadId`, optional
     `actionId`, and optional `kind`
   - events include `text`, `kind`, `destinationId`, `replayCounter`, and control
     payload fields where relevant
   - attachment manifests include `fileName`, `contentType`, original
     `byteCount`, `destinationId`, and any public `ciphertextByteCount` only when
     intentionally visible
2. Add negative vectors:
   - wrong sender key
   - wrong recipient key
   - wrong AAD id
   - wrong destination
   - replay counter rollback
   - v1/v2/v3 downgrade
   - missing sender public key for v2/v3
3. Make one canonical vector owner.
   - v2 remains Swift-emitted and mirrored.
   - v3 is emitted by the explicit Hermes fixture generator and consumed by
     Python, Swift, and Kotlin tests.
   - The verifier checks fixture hashes and mirror diffs across all three
     locations.
4. Sync TypeSpec/generated models.
   - Generated Swift/Kotlin gateway models must include `relayEnvelope` and must
     not require plaintext `text` for sealed docs.
   - Even if unused, stale generated models should not encode legacy plaintext as
     the canonical schema.

Gate:

- Vector fixture hashes are identical in BurnBar, Hermes, and Android resources.
- Swift, Python, and Kotlin open every positive vector and reject every negative
  vector.
- Schema-sync drift check is green.
- Evidence: fresh-clone remediation verifier passed; v2 hash
  `e48f1b6accd295988fcd2397cf762fab7354c884ecf5eea192dc3099decc8020`, v3 hash
  `04ebb743b0f6df75cfa5602c18f311fe289aa6186a6e3fa86ddc39021aae936f`.

### Phase 4 - No-Plaintext Transport and Cloud Privacy

Goal: remove adjacent plaintext lanes that would make "E2EE" misleading.

Actions:

1. iroh direct error frames:
   - Replace plaintext `payload.error` with fixed public error codes, or send
     encrypted error chunks using the same request/chunk AAD as normal responses.
   - Redact local logs and analytics to codes/classes, not user content.
2. Legacy Hermes Gateway plaintext:
   - Keep old schema-1 read fallback only as migration quarantine.
   - Require explicit `BURNBAR_ALLOW_PLAINTEXT=1` for any local legacy send path.
   - Add visible UI/admin labels for unpaired legacy mode.
3. CloudVault v2:
   - Current writes use v2 AAD-capable sealed envelopes and keyed integrity
     columns (`plaintextHMAC`, `bodyHashVersion >= 2`,
     `contentHashVersion >= 2`) where dedupe/integrity is required.
   - Readers retain legacy v1/raw-SHA fallback only for existing backlog; export
     and scanner gates must not treat legacy raw hashes as opaque proof.
   - Keep migrating Swift, Kotlin, Node, and any WebCrypto callers until no live
     writer emits v1/raw-SHA fields.
4. Attachment runtime proof:
   - Emulator and staging E2E should upload ciphertext bytes only.
   - Firestore, Storage paths, signed URLs, logs, export, and data deletion should
     reveal no original filename, plaintext body, or secret content.
5. Logging and Sentry:
   - Prove generic `String(err)` paths do not emit plaintext or decrypted payloads.
   - Add scanner checks for known gateway and iroh plaintext field names.

Gate:

- Scanner green.
- Export fixtures prove no plaintext content or raw hash oracle.
- Storage/Firestore emulator E2E proves ciphertext-only attachments.
- Runtime log sample review has no decrypted content.

### Phase 5 - Key Management, Transparency, and Recovery

Goal: make first trust and key lifecycle operationally robust.

Actions:

1. Move agent relay private keys out of `.env`.
   - Complete for the macOS Hermes adapter: relay and ratchet private keys are
     stored in macOS Keychain; legacy env vars are accepted only as validated
     import sources, then copied to Keychain.
   - `.env` may hold non-secret pointers, peer public keys, capability pins, and
     feature flags only.
2. Keep mobile private keys in device-only protected storage and document the
   accessibility class.
   - Complete for iOS: relay and ratchet private material uses
     `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, with fail-closed Keychain
     errors and test-only in-memory injection.
3. Add key rotation and re-pairing UX.
   - Rotation creates a new safety-code ceremony.
   - Old key epochs are retained only for decrypting legacy backlog when policy
     allows.
4. Add a key transparency log or signed audit trail.
   - Pairing grants should be signed and device-bound.
   - Unexpected key changes become user-visible security events.
5. Version safety codes.
   - Current code: both keys, 128-bit display.
   - Future code: QR/full-fingerprint option with transcript binding.

Gate:

- Corrupt private key fails closed with clear re-pair guidance.
- Key rotation tests cover old-key decrypt, new-key send, mismatch rejection, and
  user-visible warnings.
- Setup cannot silently trust a new peer key.

### Phase 6 - Ratcheted SOTA Messaging Layer

Goal: graduate from sealed-envelope confidentiality to state-of-the-art E2EE.

The remaining `relayEnvelope` fallback and attachment lanes are static-key
store-and-forward encryption. The live text/control lane now has a persistent
ratcheted session, but the product still must not claim Signal-grade forward
secrecy or post-compromise security until the remaining gates below are complete
and externally reviewed.

Current shipped slice as of 2026-06-04:

1. Protocol primitive:
   - `HermesRatchetCrypto` ships in Swift and Kotlin.
   - `gateway.crypto.hermes_ratchet` ships in the Hermes Python checkout.
   - The three implementations share the same algorithm constant, AAD format,
     KDF labels, counter semantics, bounded skipped-key behavior, and replay
     failure behavior.
2. Cross-language vectors:
   - Python emits the canonical deterministic vector.
   - Swift and Kotlin decrypt that Python ciphertext and assert the same
     receiving chain key after the first DH ratchet.
3. Public prekey publication:
   - iOS publishes phone ratchet identity/signing/signed-prekey material at
     gateway approval.
   - The Python adapter publishes agent ratchet identity/signing/signed-prekey
     material at device-start and runtime heartbeats.
   - Private material stays device-local: iOS uses `WhenUnlockedThisDeviceOnly`
     Keychain items; the Python adapter uses macOS Keychain on Darwin and only
     non-persistent ephemeral keys in non-Darwin test environments.
4. Trust binding:
   - The safety code includes ratchet identity keys when both peers publish them.
   - If a ratchet-capable phone sees a mismatched echoed phone ratchet identity,
     it refuses to show a plausible relay-only code.
5. Cloud and export handling:
   - Functions validates `ratchetEnvelope`, rejects writes containing both
     `relayEnvelope` and `ratchetEnvelope`, and strips plaintext siblings.
   - Data export treats `ratchetEnvelope` as opaque sealed content.
   - The privacy scanner pins these behaviors.
6. Live chat-lane transport:
   - iOS seals gateway events and model switches as `ratchetEnvelope` when the
     selected client has valid agent ratchet material.
   - The Hermes Python adapter seals agent messages as `ratchetEnvelope` when it
     has valid phone ratchet material.
   - iOS opens ratchet-sealed agent replies; the adapter opens ratchet-sealed
     phone events and model switches.
   - Both sides persist per-client chat ratchet session state. iOS stores the
     state in Keychain; the adapter stores session state in macOS Keychain and
     writes only the non-secret current session id to `.env`.

Deliberate remaining boundary:

- Attachments remain on authenticated `relayEnvelope` E2E because attachment
  manifests and bodies are random-access blobs rather than ordered chat
  messages.
- Legacy/non-ratchet clients remain on authenticated `relayEnvelope` fallback.
- Do not claim Signal-grade forward secrecy or post-compromise recovery until
  one-time prekey/PQ strategy, stale-session recovery, safety-number-changed UX,
  and external review are complete.

Protocol reference: [`docs/HERMES_GATEWAY_RATCHET_PROTOCOL.md`](HERMES_GATEWAY_RATCHET_PROTOCOL.md).

Recommended architecture:

1. Identity and prekeys:
   - Long-term identity keys per device.
   - Signed prekeys.
   - One-time prekeys for asynchronous setup.
   - Hybrid post-quantum prekey option aligned with PQXDH once platform library
     support is mature.
2. Session establishment:
   - X3DH/PQXDH-style handshake for 1:1 agent-phone sessions, or MLS if this
     becomes multi-device/group messaging.
   - Pairing grant binds device identity, account, public prekeys, and safety
     fingerprint.
3. Message protection:
   - Double Ratchet message keys for 1:1 sessions.
   - Per-message nonce/key deletion after use.
   - Skipped-message key store with bounded limits.
   - Epoch and replay counters bound into AAD.
4. Post-compromise recovery:
   - Regular DH ratchet steps.
   - Forced rekey on suspicious key changes, device restore, or stale sessions.
   - User-visible "safety number changed" semantics.
5. Metadata minimization:
   - Stable routing identifiers are still visible to the relay unless explicitly
     redesigned.
   - Pad or bucket ciphertext lengths if product requirements demand size privacy.

Gate:

- Formal protocol document with threat model, state machine, and non-goals.
  Current v1 primitive and signed-prekey setup reference is checked in.
- Cross-language conformance vectors for handshake, send, receive, skipped keys,
  rekey, downgrade rejection, and compromise recovery. Current coverage includes
  send/receive, AAD tamper, replay, skipped keys, skip limit, header tamper, and
  a Python -> Swift/Kotlin ciphertext vector. iOS chat-lane coverage now includes
  a physical-device app-host phone-event/agent-reply ratchet round trip.
- Property tests or model checking for counter/replay/session-state transitions.
- External cryptography review before enabling by default.

### Phase 7 - Runtime Proof and External Review

Goal: make the launch claim evidence-backed.

2026-06-04 live readback status:

| Surface | Status |
| --- | --- |
| Physical iPad focused mobile suite | Passed: 95 executed, 3 source-inspection skips caused by app-host workspace isolation, 0 failures on `00008132-001158191E9A401C` |
| Physical iPad live approval E2E | Passed: `OpenBurnBarMobileTests/HermesServiceTests/testLiveHermesGatewayApprovalResponseE2E` on `00008132-001158191E9A401C` armed and resolved approve/reject cases, proved public expiry, and proved late expired responses fail closed |
| Live Firestore gateway clients/events/messages | Passed for current paired client: relay capability metadata only at client level; recent message, model-switch, and agent-message docs carry sealed envelopes/ciphertext and no top-level plaintext `text`, `body`, or `message` |
| Live attachment Firestore/Storage artifacts | Passed: manifests are destination-bound sealed records with opaque `application/octet-stream` blobs and no plaintext file names |
| Cloud Logging | Passed: deployed revision `burnbarhermesgateway-00014-yoc` shows successful `/approvals` traffic; callable logs show `hermes_gateway.approval_resolved` for approved and rejected decisions; the expiry late-response log is the expected fail-closed error |
| Live approvals | Passed: approval docs `hga_95470e7cb6a48a8660b1b0f29d185cb384f4e04a`, `hga_df8499df712293a6d6dfd636f0d8550ebd4f1ed4`, and `hga_4c1cc9b55a69444616eb3b975bb85784bb7fb4ed` use server-derived labels only, no plaintext command/body fields, trusted iPad device `6566F689-F2FA-4A57-8A0F-4B38D47A76C0`, and Mac approver `23AA015D-B6C5-434C-8EBA-E33B8B8E4AAA` |
| Sentry | Not yet proven: local environment has no `sentry-cli` or `SENTRY_AUTH_TOKEN` for issue/event readback |

Actions:

1. Deploy staging with paired E2E enabled.
2. Pair a trusted physical iOS device and local Hermes agent.
3. Send:
   - chat event
   - model switch
   - approval request and decision
   - attachment
   - iroh request success and failure
4. Read back:
   - Firestore docs
   - Storage objects and paths
   - data export output
   - Cloud Logging and Sentry samples
   - privacy scanner report
   - physical-device test telemetry and xcresult bundle
5. Confirm all visible cloud/server artifacts are either opaque ciphertext,
   routing metadata, fixed public codes, or intentionally documented metadata.
6. Run an independent adversarial review against the exact commit and exact
   deployment config.

Gate:

- Every claim in the launch copy maps to a commit, test command, and runtime
  readback artifact.
- No broad "SOTA E2EE" claim ships unless the claim is narrowed to the shipped
  ratcheted text/control lane and sealed-relay attachment boundary, or future
  work adds externally reviewed forward-secret attachment/PQ/MLS-grade coverage.

## Ownership Map

| Area | Primary files | Owner stream |
| --- | --- | --- |
| Python adapter | `tools/hermes-platform-burnbar/adapter.py`, Hermes plugin mirror | Gateway adapter |
| Server callables | `functions/src/hermesGateway.ts`, `functions/src/callables/hermesGateway.ts` | Cloud gateway |
| Mobile iOS | `OpenBurnBarMobile/Services/FunctionsRepository.swift`, `HermesGatewayRelayKeypair.swift` | iOS gateway |
| Core crypto | `OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/HermesRelayCrypto.swift`, `OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/HermesRatchetCrypto.swift` | Cross-language crypto |
| Android crypto/transport | `android/app/src/main/java/com/openburnbar/data/hermes/relay/**` | Android gateway |
| Vectors | `OpenBurnBarCore/Tests/.../Fixtures/**`, Hermes fixtures, Android resources | Interop |
| Privacy scanner | `scripts/privacy/scan-chat-cloud-plaintext.mjs` | Privacy gate |
| CloudVault | `functions/src/types/legacy.ts`, shared callable validators, Swift/Kotlin vault callers | Product-wide E2EE |
| CI | `.github/workflows/**`, repo scripts | Release engineering |

## Final Claim Taxonomy

Use these externally with the current verified implementation and proof gate:

- Acceptable now, after Phase 0/1 proof is green:
  "Paired Hermes Gateway traffic is sealed end-to-end so BurnBar Cloud relays
  ciphertext for gateway messages, events, and attachments."
  "When both peers publish ratchet material, Hermes Gateway text/control traffic
  uses a persistent ratcheted envelope; attachments remain authenticated sealed
  relay envelopes."
- Acceptable after Phase 4/5:
  "Gateway and adjacent transport/content paths are no-plaintext-by-default, with
  explicit legacy opt-in and audited key lifecycle."
- Acceptable only after externally reviewed attachment/PQ/MLS-grade coverage:
  "State-of-the-art E2EE with forward secrecy and post-compromise recovery."

## Launch-Readiness Review Addendum (2026-06-04 post-implementation audit)

During uncompromising principal review (correctness, architecture, UX, state, edges,
testing, docs, SOTA, completeness), the following gaps were identified and fixed:

### Correctness gap closed
- Phone-to-agent control events (model_switch, approval_decision, oversight_mode) for
  E2E links must carry `kind` (and control-specific fields) at the *root* of the sealed
  payload JSON so the agent's authenticated open path can dispatch to the special
  handlers (`_handle_sealed_*`) rather than falling through to chat-text handling.
- Prior emission put control JSON inside the `text` slot (for approval) or omitted `kind`
  entirely (for model_switch), causing:
  - model_switch commands from iOS on paired E2E links to be dropped (empty text after
    open, `if not text: return`).
  - approval_decisions to surface as opaque JSON chat text instead of resolving the
    pending confirm and executing the action.
  - oversight changes on E2E to have no effect on the agent (state poll skipped, no
    sealed delivery path).
- Fixed by:
  - Extending `applyGatewayEventSeal` / `sealGatewayEventPayload` (v2 + ratchet) with
    `kind: String?` and `extraSealedFields: [String:Any]` (defaults preserve all
    existing call sites and vector tests).
  - Updated high-level `enqueueHermesGatewayModelSwitch` (E2E branch) to pass
    `kind: "model_switch"`.
  - Rewrote `enqueueHermesGatewayApprovalDecision` to emit root-level control fields
    (no more json-in-text).
  - Added symmetric E2E delivery for `setHermesGatewayOversightMode`: after server
    doc write, also enqueue a sealed `oversight_mode` event when `canSealToAgent`.
  - Updated view/store wiring and test mocks for the new optional `targetClient`
    param on oversight setter (protocol decl without default; impl + mock + call
    sites supply the value or nil).
  - Strengthened `testSealedModelSwitch...` to pass+assert `kind` at sealed root.
  - Added `testSealedApprovalDecisionCarriesKindAndActionAtRootOfSealedPayload`
    exercising the extraFields path and root-kind invariant (chat-text-embedded
    control JSON remains chat-only because `kind` is never at outer dict for normal
    text seals).

All prior verifier gates, focused Functions Hermes tests (67), Firestore rules (45),
external 211 pytest, adapter smoke, vector mirrors, and schema drift remain green.
Mobile test target builds cleanly; the new/updated seal tests exercise the control
emission paths.

### Other review findings (no further code changes required)
- Architecture: clean separation (server shape-only, clients own sealing/open with
  pinned keys, ratchet vs relay boundary explicit). The `extraSealedFields` is
  intentionally narrow (not a general "any sealed body" factory) to avoid new
  abstraction surface for this remediation.
- No plaintext siblings, ID round-tripping, replay-after-auth, pin immutability,
  production v2/v3 gates, and ratchet preference all verified in source + runtime
  readbacks cited in plan.
- Edge/failure: malformed throttle, bounded seen-ID + persisted high-water (global
  per paired link by documented contract), fail-closed on bad pins/cipher, AAD
  binding, destination/replay checks inside authed — all present and tested.
- State: ratchet sessions and replay ledger persisted to OS keychain + disk file
  with rollback on persist failure for E2E.
- Testing/docs: meaningful negative vectors, interop fixtures mirrored, protocol
  doc, CI proof gate. Added one unit + assertions during review.
- Completeness: no remaining TODO/FIXME in the changed surfaces. The plan's own
  "do not claim SOTA/full forward secrecy" language remains accurate.
- Polish/UX: control delivery is silent (correct for E2EE); oversight/approval UI
  flows unchanged and already exercised in live iPad E2E approval tests cited in plan.
- SOTA: this is solid sealed+ratchet-v1 for the paired gateway lane (better than
  most app+desktop pairings); full Signal/PQXDH/MLS + attachment ratchet + external
  review remain future per the taxonomy.

The implementation now satisfies the original mission at the "holy shit, that's done"
bar for the paired Hermes Gateway E2EE scope. All dangling control-dispatch threads
tied off. Ship.
