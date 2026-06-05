# SIGNAL_ENVELOPE_V1

**Status:** DRAFT / DESIGN — no production code path emits this format yet. This is the canonical wire + key-derivation spec the four-language facades (Swift / Kotlin / TS / Rust) must implement byte-for-byte, and the contract the legacy read-only fallback set must coexist with.

**Scope:** the on-the-wire `signalEnvelope` for **Cloud Pro private data** — both (a) at-rest Cloud Vault domains (`conversations_chat`, `session_logs`, `pensieve`) and (b) the Hermes Gateway phone↔agent transport (`connected_devices`). These are *two different sealing modes* sharing one envelope grammar; the distinction is load-bearing and is confronted head-on in §3.

**Verification basis:** every existing-code claim below was checked against branch `fix/hermes-gateway-e2ee-remediation-20260603`. File:symbol refs are given inline. The official libsignal surface was read from `packages/libsignal-bridge/node_modules/@signalapp/libsignal-client/dist/*.d.ts` (pin `0.94.4`, commit `03c449017b57eccbda715b8b018dce5dff603ac6`, AGPL-3.0-only — `packages/libsignal-bridge/src/index.ts:LIBSIGNAL_PIN`).

---

## 1. The honest starting point (verified)

There is **no Signal Protocol crypto in production today.** Verified facts:

- `packages/libsignal-bridge/src/index.ts` is a 45-line **readiness stub**: `assertOfficialLibsignalReady()` only checks that 11 named symbols are not `undefined`; it performs **zero** crypto. `index.test.ts` asserts symbol presence + pin metadata only.
- Five live envelope families, **all P-256 + AES-GCM**, none of which is libsignal:
  1. **CloudVault static** (`OpenBurnBarCore/.../CloudVaultCrypto.swift`): AES-256-GCM at-rest sealing under a single per-user 32-byte vault key. `CloudVaultSealedText` (schemaVersion ≥ 2), `CloudVaultSealedPayload` (`vaultKeyID`-bound), `CloudVaultBlobEnvelope`. AAD prefix `OpenBurnBar-CloudVault-aad-v2` (`CloudVaultCrypto.swift:173`), legacy `-v1` (`:174`). Vault key escrow-wrapped via P-256 ECIES `wrapVaultKey` (info `OpenBurnBar-Escrow-v1`).
  2. **Hermes relay HPKE v2** (`HermesRelayCrypto.swift:121 gatewayRelayKeyVersion = 2`): authenticated 2-DH key-wrap, default. No `enc` field.
  3. **Hermes relay HPKE v3** (`HermesRelayCrypto.swift:127 gatewayRelayKeyVersionV3 = 3`, `:132 relayEncryptionV3 = "hpke-auth-p256-hkdfsha256-aes256gcm"`): RFC 9180 HPKE Auth via CryptoKit `HPKE.P256_SHA256_AES_GCM_256`; adds a distinct `enc` field (`HermesRelayKeyWrapV3`, `:74`); `sealKeyV3`/`openKeyV3` (`:415`/`:446`), info `OpenBurnBar-HermesRelay-HPKE-v3|` (`:507`).
  4. **Realtime relay v1** (unauthenticated ephemeral-static ECIES; shared with iroh + Pi paths; byte layout **frozen**).
  5. **OpenBurnBar Double Ratchet v1** (`HermesRatchetCrypto.swift`, algorithm `OpenBurnBar-HermesRatchet-v1-P256-HKDFSHA256-AESGCM`) — a **bespoke** ratchet, NOT libsignal.
- Server is a **blind store-and-forward**: `functions/src/hermesGateway.ts:requireGatewayRelayEnvelope` (`:648`) validates **shape only**; supported versions `{1,2,3}` (`:84`), production-writable `{2,3}` (`:77`). `resolveGatewayWriteBody` (`callables/hermesGateway.ts:364`) rejects plaintext (`ciphertext_required`, `:388`) and rejects both-envelopes-present (`ambiguous_ciphertext`, `:374`).
- Registry tiers (`packages/data-domains/registry.json`): `conversations_chat` / `session_logs` / `pensieve` / `device_trust_keys` = `end_to_end`; **`connected_devices` = `server_readable` (`:115`)** despite sealed bodies — the scanner-blind gap.
- libsignal `0.94.4` exposes exactly the surface we need (verified in `dist/`): `PreKeyBundle.new(...)` **requires** `kyber_prekey_id`/`kyber_prekey`/`kyber_prekey_signature` (PQXDH mandatory — `ProtocolTypes.d.ts:33`); `PublicKey#seal(msg, info, associatedData)` / `PrivateKey#open(ct, info, associatedData)` are a libsignal-native **HPKE** primitive (`EcKeys.d.ts:24,43`); `signalEncrypt`/`signalDecrypt`/`signalDecryptPreKey` are the Double Ratchet (`index.d.ts:339-341`, note `signalDecryptPreKey` needs the `KyberPreKeyStore`); `sealedSenderEncrypt`/`sealedSenderMultiRecipientEncrypt`/`sealedSenderDecryptMessage` exist (`index.d.ts:342-354`).

**One-line status:** `signalEnvelope` is greenfield. This spec defines the format so that when the Stream-1 bridge grows a real seal/open API, all four languages plug in identically and every legacy envelope above stays openable.

---

## 2. Design goals & non-goals

**Goals**
1. A single versioned envelope (`SIGNAL_ENVELOPE_V1`) that carries libsignal ciphertext as an opaque blob the server never decrypts.
2. **Two sealing modes** under one grammar — `at-rest` (self → own devices) and `transport` (device → device pairwise) — so the same parser/validator works for CloudVault domains and the gateway.
3. Fits the existing **advertise-then-emit capability gate** (`supportsRelayEnvelopeVersions`/`preferredRelayEnvelopeVersion`, `HermesGatewayClientDoc`) so a paired link **never downgrades**.
4. Coexists with five legacy families as **read-only fallback**; new writes never produce legacy.
5. **Cross-language byte parity** provable by a frozen KAT fixture mirroring `BurnBarHpkeV3Vector.json`.

**Non-goals**
- Does NOT change the AES-GCM **payload** sealing layer (`sealToBase64`/`openBase64`, `HermesRelayCrypto.swift:228/243`) or any AAD label string. Like v2→v3, Signal V1 changes **only the content-key wrap / session leg**, never the body cipher or the AAD grammar.
- Does NOT touch the deterministic keyed-HMAC search trapdoors. Searchability vs forward secrecy is an explicit, separately-tiered concern (§9).
- Does NOT solve key transparency (an open question for external review, §13).

---

## 3. CONFRONTING THE CORE TENSION: Signal is a session protocol, not at-rest doc sealing

Signal Protocol (X3DH/PQXDH + Double Ratchet) establishes a **pairwise, forward-secret, ephemeral session between two parties exchanging a stream of messages.** Cloud-stored Pro data is the opposite shape: a user seals data **to themselves** for **later** reads from **any of their own devices**, possibly years apart, and must support **revocation** of a lost device. A naive "ratchet the at-rest doc" is an architectural category error:

- The Double Ratchet's whole value is **forward secrecy + post-compromise security** by *destroying* keys after each message. At-rest self-encryption requires the *opposite*: a future device with the right identity must still open a years-old doc. Ratcheting at-rest either (a) deletes the key you need, or (b) pins the chain key forever (defeating the ratchet). Either way the ratchet adds risk without delivering its guarantee.
- A ratchet is strictly 1:1. "My iPhone, iPad, Mac, and a future re-installed device" is a **1:N self-group**, not a pair.

### 3.1 Decision: TWO modes, chosen per domain

`SIGNAL_ENVELOPE_V1` defines a `mode` discriminator. **Each domain is pinned to exactly one mode by the registry** (§7); a relay/attacker cannot switch modes because `mode` is bound into AAD (§5.4).

| Mode | Used by | libsignal primitive | Key lifetime | FS / PCS |
|---|---|---|---|---|
| `at-rest` | `conversations_chat`, `session_logs`, `pensieve`, `device_trust_keys` (CloudVault domains) | `PublicKey#seal` / `PrivateKey#open` (libsignal-native HPKE, `EcKeys.d.ts:24/43`) — seal the 32-byte content key once **per recipient device identity public key** | Long-term (identity key) | **No FS by design** — must be openable later. PCS via device **revocation + re-wrap** (§8), not ratcheting |
| `transport` | Hermes Gateway (`connected_devices`): events, messages, attachments | `processPreKeyBundle` → `signalEncrypt`/`signalDecrypt`/`signalDecryptPreKey` (Double Ratchet, `index.d.ts:338-341`) — encrypt the 32-byte content key as a Signal message | Ephemeral (ratchet) | **Full FS + PCS** from the ratchet |

### 3.2 Why `at-rest` uses identity-derived sealing (HPKE-to-own-device-keys), justified

For at-rest we seal the **content key** to **each of the user's own trusted device identity public keys** (and to escrow/recovery public keys), using libsignal's `PublicKey#seal`. This is *identity-derived long-term* sealing, deliberately chosen over a ratchet:

**Why this and not a ratchet / not sealed-sender-to-self:**
- **Multi-device re-read works.** Any device holding the matching private key opens the doc, including a future re-installed device that re-registers and is re-wrapped (§8). A ratchet cannot do this.
- **Revocable.** Revoking a device removes it from the recipient set and triggers re-wrap of the content key (§8) — the revoked device cannot open *re-wrapped* docs. (Caveat §3.3.)
- **It reuses an audited primitive.** `PublicKey#seal` is libsignal's own HPKE, not a bespoke construction; it composes with the existing CloudVault escrow graph (`cloud_vault_key_wrappers`, `escrow_public_keys`) by swapping the bespoke P-256 ECIES `wrapVaultKey` for `PublicKey#seal` on the **same** identity-key directory.

**Tradeoffs accepted (stated honestly):**
- **No forward secrecy at rest.** If a device's *identity private key* leaks, every doc ever wrapped to it (and not since re-wrapped) is exposed. This is intrinsic to recoverable at-rest E2EE and is the same property the current CloudVault vault key has. Mitigations: keys live in Keychain/Keystore hardware-backed storage (`WhenUnlockedThisDeviceOnly`), per-device wrap means one leak ≠ all devices, and revocation+re-wrap bounds future exposure.
- **Wrap fan-out = O(devices).** The content key is wrapped once per recipient device. For a 4-device user that is 4 small HPKE wraps per doc. Bounded and cheap; the body is sealed once symmetrically.
- **Content-key continuity.** Because all devices must open the same body, the 32-byte content key is *shared* across the recipient set for a given doc (it is the symmetric key the body is sealed under), and only the *wraps* are per-device. This is the standard at-rest pattern. The content key MUST be fresh per doc (no reuse across docs) so a revoked device that once held one doc's content key cannot open new docs.

### 3.3 Why `transport` uses the real ratchet, justified
The gateway is a genuine bidirectional message stream between two live endpoints (phone ↔ agent). Here FS/PCS are exactly what we want and the 1:1 shape fits. So `transport` mode runs the real X3DH/PQXDH + Double Ratchet: the per-message content key is delivered *as a Signal message* (`signalEncrypt` over the 32-byte content key), and the body/manifest stay AES-GCM under that content key with the existing AADs untouched. This **supersedes** the bespoke `OpenBurnBar-HermesRatchet-v1` (which must get a distinct algorithm marker so a real-Signal envelope can never be misread as the bespoke one — see §10).

### 3.4 Honest caveat on revocation
Revocation removes a device from **future** wraps and triggers re-wrap, but **the revoked device's private key is never rotated and already-wrapped docs it holds remain openable by it** until those docs are re-wrapped (verified gap: `revokeEscrowDeviceTrust`, `functions/src/callables/computerUseSecurity.ts:248`, has no key-rotation/re-wrap today). `SIGNAL_ENVELOPE_V1` mandates the re-wrap-on-revoke job in §8; until that ships, "revoked = safe" is only true for docs written/re-wrapped *after* revocation. External reviewers must treat this as a known limitation (§13 Q7).

---

## 4. Envelope versioning & the relay-key-version ladder

`SIGNAL_ENVELOPE_V1` slots in as **relay key version 4** on the gateway ladder, and as a new sealed-type alongside `CloudVaultSealedText`/`Payload` for at-rest. Constants (new):

```
gatewayRelayKeyVersionSignal      = 4
relayEncryptionSignalTransport    = "signal-doubleratchet-pqxdh-v1"      // transport mode
relayEncryptionSignalAtRest       = "signal-hpke-identity-seal-v1"       // at-rest mode
signalEnvelopeFormatVersion       = 1
```

The version 1..4 ladder mirrors the verified v2→v3 gate exactly:
- `HERMES_GATEWAY_SUPPORTED_RELAY_KEY_VERSIONS` (`functions/src/hermesGateway.ts:84`) gains `4` so reads tolerate it.
- `HERMES_GATEWAY_PRODUCTION_RELAY_KEY_VERSIONS` (`:77`) does **NOT** gain `4` in the first PR — no client can negotiate/emit it (flag OFF). It is added only when the activation PR flips the capability default.
- `requireGatewayRelayEnvelope`/`sanitizeGatewayRelayEnvelope` enforce a **strict per-version algorithm-string equality** (verified pattern at `hermesGateway.ts:665-671` / `:767-770`): version 4 + transport ⇒ `relayEncryption == "signal-doubleratchet-pqxdh-v1"`, version 4 + at-rest ⇒ `"signal-hpke-identity-seal-v1"`. Any mismatch fails closed.

---

## 5. On-the-wire format

### 5.1 Common header (both modes)
`signalEnvelope` is a JSON object stored opaquely by the server. All binary fields are base64 (standard, padded — matching existing fixtures).

```jsonc
{
  "signalEnvelopeFormatVersion": 1,        // integer; downgrade fail-close (§6)
  "mode": "at-rest" | "transport",         // bound into AAD (§5.4); not relay-mutable
  "relayKeyVersion": 4,                     // gateway ladder slot (transport); omitted for pure at-rest CloudVault docs
  "relayEncryption": "signal-doubleratchet-pqxdh-v1" | "signal-hpke-identity-seal-v1",
  "ciphertextLayer": {                      // the body — UNCHANGED AES-256-GCM layer
    "payloadCiphertextB64": "…",            // sealToBase64 output (HermesRelayCrypto.swift:228) — body bytes
    "payloadAADLabel": "gatewayEvent" | "gatewayMessage" | "cloudVault" | …,
    "schemaVersion": 2
  },
  "keyDelivery": { /* mode-specific, §5.2 / §5.3 */ },
  "binding": { /* §5.4 */ }
}
```

**Invariant:** `ciphertextLayer` is byte-identical to today's AES-GCM payload seal. The migration changes ONLY `keyDelivery`. The same 32-byte content key seals body and (for attachments) manifest under their distinct AADs, preserving the verified body↔manifest swap protection (`gatewayAttachmentManifestAAD`/`gatewayAttachmentBodyAAD`/`gatewayAttachmentKeyAAD`, `HermesRelayCrypto.swift:214/219/224`).

### 5.2 `keyDelivery` — `at-rest` mode (HPKE-to-own-device-keys)
The content key is wrapped once per recipient device/escrow public key via libsignal `PublicKey#seal`:

```jsonc
"keyDelivery": {
  "scheme": "signal-hpke-identity-seal-v1",
  "wraps": [
    {
      "recipientKind": "device" | "escrow" | "recovery",
      "recipientIdentityKeyId": "<opaque key id / fingerprint>",   // NOT a routable address
      "recipientIdentityKeyB64": "<libsignal IdentityKey public bytes>",  // also pinned; carried as hint only
      "sealedContentKeyB64": "<PublicKey#seal( contentKey, info, AAD )>"
    }
    // … one per trusted recipient device + escrow + recovery
  ],
  "contentKeyLength": 32
}
```
- `info` argument to `PublicKey#seal` = `"OpenBurnBar-Signal-AtRest-v1|" ‖ binding-string` (§5.4). `associatedData` = the same binding-string bytes. Both must match on `open` or the GCM tag fails — this is the libsignal-native HPKE behavior (`EcKeys.d.ts:41`).
- The recipient set is derived from the **trusted** device directory (`escrow_devices` where `trustState == trusted`, `EscrowModels.swift:EscrowDeviceTrustState`). A device in `pending`/`revoked` is excluded.

### 5.3 `keyDelivery` — `transport` mode (Double Ratchet)
The content key is delivered as a Signal message produced by `signalEncrypt` over the established session for `(uid, clientId)`:

```jsonc
"keyDelivery": {
  "scheme": "signal-doubleratchet-pqxdh-v1",
  "signalMessageType": 2 | 3,                 // 3 = PreKeySignalMessage (first msg, carries X3DH/PQXDH), 2 = SignalMessage
  "signalMessageB64": "<CiphertextMessage.serialize()>",  // encrypts the 32-byte content key
  "senderIdentityKeyId": "<fingerprint>",     // for pin verification; the body proves the rest
  "ratchetEpochHint": <int>                   // OPTIONAL, debugging only; never trusted for crypto
}
```
- Session establishment is the standard `processPreKeyBundle(bundle, remoteAddr, …)` (`index.d.ts:338`). The `bundle` carries the **mandatory Kyber prekey** (`PreKeyBundle.new` requires `kyber_prekey_*`, `ProtocolTypes.d.ts:33`); the responder's `signalDecryptPreKey` consumes the `KyberPreKeyStore` (`index.d.ts:341`).
- `signalMessageType == 3` ⇒ the receiver routes to `signalDecryptPreKey`; `== 2` ⇒ `signalDecrypt`.

### 5.4 `binding` — replay/tamper context bound into every AEAD
The binding string is the load-bearing anti-tamper / anti-cross-slot field. It is concatenated into BOTH the `info` and `associatedData` of every seal (at-rest) and into the AAD of the AES-GCM body layer (transport), and it reuses the **exact existing AAD grammar** so a relay cannot move ciphertext between slots, directions, or domains.

```jsonc
"binding": {
  "uid": "<owner uid>",
  "scope": "gateway" | "cloudvault",
  "clientId": "<gateway clientId>",      // transport only
  "collection": "<firestore collection>",// at-rest only
  "docId": "<doc id>",                   // at-rest only
  "field": "<sealed field>",             // at-rest only
  "slotId": "<eventId|messageId|attachmentId>", // transport only
  "mode": "at-rest" | "transport",       // re-stated so mode is authenticated
  "formatVersion": 1
}
```
- **Transport** canonical binding string = the existing labels verbatim, e.g. body uses `OpenBurnBar-HermesRelay-v1|gatewayEvent|<uid>|<clientId>|<eventId>` (verified at `HermesRelayCrypto.swift:180-191`) and the key-delivery `associatedData` uses `…|gatewayEventKey|<uid>|<clientId>|<eventId>`. **Unchanged** — Signal V1 reuses these strings byte-for-byte.
- **At-rest** canonical binding string = the existing CloudVault AAD context verbatim: `OpenBurnBar-CloudVault-aad-v2|<uid>|<collection>|<docId>|<field>|<schemaVersion>|<purpose>` (verified at `CloudVaultCrypto.swift:58/173`). Signal V1 reuses this exact string as the `PublicKey#seal` `associatedData`; the `info` adds the `OpenBurnBar-Signal-AtRest-v1|` prefix.

### 5.5 Replay & ordering (transport)
Replay defense today is NOT in the crypto — it is the AAD-bound `eventId` + the agent's persisted monotonic `replayCounter` high-water + bounded seen-id cache, recorded only after authenticated open (verified: `tools/hermes-platform-burnbar/adapter.py` REPLAY_COUNTER_KEYS, `_RelayPlaintextRefused`; counter minted in `FunctionsRepository.sealGatewayEventPayload`). `SIGNAL_ENVELOPE_V1` transport mode has TWO compatible options; pick ONE and pin it in the activation PR:
1. **Keep emitting `replayCounter` inside the sealed payload** (zero change to the agent's `_sealed_event_replay_counter` guard) — simplest, recommended for first activation.
2. **Derive replay/ordering from the ratchet** (message number + chain) — teach the agent that v4 trusts the Signal session's own monotonic ordering instead of the JSON counter.
If neither is present on a v4 transport open, fail closed (mirror the verified "missing authenticated replayCounter" refusal). At-rest mode has no replay concept (it is self-read, not a stream); its tamper protection is the binding AAD alone.

---

## 6. Versioning + downgrade fail-close

Two version axes, both fail-closed:

1. **`signalEnvelopeFormatVersion`** — an opener that does not recognize the integer **refuses** (no "best effort"). An attacker cannot present `formatVersion: 99` and get lenient parsing, nor present `0`/absent to drop into a weaker path.
2. **`relayKeyVersion` + `relayEncryption` strict equality** — reuses the verified v2/v3 contract: the open path hard-branches on *exact* version AND algorithm string (`requireGatewayRelayEnvelope:665-671`; `sanitizeGatewayRelayEnvelope:767-770`). A relay cannot strip a v4 envelope down to v3/v2 because:
   - the write validator rejects v1 and (until activation) v4 for production writes (`requireProductionGatewayRelayEnvelope:739`);
   - the read validator drops any version/algorithm pair it does not exactly recognize (`sanitizeGatewayRelayEnvelope:764-770`);
   - the **capability negotiation never selects a lower version than both peers advertise** — `preferredRelayEnvelopeVersion` is min-of-mutually-supported, and a peer that advertises Signal will not accept a non-Signal reply on a slot it sealed Signal-side (mirror the existing `requiresSealedReplies` posture, `HermesGatewayRelayKeypair.swift:751`).
3. **Mode confusion fail-close** — because `mode` is authenticated inside the binding AAD (§5.4), flipping `at-rest`↔`transport` invalidates the GCM tag. A doc sealed `at-rest` can never be opened as `transport` or vice versa.
4. **Pin/identity binding fail-close** — at-rest `open` requires the wrap's `recipientIdentityKeyB64` to match a **locally held private key**; transport `open` requires the Signal session's sender identity to match the **pinned** identity (extend `HermesGatewayAgentKeyPinStore.verifyOrPin`, `:709`, to pin the Signal IdentityKey, not just the P-256 relay key — see §11). If no verified Signal session/identity exists, return `nil` (fail closed). This preserves the verified "fail closed when `pinnedSenderKey == nil`" property (`FunctionsRepository.swift:1238`).

**Rule:** *strict equality, never range checks.* No `version >= N` acceptance anywhere on the crypto path.

---

## 7. Per-domain mode assignment (registry-pinned)

The registry is the single source of truth (`packages/data-domains/registry.json`, codegens TS/Swift/Kotlin, CI driftcheck). `SIGNAL_ENVELOPE_V1` adds an optional `signalMode` field per domain:

| Domain | Tier (current) | `signalMode` | Rationale |
|---|---|---|---|
| `conversations_chat` | end_to_end | `at-rest` | self-read across devices |
| `session_logs` | end_to_end | `at-rest` | bodies in Storage; self-read |
| `pensieve` | end_to_end | `at-rest` | lowest traffic → first migration target |
| `device_trust_keys` | end_to_end | `at-rest` (key layer) | becomes the identity-key directory itself |
| `connected_devices` (gateway) | **server_readable** ⚠ | `transport` | live phone↔agent stream |

**⚠ Honesty fix (coordinated, not silent):** `connected_devices` is tier `server_readable` (`registry.json:115`) although gateway bodies are sealed `end_to_end`. The privacy scanner keys off this tier, so it is structurally blind to the gateway. The Signal activation PR is the moment to correct the tier — but `registry.json`/`firestore.rules` are shared driftchecked files; this edit must be coordinated with the registry owner, not made unilaterally (Rule 0 adjacency).

---

## 8. Multi-device, revocation, and re-wrap (at-rest)

- **Add device:** the new device registers an `IdentityKeyPair` (replacing the bespoke P-256 device keypair `CloudVaultDeviceKeypair.swift`), publishes its IdentityKey public bytes + (for transport) a PQXDH `PreKeyBundle` into the directory. An **existing trusted device** re-wraps each live content key to the new device's IdentityKey via `PublicKey#seal` (the new device cannot self-bootstrap content keys it has never held — this matches the verified escrow approval requiring a distinct trusted approver, `computerUseSecurity.ts:approveEscrowDeviceTrust:155`).
- **Verify device (close the verified gap):** approval today never compares fingerprints (`approveEscrowDeviceTrust` matches deviceId+platform only — verified P1). `SIGNAL_ENVELOPE_V1` requires a libsignal **safety-number** comparison at approval: render `Fingerprint → DisplayableFingerprint.toString()` (the bridge already declares `Fingerprint` required, `index.ts:REQUIRED_SIGNAL_PROTOCOL_SYMBOLS`) and gate approval on out-of-band match, reusing the formatter shape from `HermesGatewayAgentKeyPinStore.safetyCode` (`:769`, sorted-key SHA-256 → 8 hex groups) until the libsignal numeric fingerprint is wired.
- **Revoke device:** remove from the recipient set AND run a **re-wrap job** that re-seals every live content key to the *remaining* trusted set, then deletes the revoked wrap. Per §3.4 this is the missing piece today; `SIGNAL_ENVELOPE_V1` mandates it. Until shipped, document the residual exposure window.
- **Recovery/escrow** wraps stay in the `wraps[]` array as `recipientKind: "recovery"|"escrow"`, replacing the bespoke ECIES `wrapVaultKey` with `PublicKey#seal` on the same escrow directory.

---

## 9. Searchability tension (explicit, unsolved by Signal)

The deterministic keyed-HMAC search trapdoors (`tokenHashes`/`semanticHashes`/`projectMemoryDocID`/`pensieveDedupHash`/`subscriptionDocID`, `CloudVaultCrypto.swift`) leak co-occurrence/structure server-side and are **not fixed by Signal envelopes** — forward-secret/identity-sealed bodies and a deterministic HMAC index are in tension. `SIGNAL_ENVELOPE_V1` leaves the search index unchanged and **honestly tiered separately**; migrating bodies to Signal preserves the structural search leak, which the registry already admits for `session_logs`. This is called out so an external reviewer is not misled into thinking Signal closes it (§13 Q5).

---

## 10. Legacy compatibility policy — everything old becomes READ-ONLY fallback

On activation, all five legacy families become **read-only**; new writes emit only `SIGNAL_ENVELOPE_V1`. Enforcement reuses the verified write-strict / read-tolerant split:

| Legacy family | Read | Write after activation | Mechanism |
|---|---|---|---|
| HPKE v2 (`relayKeyVersion 2`) | open | no | `requireProductionGatewayRelayEnvelope` stops accepting 2 once preferred=4 + both peers advertise Signal; `sanitize` still opens 2 |
| HPKE v3 (`relayKeyVersion 3`, `enc` field) | open | no | same; v3 stays in SUPPORTED, leaves PRODUCTION |
| Realtime v1 ECIES (frozen) | open | n/a (different transport) | **Byte layout NOT touched** — shared with iroh/Pi |
| OpenBurnBar Double Ratchet v1 (`OpenBurnBar-HermesRatchet-v1`) | open | no | distinct algorithm marker so Signal transport (`signal-doubleratchet-pqxdh-v1`) can **never** be misread as the bespoke ratchet, and vice versa |
| CloudVault static (`CloudVaultSealedText/Payload/Blob`, AAD `-v2` and legacy `-v1`) | open (incl. schema-1 no-AAD path, `CloudVaultCrypto.swift:278`) | no | dual-open: try `signalEnvelope` first, fall back to CloudVault |
| Gateway **schema-1 plaintext** read fallback (`fileName?`/`text?`, `hermesGateway.ts:1060-1114`) | read (legacy plaintext docs) | no (writes already `ciphertext_required`) | the fallback set includes plaintext, not just old ciphertext — migration must keep reading it until drained |

**Migration policy (per `third_party/libsignal/manifest.json`):** old rows stay legacy read-only until telemetry proves they are gone; a dual-decrypt path + backfill + a drain/expire job for the schema-1 plaintext fallback are required before any legacy reader is removed. No flag flips production until the cross-language KAT (§12) is green on all four languages. Two envelope FAMILIES coexist per gateway message today (`relayEnvelope` vs `ratchetEnvelope`, mutually exclusive per write — `ambiguous_ciphertext`, `callables/hermesGateway.ts:374`); Signal V1 transport replaces `relayEnvelope`'s key-wrap leg and deprecates the bespoke `ratchetEnvelope`, but ships as a single new envelope to avoid doubling the legacy-fallback surface.

---

## 11. Trust-root migration (pin + safety code)

- The transport pin store (`HermesGatewayAgentKeyPinStore.verifyOrPin`, `:709`) currently pins a P-256 X9.63 relay key. Signal identities are a different key type. `SIGNAL_ENVELOPE_V1` **extends** (does not fork) the pin: pin the Signal `IdentityKey` alongside the relay key; the `/runtime` immutability guard (`callables/hermesGateway.ts:902-934`) must make the Signal identity immutable too, or the first-pin MITM window reopens.
- The two-key safety code (`safetyCode`/`pinnedSafetyCode`, `:769`/`:797`, verified to bind BOTH the pinned agent key AND this device's own relay key) must incorporate the Signal identity so the displayed code changes if either the relay key or the Signal identity is substituted. Prefer migrating the *display* to libsignal's numeric `DisplayableFingerprint` once wired.
- At-rest has **no pin today** and **no fingerprint comparison on escrow approval** (verified P1, §8). Signal V1 closes this by rooting at-rest device trust in the Signal IdentityKey with an explicit safety-number comparison gate.

---

## 12. Test-vector schema for cross-language parity

Mirror the verified `BurnBarHpkeV3Vector.json` shape (a Python reference generates; Swift CryptoKit + Android JCE + TS open the same bytes). New canonical fixtures (Stream-owned test paths, NOT AGPL paths):

`Fixtures/SignalEnvelopeV1Vector.json` — array of `cases`, each:

```jsonc
{
  "name": "at_rest_pensieve_chunk" | "transport_event_text" | "transport_attachment" | …,
  "mode": "at-rest" | "transport",
  "expected": "open" | "fail",
  "failReason": "wrong_recipient" | "mutated_sealed_key" | "tampered_binding"
                | "mode_flip" | "format_downgrade" | "version_downgrade"
                | "dropped_field" | "wrong_pinned_identity" | "replayed",

  // common
  "signalEnvelopeFormatVersion": 1,
  "relayKeyVersion": 4,
  "relayEncryption": "signal-hpke-identity-seal-v1" | "signal-doubleratchet-pqxdh-v1",
  "binding": { /* §5.4, fully expanded */ },
  "bindingStringInfo": "OpenBurnBar-Signal-AtRest-v1|OpenBurnBar-CloudVault-aad-v2|u|coll|doc|field|2|purpose",
  "payloadAAD": "OpenBurnBar-HermesRelay-v1|gatewayEvent|u|c|e",   // or cloudvault context
  "payloadCiphertextB64": "…",
  "payloadPlaintext": "{…}",
  "contentKeyB64": "<32 bytes, for test only>",
  "contentKeyLength": 32,

  // at-rest mode
  "wraps": [
    { "recipientKind": "device",
      "recipientIdentityPublicB64": "…",
      "recipientIdentityPrivateB64": "…",   // test-only
      "sealedContentKeyB64": "…" }
  ],

  // transport mode (full session reproduction)
  "aliceIdentityKeyPairB64": "…",            // test-only
  "bobIdentityKeyPairB64": "…",
  "bobPreKeyBundle": {
    "registrationId": 1, "deviceId": 1,
    "preKeyId": 31337, "preKeyPublicB64": "…",
    "signedPreKeyId": 22, "signedPreKeyPublicB64": "…", "signedPreKeySignatureB64": "…",
    "kyberPreKeyId": 33, "kyberPreKeyPublicB64": "…", "kyberPreKeySignatureB64": "…",  // PQXDH mandatory
    "identityKeyB64": "…"
  },
  "signalMessageType": 3,
  "signalMessageB64": "<CiphertextMessage.serialize()>",
  "pinnedSenderIdentityB64": "…"
}
```

**Parity gates (mirror `BurnBarHpkeV3CrossPlatformVectorTests` + `HermesRelayCryptoHpkeV3Test`):**
- Positive: every `expected:"open"` case opens to the exact `payloadPlaintext` in Swift, Kotlin, TS (and Rust facade once it exists).
- Negatives: `mutated_sealed_key`, `tampered_binding`, `mode_flip`, `format_downgrade`, `version_downgrade`, `dropped_field`, `wrong_recipient`/`wrong_pinned_identity`, `replayed` all **fail closed**.
- Transport adds the canonical **Alice↔Bob round-trip**: full `processPreKeyBundle` session establishment, send/receive both directions, **safety-number match**, plus **out-of-order/skipped-key** and **replay-rejection** cases (the bridge's own round-trip requirement, `packages/README.md:45-47`).
- A KAT block pins the suite identity (libsignal pin commit + the two `relayEncryption` algorithm strings + `contentKeyLength == 32`) so a silent algorithm rename trips CI.
- Provenance honesty: like the HPKE v3 lane, the Python generator currently lives in the external Hermes repo (`generate_burnbar_hpke_v3_vectors.py`/`hpke_v3_reference.py` are NOT in this tree). `SIGNAL_ENVELOPE_V1` requires **in-sourcing the generator** (or shipping a reproducible KAT bundle) so an external auditor can regenerate from a fresh clone — the current fixtures are not independently reproducible (§13 Q9).

---

## 13. Open questions an external crypto reviewer would raise

1. **At-rest has no forward secrecy — accepted, but is the threat model written down?** Identity-key compromise exposes all not-yet-re-wrapped docs sealed to that device. Is there a published threat model stating this is an explicit accepted tradeoff for recoverable at-rest E2EE, and quantifying the re-wrap cadence that bounds it?
2. **Is `PublicKey#seal` the right primitive for self-encryption, or should at-rest use sealed-sender-multi-recipient?** `sealedSenderMultiRecipientEncrypt` (`index.d.ts:351`) seals one message to N recipients efficiently and could replace the O(devices) per-doc wrap fan-out. Why per-recipient `PublicKey#seal` instead? (Leaning on statelessness + no session state at rest, but a reviewer will want the analysis.)
3. **Content-key reuse across the recipient set.** At rest, all of a user's devices share the per-doc content key (only wraps differ). Does any device-compromise scenario let a revoked device that held the content key decrypt *new* docs that reuse a key it once saw? (Mandate fresh content key per doc + re-wrap on revoke; confirm no key reuse across docs.)
4. **PQXDH state explosion.** Kyber prekeys are mandatory (`PreKeyBundle.new`), adding `KyberPreKeyStore` rotation/exhaustion. What is the prekey replenishment + one-time-prekey-exhaustion fallback policy, and what happens when a stale `PreKeyBundle` is used (does establishment fail closed)?
5. **Deterministic search index leak persists.** Signal does not touch the keyed-HMAC trapdoors (§9). Will the index stay, and is its `server_readable`-adjacent leak honestly tiered and documented for users, or is there a plan (PSI/OPRF) to close it?
6. **Mode discriminator as an attack surface.** `mode` is AAD-bound, but is there any code path (validator, exporter, backfill, dataExport `isSealedEnvelope`) that branches on the *unauthenticated* top-level `mode` field before opening? Any such branch is a downgrade vector.
7. **Revocation does not rotate the revoked key.** Until the re-wrap-on-revoke job ships (§3.4, §8), a revoked device still opens already-wrapped docs. Is there a hard deadline + telemetry proving the window closes, and how is the residual disclosed to the user?
8. **Two ratchets coexisting.** Bespoke `OpenBurnBar-HermesRatchet-v1` and real Signal transport both occupy the "upgraded transport" slot (mutually exclusive per write, `callables/hermesGateway.ts:374`). Does Signal *replace* or *coexist with* the bespoke ratchet long-term? Two ratchets = audit hazard; what is the deprecation plan?
9. **Fixture provenance / reproducibility.** The cross-language vectors are generated by an external Python repo not in this tree (verified for the HPKE v3 lane). Can an external auditor regenerate `SignalEnvelopeV1Vector.json` from a fresh clone, or is "triangulation" really Python(external)→{Swift,Kotlin}? In-source the generator.
10. **No live stored-ciphertext gate.** Today the only proof the server stored ciphertext (not plaintext) is a **manual device run** (Phase 7) + a **string-matching** privacy scanner that does not read stored bytes. What automated test proves a real end_to_end domain stored only `SIGNAL_ENVELOPE_V1` ciphertext server-side?
11. **AAD label namespace collision.** Signal V1 reuses the existing `OpenBurnBar-HermesRelay-v1|`/`OpenBurnBar-CloudVault-aad-v2|` strings verbatim. Is reusing the v1/v2 labels for a v4/Signal envelope safe, or should the label namespace bump to prevent a cross-version oracle where a v3 and a v4 envelope share an AAD?
12. **`enc` field semantics divergence.** v3 introduced a distinct `enc` field; Signal transport carries `signalMessageB64` instead. Does any shape validator conflate `enc` presence with version, such that a v4 lacking `enc` is mis-bucketed as v2?
13. **Key transparency / MITM at first pin.** Trust is still TOFU (first-use pin) + manual safety-number comparison. The remediation plan's own future-work item ("add a key transparency log / signed audit trail") is unbuilt. Without KT, a compromised directory can hand a fresh device the wrong IdentityKey at first pin. Is KT in scope before GA?
14. **AGPL containment.** Vendoring the libsignal Swift Package / Android maven / Rust crate pulls AGPL native code into shipped binaries, forcing LICENSE/NOTICE/THIRD_PARTY/source-offer updates (Rule-0 AGPL-owned). Has the AGPL agent confirmed the source-offer (`scripts/create-corresponding-source.sh`) covers all four language bindings, and is the App Store binary-size / notarization impact assessed?

## Open Questions (external-reviewer surface)

1. At-rest mode has no forward secrecy by design (identity-key compromise exposes all not-yet-re-wrapped docs). Is this accepted tradeoff documented in a published threat model with a re-wrap cadence that bounds exposure?
2. Should at-rest self-encryption use per-recipient PublicKey#seal (chosen here for statelessness/simplicity) or sealedSenderMultiRecipientEncrypt to avoid O(devices) wrap fan-out? Reviewer will want the comparative analysis.
3. Revocation does not rotate the revoked device's private key; until the mandated re-wrap-on-revoke job ships (currently absent at computerUseSecurity.ts:revokeEscrowDeviceTrust:248), a revoked device still opens already-wrapped docs. What is the hard deadline + telemetry proving the window closes?
4. PQXDH adds mandatory Kyber prekey state (PreKeyBundle.new requires kyber_prekey_*; signalDecryptPreKey needs KyberPreKeyStore). What is the one-time-prekey replenishment + exhaustion fallback, and does a stale bundle fail establishment closed?
5. Signal does not fix the deterministic keyed-HMAC search trapdoors (tokenHashes/semanticHashes/projectMemoryDocID). Does the index stay (preserving the admitted structural leak) and is it honestly tiered to users, or is a PSI/OPRF replacement planned?
6. Does Signal transport REPLACE or COEXIST with the bespoke OpenBurnBar-HermesRatchet-v1 long-term? Two ratchets in the mutually-exclusive 'upgraded transport' slot is an audit hazard; a deprecation plan is needed.
7. Fixture provenance: the cross-language KAT generator currently lives in an external Python repo (verified for the HPKE v3 lane), so vectors are not regenerable from a fresh clone. Will the generator be in-sourced so external auditors can reproduce SignalEnvelopeV1Vector.json?
8. There is no automated gate proving the server stored only ciphertext for any end_to_end domain (Phase 7 readback is manual; the privacy scanner is string-match only, not stored-byte). What automated stored-ciphertext proof gates activation?
9. Reusing the existing OpenBurnBar-HermesRelay-v1| / OpenBurnBar-CloudVault-aad-v2| AAD labels verbatim for a v4/Signal envelope: is this safe, or should the AAD namespace bump to prevent a cross-version oracle between v3 and v4 envelopes sharing an AAD?
10. Trust is still TOFU + manual safety-number; the remediation plan's key-transparency-log future-work item is unbuilt. Is a key transparency / signed audit log in scope before GA to close the first-pin MITM window?
11. AGPL containment: vendoring libsignal Swift/Android/Rust bindings pulls AGPL native code into shipped binaries (LICENSE/NOTICE/THIRD_PARTY/source-offer impact, App Store binary-size + notarization). Has the AGPL owner confirmed scripts/create-corresponding-source.sh covers all four bindings?
