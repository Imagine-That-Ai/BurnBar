I now have the complete, definitive picture across both repos. I have the byte-exact `HermesRelayCrypto` contract, the `relayRequestWrite`/`relayConnectionWrite` precedent rules, the gateway handlers, the device-grant flow, the keyless adapter, and the Python crypto precedents. Writing the design brief.

---

## RECON SUMMARY — gateway-wire-and-pairing slice

### The two participants and who holds keys
- **Phone (Participant B):** Firebase-authenticated, holds the Cloud Vault key (`MobileCloudVaultKeyAccess`) AND can generate per-link relay keypairs (mirrors `HermesRelayKeyStore`). Writes events via the **`enqueueHermesGatewayEvent` callable** (server-side, `hermesGateway.ts:1100-1201`) and reads agent replies via a **direct Firestore listener** on `hermes_gateway_messages` (`FunctionsRepository.swift:504-534`). Reads via `firestore.rules:2272-2275` (`read: if ownsUserNamespace; write: if false`).
- **Agent (Participant A):** keyless today — `adapter.py` authenticates with `deviceSecretHash` + bearer token (`adapter.py:826-849`), sends plaintext `text` over `POST /messages` (`adapter.py:583-590`) and reads plaintext `text`/`senderDisplayName` over `GET /events`. It has **no** Firestore creds and **no** vault key.

### The decisive design fact
All gateway collections are `write: if false` in rules (`firestore.rules:2256-2300`) — **every write goes through privileged Functions or the bearer-token HTTP surface**, never client Firestore. So the wire format is governed by **two enforcement points only**: (1) the `enqueueHermesGatewayEvent` callable + the `burnBarHermesGateway` HTTP handlers (server-side TS), and (2) the phone-side seal/open in Swift + the agent-side seal/open in Python. There is **no Firestore-rules allowlist to write for these collections** (unlike `relayRequestWrite`), which simplifies the slice: the server callables/handlers are the gatekeepers.

### Byte-exact crypto to reuse (no new scheme)
`HermesRelayCrypto` (`HermesRelayCrypto.swift:61-186`), algorithm `"p256-hkdf-sha256-aesgcm"`, `keyVersion=1`:
- `sealToBase64(plaintext, keyData, aad)` → AES-256-GCM `.combined` (nonce12‖ct‖tag16) base64. AAD **mandatory**.
- `wrapSymmetricKey(keyData, recipientPublicKeyBase64, aad)` → ephemeral P-256 ECDH → HKDF-SHA256 (salt ∅, sharedInfo `"OpenBurnBar-HermesRelay-KeyWrap-v1|"+aad`) → AES-GCM wrap; output = `ephemeralPubKey.x963(65B) ‖ combined`, base64.
- AAD format: `"OpenBurnBar-HermesRelay-v1|"+parts.join("|")` (`:177-178`). X9.63 uncompressed pubkeys (65B, `0x04` prefix).
- The relay precedent fields are `payloadCiphertext` / `wrappedKey` / `relayEncryption` / `relayKeyVersion` (`legacy.ts:547-550`); pubkeys published as `relayPublicKey` / `relayKeyVersion` / `relayEncryption` on a connection doc (`legacy.ts:213-215`); size caps `payloadCiphertext ≤ 900000`, `wrappedKey ≤ 4096`, `relayPublicKey ≤ 256` (`firestore.rules:721-726, 822`).

---

## DESIGN BRIEF

### A. Pairing handshake — both endpoints publish a relay public key

1. **Agent generates a P-256 keypair at `device/start`.** In `adapter.py interactive_setup()` (`tools/hermes-platform-burnbar/adapter.py:826-833`), before `POST /device/start`, generate a P-256 KeyAgreement keypair via the new Python module (§E) and add to the start payload:
   - `agentRelayPublicKey`: base64 X9.63 uncompressed (65B, `0x04`-prefixed) of the agent public key.
   - `agentRelayKeyVersion: 1`, `agentRelayEncryption: "p256-hkdf-sha256-aesgcm"`.
   Persist the agent **private** key to `~/.hermes/.env` (e.g. `BURNBAR_RELAY_PRIVATE_KEY` = base64 of the 32B raw scalar / DER) alongside `BURNBAR_ACCESS_TOKEN`. The private key never leaves the agent host.

2. **`handleDeviceStart` accepts + persists the agent pubkey.** `functions/src/callables/hermesGateway.ts:329-370`: read `body.agentRelayPublicKey` (validate base64, decoded length == 65, first byte `0x04`), `agentRelayKeyVersion` (int, default 1), `agentRelayEncryption` (must equal `"p256-hkdf-sha256-aesgcm"`). Store all three on the `hermes_gateway_device_sessions/{deviceCode}` doc (`:346-357`). Add a validator `isGatewayRelayPublicKeyB64(raw)` to `functions/src/hermesGateway.ts`.

3. **`approveHermesGatewayDeviceGrant` copies the agent pubkey onto the client doc AND mints the phone's relay key reference.** `hermesGateway.ts:873-968`:
   - Carry `session.agentRelayPublicKey/agentRelayKeyVersion/agentRelayEncryption` onto the new `HermesGatewayClientDoc` (`:927-940`) as `agentRelayPublicKey` / `agentRelayKeyVersion` / `agentRelayEncryption`.
   - The **phone** that calls this callable is the key authority for the phone→agent direction's *recipient* (the agent) and the agent→phone direction's *recipient* (the phone). So the phone passes its **own** relay pubkey into the callable: add `request.data.phoneRelayPublicKey` (+ `phoneRelayKeyVersion`, default 1) to the callable input (`:882-888`), validate identically, and store `phoneRelayPublicKey` / `phoneRelayKeyVersion` / `phoneRelayEncryption` on the client doc. The phone holds the matching private key in its keystore (mirror `HermesRelayKeyStore`; one keypair per client/link).
   - Echo `agentRelayPublicKey` back to the phone in the callable return (`:965`) so the phone can immediately seal its first event; echo `phoneRelayPublicKey` to the agent via `device/poll` (next item).

4. **`handleDevicePoll` returns the phone pubkey to the agent.** `hermesGateway.ts:372-417`: in the `approved` branch (`:396-410`) add `phoneRelayPublicKey`, `phoneRelayKeyVersion`, `phoneRelayEncryption` (read from the approved session, copied there by step 3 alongside `accessToken`). Persist these onto the session in `approveHermesGatewayDeviceGrant`'s `sessionRef.set({...})` (`:950-962`). The agent saves `BURNBAR_PHONE_RELAY_PUBLIC_KEY` to `.env`.

5. **Pubkey publication doc-shape (mirror `HermesConnectionDoc`):** on `HermesGatewayClientDoc` (`functions/src/hermesGateway.ts:66-95` and `functions/src/types/legacy.ts:592-609`) add:
   ```
   agentRelayPublicKey?: string;  agentRelayKeyVersion?: number;  agentRelayEncryption?: string;
   phoneRelayPublicKey?: string;  phoneRelayKeyVersion?: number;  phoneRelayEncryption?: string;
   ```
   Surface `agentRelayPublicKey`/`phoneRelayPublicKey`/versions in `publicClientView` (`functions/src/hermesGateway.ts:523-547`) so the phone reading `/state` or `hermes_gateway_clients` gets the agent pubkey, and `isHermesGatewayClientDoc` (`:386-404`) tolerates them (optional strings/numbers). **Key rotation:** when `rotateHermesGatewayClientToken` runs (`hermesGateway.ts:1021-1098`), do NOT rotate relay keys (token rotation ≠ key rotation); add a separate optional `rotateHermesGatewayClientRelayKey` later if needed (out of scope — note it).

### B. Sealed wire shape per collection (the "relayEnvelope" sub-object)

Reuse the relay field names verbatim. Define one canonical sealed sub-object `relayEnvelope` to avoid colliding with existing top-level fields and to keep `serializeHermesGatewayEvent` clean:
```
relayEnvelope: {
  payloadCiphertext: string;   // sealToBase64 of the JSON-encoded private payload
  wrappedKey: string;          // wrapSymmetricKey(symKey, recipientPubKey, keyAAD)
  relayEncryption: "p256-hkdf-sha256-aesgcm";
  relayKeyVersion: number;     // recipient key version used
}
```
Each direction seals a **single JSON object** of all private fields (so one envelope per doc, not one per field):

6. **`hermes_gateway_events` (phone → agent):** seal `{ text, senderDisplayName, threadId }`. The recipient is the **agent** → wrap to `agentRelayPublicKey`. AAD: `requestAAD`-style namespaced to `["gatewayEvent", uid, clientId, eventId]`. Keep cleartext routing fields only: `id`, `sequence`, `kind`, `destinationId`, `targetClientId`, `senderId` (non-PII routing id, default `"burnbar-user"`), `modelId` (a model id is not private; needed by the runtime catalog check at `:1145-1153`), `attachmentIds`, `createdAt`, `schemaVersion`, plus `relayEnvelope`. REMOVE top-level `text`, `senderDisplayName`, `threadId`.

7. **`hermes_gateway_messages` (agent → phone):** seal `{ text }` (the agent's reply). Recipient is the **phone** → wrap to `phoneRelayPublicKey`. AAD: `["gatewayMessage", uid, clientId, messageId]`. Keep cleartext: `id`, `clientId`, `kind`, `destinationId`, `replyToEventId`, `attachmentIds`, `createdAt`, `schemaVersion`, plus `relayEnvelope`. REMOVE top-level `text`. (`threadId` carries no private content but is routing — keep cleartext.)

8. **`hermes_gateway_attachments` (agent → phone):** the agent seals the **bytes** with a fresh symmetric key BEFORE the signed-URL upload (so Storage holds ciphertext), and seals `fileName` in the manifest. Two pieces:
   - **Bytes:** agent generates a per-attachment 32B symmetric key, seals the file with `sealToBase64`-equivalent over raw bytes (or streams AES-GCM with `.combined` layout) using AAD `["gatewayAttachmentBody", uid, clientId, attachmentId]`, uploads the ciphertext to the signed URL. The manifest carries `relayEnvelope` whose `payloadCiphertext` is the sealed JSON `{ fileName, byteCount, contentType }` and whose `wrappedKey` wraps the **attachment body key** to `phoneRelayPublicKey` (AAD `["gatewayAttachmentKey", uid, clientId, attachmentId]`). The phone unwraps the body key and decrypts the downloaded ciphertext.
   - **`handleAttachmentInit`** (`hermesGateway.ts:611-648`): stop storing plaintext `fileName`; require `relayEnvelope` (sealed `fileName`) or accept a sealed-name field. Store a non-revealing storage object name (use `attachmentId` only, not `fileName` — change `storagePath` at `:624` to drop the `/${fileName}` segment so the path no longer leaks the name).
   - **`handleAttachmentFinalize`** (`hermesGateway.ts:650-737`): the server `sha256ForStorageFile` (`:714`) now hashes **ciphertext** (still a valid integrity check on the stored object) — keep it but rename the semantic to `ciphertextSha256` and stop asserting it equals a plaintext hash; drop the content-type sniffing on the now-encrypted bytes (`:699-712`) or assert `application/octet-stream`. **byteCount** stored is ciphertext length (≈ plaintext+28B GCM overhead) — relax the size check accordingly.

9. **`hermes_gateway_typing` / `hermes_gateway_state`:** unchanged (no private text). **`hermes_gateway_clients.displayName`** is a user-chosen label ("Hermes Agent") — out of scope for this slice (low sensitivity; sealing it would break `/state` client listing). Note it as a residual server-readable field.

### C. Handlers that reject plaintext + require ciphertext

10. **`enqueueHermesGatewayEvent` callable** (`hermesGateway.ts:1100-1201`): the phone now seals **client-side before** calling. Change the callable input from `text`/`senderDisplayName`/`threadId` to `relayEnvelope: { payloadCiphertext, wrappedKey, relayEncryption, relayKeyVersion }`. **Reject** any request carrying a plaintext `text`/`senderDisplayName` once `schemaVersion ≥ 2` (see grace window §G). Validate `relayEnvelope` with a new `requireGatewayRelayEnvelope(raw)` helper (mirror `requireSealedText`, `shared.ts:338`): `relayEncryption === "p256-hkdf-sha256-aesgcm"`, `relayKeyVersion ∈ [1,100]`, `payloadCiphertext` base64 ≤ 900000, `wrappedKey` base64 ≤ 4096. **Exception:** `eventKind === "model_switch"` synthesizes `/model <id>` from `modelId` (`:1127-1130`) — a model id is not private, so model-switch events may stay cleartext `text` OR seal it; keep model_switch cleartext for the runtime to read the `/model` command without a key (the runtime needs `modelId` anyway, already cleartext). Write `relayEnvelope` into the event doc (`:1170-1187`), drop plaintext `text`/`senderDisplayName`/`threadId`.

11. **`handleMessageSend` HTTP** (`hermesGateway.ts:473-501`): the agent now seals. Replace `body.text` (`:478`) with `body.relayEnvelope`. Require it via `requireGatewayRelayEnvelope`; reject a plaintext `text` once the client is on schema 2. The empty-message guard (`:480-482`) becomes "`relayEnvelope` absent AND `attachmentIds` empty → `empty_message`." Write `relayEnvelope`, drop `text` (`:493-497`).

12. **`handleEvents` / `serializeHermesGatewayEvent`** (`hermesGateway.ts:435-471` + `functions/src/hermesGateway.ts:435-466`): **return the ciphertext verbatim.** `serializeHermesGatewayEvent` must (a) stop requiring `typeof record.text === "string"` (`:444`), (b) pass through `relayEnvelope` (validate it's a record with the 4 fields), (c) drop `text`/`senderDisplayName` from the returned object or only echo them when present for legacy docs. The SSE serializer `makeHermesGatewaySSE` (`:468-480`) needs no change (it JSON-stringifies the event, now carrying `relayEnvelope`). The agent decrypts in `adapter.py`'s event-poll loop.

13. **`handleAttachmentInit/Finalize`:** per §8 — require sealed `fileName` (in `relayEnvelope`), drop the plaintext `fileName` field and the name segment from `storagePath`.

### D. Schema version bump + legacy handling

14. **Bump `HERMES_GATEWAY_SCHEMA_VERSION = 2`** (`functions/src/hermesGateway.ts:8`). Sealed docs carry `schemaVersion: 2`. **Bump `HERMES_GATEWAY_PROTOCOL_VERSION = 2`** (`:26`) so `/state` advertises the sealed contract; clients gate the seal path on `protocolVersion ≥ 2`.

15. **Keyless legacy client policy = bounded grace window, then reject (fail toward privacy).** A v1 client (no relay keypair published) cannot seal/open. Policy:
   - **Pairing:** a `device/start` WITHOUT `agentRelayPublicKey` is allowed during the grace window but the resulting client is flagged `relayCapable: false`. After the cutoff date, `handleDeviceStart` **rejects** a start missing `agentRelayPublicKey` (`unsealed_pairing_unsupported`).
   - **Writes:** `enqueueHermesGatewayEvent` and `handleMessageSend` accept a plaintext `text` ONLY when the target client is `relayCapable:false` AND within the grace window; emit a `logInfo` deprecation counter. After cutoff, plaintext writes are rejected (`ciphertext_required`).
   - **Reads:** `serializeHermesGatewayEvent` and the iOS message decoder keep a **legacy fallback** (per CONTRACT.md line 11): if `relayEnvelope` absent, read the old plaintext `text` (so in-flight v1 docs still render during migration). The phone decoder `HermesGatewayMessageRecord.init` (`FunctionsRepository.swift:516-534`) gains: if `relayEnvelope` present → unwrap body key with phone relay private key + open → set `text`; else fall back to `data["text"]`.
   - Add `relayCapable?: boolean` to `HermesGatewayClientDoc` + a `GRACE_WINDOW_CUTOFF` constant in `functions/src/hermesGateway.ts`. Backfill counter via the existing `lastSeenAt` write path.

### E. New Python crypto module (agent side — names the reusable fork module)

16. Add `gateway/platforms/burnbar_relay_crypto.py` (or, per the two-PR plan, a **reusable** `gateway/platforms/relay_crypto.py` so any adapter can seal) implementing the byte-exact `HermesRelayCrypto` contract in Python with `cryptography.hazmat` (precedent: `qqbot/crypto.py` AES-GCM, `wecom_crypto.py` structure):
   - `generate_keypair() -> (priv, pub_x963_b64)` (P-256, `ec.SECP256R1`, X9.63 uncompressed 65B).
   - `seal_to_base64(plaintext: bytes, key: bytes(32), aad: bytes) -> str` — AESGCM, 12B nonce, output `nonce‖ct‖tag` base64 (matches Swift `.combined`).
   - `open_base64(ciphertext_b64, key, aad) -> bytes`.
   - `wrap_symmetric_key(key, recipient_pub_x963_b64, aad) -> str` — ephemeral ECDH → HKDF-SHA256(salt=`b""`, info=`b"OpenBurnBar-HermesRelay-KeyWrap-v1|"+aad`, length=32) → AESGCM seal; output `ephemeral_pub_x963(65) ‖ combined` base64.
   - `unwrap_symmetric_key(wrapped_b64, priv, aad) -> bytes`.
   - `aad(parts: list[str]) -> bytes` = `b"OpenBurnBar-HermesRelay-v1|" + "|".join(parts).encode()`.
   - This is the module the second fork PR (gateway E2EE) ships; `adapter.py` imports it. (The Hermes-fork slice owner writes/polishes this; this slice's contract above is the spec it must satisfy byte-for-byte.)

### F. Validators + types (server) — exact change points

17. `functions/src/hermesGateway.ts`:
    - `:8` `HERMES_GATEWAY_SCHEMA_VERSION = 2`; `:26` `HERMES_GATEWAY_PROTOCOL_VERSION = 2`.
    - Add `isGatewayRelayPublicKeyB64`, `requireGatewayRelayEnvelope`, `GatewayRelayEnvelopeDoc` type, and `GRACE_WINDOW_CUTOFF`.
    - `HermesGatewayClientDoc` (`:66-95`): add 6 relay-pubkey fields + `relayCapable?`.
    - `HermesGatewayEventDoc` (`:127-141`): replace `text`/`senderDisplayName` with `relayEnvelope?` (+ keep optional `text?` for legacy read).
    - `HermesGatewayMessageDoc` (`:143-154`): `text?` → optional, add `relayEnvelope?`.
    - `HermesGatewayAttachmentManifestDoc` (`:156-173`): `fileName` becomes optional (sealed in `relayEnvelope`); add `relayEnvelope?`, `bodyKeyWrapped?` (or fold into `relayEnvelope.wrappedKey`).
    - `serializeHermesGatewayEvent` (`:435-466`): emit `relayEnvelope`, tolerate missing `text`.
    - `publicClientView` (`:523-547`) + `isHermesGatewayClientDoc` (`:386-404`): include/tolerate the relay fields.
18. `functions/src/types/legacy.ts`: mirror the same field additions on `HermesGatewayClientDoc:592-609`, `HermesGatewayEventDoc`, `HermesGatewayMessageDoc`, `HermesGatewayAttachmentManifestDoc`.
19. `functions/src/callables/hermesGateway.ts`: the 5 handler edits (§10–13) + the device-start/poll/grant pubkey plumbing (§2–4).

### G. Migration + blast radius (this slice)

20. **`firestore.rules`:** the gateway collections are `write: if false` (`:2256-2300`) so **no rule allowlist changes are needed for the sealed wire** — the server is the only writer. The only honesty change: `dataExport.ts:115-138` currently tiers all `hermes_gateway_*` as `server_readable`. After this slice, `hermes_gateway_events`/`messages`/`attachments` become **`end_to_end`** (or a dedicated `gateway_e2e` tier) since neither the server nor any non-key-holder reads bodies; keep `hermes_gateway_clients/destinations/typing/state/approvals` as `server_readable` (routing/labels). This is the registry/data-domains change handed to the honesty stream — flag it; do not edit `gen/*` here.
21. **Companion-repo blast radius (named, not owned here):** phone seal/open in Swift (`FunctionsRepository.swift:516-534` decode, `:1185-1226` enqueue, plus a new per-link `HermesGatewayRelayKeyStore` mirroring `HermesRelayKeyStore`); the phone passes `phoneRelayPublicKey` into `approveHermesGatewayDeviceGrant`; agent seal/open in `adapter.py` (`:583-590` send, event-poll decrypt, `:826-849` device-start keygen, attachment seal in `_create_attachments`). Tests: `functions/src/__tests__/hermesGateway*.test.ts` (envelope validators, plaintext rejection past cutoff, legacy fallback), a Swift↔Python interop fixture (seal in Swift, open in Python and vice versa) gating the cross-language byte-compat.

**Key files (absolute):**
- `/Users/albertonunez/Documents/Windsurf/BurnBar/functions/src/callables/hermesGateway.ts` (handlers `:329-417` device, `:435-501` events/messages, `:611-737` attachments, `:873-968` grant, `:1100-1201` enqueue)
- `/Users/albertonunez/Documents/Windsurf/BurnBar/functions/src/hermesGateway.ts` (`:8,:26` versions, `:66-95` client doc, `:127-173` event/message/attachment docs, `:386-404` guard, `:435-466` serialize, `:523-547` public view)
- `/Users/albertonunez/Documents/Windsurf/BurnBar/functions/src/types/legacy.ts` (`:205-221` connection precedent, `:538-561` relay-request precedent, `:592-609` gateway client doc)
- `/Users/albertonunez/Documents/Windsurf/BurnBar/OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/HermesRelayCrypto.swift` (`:61-186` byte-exact contract the Python module mirrors)
- `/Users/albertonunez/Documents/Windsurf/BurnBar/firestore.rules` (`:680-727` relayRequestWrite precedent, `:2256-2300` gateway `write:false`)
- `/Users/albertonunez/Documents/Windsurf/BurnBar/functions/src/callables/dataExport.ts` (`:115-138` tier reclassification)
- `/Users/albertonunez/Documents/Windsurf/BurnBar/tools/hermes-platform-burnbar/adapter.py` (`:583-590` send, `:826-849` device-start)
- `/Users/albertonunez/.hermes/hermes-agent/gateway/platforms/qqbot/crypto.py` + `wecom_crypto.py` (Python AES-GCM precedents for the new `relay_crypto.py`)