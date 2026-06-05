# Hermes Gateway Ratchet Protocol v1

Status: live chat-lane ratchet transport shipped for gateway messages, events,
and model switches when both peers publish ratchet material. Attachments remain
on authenticated `relayEnvelope` E2EE for random-access blob correctness.

This document is the protocol reference for the Hermes Gateway ratchet work that
landed during the 2026-06-04 E2EE remediation pass. It describes the v1
primitive, signed-prekey setup, trust binding, shipped rollout boundary, and the
remaining gates before any product copy may claim Signal-grade forward secrecy or
post-compromise recovery.

## Threat Model

Trusted:

- The phone device that owns its local relay and ratchet private keys.
- The local Hermes agent host that owns its local relay and ratchet private keys.
- The user comparing the safety code during pairing.

Untrusted:

- BurnBar Cloud and Firestore as plaintext readers.
- Runtime `/state`, `/events`, and `/destinations` responses as key-trust
  sources.
- Any wire `senderPublicKey` field as a trust source after pairing.

Cloud may route, store, and replay opaque ciphertext. Cloud must not learn
gateway message/event/attachment plaintext. Key substitution must change the
human safety code or fail closed.

## Wire Constants

- Version: `1`
- Algorithm: `OpenBurnBar-HermesRatchet-v1-P256-HKDFSHA256-AESGCM`
- Root KDF info: `OpenBurnBar-HermesRatchet-v1-root`
- Chain KDF label: `OpenBurnBar-HermesRatchet-v1-chain`
- Message KDF label: `OpenBurnBar-HermesRatchet-v1-message`
- AAD domain: `OpenBurnBar-HermesRatchet-v1-AAD`
- Prekey setup KDF domain: `OpenBurnBar-HermesRatchet-v1-prekey-x3dh-p256`
- Session ID domain: `OpenBurnBar-HermesRatchet-v1-session`
- Live transport lane: `chat`
- Max skipped message keys: `64` by default

AAD format is:

```text
domain
u64be(len(associatedData)) || associatedData
u64be(len(algorithm)) || algorithm
u64be(len(sessionID)) || sessionID
u64be(len(senderDeviceID)) || senderDeviceID
u64be(len(receiverDeviceID)) || receiverDeviceID
u64be(len(ratchetPublicKeyBase64)) || ratchetPublicKeyBase64
u64be(version)
u64be(previousChainLength)
u64be(messageNumber)
u64be(epoch)
```

Ciphertext is `base64(nonce || AESGCM(messageKey, plaintext, aad))` with a
12-byte nonce.

## Public Prekeys

Each peer publishes public-only ratchet material:

- `*RatchetIdentityPublicKey`
- `*RatchetSigningPublicKey`
- `*RatchetSignedPreKeyPublicKey`
- `*RatchetSignedPreKeyId`
- `*RatchetSignedPreKeySignature`
- `*SupportsRatchetV1`

The signed-prekey signature payload is domain-separated:

```text
OpenBurnBar-HermesRatchet-v1-signed-prekey
u64be(len(identityPublicKey)) || identityPublicKey
u64be(len(signedPreKeyPublicKey)) || signedPreKeyPublicKey
u64be(len(signedPreKeyID)) || signedPreKeyID
```

Private material is device-local. iOS stores private halves in
`WhenUnlockedThisDeviceOnly` Keychain items. The Python adapter stores private
halves in macOS Keychain on Darwin; non-Darwin test environments use ephemeral
keys and must not be treated as durable production pairing.

## Session Setup

The live chat lane uses an X3DH-style P-256 setup from identity keys, signed
prekeys, and the initiator's initial ratchet key. There are no one-time prekeys
in v1.

For a phone-initiated session:

- DH1: `phoneIdentityPrivate x agentSignedPreKeyPublic`
- DH2: `phoneInitialRatchetPrivate x agentIdentityPublic`
- DH3: `phoneInitialRatchetPrivate x agentSignedPreKeyPublic`

The agent computes the same three DH values from the responder side. For an
agent-initiated session the roles are mirrored. The setup secret is
`HKDF-SHA256(dh1 || dh2 || dh3, salt=prekeyDomain, info=transcript, L=32)`,
where the transcript length-prefixes:

- `uid`
- `clientId`
- lane name (`chat`)
- initiator role (`phone` or `agent`)
- initiator identity public key
- responder identity public key
- initiator signed-prekey public key
- responder signed-prekey public key
- initiator initial ratchet public key

The session ID is `hgr1_` plus the first 20 bytes of SHA-256 over the same
domain-separated transcript. Device IDs are `phone:` or `agent:` plus the first
8 bytes of SHA-256 over the peer ratchet identity public key.

## Safety Code

The safety code hashes all active paired identity keys:

- Legacy relay-only clients: agent relay public key + phone relay public key.
- Ratchet-capable clients: both relay public keys + agent ratchet identity
  public key + the phone's local ratchet identity public key.

All keys are base64-decoded, sorted lexicographically by raw bytes, concatenated,
SHA-256 hashed, and displayed as the first 16 digest bytes split into eight
uppercase hex groups.

If any required key is missing or malformed, the code is absent. The app must not
fall back to a plausible relay-only code for a ratchet-capable pairing whose
ratchet identity echo does not match the local phone identity.

## State Machine

The v1 primitive is a 1:1 DH ratchet:

1. Initiator derives `(root, sendingChain)` from the shared setup secret and
   `ECDH(localInitialRatchetPrivate, remoteInitialRatchetPublic)`.
2. Responder starts with the shared setup secret and local initial ratchet
   private key.
3. On first received header, responder performs a DH ratchet, derives the
   receiving chain, generates the next sending ratchet key, and derives a sending
   chain for the reply direction.
4. Each message advances its chain by HMAC labels, deletes the used message key,
   and authenticates header fields through AAD.
5. Out-of-order messages use a bounded skipped-message key store.
6. Replay after a successful open fails because the relevant message key has
   advanced or been consumed.

## Sealed Payload Schema and Control Dispatch

Every gateway event sealed via `relayEnvelope` v2/v3 or `ratchetEnvelope` carries
the following fields inside the authenticated ciphertext:

| Field | Type | Required | Notes |
|---|---|---|---|
| `text` | String | Chat events | Empty string for control events |
| `destinationId` | String | Yes | Authenticated binding — relay cannot override |
| `replayCounter` | Int | Yes | Monotonic per-link counter |
| `senderDisplayName` | String | Yes | Must come from sealed payload, not wire metadata |
| `threadId` | String | Yes | Thread routing |
| `modelId` | String | No | Present only for model_switch events |
| `kind` | String | Control only | **Must be at root** for dispatch to sealed control handlers |

**Control event dispatch rule (critical):** For the agent to dispatch a sealed
event to a special control handler (`_handle_sealed_approval_decision`,
`_handle_sealed_oversight_mode`) instead of chat-text processing, the `kind`
field **must appear at the root of the authenticated sealed payload JSON** — not
embedded inside `text`. The receiver reads `authed.get("kind")` after open; if
absent or not a recognized control kind, the event falls through to chat-text
handling. An event whose `text` value contains embedded JSON with `kind` inside
is treated as opaque chat text only.

Control kind values:
- `approval_decision` — must carry `actionId`, `choice` at root
- `oversight_mode` — must carry `mode` at root  
- `model_switch` — must carry `modelId` at root (preferred over `text` command synthesis)

iOS emits control events as follows (all E2E paths, v2 relay or ratchet):
- `model_switch`: `kind: "model_switch"` via `applyGatewayEventSeal(kind:)`
- `approval_decision`: `kind: "approval_decision"` + `actionId` + `choice` via `extraSealedFields`
- `oversight_mode`: `kind: "oversight_mode"` + `mode` via `extraSealedFields`

Chat text events never pass `kind` or `extraSealedFields`, preserving the
invariant that only explicitly-constructed control paths can produce control-kind
sealed events.

## Shipped Boundary

Implemented:

- Swift/Kotlin/Python ratchet primitive and tests.
- Python → Swift/Kotlin deterministic ciphertext vector.
- Functions `ratchetEnvelope` validation and plaintext sibling stripping.
- Data export opaque handling for `ratchetEnvelope`.
- iOS and Python public ratchet prekey publication.
- Safety-code binding for ratchet identities.
- X3DH-style P-256 signed-prekey setup for the live chat lane.
- Persistent per-client chat ratchet session state on phone and agent.
- Live phone → agent gateway events and model switches prefer
  `ratchetEnvelope` when both peers are ratchet-capable.
- Live agent → phone gateway messages prefer `ratchetEnvelope` when both peers
  are ratchet-capable.
- Mobile read-model opening for ratchet-sealed replies, with fail-closed handling
  when the target client or local ratchet key material is unavailable.
- Legacy/non-ratchet clients still fall back to authenticated `relayEnvelope`.
- Attachments remain on authenticated `relayEnvelope` E2EE because their
  manifests and bodies are random-access blobs that do not share the chat
  message ordering guarantees.
- **Control event dispatch correctness (principal review fix):** iOS E2E sends
  for `model_switch`, `approval_decision`, and `oversight_mode` now emit `kind`
  (and control-specific fields) at the root of the sealed payload so the agent's
  authenticated open path dispatches to the correct sealed control handler.
  Prior to this fix, control events were silently dropped (model_switch) or
  surfaced as JSON chat text (approval_decision). All three control kinds are
  covered by unit tests verifying root-level `kind` invariant.

Remaining non-goals and gates:

- One-time prekey consumption.
- PQXDH/MLS hybrid setup.
- Ratcheting attachment manifests and bodies. The current attachment lane is
  already E2E sealed, but it is not part of the ordered chat ratchet.
- Session recovery, stale-session rekey, and safety-number-changed UX.
- Cross-language vectors for the signed-prekey setup transcript.
- Property tests or model checking for session-state transitions.
- External cryptography review of the full transport.

Until those gates are complete, product copy may say the paired text/control
gateway lane uses a persistent ratcheted envelope, but must not claim
"Signal-grade E2EE" or "post-compromise recovery."

Primary references for the intended final direction:

- Signal Double Ratchet: https://signal.org/docs/specifications/doubleratchet/
- Signal X3DH: https://signal.org/docs/specifications/x3dh/
- Signal PQXDH: https://signal.org/docs/specifications/pqxdh/
- MLS RFC 9420: https://www.rfc-editor.org/rfc/rfc9420.html
- HPKE RFC 9180: https://www.rfc-editor.org/rfc/rfc9180.html
