I have confirmed all facts needed. Confirmed: Android `CloudVaultCrypto` has `sealText`, `sealPayload`, `openBlob`, `tokenHashes`, `semanticHashes` — but **no `sealBlob`** (it can open blobs but the blob writer for Android is not present; Android writes via `sealText`/`sealPayload`). This is the one cross-platform gap implementers must know.

This is the shared crypto contract brief.

---

## SHARED CRYPTO CONTRACT — Cloud Vault sealing APIs (all platforms)

### 1. DATA FLOW — who owns each primitive

The vault key is a per-user random 32-byte key. It is **never** sent to any server. It is created on first native device, ECIES-wrapped (`wrapVaultKey`) to each trusted device's P-256 public key, and unwrapped locally (`unwrapVaultKey`). All five seal/open implementations are byte-for-byte wire-compatible.

| Platform | File:line | Seal/open surface |
|---|---|---|
| **Swift (Mac+iOS, shared)** | `OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/CloudVaultCrypto.swift` | `sealText`/`openText` (124/129), `sealBlob`/`openBlob` (137/149), `sealPayload`/`openPayload` (161/178), `sealedPayloadDictionary` (189), `vaultKeyID` (108), `tokenHashes`/`searchIndexTokenHashes`/`searchQueryTokenHashes` (217/223/232), `semanticHashes` (301), `wrapVaultKey`/`unwrapVaultKey` (357/377) |
| **Kotlin (Android)** | `android/app/src/main/java/com/openburnbar/data/cloud/CloudVaultCrypto.kt` + `CloudVaultCryptoSearch.kt` | `sealText`/`openText` (67/88), **`openBlob` (103) but NO `sealBlob`**, `sealPayload`/`openPayload` (119/135), `sealedPayloadMap`/`sealedPayloadFromMap` (149/158), `vaultKeyID` (117), `tokenHashes`/`semanticHashes` (Search.kt 32/46), `unwrapVaultKey` (169), `publicKeyX963` (194) |
| **TS — Cloud Functions** | `functions/src/callables/shared.ts` | **VALIDATE-ONLY**: `requireSealedText` (338), `requireCloudVaultBlobEnvelope` (393), `requireTokenHashes`/`requireSearchHashes` (310/318), `requireHexDigest` (262). Never decrypts. |
| **TS — MCP remote (Node CLI)** | `tools/openburnbar-mcp-remote/src/seal.ts` + `decrypt.ts` | `sealText`/`sealTextWithVaultKey` (19/34), `decryptSealedText` (decrypt.ts 24); `SealedEnvelope` type (decrypt.ts 4) |
| **TS — web console (browser)** | `apps/console/lib/escrow.ts` | `sealText`/`openText` (383/409), `sealBlob`/`openBlob` (331/354), `wrapVaultKey`/`unwrapVaultKey` (237/314), `importVaultKey` (323) |

### 2. SERVER-READ REQUIREMENT — definitive: NO

Cloud Functions are **pure store-and-forward / opaque-index**. The only `createDecipheriv` in `functions/src` is `secrets.ts:144` (provider-credential DEK, unrelated to the vault). `encryptedSearch.ts` ranks results purely by intersecting opaque hash postings via Firestore `array-contains-any` (`encryptedSearch.ts:618-627`) — it never sees plaintext, embeddings, or the vault key. `requireSealedText` (`shared.ts:338`) only checks `algorithm==="AES-256-GCM"`, `keyVersion∈[1,100]`, and base64 shape of `nonce/ciphertext/tag`. **Conclusion: the server has zero need for plaintext for any of these surfaces → seal everything; do not "honest-label."**

### 3. VAULT-KEY AVAILABILITY

Every native participant that must read content holds the key: Mac via `CloudVaultKeyStore` (Keychain `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, `CloudVaultCrypto.swift:614-675`); Android via `AndroidCloudVaultKeyAccess` (unwraps wrapper, caches in `AndroidLocalSecretBox`, `CloudVaultCrypto.kt:249`); browser via IndexedDB non-extractable device key (`escrow.ts:185`); Node MCP via `loadVaultKeyBytes` (`seal.ts:35`). **The server is the only party without the key — which is exactly why store-and-forward sealing works.** A non-key holder (the server) is never a required reader.

### 4. EXACT CANONICAL ENVELOPE FORMATS — identical JSON across all 5 platforms

**Sealed text** (`CloudVaultSealedText`) — for titles, snippets, names, dirs, short bodies:
```
{ "algorithm":"AES-256-GCM", "keyVersion":1, "nonce":<b64 12B>, "ciphertext":<b64>, "tag":<b64 16B> }
```
Field names identical: Swift (`CloudVaultCrypto.swift:31-44`), Kotlin (`CloudVaultCrypto.kt:28-34`), web (`escrow.ts:62-68`), MCP (`decrypt.ts:4-10`), server validator (`shared.ts:348` iterates exactly `["nonce","ciphertext","tag"]`).

**Sealed blob** (`CloudVaultBlobEnvelope`) — for large bodies (session logs), `sealedBoxBase64` is CryptoKit `.combined` = `nonce(12)‖ciphertext‖tag(16)`:
```
{ "schemaVersion":1, "algorithm":"AES-256-GCM", "keyVersion":1, "plaintextSHA256":<hex>, "sealedBoxBase64":<b64 combined>, "createdAt":<ISO> }
```
Swift (`:47-70`), Kotlin (`:36-42`, open-only), web (`escrow.ts:53-60`), server validator `requireCloudVaultBlobEnvelope` (`shared.ts:393`).

**Sealed payload** (`CloudVaultSealedPayload`) — blob-style + key binding, for structured records (agent notification replies, mission payloads):
```
{ "schemaVersion":1, "algorithm":"AES-256-GCM", "keyVersion":1, "vaultKeyID":"v1_<sha256(key) prefix 32>", "sealedBoxBase64":<b64 combined> }
```
Swift (`:72-92`, dict at `:189`), Kotlin (`:44-50`, map at `:149`). Server binds it via `agentNotifications.ts:30-32` (`vaultKeyID` must match).

### 5. KEYED HMAC TRAPDOOR (opaque ids / search / hashes — no plaintext to server)

Derive a **search key** from the vault key with HKDF-SHA256, then HMAC-SHA256 each normalized term and take the **first 16 bytes hex (32 hex chars)**. This is the canonical trapdoor for opaque ids/tokens:

- HKDF salt `"OpenBurnBar-CloudSearch-Salt-v1"`, info `"OpenBurnBar-CloudSearch-TokenHash-v1"`, 32-byte output (`CloudVaultCrypto.swift:466-474`; Kotlin `CloudVaultCryptoSearch.kt:33`; server regex gate `^[a-f0-9]{32}$` `shared.ts:331`).
- Semantic variant uses salt `"...Semantic-Salt-v1"`, info `"...SemanticHash-v1"` (Swift `:476`, Kotlin `:49`).
- Call sites: Swift `tokenHashes(for:keyData:)` `:217`, Kotlin `tokenHashes(text,vaultKey)` `:97`. To hash an opaque id, feed the id string as the term; the 16-byte HMAC prefix is the stable cross-platform trapdoor.

### 6. RELAY HOST SEALING (`p256-hkdf-sha256-aesgcm`) — separate from vault

The Hermes/PiAgent relay uses an **ephemeral per-request symmetric key** (not the vault key): `HermesRelayCrypto` (`OpenBurnBarCore/.../HermesRelayCrypto.swift:61`), algorithm constant `"p256-hkdf-sha256-aesgcm"` (`:62`).
- Requester (iOS) seals: `sealToBase64(plaintext,keyData,aad)` (`:99`) + `wrapSymmetricKey(...,recipientPublicKeyBase64,aad)` (`:125`) → writes `payloadCiphertext` + `wrappedKey` + `relayEncryption` (`OpenBurnBarMobile/Services/HermesService.swift:3872-3877`, `4219-4224`).
- Host (Mac) opens: `unwrapSymmetricKey` (`:152`) + `openBase64` (`:114`) (`AgentLens/Services/HermesRealtimeRelayHostClient.swift:208-216`).
- **AAD is mandatory and namespaced**: `requestAAD`/`keyAAD`/`chunkAAD` bind `uid|connectionID|requestID(|seq|kind)` (`:81-97`). Key-wrap HKDF uses empty salt + `sharedInfo = "OpenBurnBar-HermesRelay-KeyWrap-v1|"+aad` (`:181`). PiAgent mirrors this with `OpenBurnBar-PiAgentRelay-*` strings (`:315-322`). The server relays `payloadCiphertext`/`wrappedKey` opaquely.

### 7. INTEROP — CONFIRMED

- **iOS↔Mac**: same `OpenBurnBarCore.CloudVaultCrypto` compiled into both targets → trivially identical.
- **Swift↔JS**: real-CryptoKit fixture gate `apps/console/test/interop.test.ts` unwraps a Swift-wrapped key and opens Swift-sealed blob+text in JS.
- **Swift↔Kotlin**: `android/.../CloudVaultCryptoTest.kt:46` proves Kotlin `unwrapVaultKey` accepts Swift's empty-salt HKDF wrap; `semanticHashes` regex/format match (`:39`).
- Wire invariants all platforms must preserve: AES-256-GCM, **12-byte nonce**, **16-byte tag**, `.combined = nonce‖ct‖tag`, escrow HKDF `salt=∅ info="OpenBurnBar-Escrow-v1"` over P-256 X-coordinate (32B) shared secret, X9.63 uncompressed pubkeys (65B, `0x04` prefix), `vaultKeyID = "v1_"+sha256hex(key)[0:32]`.

---

## DESIGN BRIEF (copy-pasteable change points)

1. **Reuse, never reinvent.** Every implementation stream MUST call the existing platform crypto: Swift `OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/CloudVaultCrypto.swift`; Kotlin `android/app/src/main/java/com/openburnbar/data/cloud/CloudVaultCrypto.kt` (+`CloudVaultCryptoSearch.kt`); web `apps/console/lib/escrow.ts`; Node `tools/openburnbar-mcp-remote/src/seal.ts`. No new AES/HKDF/HMAC code.

2. **Seal short private strings** (titles, snippets, project names, working dirs/paths, filenames, sender display names, prompts/short results): Swift `CloudVaultCrypto.sealText(text, keyData:)` → `CloudVaultSealedText`; Kotlin `CloudVaultCrypto.sealText(text, vaultKey)`; web `sealText(text, vaultKey)`; Node `sealTextWithVaultKey(text)`. Store the envelope `{algorithm,keyVersion,nonce,ciphertext,tag}`. Server validates with `requireSealedText(raw, fieldName)` (`functions/src/callables/shared.ts:338`).

3. **Seal large bodies** (transcripts, full message bodies): Swift `CloudVaultCrypto.sealBlob(data, keyData:)` → `CloudVaultBlobEnvelope`; web `sealBlob(data, vaultKey)`. Server validates with `requireCloudVaultBlobEnvelope` (`shared.ts:393`). For >~1MB use the existing storage path pattern guarded by `assertUserStoragePath` (`shared.ts:425`, suffix `.json.aesgcm`).

4. **Seal structured records needing key-binding** (agent notification replies, mission request/result payloads): Swift `CloudVaultCrypto.sealPayload(data, keyData:, vaultKeyID:)` + `sealedPayloadDictionary(...)`; Kotlin `sealPayload(...)` + `sealedPayloadMap(...)`. Server enforces `vaultKeyID` equality (`functions/src/callables/agentNotifications.ts:30-32`).

5. **Opaque ids / search keys** (when the server must equality-match without plaintext): use the HMAC trapdoor — Swift `CloudVaultCrypto.tokenHashes(for:keyData:)` / `searchIndexTokenHashes` / `searchQueryTokenHashes`; Kotlin `CloudVaultCrypto.tokenHashes`. Output is 16-byte (32-hex) HMAC-SHA256 under the HKDF search key; server gate is `^[a-f0-9]{32}$` (`shared.ts:331`). For a single opaque id, HMAC the id string as one term.

6. **Relay payloads** (live request/response over Hermes/iroh): use `HermesRelayCrypto`/`PiAgentRelayCrypto` (`OpenBurnBarCore/.../HermesRelayCrypto.swift`) with `sealToBase64`+`wrapSymmetricKey` (requester) and `unwrapSymmetricKey`+`openBase64` (host), always passing the namespaced `requestAAD`/`keyAAD`/`chunkAAD`. Write fields `payloadCiphertext`, `wrappedKey`, `relayEncryption="p256-hkdf-sha256-aesgcm"`, `relayKeyVersion=1`.

7. **GAP to close in lockstep — Android `sealBlob` is missing.** `CloudVaultCrypto.kt` has `openBlob` (`:103`) and `sealPayload` (`:119`) but **no `sealBlob`**. Any new private-text surface that Android must *write* as a blob requires adding a Kotlin `sealBlob(data, vaultKey): CloudVaultBlobEnvelope` mirroring Swift `:137-147` (nonce(12)‖cipher.doFinal, `plaintextSHA256` hex, schemaVersion=1). If Android only writes short text, route through `sealText`/`sealPayload` and avoid the gap; if it must write blobs, add `sealBlob` first.

8. **BLAST RADIUS (must change together):**
   - **Interop gates**: re-run/extend `apps/console/test/interop.test.ts` (Swift↔JS fixture), `OpenBurnBarCoreTests/CloudVaultCryptoTests.swift`, `android/.../CloudVaultCryptoTest.kt`. Any new sealed field needs a round-trip test on each platform that reads it.
   - **Server validators**: `functions/src/callables/shared.ts` (`requireSealedText`/`requireCloudVaultBlobEnvelope`/`requireTokenHashes`) and any callable adding a sealed field (e.g. `encryptedSearch.ts`, `knowledgeMemory.ts`, `agentNotifications.ts`). Firestore types in `functions/src/types/legacy.ts` (the `AES-256-GCM` doc shapes at `:908/916/1011`).
   - **Clients**: Swift writers in `OpenBurnBarMobile/Models/{ActivityStore,MobileTextExpansionStore,MobileChatHistoryStore}.swift`, `OpenBurnBarMobile/Services/{AgentReplyNotificationService,CLIAgentMissionDispatcher}.swift`, `AgentLens/Services/CloudSync/{SessionLogSyncService,ChatThreadSyncService,TextExpansionSyncService,CLIAgentMissionRequestListener}.swift`, `AgentLens/Services/Chat/MacAgentReplyNotificationListener.swift`; matching Kotlin writers under `android/app/.../data/...`; web reader `apps/console`; Node `tools/openburnbar-mcp-remote/src/{seal,decrypt}.ts`.
   - **Docs**: keep `docs/PENSIEVE*.md` and any envelope spec in sync; the canonical wire-format comment block lives in `apps/console/lib/escrow.ts:12-19` — update it if the format ever extends.

9. **Hard invariants for every stream (do not drift):** AES-256-GCM only; 12-byte nonce; 16-byte tag; `.combined = nonce‖ciphertext‖tag`; `keyVersion=1`/`schemaVersion=1`; escrow wrap = P-256 ECDH (X-coord 32B) → HKDF-SHA256 (salt ∅, info `"OpenBurnBar-Escrow-v1"`, 32B) → AES-GCM; X9.63 uncompressed pubkeys (65B); `vaultKeyID="v1_"+sha256hex(key)[:32]`; search/semantic HMAC trapdoor = first 16 bytes hex under the HKDF-derived search key. The server stays a blind store-and-forward + opaque-index — never add a server decrypt path.