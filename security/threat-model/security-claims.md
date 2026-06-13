> **CONFIDENTIAL — BurnBar security package.** Independently code-verified at HEAD `5416ef780`. Share with Cure53 out-of-band; do not publish.

# Security Claims Matrix

Each claim below was **adversarially verified against current HEAD code** — an independent reviewer tried to *refute* it before assigning a status. Status legend: **✅ Defensible** (code clearly supports it on current paths) · **🟡 Partially defensible** (true with material caveats/scope limits) · **❌ Not defensible** (code contradicts it) · **❓ Unknown** (needs deployed config/IAM/runtime evidence). Raw verifier output: [`_evidence/_claims.json`](_evidence/_claims.json). Per-domain claim assessments: [`_evidence/NN-*.md`](_evidence/).

**Headline:** of the 14 load-bearing claims, **4 Defensible, 10 Partial, 0 Not-defensible, 0 Unknown**. No headline claim is outright *false*, but **10 of 14 carry material caveats** — the safe wording below states each caveat. The single most important discipline: never collapse a Partial into an absolute ("zero-knowledge", "end-to-end", "never", "cannot ever").

## Summary table

| ID | Category | Claim | Status | Confidence |
|---|---|---|---|---|
| C1 | Confidentiality | Cloud cannot read current Gateway message/event bodies | ✅ Defensible | Medium |
| C2 | Confidentiality | Cloud cannot read CloudVault at-rest content | 🟡 Partially defensible | High |
| C3 | Confidentiality | Attachments sealed client-side before upload | 🟡 Partially defensible | Medium |
| C4 | Authentication/Authorization | Gateway bearer alone insufficient (PoP required) | ✅ Defensible | High |
| C5 | Authentication/Authorization | Revoked device cannot receive newly-sealed material | 🟡 Partially defensible | High |
| C6 | Agentic AI | Untrusted content cannot directly trigger high-impact action | 🟡 Partially defensible | High |
| C7 | Agentic AI | High-risk grants need single-use local-auth bound to op hash | 🟡 Partially defensible | Medium |
| C8 | Authentication/Authorization | Only pinned paired devices exchange Gateway msgs | 🟡 Partially defensible | Medium |
| C9 | Integrity/Authenticity | Iroh pairing records cannot be spoofed/replayed | 🟡 Partially defensible | Medium |
| C10 | Confidentiality | Provider creds not in Firestore plaintext (KMS) | ✅ Defensible | High |
| C11 | Authentication/Authorization | Object-level authz: no cross-user access | 🟡 Partially defensible | Medium |
| C12 | Replay/Freshness | Old messages/pairing codes cannot be replayed | 🟡 Partially defensible | High |
| C13 | Confidentiality | Logs/crash/push contain no plaintext bodies/secrets | 🟡 Partially defensible | Medium |
| C14 | Non-claim discipline | BurnBar does NOT claim production Signal E2EE | ✅ Defensible | High |

## Per-claim detail (claim · status · evidence · safe vs unsafe wording · gaps)

### C1 — Cloud cannot read current Gateway message/event bodies
**Claim as tested:** BurnBar Cloud cannot read CURRENT Hermes Gateway message/event bodies.
**Status:** ✅ Defensible  **Confidence:** Medium  **Category:** Confidentiality

**Refutation attempt (what the verifier tried to break, and what held / broke):**

> I tried to find a path where the server sees plaintext bodies on CURRENT writes. (1) Write enforcement: functions/src/callables/hermesGateway.ts:413-455 resolveGatewayWriteBody rejects all plaintext — if no envelope is present it calls gatewayPlaintextWriteAllowed(client.relayCapable), which is hardcoded to return false (functions/src/hermesGateway.ts:188-190), throwing HttpsError "ciphertext_required". isWithinGatewayGraceWindow() also hardcodes false (hermesGateway.ts:166-168). Both the message-send path (callables/hermesGateway.ts:1129-1136) and the event/model_switch path (2348-2395) route through resolveGatewayWriteBody, so neither phone->agent events nor agent->phone messages can write a server-readable body. Even the non-relay/broadcast event path (2376-2384) passes through the same plaintext rejection. (2) Server validation is shape-only: requireGatewayRelayEnvelope (hermesGateway.ts:712-789) checks base64 charset, size caps, algorithm constant, and key version only; the doc-comment at 704-711 states "The server never decrypts; this is a pure SHAPE gate." (3) No server-side decryption primitives: grepping functions/src/hermesGateway.ts and callables/hermesGateway.ts for AES/GCM/decrypt/.open(/unwrap/sharedSecret/KeyAgreement/HPKE/privateKey returned only comment strings and algorithm-name constants — no actual crypto-open call. (4) Key custody is client-side: HermesRelayCrypto.swift:28-45 HermesRelayPrivateKey wraps P256.KeyAgreement.PrivateKey; the server only ever receives PUBLIC keys (parseRelayPublicKey, callables/hermesGateway.ts:290-297) and the per-payload key is wrapped to the recipient PUBLIC key (sealKeyV3, HermesRelayCrypto.swift:493-514). The server never holds a recipient relay private key, so it cannot unwrap wrappedKey to recover the AES-256-GCM content key. (5) MITM: relay public keys are pinned on first pairing and immutable thereafter — a differing key on re-publish is dropped and logged as relay_key_change_rejected (callables/hermesGateway.ts:1240-1262); v2/v3 opens bind the PINNED sender static key, not the wire senderPublicKey (HermesRelayCrypto.swift:484-487). Residual breaks I DID find: (a) a legacy schema-1 plaintext READ fallback still surfaces a plaintext text/threadId/senderDisplayName sibling for any UNSEALED pre-cutoff doc (serializeHermesGatewayEvent, hermesGateway.ts:1222-1268) — current writes cannot create such docs, but historical/backfilled/admin-written ones would be server-readable; (b) no out-of-band user-verified safety code/number was found anywhere in Swift, so first-pairing key exchange is trust-on-first-use relayed through the untrusted Cloud (the Cloud could in principle substitute keys at the FIRST pairing before pinning); (c) routing metadata (destinationId, senderId, sequence, kind, timestamps, attachmentIds) remains plaintext at rest — only the BODY is sealed.

**Evidence (file:line):**
- functions/src/hermesGateway.ts:188-190 gatewayPlaintextWriteAllowed() hardcodes `return false` — no new plaintext body write is ever approved
- functions/src/hermesGateway.ts:166-168 isWithinGatewayGraceWindow() hardcodes `return false` — the schema-1 plaintext grace window is closed
- functions/src/callables/hermesGateway.ts:439-446 resolveGatewayWriteBody throws HttpsError 'ciphertext_required' when plaintext text is supplied without an envelope
- functions/src/callables/hermesGateway.ts:1129-1136 message-send routes the body through resolveGatewayWriteBody (sealed-only); 1162-1166 only relay/ratchet/signal envelopes (or dead legacyText) are persisted
- functions/src/callables/hermesGateway.ts:2348-2361 & 2376-2395 event + model_switch send paths also require a sealed envelope, throwing 'ciphertext_required'
- functions/src/hermesGateway.ts:704-789 requireGatewayRelayEnvelope is a pure SHAPE gate (base64/size/algorithm/version) — doc-comment: 'The server never decrypts'
- grep of functions/src/hermesGateway.ts + callables/hermesGateway.ts for AES/GCM/decrypt/.open(/unwrap/sharedSecret/privateKey found NO server-side decryption call — only comments/constants
- OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/HermesRelayCrypto.swift:28-45 HermesRelayPrivateKey wraps P256.KeyAgreement.PrivateKey; publicKeyBase64 is the only thing exported to the wire
- OpenBurnBarCore/.../HermesRelayCrypto.swift:493-514 sealKeyV3 wraps the 32-byte content key to the recipient PUBLIC key via HPKE Auth — server lacks the recipient private key to unwrap
- functions/src/callables/hermesGateway.ts:1240-1262 relay public keys are pinned on first pairing and immutable; a changed key is dropped + logged 'relay_key_change_rejected' (anti-MITM after pairing)
- CAVEAT functions/src/hermesGateway.ts:1222-1268 serializeHermesGatewayEvent still surfaces plaintext text/threadId/senderDisplayName for an UNSEALED legacy schema-1 doc (read fallback) — readable by anyone with Firestore access
- CAVEAT: no out-of-band safety-code/key-verification UI found in Swift — first-pairing key trust is TOFU relayed through the untrusted Cloud; routing metadata (destinationId/senderId/sequence/timestamps) is plaintext at rest

**✅ SAFE wording (defensible to publish):**

> For messages and events written by the current app, the body content (message text, thread name, sender display name, attachment file names) is end-to-end encrypted on-device and the BurnBar Cloud stores and forwards only opaque ciphertext: the server validates envelope shape but never holds a recipient private key and never decrypts, so it cannot read current message/event bodies. This protection depends on (a) an honest first-pairing key exchange — keys are trusted-on-first-use and pinned thereafter, with no user-verified safety number, so a malicious cloud could in theory substitute keys during the very first pairing; (b) routing metadata (who/when/which destination, message ordering, attachment counts) remaining visible to the cloud by design; and (c) legacy pre-2026-06-03 plaintext messages, if any are still queued, remaining server-readable.

**⛔ UNSAFE wording (do NOT publish):**

> BurnBar Cloud can never see any of your message data — everything is fully end-to-end encrypted and the cloud is zero-knowledge. (Unsafe: overstates it — routing metadata is plaintext at rest, first-pairing key trust is TOFU with no verified safety number so a malicious cloud could MITM at first pairing, and legacy schema-1 plaintext docs remain server-readable. 'Cannot read CURRENT bodies' is defensible; 'never sees any message data / zero-knowledge' is not.)

**Open gaps / what would raise confidence:**
- First-pairing key authenticity is trust-on-first-use; no user-verified safety code/number was found in Swift, so a malicious-cloud MITM at the FIRST pairing cannot be ruled out from code alone — needs review of pairing UX/QR/proximity channel to confirm keys aren't solely cloud-relayed
- Whether any legacy schema-1 plaintext gateway docs still exist in production Firestore (and whether a backfill/scrubber drained them) is a deployed-data question, not visible in code
- Firestore rules + IAM were not re-verified here for whether a cloud operator/admin SDK could write a plaintext-sibling doc that the read fallback would then surface (admin writes bypass callable enforcement)
- ratchetEnvelope (Phase 6) and signalEnvelope (libsignal v4) wire families were validated as shape-only but their full key-custody paths were not traced end-to-end in this pass
- Metadata exposure (destinationId, senderId, sequence, timestamps, attachmentIds) is by design and out of scope of C1's 'bodies' wording, but should be stated explicitly in any user-facing claim

---

### C2 — Cloud cannot read CloudVault at-rest content
**Claim as tested:** BurnBar Cloud cannot read CloudVault at-rest content (conversations/chat/sessions/memory).
**Status:** 🟡 Partially defensible  **Confidence:** High  **Category:** Confidentiality

**Evidence (file:line):**
- OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/CloudVaultCrypto.swift:438,466,573 — client-side AES-256-GCM seal of text/blob/payload under 32-byte vault key
- OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/CloudVaultCrypto.swift:420,1426,1435 — vault key generated on device; Keychain kSecAttrAccessibleWhenUnlockedThisDeviceOnly; never uploaded cleartext
- OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/CloudVaultCrypto.swift:976,1027 — vault key only leaves device wrapped (ECIES-P256 to device pubkey, or recovery-KEK)
- functions/src/signalEnvelopeExport.ts:4 and functions/src/signalAtRestWrite.ts:18 — explicit 'server never decrypts' design
- functions/src/signalAtRestWrite.ts:72 validateSignalAtRestEnvelopeForWrite — admin path only sanitizes shape + path-binds AAD; content key stays HPKE-wrapped per recipient
- functions/src/callables/knowledgeSearch.ts:9-15 — search over on-device-cloaked vectors; server returns sealed ciphertext, never sees plaintext/query/vault key
- functions/src/callables/recovery.ts:215-223 — stores client-wrapped vault key + one-way commitment; server never unwraps
- firestore.rules:1274-1277 (conversations), 1323-1325 (mobile_assistant_chats), 1368-1370 (cli_sessions) — require contentSealed==true, sealedSchemaVersion==2, validSealedPayloadForUser
- firestore.rules:650 validSealedPayloadForUser + 599 validCloudSealedPayload — sealed payload must match user's current active vault key id; only ciphertext fields allowed
- firestore.rules:731 validChatThreadSealedContent / 706 chatThreadHasPlaintextContent — title/preview/messages never permitted
- firestore.rules:1758 mission_groups + 1962-1963 project_memory_snapshots — explicit plaintext-field denylists; content forced into sealed envelopes/blobs
- functions/src/callables/privacyBackfill.ts:95-109,126-159 — CAVEAT: legacy plaintext content fields existed server-readable (projectName/title/preview/Hermes relayed text, an audit BLOCKER) and are stripped only once a sealed copy exists; firestore.rules:1789/1821 note 'legacy plaintext rows remain readable'

**✅ SAFE wording (defensible to publish):**

> For content created by current app versions, conversation/chat/session/memory data is encrypted on your device with a vault key that never leaves your devices in readable form (held only in the Keychain, and shared between your own trusted devices only as ciphertext). BurnBar's cloud stores and serves only ciphertext for these surfaces and is not able to decrypt them — Firestore rules reject plaintext content on these collections, and the Cloud Functions are coded to never decrypt vault content or hold the vault key. Note: some data written by older app versions could contain plaintext metadata/content in the cloud; an automatic, owner-scoped backfill removes that legacy plaintext once an encrypted copy exists, so older un-migrated records may still be server-readable until they are re-sealed.

**⛔ UNSAFE wording (do NOT publish):**

> BurnBar Cloud can never read any of your conversation, chat, session, or memory data — everything has always been end-to-end encrypted and the server has zero ability to see plaintext. (Unsafe: ignores the documented legacy plaintext fields that the server could read and that are still being stripped by an in-product backfill, treats 'at-rest sealed' as 'E2E always', and overstates the historical guarantee.)

**Open gaps / what would raise confidence:**
- Could not confirm at runtime how many legacy un-swept documents still hold plaintext, or whether the scheduled privacyBackfill sweep has completed across all existing users — needs deployed Firestore data + sweep watermark (privacy_reseal_state/current.resealEpoch) inspection
- Firestore rules are the SOURCE; the DEPLOYED ruleset and its version were not verified against this firestore.rules file — needs `firebase deploy` history / console rules to confirm prod parity
- Admin-SDK / Cloud Functions can structurally bypass Firestore rules; verified by code review that no function decrypts, but a deployed IAM review of which service accounts can read the buckets/collections would strengthen this
- The Signal at-rest envelope path is flag-gated and 'fails open to legacy' (SECURITY.md:94) — 'legacy' = existing AES-256-GCM seal (still zero-plaintext), but the activation state and any gateway-relayed transient plaintext window were not runtime-verified
- Hermes Gateway relayed content is a transport/relay surface, not strictly CloudVault at-rest; its historical plaintext (privacyBackfill.ts:95) is outside the strict claim scope but adjacent and worth flagging

---

### C3 — Attachments sealed client-side before upload
**Claim as tested:** C3: "Attachments are sealed client-side before upload; cloud cannot read bytes or filenames.
**Status:** 🟡 Partially defensible  **Confidence:** Medium  **Category:** Confidentiality

**Refutation attempt (what the verifier tried to break, and what held / broke):**

> I tried to break C3 by finding (a) an unsealed/fail-open write path, (b) a server-side decrypt or plaintext sink, (c) a legacy/backfill hole, and (d) a place the cloud can read bytes or filenames.
>
> (a) Fail-open write path — NOT found, gate holds. functions/src/hermesGateway.ts:188-190 gatewayPlaintextWriteAllowed() unconditionally `return false`, despite the parameter that suggests a relayCapable/grace-window override. Attachment init (functions/src/callables/hermesGateway.ts:1438-1444) computes `sealed = relayEnvelope||ratchetEnvelope||signalEnvelope` and throws `ciphertext_required` when not sealed. Message-send requires relayCapable===true (callables/hermesGateway.ts:1123-1125) and rejects plaintext. So NEW writes are sealed-only.
>
> (b) On the sealed path no plaintext name reaches a sink: legacyFileName is forced undefined (callables/hermesGateway.ts:1447-1449), declaredContentType is hard-set to application/octet-stream (1455-1456), and the storagePath carries NO fileName segment (1470-1472). The envelope validators (hermesGateway.ts:712-792, 691-702, 629-637) are pure SHAPE gates over base64 ciphertext (payloadCiphertext = AES-256-GCM .combined seal; wrappedKey wrapped to the recipient's relay key) — the server never holds the recipient private key and never decrypts (documented hermesGateway.ts:225-238, 707). Finalize (callables/hermesGateway.ts:1561-1604) checks size + ciphertext sha256 and explicitly SKIPS content-type sniffing for sealed objects (1574-1580). So for a correctly-behaving sealed client the cloud genuinely cannot read bytes or the filename.
>
> BREAKS that lower this to Partial:
> (c) LEGACY HOLE (a real, documented audit BLOCKER). privacyBackfill.ts:95-99 states legacy schema<2 attachments stored a plaintext `fileName` in the manifest AND the original `requires:"relayEnvelope"` gate was a STRUCTURAL NO-OP, so the plaintext fileName "was stored AND served forever until an operator hand-ran the scrubber." Legacy uploads also stored REAL media bytes with the real content type (assertLegacyAttachmentContentType, callables/hermesGateway.ts:472-490). A scheduled sweep now strips the manifest fileName field (every 24h, privacyBackfill.ts:497-500; field list privacyBackfill.ts:234-236), but it (i) lags by up to a day, and (ii) strips only the Firestore manifest field — I found NO code that deletes or reseals the legacy plaintext Storage OBJECTS, so pre-migration plaintext attachment bytes may still sit cloud-readable in Storage.
> (d) CLIENT-ENFORCED, NOT CLOUD-VERIFIED. Sealing happens entirely on the client; because the cloud forces octet-stream and skips sniffing for sealed objects (callables/hermesGateway.ts:1578), it CANNOT verify the uploaded bytes are actually ciphertext. A buggy/malicious relayCapable client could upload plaintext bytes to the signed URL and the cloud would store/serve them opaquely while they remain plaintext-readable. So "cloud cannot read bytes" is a property of the client doing its job, not a server-enforced invariant.
> Always-visible metadata: byteCount (ciphertext size), storagePath, status, ciphertext sha256, storageGeneration (callables/hermesGateway.ts:1588-1602).

**Evidence (file:line):**
- functions/src/hermesGateway.ts:188-190 gatewayPlaintextWriteAllowed() unconditionally returns false (comment 184-187: new writes sealed-only, legacy plaintext read-only)
- functions/src/callables/hermesGateway.ts:1438-1444 handleAttachmentInit — `sealed` flag; throws ciphertext_required when no relay/ratchet/signal envelope and plaintext not allowed
- functions/src/callables/hermesGateway.ts:1447-1456 sealed path forces legacyFileName=undefined and declaredContentType='application/octet-stream' (no plaintext name/type stored)
- functions/src/callables/hermesGateway.ts:1470-1472 storagePath = users/{uid}/hermes_gateway_attachments/{clientId}/{attachmentId} — NO fileName segment in the object path
- functions/src/hermesGateway.ts:712-792 requireGatewayRelayEnvelope — pure SHAPE gate (base64 payloadCiphertext/wrappedKey, version, size caps); comment 707 'The server never decrypts'
- functions/src/hermesGateway.ts:225-238 doc: payloadCiphertext = AES-256-GCM seal, wrappedKey wrapped to recipient relay key, server validates SHAPE only and 'can never decrypt'
- functions/src/callables/hermesGateway.ts:1574-1580 finalize skips content-type sniff for sealed objects; integrity via ciphertext sha256 (1582-1586)
- functions/src/callables/hermesGateway.ts:1123-1125 handleMessageSend rejects unsealed_client_unsupported unless relayCapable===true
- functions/src/callables/privacyBackfill.ts:95-99 audit BLOCKER: legacy schema<2 plaintext fileName stored AND served 'forever until an operator hand-ran the scrubber'
- functions/src/callables/privacyBackfill.ts:234-236 gatewayRelayed strip applies to hermes_gateway_attachments.fileName; 497-500 scheduled sweep 'every 24 hours' (no code seen that deletes/reseals legacy plaintext Storage objects)
- functions/src/callables/hermesGateway.ts:472-490 assertLegacyAttachmentContentType — legacy uploads stored REAL media bytes with real content type (cloud-readable on those legacy objects)
- storage.rules:5-28 + callables/hermesGateway.ts:1588-1602 metadata always cloud-visible: byteCount, storagePath, status, ciphertext sha256, storageGeneration

**✅ SAFE wording (defensible to publish):**

> For current (schema 2+) Hermes Gateway attachments, the client seals the file bytes (AES-256-GCM) before upload and seals the filename, content type, and byte count inside a relay/ratchet envelope the cloud cannot decrypt; on these paths the server stores an opaque object, never accepts a plaintext filename, and never holds the key to read the bytes or name. New unsealed attachment writes are rejected in code. Caveats: sealing is enforced on the client, so the cloud cannot prove an uploaded object is truly ciphertext; the cloud always sees metadata (ciphertext size, storage path, status, ciphertext hash); and legacy pre-migration attachments stored plaintext filenames (now stripped by a daily backfill, but the legacy plaintext Storage objects themselves are not provably purged in code). A production data scan is needed to confirm no legacy plaintext attachment bytes or filenames remain.

**⛔ UNSAFE wording (do NOT publish):**

> All attachments are end-to-end encrypted; the cloud can never read attachment bytes or filenames. (Overclaim: ignores that sealing is client-enforced and unverifiable by the cloud, that metadata is always visible, that legacy attachments stored cloud-readable plaintext filenames and bytes, and that the backfill only strips the manifest field on a 24h lag without provably purging legacy plaintext Storage objects.)

**Open gaps / what would raise confidence:**
- No code found that deletes or re-seals the legacy plaintext attachment Storage OBJECTS (bytes) — backfill only strips the Firestore manifest fileName field; legacy media bytes in Storage may remain cloud-readable. Needs a production Storage scan.
- Cloud cannot verify uploaded bytes are actually ciphertext (octet-stream forced, sniff skipped for sealed) — a misbehaving relayCapable client could upload plaintext; whether any client does is a runtime/endpoint question.
- Whether any legacy schema-1 attachments with plaintext fileName still exist before the daily sweep converges is unknown without a production Firestore data-shape scan (threat-model open question #5, docs/security/BurnBar-threat-model.md:517).
- Signed upload URL is issued with contentType pinned but GCS enforcement of that content type / object immutability before finalize was not verified; an attacker with the short-lived URL window could potentially overwrite — needs deployed bucket/IAM config to assess.
- Client-side sealing implementation (the actual AES-GCM seal of bytes + envelope construction) lives in the agent/mobile clients, not verified here; C3's 'sealed client-side' depends on that client code being correct.

---

### C4 — Gateway bearer alone insufficient (PoP required)
**Claim as tested:** C4: "A Gateway bearer token alone is insufficient for active access — proof-of-possession of the pairing-pinned signing key is required.
**Status:** ✅ Defensible  **Confidence:** High  **Category:** Authentication/Authorization

**Refutation attempt (what the verifier tried to break, and what held / broke):**

> I tried to find a path where a bearer token alone grants active gateway access without PoP of the pinned signing key, and could not on current code. (1) ROUTE COVERAGE: Every active-access HTTP route in dispatchHermesGatewayRequest (functions/src/callables/hermesGateway.ts:1782-1794) — /destinations(1064), /events(1080), /messages(1118), /typing(1197), /runtime(1216), /state(1370), /approvals arm+list(1683,1736), /attachments/init(1411), /attachments/finalize(1515) — funnels through resolveGatewayGrant, which calls verifyGatewayRequestPoP (845). The only routes that skip PoP are /device/start(884) and /device/poll(984): pairing bootstrap gated by a device secret (safeEqualHex at 999) that only RETURN a token after owner approval and grant no active access. (2) FAIL-OPEN ON LEGACY: A client lacking a pinned signing key or with popRequired!==true is rejected 401 'legacy_pop_required' (697-699) — fails closed, no plaintext/legacy bypass. (3) SIGNING-KEY SWAP: The pinned key agentClientSigningPublicKeyBase64 is written only at /device/start session (945) and approveHermesGatewayDeviceGrant client doc (2005), the latter requiring Firebase auth+App Check; no bearer-token HTTP path writes it, and firestore.rules hermes_gateway_clients is 'write: if false' (firestore.rules:2582) while hermes_gateway_token_index is 'read,write: if false' (4251). A token holder cannot read or rewrite the client doc to substitute a key. rotateHermesGatewayClientToken refuses legacy clients without a pinned key (2217-2222), so rotation can't strip PoP. (4) ORDERING (auth-before-authz): PoP failure is thrown BEFORE scope and entitlement via Promise.allSettled (844-857) — no 403 leak before PoP. (5) BINDING/REPLAY: body hash compared (720), v2 binds canonical query (742), nonce replay guarded in a transaction (758-771), timestamp skew ±5min (716), Ed25519 verify (755), v1→v2 downgrade refused once v2 registered (705-707, tested). I found no fail-open, no unsealed bearer-only path, and no TODO. The one true SCOPE caveat: enqueueHermesGatewayEvent (2276) lets the PHONE inject events using Firebase auth+App Check+entitlement, NOT a gateway bearer token — a different (owner-bound) credential, so it is not a bearer-token bypass of PoP but means not every active write to gateway data goes through bearer+PoP.

**Evidence (file:line):**
- functions/src/callables/hermesGateway.ts:697-699 verifyGatewayRequestPoP — rejects 401 'legacy_pop_required' when client.agentClientSigningPublicKeyBase64 is absent OR client.popRequired!==true (fail-closed)
- functions/src/callables/hermesGateway.ts:755-756 verifyGatewayRequestPoP — Ed25519 verifySignature(null,payload,publicKey,signature); failure throws 401 'bad_pop_signature'
- functions/src/callables/hermesGateway.ts:758-771 verifyGatewayRequestPoP — transactional nonce single-use replay guard (pop_nonce_replay), expireAt = now+skew
- functions/src/callables/hermesGateway.ts:719-722 verifyGatewayRequestPoP — request body hash bound and compared (bad_pop_body_hash); 736-746 v2 binds canonical query string
- functions/src/callables/hermesGateway.ts:844-857 resolveGatewayGrant — Promise.allSettled runs PoP+entitlement; popResult rejected is thrown first (853) BEFORE scope check (854) and entitlement (857): auth-before-authz ordering correct
- functions/src/callables/hermesGateway.ts:811-840 resolveGatewayGrant — bearer token is only an index hint: token->tokenHash->index doc->client doc; verifies client.tokenHash match (831), expiry (838) before PoP
- functions/src/callables/hermesGateway.ts:1782-1794 dispatchHermesGatewayRequest — all active routes; resolveGatewayGrant called at 1064,1080,1118,1197,1216,1370,1411,1515,1683,1736 (every route except /device/start,/device/poll)
- functions/src/callables/hermesGateway.ts:907,945-947 handleDeviceStart — requireGatewayClientSigningPublicKey (mandatory, throws 400) + popRequired:true persisted at pairing
- functions/src/callables/hermesGateway.ts:1922,2005-2007 approveHermesGatewayDeviceGrant — requireCallableGatewayClientSigningPublicKey + popRequired:true on the client doc (PoP cannot be opted out at pairing)
- functions/src/callables/hermesGateway.ts:2217-2222 rotateHermesGatewayClientToken — refuses to rotate a legacy client lacking pinned signing key / popRequired (token rotation cannot strip PoP)
- firestore.rules:2580-2582 hermes_gateway_clients — allow read: ownsUserNamespace(owner Firebase auth); allow write: if false (signing-key pin not client-mutable); firestore.rules:4250-4251 hermes_gateway_token_index read,write: if false
- functions/src/callables/hermesGateway.ts:2276-2330 enqueueHermesGatewayEvent — SCOPE caveat: phone->agent events use Firebase auth+App Check+entitlement, NOT a gateway bearer token, so this write path is governed by owner auth rather than bearer+PoP

**✅ SAFE wording (defensible to publish):**

> On the Hermes Gateway's bearer-token HTTP surface, a stolen or replayed bearer token by itself does not grant active access: every active-access route (events, messages, runtime, state, approvals, typing, destinations, attachments) additionally requires a per-request Ed25519 proof-of-possession signed with the client signing key pinned at pairing — covering method, path, body hash (and query in v2), with a single-use nonce and ±5-minute timestamp. Requests missing the signing key or PoP fail closed (401), the pinned key is server-only and immutable to token holders (Firestore client doc is write:if false), and PoP is verified before scope/entitlement so no authorization state leaks first. Note this is verified at the code level for the current paths; it does not certify deployed proxy header forwarding or runtime config.

**⛔ UNSAFE wording (do NOT publish):**

> Avoid: "BurnBar's Gateway is fully end-to-end secure and a bearer token can never be used to do anything." That overclaims: (a) the claim is scoped to the bearer-token HTTP surface — the phone injects events via a separate Firebase-authenticated callable (enqueueHermesGatewayEvent) that does not use bearer+PoP at all; (b) bearer tokens still gate the index lookup and could be replayed against the network up to the PoP check; (c) the guarantee is code-level and assumes the deploy forwards the x-obb-pop-* headers and clocks are within skew — none of that is runtime-verified here.

**Open gaps / what would raise confidence:**
- Deployment/runtime UNKNOWN: cannot confirm Firebase Hosting->Cloud Run forwards the x-openburnbar-pop-* / x-obb-pop-* headers intact; if stripped, requests would fail closed (401) rather than fail open, but PoP would be unenforceable end-to-end. Would be resolved by a live request trace or Hosting rewrite config.
- Did not exhaustively audit every helper (gatewayHeader/header/requestBody/stableJSONString at 542-561) for parsing quirks that could let two distinct bodies hash equal; spot-checked only.
- Scope boundary: enqueueHermesGatewayEvent (phone->agent) and approveHermesGatewayDeviceGrant rely on Firebase auth + App Check + entitlement, not bearer+PoP — claim C4 is true for the bearer surface but is not a statement about those owner-auth callables.
- Did not verify the GATEWAY_POP_CLOCK_SKEW_MS=5min window against nonce TTL cleanup at scale (replay doc expireAt=now+skew); a clock-skew + nonce-GC race was not runtime-tested.
- Legacy pre-PoP client docs (popRequired absent) presumably still exist for already-paired users; they are rejected with legacy_pop_required (fail-closed) but cannot self-heal without an explicit re-pair — confirmed in code, not in production data.

---

### C5 — Revoked device cannot receive newly-sealed material
**Claim as tested:** C5: "A revoked device cannot continue to receive NEWLY-sealed vault material; revocation triggers rotation+rewrap+reseal.
**Status:** 🟡 Partially defensible  **Confidence:** High  **Category:** Authentication/Authorization

**Refutation attempt (what the verifier tried to break, and what held / broke):**

> I traced the full revoke -> rotate -> rewrap -> reseal chain in current code and found a real, code-acknowledged gap that defeats the strong reading of C5.
>
> WHAT IS WIRED (supports the claim): revokeEscrowDeviceTrust (functions/src/callables/computerUseSecurity.ts:1456) now atomically, in one batch (commit at :1591): flips trustState->revoked (:1487), revokes that device's active cloud_vault_key_wrappers (:1508-1519), deletes its iroh controllers + agent_grant_authority (:1576,:1588), AND creates a cloud_vault_rotation_requirements/{receiptId} doc with status=pending, survivorDeviceIds, rotateCallable=rotateCloudVaultKey, reason=device_revoked (:1535-1557). A surviving Mac picks it up (ComputerUseSecurityCallableClient.swift pickUpPendingCloudVaultRotations :370 + performRevocationCloudVaultRotation :586), generates a NEW vault key locally (:612), wraps it ONLY to survivors' escrow public keys (:616-624, survivorWrapper :661), calls rotateCloudVaultKey (cloudVaultRotation.ts:111) which validates trusted survivors (:104-109,:188-197), advances generation by exactly one (:185), sets cloud_vault_state/current to the new key (:220-237), revokes all old-key wrappers (:294-309), and the client rewraps/reseals all domains under the new key (CloudVaultRotationRewrapWorker.swift runDocumentRewrap :36, sealBlob/sealText with newKeyData). After rotation completes, keyForWriting (CloudVaultKeyAccess.swift:173) seals NEW writes under cloud_vault_state/current.vaultKeyID = the NEW key, which the revoked device cannot derive (its survivor-only ECIES wrap; rotateCloudVaultKey refuses non-trusted devices, cloudVaultRotation.ts:134). So once rotation finishes, the strong claim holds.
>
> WHERE IT BREAKS (refutes the strong/unconditional claim):
> 1. Rotation is NOT synchronous with revocation and NOT server-driven. The server only writes a pending REQUIREMENT; actual rotation requires a surviving TRUSTED macOS device to come online and run the chain (pickUpPendingCloudVaultRotations triggered only on app launch/foreground, AppDelegate.swift:119,:134,:143). If the revoking device is offline/Android, the requirement stays pending.
> 2. During the pending window the current vault key is unchanged, so keyForWriting (CloudVaultKeyAccess.swift:173-198) seals NEW material under the OLD key/generation.
> 3. Reads are gated ONLY on uid ownership, not device trust: ownsUserNamespace (firestore.rules:52-54) = isSignedIn() && request.auth.uid==userId; session_logs/wrappers/etc all use it (firestore.rules:1922,:2210). A revoked escrow device authenticates as the SAME Firebase uid, and NO Firebase token/session revocation is tied to escrow revoke (no revokeRefreshTokens in functions/src). So the revoked device retains read access to all ciphertext.
> 4. The code ITSELF documents the hole: cloudVaultRotationResilience.ts:214-215 comment "A revoked device's cached vault key keeps decrypting until a survivor completes rotation; surface that window." The stale-pending detector (sweepStalePendingCloudVaultRotations :186, STALE_PENDING_GRACE_MS=1h :48) only WARNS and FCM-nudges survivors; it cannot itself rotate (server never holds the key).
>
> Net: until a survivor finishes rotation, a revoked device that retains its Firebase session can still read AND decrypt newly-written material sealed under the old key. The claim is true only AFTER rotation completes, not at/around revocation time.

**Evidence (file:line):**
- functions/src/callables/computerUseSecurity.ts:1535-1557 revokeEscrowDeviceTrust writes cloud_vault_rotation_requirements/{receiptId} status='pending' with survivorDeviceIds + rotateCallable; rotation is a requirement, not performed inline (batch.commit at :1591)
- functions/src/callables/computerUseSecurity.ts:1508-1519 only revokes the revoked device's OWN active wrappers; does not produce a new key — server cannot (no plaintext key server-side)
- functions/src/callables/computerUseSecurity.ts:1558-1562 if no surviving trusted device, cloudVaultRotationBlockedReason='no_surviving_trusted_device' and NO rotation requirement is created — old key never retired
- functions/src/callables/cloudVaultRotation.ts:104-109,134,188-197 rotateCloudVaultKey requires caller + every survivor target to be trustState=='trusted'; revoked device cannot wrap the new key to itself
- functions/src/callables/cloudVaultRotation.ts:220-237 sets cloud_vault_state/current to newVaultKeyID and :294-309 revokes all wrappers for the old key — this is the moment new writes flip to the new key
- AgentLens/Services/CloudVaultKeyAccess.swift:173-198 keyForWriting seals NEW material under cloud_vault_state/current.vaultKeyID; before rotation completes that is still the OLD key the revoked device holds
- AgentLens/Services/ComputerUse/ComputerUseSecurityCallableClient.swift:370-407 pickUpPendingCloudVaultRotations only runs on a surviving Mac; triggered by AppDelegate.swift:119/:134/:143 (launch/foreground), so rotation is deferred and availability-dependent
- AgentLens/Services/CloudSync/CloudVaultRotationRewrapWorker.swift:36-124 runDocumentRewrap reseals documents + storage blobs under newKeyData (sealBlob/sealText) — confirms rewrap+reseal exists but is client-side and post-rotation
- firestore.rules:52-54 ownsUserNamespace = isSignedIn() && request.auth.uid==userId; firestore.rules:1922,:2210 reads on session_logs and cloud_vault_key_wrappers gate on uid ownership ONLY, no device-trust check
- No Firebase token/session revocation on escrow revoke (grep for revokeRefreshTokens/disableUser in functions/src returns no escrow-revoke caller) — a revoked device keeps its Firebase auth and thus read access to ciphertext
- functions/src/cloudVaultRotationResilience.ts:214-215 code comment: 'A revoked device's cached vault key keeps decrypting until a survivor completes rotation; surface that window.'
- functions/src/cloudVaultRotationResilience.ts:186-256 sweepStalePendingCloudVaultRotations (STALE_PENDING_GRACE_MS=1h) only logs warning + FCM-nudges survivors; it cannot complete rotation server-side

**✅ SAFE wording (defensible to publish):**

> Escrow-device revocation is atomic and immediately (1) marks the device revoked, (2) revokes its existing vault-key wrappers, removes its iroh controller and agent-grant authority, and (3) records a pending rotation requirement so a surviving trusted Mac re-keys the vault, rewraps every domain, and reseals all data under a new key the revoked device cannot derive. Once that rotation completes, all newly-sealed material is sealed under the new key and is unreadable to the revoked device. Important scope: rotation is performed by a surviving trusted macOS device (not the server and not synchronously with revoke), so there is a bounded window — until a survivor comes online and finishes rotation — during which (a) new material is still sealed under the old key and (b) the revoked device, which keeps its Firebase session and read access, can still decrypt it with its cached key. If no surviving trusted device exists, rotation cannot be performed and the old key is not retired. The system surfaces stale-pending rotations via alerts/push nudges but cannot force completion.

**⛔ UNSAFE wording (do NOT publish):**

> Revoking a device instantly cuts it off from all future vault data — revocation triggers rotation, rewrap, and reseal so a revoked device can never read newly-sealed material. (UNSAFE: rotation is deferred, client-driven, and requires a surviving trusted Mac; until it completes the revoked device retains its Firebase session and can still read and decrypt new material sealed under the old key — the code itself notes the cached key 'keeps decrypting until a survivor completes rotation', and if no survivor exists no rotation happens at all.)

**Open gaps / what would raise confidence:**
- Exact duration of the pending-rotation window in practice depends on when a surviving trusted Mac next launches/foregrounds (AppDelegate triggers) — needs runtime/fleet telemetry to bound; code only enforces a 1h stale-WARN threshold, not a hard retire deadline
- Whether deployed Firebase config revokes/limits the revoked device's auth session at all is not evident in code (no revokeRefreshTokens wired to escrow revoke) — would need deployed Auth/Identity config to confirm a revoked device's token truly stays valid
- No server-side cap observed on how long writes may continue under the old key while a requirement is pending; confirm no Cloud Function blocks old-key writes after a pending requirement exists
- Behavior when survivorDeviceIds is empty (no_surviving_trusted_device, computerUseSecurity.ts:1559) means the old key is never retired — confirm product UX warns the user that revocation did not re-key in this case
- Storage-blob reseal completion is tracked by client checkpoints (CloudVaultRotationRewrapWorker storageRewrapPending); verify a partially-completed rewrap cannot leave some new blobs still under the old key without surfacing as failed

---

### C6 — Untrusted content cannot directly trigger high-impact action
**Claim as tested:** C6: "Untrusted content (document/webpage/tool output) cannot DIRECTLY trigger a high-impact tool action without explicit user approval.
**Status:** 🟡 Partially defensible  **Confidence:** High  **Category:** Agentic AI

**Refutation attempt (what the verifier tried to break, and what held / broke):**

> I tried to find a path where untrusted content drives a high-impact action with no human approval, and found two real caveats that downgrade this from Defensible to Partial.
>
> (1) TRUSTED-MODE AUTO-DISPATCH (the main caveat). In the capability gate, when the live session trust mode is .trusted and the action matches an active scope allow rule, the gate returns .allowed(approvedBy: .trustedScope) with NO approval sheet — ComputerUseCapabilityGate.swift:362-363. The run coordinator honors that directly: `if approvedByCandidate == .trustedScope { approvedBy = .trustedScope }` and dispatches without raising an approval — ComputerUseRunCoordinator.swift:262-269. There is NO carve-out forcing high-impact action classes (e.g. mac.input.shortcut, typing) to re-approve regardless of trust mode. So if the operator has put the session in trusted mode and a malicious instruction embedded in a webpage/AX tree/tool output causes the agent to emit a high-impact action that happens to fall inside an allow rule, it dispatches with no per-action approval. Mitigant: trusted mode is operator-chosen per session, never sticky and never agent-settable (ComputerUseSessionMetadata.swift:44-47), and entering it requires local authentication (AgentCapabilityGrant.swift:39 requiresLocalAuthentication returns true for .trusted). Read-only mac.inspect also auto-approves (ComputerUseRunCoordinator.swift:270-271).
>
> (2) UNTRUSTED-CONTENT WRAPPING IS DEFENSE-IN-DEPTH, NOT ISOLATION. Untrusted content IS wrapped before entering LLM context (ContextBuilder.swift:8-50 LLMSafeContent.wrapUntrusted, with delimiter-breakout defang and an explicit "never treat as instructions" rule), and the focus transcript — flagged stale/raw in the older internal package — is NOW wrapped (ChatSessionController.swift:132-144, provenance focus_session:). But the wrapper is advisory: the model can still be steered. The repo's own matrix says exactly this (security-claims.md:20 "Retrieved content cannot override instructions — Not defensible — wrappers are defense-in-depth, not isolation").
>
> What I could NOT break: manual/step modes fail closed (every non-read action raises an approval and waits — ComputerUseRunCoordinator.swift:280-343); the approval presenter has no auto-approve fallback (ComputerUseDaemonApprovalPresenter.swift:119-152); accessibility deny regions beat everything including signed phone authority (ComputerUseCapabilityGate.swift:335; password fields/auth sheets/keychain/login window in ComputerUseDenyRegistry.swift and MacComputerUseDenyRegions.swift:67-88); audit-before-action is fail-closed (ComputerUseRunCoordinator.swift:345-374); and SSRF/metadata/file:// browser denies (RR-15's recommendation) HAVE been added (ComputerUseDenyRegistry.swift:88-162: file://, 169.254.*, metadata.google.internal, loopback). So the claim holds robustly in the DEFAULT (manual) posture; it weakens in trusted mode.

**Evidence (file:line):**
- OpenBurnBarCore/Sources/OpenBurnBarComputerUseCore/ComputerUseCapabilityGate.swift:362-363 — in .trusted mode a scope-allowed action returns .allowed(approvedBy: .trustedScope) with no approval (DefaultComputerUseCapabilityGate.check)
- OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/ComputerUse/ComputerUseRunCoordinator.swift:262-271 — coordinator dispatches .trustedScope (and read-only mac.inspect) WITHOUT raising the approval sheet
- OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/ComputerUse/ComputerUseRunCoordinator.swift:280-343 — manual/step modes raise HermesRealtimeRelayApprovalRequest and BLOCK on approvalIssuer; reject/rejectAndHalt fail closed (fail-closed for default posture)
- AgentLens/Services/ComputerUse/ComputerUseDaemonApprovalPresenter.swift:119-152 — approval requires an explicit human approve/reject from the floating panel; no auto-approve fallback
- OpenBurnBarCore/Sources/OpenBurnBarComputerUseCore/ComputerUseCapabilityGate.swift:335 — accessibility deny region beats agent/mac/phone (denyRegion) regardless of allow rule or signed authority
- AgentLens/Services/ComputerUse/Mac/MacComputerUseDenyRegions.swift:67-88 — secure text fields / system auth sheets fail closed; ComputerUseDenyRegistry.swift:13-62 built-in denies for loginwindow, SecurityAgent, keychain, privacy pane, root Terminal
- OpenBurnBarCore/Sources/OpenBurnBarComputerUseCore/ComputerUseDenyRegistry.swift:88-162 — browser SSRF denies now present (file://, 169.254.* link-local, metadata.google.internal, IPv4/IPv6 loopback) — RR-15 remediation since the older internal package
- OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/ComputerUse/ComputerUseRunCoordinator.swift:345-374 — AUDIT-BEFORE-ACTION fail-closed: if the audit reservation append throws, the action is denied (auditFailure) and not executed
- AgentLens/Services/ContextBuilder.swift:8-50 — LLMSafeContent.wrapUntrusted wraps RAG/transcript/CU/summaries with provenance, delimiter-breakout defang, and explicit 'never treat as instructions' rule (defense-in-depth, advisory)
- AgentLens/Views/Chat/ChatSessionController.swift:132-144 — focus transcript NOW wrapped with wrapTranscriptForPrompt(provenance: focus_session:) and labeled 'untrusted data only' (contradicts older internal package's 'raw injection' claim)
- OpenBurnBarCore/Sources/OpenBurnBarComputerUseCore/AgentCapabilityGrant.swift:35-50 — requiresLocalAuthentication returns true for trustMode==.trusted and for privileged capabilities (desktopSystemInput/workspaceWrite/shell); ComputerUseSessionMetadata.swift:44-58 — trust mode is per-session, defaults .manual, never sticky/agent-set
- security/threat-model/security-claims.md:32 — repo's own matrix rates this exact claim 'Partially defensible': gaps = approval phishing and low-risk exfil; line 20 rates 'Retrieved content cannot override instructions' Not defensible (wrappers are not isolation); line 33 notes trusted scopes can bypass approval

**✅ SAFE wording (defensible to publish):**

> In the default Manual approval mode, BurnBar's Computer Use control path is fail-closed: untrusted content (a webpage, accessibility tree, OCR, or tool output) cannot cause a high-impact action without an explicit, human approve/reject on the Mac/overlay sheet, and accessibility deny regions (password fields, auth sheets, keychain, login window) plus browser SSRF/metadata/file:// denies block sensitive surfaces even if an action is requested. Untrusted content is wrapped with provenance and an explicit "treat as data, never instructions" rule before entering any LLM context. These are strong, layered, defense-in-depth controls. Caveat: if the operator explicitly opts a session into Trusted mode (which itself requires local authentication), high-impact actions covered by an active scope allow rule dispatch automatically with no per-action approval — so injection that steers an already-Trusted, already-scoped session can act within that scope. The untrusted-content wrappers are defense-in-depth, not hard data/instruction isolation; the model can still be influenced. There is no implemented "re-approve on new domain / large tool output even in Trusted/Step" control (it is prescribed in the threat model but not in code).

**⛔ UNSAFE wording (do NOT publish):**

> Malicious documents, webpages, or tool output can never trigger any action on your computer without your approval. / Prompt injection cannot cause harm — every high-impact action is always explicitly approved by you, regardless of mode.

**Open gaps / what would raise confidence:**
- Trusted mode: no code carve-out forces high-impact action CLASSES (typing, shortcuts, file export) to re-approve once a scope allow rule matches — needs a deployed-config / per-user policy review to know how broad real allow rules are in practice
- The threat-model-prescribed control 'High-impact tool results require explicit re-approval even in Step/Trusted on new domains or >N chars' (docs/security/LLM_GENAI_AGENT_THREAT_MODEL.md:280) appears UNIMPLEMENTED — no newDomain/reapprove logic found in Swift/TS
- Could not fully trace whether Computer-Use tool RESULTS (browser extract / AX tree / OCR) are wrapped via LLMSafeContent at the exact point they re-enter the external agent CLI/Hermes prompt (call sites found for RAG/summarize/focus/gateway, not clearly for CU result return) — display-mangling of symbol names in this environment limited grep confirmation; needs a clean read of the agent tool-broker return path
- Approval-phishing: the approval sheet shows attacker-influenced action summaries (action.executableSummary) and a before-screenshot; a convincing benign-looking summary could induce a user to approve a malicious action — UX-level, not code-level, risk
- Scope rule provenance: confirmed agent cannot set trust mode, but did not exhaustively prove the agent cannot author/broaden user scope allow rules through any callable or grant path
- Whether wrapper effectiveness is validated against current models — PromptInjectionHardeningTests exist but wrappers are advisory and not a guarantee

---

### C7 — High-risk grants need single-use local-auth bound to op hash
**Claim as tested:** C7: "High-risk agent grants (shell/workspace_write/desktop_system_input/shell_unrestricted) require a single-use local-auth proof bound to the exact canonical operation hash.
**Status:** 🟡 Partially defensible  **Confidence:** Medium  **Category:** Agentic AI

**Refutation attempt (what the verifier tried to break, and what held / broke):**

> I traced both the cloud queued lane and the on-device (Mac) authority validator, then tried to find a high-risk grant that reaches a privileged sink WITHOUT a single-use proof bound to the canonical hash.
>
> WHAT HOLDS (claim is substantially correct on the legacy/ed25519 path):
> - Cloud queued lane: queuedAgentGrantRequiresLocalAuthProof (functions/src/callables/computerUseSecurity.ts:911-922) returns true for shell, workspace_write, desktop_system_input, shell_unrestricted (and any desktop_*). It is computed independently of deliveryMode (line 2105) and enforced at 2141 (localAuthenticationSatisfied must be true) and 2151 (proof must be present) — there is no fail-open or delivery-mode bypass of the proof requirement in this function. "live" only skips Mac *approval* (2111-2113), not the proof.
> - Binding to canonical hash: the proof's signedIntentHash must equal observedIntentHashHex = sha256 of the canonicalized grant request (agentGrantRequestHashHex, lines 435-437; check at 2193-2196 and 2221-2227 verifyAgentGrantLocalAuthProof "wrong_intent" at 976). The proof signature itself covers proofId/deviceId/signedIntentHash/authenticatedAt/expiresAt (agentGrantLocalAuthProofSignablePayload, 455-468). So the proof IS cryptographically bound to the exact canonical grant-request hash.
> - Single-use: enforced by a Firestore transaction creating users/{uid}/local_auth_proofs/{proofId}; pre-existing proofSnapshot ⇒ "local_auth_proof_replay" (2269-2291). On the Mac side the consumed-proof set + persistent store enforce single-use across restarts (PhoneControlAuthorityValidator.swift:540-547), plus a monotonic envelope counter (448-451, 467).
> - Validator is fail-closed: replayStoreHealthy gate denies everything if the replay baseline is unreadable (304-314), and a single signature chokepoint with key-kind pinning (363-369).
>
> WHERE THE CLAIM BREAKS / NEEDS A CAVEAT:
> 1) SE-P256 EXEMPTION (the real gap). On the Mac authority validator, validateLocalAuthProofIfNeeded sets requiresProof = false when the controller key is a biometry-gated Secure-Enclave key (PhoneControlAuthorityValidator.swift:493-503; policy in PhoneControlStepUpPolicy.swift:68-87 stepUpEvidence -> .enforcedBySecureEnclaveSignature). For SE-P256 controllers a high-risk grant (incl. shell/shell_unrestricted/desktop_system_input/workspace_write) is accepted with NO explicit single-use local-auth proof — the SE signature is treated as the user-presence proof, and replay is covered only by the monotonic counter, not a per-operation single-use proof. So "require a single-use local-auth proof" is literally false for the SE-P256 custody class. Note a cloud/Mac DIVERGENCE: the cloud queued function (911-922) has NO SE exemption and still demands the explicit proof, but the on-device validator (the actual gate for live-relay actions via PhoneControlReceiver/SystemPermissionReceiver/AgentContextTargetReceiver/ComputerUseSessionCoordinator) does exempt SE keys.
> 2) GRANT-LEVEL, NOT PER-ACTION. The proof binds to the canonical GRANT-REQUEST hash (capabilities/preset/runtime/thread/device/timing), i.e. the operation = "issue this capability grant." It is NOT a per-keystroke/per-shell-command operation hash. The grant then authorizes many subsequent actions for its duration. So "exact canonical operation hash" is accurate for the grant operation but should not be read as per-action.
> 3) workspace_write is in requiresLocalAuthentication (AgentCapabilityGrant.swift:40-49) so it DOES require the explicit proof under ed25519 — but it is NOT in biometricStepUpRequired (PhoneControlStepUpPolicy.swift:9-13), so even on a software key there is no per-action biometric step-up for workspace_write; the proof is one-time at grant issuance.
>
> No outright contradiction found (no fail-open, no legacy backfill skipping the proof, no auth-before-authz hole on the ed25519 path), but the SE-P256 exemption and grant-vs-action scope make the claim Partial, not Defensible.

**Evidence (file:line):**
- functions/src/callables/computerUseSecurity.ts:911-922 queuedAgentGrantRequiresLocalAuthProof — requires proof for shell/workspace_write/desktop_system_input/shell_unrestricted/desktop_* (cloud, no SE exemption)
- functions/src/callables/computerUseSecurity.ts:2105,2141,2151 — proof requirement enforced independent of deliveryMode; rejects when localAuthenticationSatisfied!=true or proof missing
- functions/src/callables/computerUseSecurity.ts:2111-2113 queuedAgentGrantDeliveryRequiresMacApproval — 'live' skips Mac approval only, not the proof
- functions/src/callables/computerUseSecurity.ts:435-437 agentGrantRequestHashHex + 414-433 canonicalAgentGrantRequestJSON — canonical sha256 of grant request
- functions/src/callables/computerUseSecurity.ts:2193-2196 — observedIntentHashHex must equal authority.intentHashBlake3
- functions/src/callables/computerUseSecurity.ts:963-995 verifyAgentGrantLocalAuthProof — wrong_device/wrong_intent/expired/future/too_long/bad_signature checks; signedIntentHash must match observed (976)
- functions/src/callables/computerUseSecurity.ts:455-468 agentGrantLocalAuthProofSignablePayload — signature binds proofId/deviceId/signedIntentHash/authenticatedAt/expiresAt
- functions/src/callables/computerUseSecurity.ts:2268-2291 — single-use enforced via Firestore proofRef create; existing proof ⇒ local_auth_proof_replay
- AgentLens/Services/ComputerUse/PhoneControlAuthorityValidator.swift:493-503 — requiresProof=false for SE-P256 (enforcedBySecureEnclaveSignature); explicit proof skipped
- AgentLens/Services/ComputerUse/PhoneControlAuthorityValidator.swift:510-547 — proof device/intent/freshness/signature checks + single-use consumedLocalAuthProofIds + persistent store; 312-314 fail-closed replayStoreHealthy
- OpenBurnBarCore/Sources/OpenBurnBarComputerUseCore/PhoneControlStepUpPolicy.swift:9-13,68-87 — biometricStepUpRequired={desktopSystemInput,shell,shellUnrestricted} (no workspace_write); SE key ⇒ no explicit proof
- OpenBurnBarCore/Sources/OpenBurnBarComputerUseCore/AgentCapabilityGrant.swift:40-50 requiresLocalAuthentication privileged set includes workspaceWrite/shell/shellUnrestricted/desktopSystemInput (ed25519 path)

**✅ SAFE wording (defensible to publish):**

> For legacy software-key (ed25519) controllers, high-risk agent grants (shell, workspace_write, desktop_system_input, shell_unrestricted) require a single-use local-auth proof whose signature is cryptographically bound to the canonical hash of the grant request, with replay prevented at both the cloud (Firestore transaction) and the Mac validator (consumed-proof set plus monotonic counter). For biometry-gated Secure-Enclave (SE-P256) controllers, the explicit proof is intentionally replaced on-device by the Secure-Enclave biometric signature itself, with replay covered by the monotonic envelope counter rather than a single-use proof. The proof binds the grant-issuance operation, not each subsequent executed action.

**⛔ UNSAFE wording (do NOT publish):**

> Every high-risk agent grant always requires a fresh single-use biometric local-auth proof bound to the exact operation, so no privileged action can ever run without a one-time per-operation proof.

**Open gaps / what would raise confidence:**
- UNKNOWN: is SE-P256 (secureEnclaveP256) custody actually used in production for phone controllers, or are deployed controllers still ed25519? If SE-P256 is live, a large class of high-risk grants ship with NO explicit single-use proof. Needs deployed device-registration data (signingKeyKind on users/{uid}/agent_grant_authorities/* and escrow device records).
- Cloud-vs-Mac divergence on SE exemption: cloud queued function always demands the proof while the Mac validator exempts SE — confirm whether the live-relay lane ever bypasses the cloud function entirely so an SE grant could be applied with no proof at any layer (live-relay receivers call only the on-device validator).
- Claim wording 'operation hash' vs actual 'grant-request hash' — confirm intended granularity with the threat model; the proof is one-time at grant issuance, not per executed action.
- Confirm no separate non-queued/legacy callable issues high-risk grants without going through queuedAgentGrantRequiresLocalAuthProof or the Mac validator (broader grant-issuance surface not fully enumerated here).

---

### C8 — Only pinned paired devices exchange Gateway msgs
**Claim as tested:** C8: "Only paired devices with pinned keys can exchange Gateway messages; a compromised relay cannot impersonate a paired device.
**Status:** 🟡 Partially defensible  **Confidence:** Medium  **Category:** Authentication/Authorization

**Refutation attempt (what the verifier tried to break, and what held / broke):**

> I traced the relay-receive path on the agent/host side. The recipient opener (HermesRelayAuthenticatedRequest.swift:187-275) fails closed unless the inbound is a v3 HPKE-Auth envelope whose sender public key BYTE-MATCHES a pinned key (line 224-227, senderKeyUntrusted otherwise), then HPKE-Auth-decrypts with AAD binding uid/connectionID/requestID/operation/counter/keyID (line 230-246) and enforces a monotonic-counter + unique-requestID replay cache (line 248-253). There is NO v1/v2/plaintext fallback: the opener rejects anything not relayKeyVersion v3 with senderAuthRequired (line 195-208). All three production host receive paths (HermesRealtimeRelayHostClient.swift:208, CloudSync/HermesRelayHostService.swift:669, IrohRelay/IrohRelayRequestHandler.swift:303) route through this opener with no bypass. Because the relay process holds neither the recipient private key nor the pinned sender private key, it cannot forge a ciphertext the recipient accepts, nor replay one. The cloud HTTP gateway is independently gated: every request must carry an Ed25519 proof-of-possession over the pinned agentClientSigningPublicKeyBase64 (functions/src/callables/hermesGateway.ts:693-757); missing key / popRequired!=true fails closed (legacy_pop_required, line 697-698) and a v1 downgrade is refused once v2 is registered (line 705). The agent relay public key is pin-only: written solely on first pairing and a differing re-publish is DROPPED and audit-logged (hermesGateway.ts:1250-1262, reason agent_relay_public_key_immutable). Trust elevation to "trusted" requires a server-verified XEdDSA trust-chain signature and fails closed (computerUseSecurity.ts:1396-1423); firestore.rules forbids clients writing relay_sender_keys (allow ... : if false, line 2784) and changing escrow_devices.trustState on update (line 3465) and creating a trusted device (line 3450). So against the realtime/iroh relay PROCESS and against any malicious peer/client, impersonation is blocked. THE BREAK: the relay-receive trust anchor is resolved from Firestore — FirestoreHermesRelaySenderTrustResolver.swift:59-104 reads the pinned sender key from relay_sender_keys/{deviceID} and trusts escrow_devices/{deviceID}.trustState=="trusted" DIRECTLY, and does NOT invoke the device-side cryptographic chain verifier (CloudVaultTrustedDeviceChainVerifier.swift:151-199) that other subsystems use (CloudVaultKeyAccess, KnowledgeSyncService, SessionLogSyncService, ComputerUseSecurityCallableClient). relay_sender_keys is written by a Cloud Function via the admin SDK (computerUseSecurity.ts:1953), which bypasses firestore.rules. Therefore a fully COMPROMISED CLOUD/Firestore control plane (not the relay data-plane process, but the backend that can write with admin privileges) could forge a relay_sender_keys doc with an attacker-controlled public key and flip trustState, and the relay opener would accept attacker-sealed v3 messages as if from the paired device, because the local trust-chain re-verification that would catch this is not wired into the relay path.

**Evidence (file:line):**
- OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/HermesRelayAuthenticatedRequest.swift:195-208 — open() rejects any non-v3 / sender-unauthenticated payload with senderAuthRequired (no plaintext/v1/v2 fallback)
- OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/HermesRelayAuthenticatedRequest.swift:224-227 — samePublicKey check rejects with senderKeyUntrusted unless envelope sender key byte-matches the pinned key from the trust resolver
- OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/HermesRelayAuthenticatedRequest.swift:230-246 — openKeyV3 HPKE-Auth unwrap bound to pinnedSenderPublicKey + AAD (uid/connectionID/requestID/operation/counter/keyID); relay cannot forge without sender private key
- OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/HermesRelayAuthenticatedRequest.swift:248-253 + 91-141 — HermesRelayReplayCache.recordFresh enforces monotonic counter + unique requestID (senderReplay), blocking relay replay
- AgentLens/Services/HermesRealtimeRelayHostClient.swift:208 / AgentLens/Services/CloudSync/HermesRelayHostService.swift:669 / AgentLens/Services/IrohRelay/IrohRelayRequestHandler.swift:303 — all production receive paths route through authenticatedRequestOpener.open with no bypass
- AgentLens/Services/HermesRelaySenderTrustResolver.swift:59-104 — pinned sender key + trust resolved from Firestore relay_sender_keys/{deviceID} and escrow_devices.trustState=='trusted' DIRECTLY; no call to CloudVaultTrustedDeviceChainVerifier (cloud-writable trust anchor)
- AgentLens/Services/CloudVaultTrustedDeviceChainVerifier.swift:151-199 — device-side XEdDSA chain verification to local identity exists but is used only by CloudVault/sync/computer-use paths, NOT the Hermes relay receive path
- firestore.rules:2782-2784 — relay_sender_keys: allow create,update,delete: if false (clients cannot write it; only admin-SDK Cloud Functions can)
- functions/src/callables/computerUseSecurity.ts:1936-1972 — publishRelaySenderKey requires a pre-trusted escrow device + published Signal identity, then admin-SDK writes relay_sender_keys (so a compromised backend with admin creds could write directly, bypassing these checks and rules)
- functions/src/callables/computerUseSecurity.ts:1396-1423 — approveEscrowDeviceTrust verifies XEdDSA trust-chain signature server-side, fails closed; firestore.rules:3450 & 3465 forbid clients creating/elevating trustState=='trusted'
- functions/src/callables/hermesGateway.ts:693-757 — verifyGatewayRequestPoP: Ed25519 PoP over pinned agentClientSigningPublicKeyBase64, fails closed (legacy_pop_required at 697-698), refuses v1 downgrade once v2 registered (705), nonce replay guard (758-762)
- functions/src/callables/hermesGateway.ts:1250-1262 + 1318-1322 — agent relay public key is pin-only (first-pairing write); a differing re-publish is dropped and audit-logged (agent_relay_public_key_immutable)

**✅ SAFE wording (defensible to publish):**

> Paired devices authenticate Gateway messages with pinned per-device keys: the agent only accepts inbound relay requests sealed in HPKE-Auth (v3) mode by a sender public key that byte-matches the pinned key, with replay protection, and every cloud-gateway HTTP request is signed (proof-of-possession) by the pinned client key. A relay or peer that merely relays traffic — holding no device private key — cannot forge or replay a message that a paired device will accept. Trust is established through a cryptographically verified device trust chain. Note: the relay-receive path resolves the pinned key and device-trust flag from the cloud datastore and does not locally re-verify the trust-chain signature, so this protection assumes the cloud control plane that writes those trust records is not itself compromised.

**⛔ UNSAFE wording (do NOT publish):**

> A compromised relay or compromised cloud can never impersonate a paired device; only paired devices with pinned keys can ever exchange Gateway messages, end to end, with no trust placed in the server. (Unsafe: the on-device relay trust resolver trusts cloud-written relay_sender_keys and escrow trustState without local trust-chain re-verification, so a compromised admin-SDK backend could forge the pinned-key record and impersonate a paired device.)

**Open gaps / what would raise confidence:**
- UNKNOWN: deployed IAM on the Firestore/Cloud-Functions project — whether the relay data-plane (hermes-realtime-relay Cloud Run) service account has admin-SDK write access to users/*/relay_sender_keys and escrow_devices. If it does NOT (only the security callables' SA does), the 'compromised relay' (data-plane) genuinely cannot impersonate and the claim strengthens toward Defensible; if relay and control-plane share creds, the break is reachable.
- Whether the bootstrap/first-device trust root is anchored by an out-of-band user fingerprint comparison (QR/safety-code) at pairing time, which would let an attentive user detect a cloud-forged trust chain; the on-device EscrowDeviceSafetyCode exists but its enforcement at relay pairing was not traced here.
- Whether any roadmap step wires CloudVaultTrustedDeviceChainVerifier (or equivalent local XEdDSA chain check) into FirestoreHermesRelaySenderTrustResolver so the relay path stops trusting the cloud's trustState flag.
- Runtime confirmation that no legacy v1/v2 relay envelopes are still produced by any shipping client and accepted on a path other than the v3-only opener (the cloud constants still list SUPPORTED versions {1,2,3}).

---

### C9 — Iroh pairing records cannot be spoofed/replayed
**Claim as tested:** C9: "Iroh pairing records cannot be spoofed or replayed by another user or a malicious relay.
**Status:** 🟡 Partially defensible  **Confidence:** Medium  **Category:** Integrity/Authenticity

**Refutation attempt (what the verifier tried to break, and what held / broke):**

> I tried to forge/replay a pairing record and to substitute the trust root, following the verify-before-dial path end to end.
>
> 1) Cross-tenant spoof (another user): The signed canonical payload binds the uid — OpenBurnBarCore/Sources/OpenBurnBarIrohRelay/IrohRelayPairing.swift:95-98 (canonicalPayload includes uid|connectionId|nodeId|relayURL|directAddresses|publishedAtMs). Records live under users/{uid}/iroh_pairing/{connectionId} and the host trust-root key under users/{uid}/iroh_pairing_keys/host; firestore.rules:2659-2678 sets `allow create,update,delete: if false` for BOTH, so clients cannot write either directly. Reads are gated by ownsUserNamespace. Cross-tenant spoof FAILS.
>
> 2) Malicious relay: The iroh/Hermes relay never holds the Ed25519 signing key (Mac signs locally; directory only stores — IrohPairingDirectory.swift:56-85). iOS dials only the SIGNED NodeId after fetchAndVerify succeeds; on any verify failure it throws relayUnavailable and does NOT dial (HermesIrohRelayTransport.swift:383-409, fail-closed). The public key is read with getDocument(source: .server) (FirestoreIrohPairingPublicKeyProvider.swift:36), so a relay cannot feed a cached/swapped key. A relay cannot forge the signature or substitute its own NodeId. Relay spoof FAILS for an established pairing.
>
> 3) Where it is NOT fully guaranteed (caveats that make the absolute claim overclaim):
>  a) TOFU / unattested platform: registerEscrowDevice takes platform from request.data.platform (computerUseSecurity.ts:1132,1154) with no cryptographic proof the device is a Mac. publishIrohPairingPublicKey / publishIrohPairingRecord only require requireTrustedEscrowDevice(uid,deviceId,{"macOS"}) (computerUseSecurity.ts:1690,1741; check at 196-201 reads the self-declared platform field). The first trusted device is established by bootstrap self-approval (computerUseSecurity.ts:1315) with no second device to gate it. So whoever wins first-pairing becomes the trust root — classic TOFU; a non-Mac/attacker-controlled session at bootstrap can become the macOS root.
>  b) Replay window: verify() only enforces publishedAtMillis age <= 3 min (IrohRelayPairing.swift:69-75,163-167) against the LOCAL device clock; there is no per-dial challenge/nonce or monotonic counter in the record. A still-fresh record is honored for up to 3 minutes; revocation is a Firestore delete() (computerUseSecurity.ts:1799) with no signed/monotonic revocation, so a deleted-but-cached or 3-min-stale record could be honored. Namespace isolation means only a trusted device can re-serve it, so this is a window, not an open replay.
>  c) Server is in the TCB: the Admin SDK (Cloud Functions) is the sole writer of both the host trust-root key and the records; the server does NOT verify the Ed25519 signature on publish (publishIrohPairingRecord stores the client-supplied signature verbatim, computerUseSecurity.ts:1755-1772). A compromised server/insider with Admin SDK can replace iroh_pairing_keys/host and forge records; iOS would TOFU-trust whatever host key the server serves on first fetch. The scheme does not protect against the server substituting the trust root.
>  d) Replay defense on the publish callables is config-gated: enforceHighRiskComputerUseCallableWithNonce fail-opens when requireHighRiskNonce is off and no nonce is supplied (appCheckAttestation.ts:240-250). config.ts:92-95 defaults this ON in prod and refuses to boot prod without App Check (config.ts:78-84), and the bootstrap self-approval branch hard-requires a nonce (computerUseSecurity.ts:1334-1344) — but actual prod values (ENFORCE_APP_CHECK, REQUIRE_HIGH_RISK_NONCE) are deployed config I cannot confirm from code.

**Evidence (file:line):**
- OpenBurnBarCore/Sources/OpenBurnBarIrohRelay/IrohRelayPairing.swift:95-98 — canonicalPayload binds uid|connectionId|nodeId|relayURL|directAddresses|publishedAtMs (anti cross-tenant / anti relay substitution)
- OpenBurnBarCore/Sources/OpenBurnBarIrohRelay/IrohRelayPairing.swift:133-168 — verify(): protocolVersion check, Ed25519 isValidSignature, then age <= maximumAge; no per-dial nonce / monotonic counter
- OpenBurnBarCore/Sources/OpenBurnBarIrohRelay/IrohRelayPairing.swift:69-75 — IrohPairingFreshness.maximumAgeSeconds = 3*60 (replay window vs local clock)
- firestore.rules:2659-2678 — iroh_pairing_keys/{roleId} and iroh_pairing/{connectionId}: allow read if ownsUserNamespace; create/update/delete: if false (server-owned trust roots)
- functions/src/callables/computerUseSecurity.ts:1690-1704 — publishIrohPairingPublicKey requires requireTrustedEscrowDevice(uid,deviceId,MAC_ESCROW_PLATFORMS) then Admin-writes host key (server does not attest hardware)
- functions/src/callables/computerUseSecurity.ts:1741-1772 — publishIrohPairingRecord stores client-supplied signature verbatim; server never verifies the Ed25519 signature on publish
- functions/src/callables/computerUseSecurity.ts:191-201 — requireTrustedEscrowDevice reads self-declared device.platform; trust = trustState 'trusted' + platform in {macOS}
- functions/src/callables/computerUseSecurity.ts:1132,1154 — registerEscrowDevice: platform = parseEscrowPlatform(request.data.platform), written as 'pending' (client self-declares platform; no Mac attestation)
- functions/src/callables/computerUseSecurity.ts:1315,1334-1344 — bootstrap self-approval (first trusted device, no second gate) hard-requires a fresh single-use nonce when App Check enforced (TOFU root)
- functions/src/appCheckAttestation.ts:234-252 — enforceHighRiskComputerUseCallableWithNonce fail-opens when requireHighRiskNonce off and no nonce supplied; consumeHighRiskNonceForUid (179-207) is atomic single-use, 2-min TTL
- functions/src/config.ts:68-95 — prod refuses to boot without App Check; requireHighRiskNonce defaults ON in prod (overrides stale comment at computerUseSecurity.ts:1329)
- OpenBurnBarMobile/Services/IrohRelay/HermesIrohRelayTransport.swift:383-409 + FirestoreIrohPairingPublicKeyProvider.swift:36 — fetchAndVerify gates dial, throws relayUnavailable on failure (fail-closed); public key fetched source:.server (no stale-cache swap)

**✅ SAFE wording (defensible to publish):**

> For an already-established pairing, iroh pairing records are signed (Ed25519) and bound to your account (uid) and the host's NodeId, and your phone verifies the signature against the Mac's published key and rejects records older than ~3 minutes before dialing — so another BurnBar user cannot inject a record into your account and a malicious relay cannot forge or substitute one (verification fails closed; no unverified dial). Trust is rooted on first pairing (TOFU): whichever device first becomes your trusted macOS escrow device defines the signing key, and the cloud (which writes the trust-root key and records and does not itself check the signature) is inside the trust boundary, so a compromised account-at-bootstrap, or a compromised server, could establish or replace that root. A captured-but-still-fresh record could also be honored within the ~3-minute freshness window.

**⛔ UNSAFE wording (do NOT publish):**

> Iroh pairing records can never be spoofed or replayed by anyone — the cryptographic signature makes it impossible for any user, relay, or even the server to impersonate your Mac.

**Open gaps / what would raise confidence:**
- Deployed Remote Config / env not visible: actual prod values of ENFORCE_APP_CHECK and REQUIRE_HIGH_RISK_NONCE (code defaults fail-closed in prod, but runtime config would confirm replay defense on the publish callables is active)
- No cryptographic device-platform attestation: cannot confirm from code whether anything outside this scope (DeviceCheck/App Attest/MDM) proves an escrow device is genuinely a Mac before it becomes the macOS trust root
- First-pairing/TOFU UX: whether the user is shown a safety-number / key-fingerprint comparison at first host-key fetch (EscrowDeviceTrustSafetyCheckFlag is referenced as staged) — would harden TOFU but not verified end-to-end here
- Revocation propagation: no signed/monotonic revocation in the record; need to confirm clients re-fetch and that a deleted record cannot be replayed from cache within the 3-min freshness window
- Server/insider trust: the Admin SDK can rewrite host key + records; out-of-band integrity (e.g., transparency log, client pinning) for the trust root is not present in the reviewed code

---

### C10 — Provider creds not in Firestore plaintext (KMS)
**Claim as tested:** C10: "Provider API credentials are NOT stored in Firestore plaintext; they live in Secret Manager with KMS-wrapped DEKs.
**Status:** ✅ Defensible  **Confidence:** High  **Category:** Confidentiality

**Refutation attempt (what the verifier tried to break, and what held / broke):**

> I traced every credential-ingest path and tried to find a place where plaintext reaches Firestore or where Secret Manager/KMS is bypassed.
>
> 1) Storage path: All connect callables (connectProviderAccount, connectProviderCredential [legacy], connectHostedQuotaAccount) funnel into connectProviderAccountInternal/storeCredential. The plaintext never lands in a Firestore field — only the Secret Manager version name does. functions/src/callables/shared.ts:1537 calls storeCredential(); :1538 writePrivateSecretRef() writes ONLY {uid, providerID, accountID, secretVersionName, createdAt, updatedAt} (type at functions/src/types/legacy.ts:155-162). The accountDoc written to provider_accounts (shared.ts:1547-1571) carries redactedLabel/credentialKind but NO credential field.
>
> 2) Envelope + KMS: storeCredential -> encryptEnvelope (functions/src/secrets.ts:98-122) generates a 256-bit DEK, AES-256-GCM-encrypts the plaintext, then KMS-encrypts the DEK (secrets.ts:111-119), packs [encDEK|iv|ct|tag] and writes it as a Secret Manager version (secrets.ts:216-223). Firestore only ever stores the version resource name.
>
> 3) Fail-closed check: encryptEnvelope/decryptEnvelope throw if kmsKeyName is unset (secrets.ts:100-102, 131-133) — no plaintext-passthrough fallback. I found NO fail-open that writes raw credential to Firestore when KMS is unavailable.
>
> 4) Defense-in-depth in rules: provider_account_secret_refs is server-only (firestore.rules:1086-1088, allow read,write: if false). provider_accounts create/update requires ownerWritableNonSecret (which calls hasNoPlaintextSecretFields, firestore.rules:56-68/71-75) AND a hasOnly allowlist with no credential field (firestore.rules:2455-2479, 2525-2526). hasNoPlaintextSecretFields explicitly rejects apiKey/token/secret/credential/secretVersionName/etc.
>
> 5) Cross-device transfer hole? credential_transfers stores a "payload" string constrained to a v1.x.x.x ciphertext regex (firestore.rules:1115-1117) and is documented as "end-to-end opaque to the server" (functions/src/callables/credentialTransfer.ts:4); client get is denied (rules:1129). No plaintext stored there.
>
> 6) I grepped for any Firestore .set/.update with a credential field across functions/src — none found. I found no backfill that writes plaintext.
>
> REMAINING CAVEATS (do not break the narrow claim but bound it): (a) The server CAN reconstruct plaintext: retrieveCredential (secrets.ts:238-250) -> KMS decrypt -> AES decrypt, used during quota refresh (functions/src/quota.ts:94, 127, 133) where plaintext is passed to adapter.fetchQuota/testCredential. The Cloud Function ADC has cloudkms + cloud-platform scopes (secrets.ts:39). So this is server-side envelope encryption, NOT E2E — a malicious/compromised server or anyone with KMS-decrypt + Secret-Manager-access IAM sees plaintext. (b) The macOS daemon necessarily holds provider credentials in plaintext locally (TECH_DEBT_AUDIT_2026-06-11.md notes a "plaintext vault fallback"; OpenBurnBarConfigStoreTests.swift asserts legacy local plaintext vaults are scrubbed). That is device-local, not Firestore, so out of scope for C10 but means "credentials are never in plaintext" would be false.

**Evidence (file:line):**
- functions/src/secrets.ts:98-122 encryptEnvelope() — local 256-bit DEK, AES-256-GCM over plaintext, then KMS-encrypts the DEK; packEnvelope stores [encDEK|iv|ct|tag]
- functions/src/secrets.ts:100-102 & 131-133 — encrypt/decrypt throw if kmsKeyName unconfigured (fail-closed; no plaintext fallback)
- functions/src/secrets.ts:216-223 storeCredential() — writes the envelope as a Secret Manager addVersion payload; returns version resource name only
- functions/src/callables/shared.ts:1537-1545 connectProviderAccountInternal — storeCredential() then writePrivateSecretRef() with only the secretVersionName
- functions/src/callables/shared.ts:1466-1483 writePrivateSecretRef() — Firestore doc contains uid/providerID/accountID/secretVersionName/timestamps, no credential
- functions/src/types/legacy.ts:155-162 ProviderAccountSecretRefDoc — schema has secretVersionName, no plaintext field
- functions/src/callables/providerAccounts.ts:204-205 (connectHostedQuotaAccount) — same storeCredential + writePrivateSecretRef pattern; redactedLabel = 'credential stored in Secret Manager'
- functions/src/callables/shared.ts:685-697 connectionDocFromAccount() — legacy provider_connections doc carries only redactedLabel/credentialKind, no credential
- firestore.rules:1086-1088 — provider_account_secret_refs allow read,write: if false (Admin-SDK only)
- firestore.rules:56-68 hasNoPlaintextSecretFields() rejects apiKey/token/secret/credential/secretVersionName/etc.; enforced on provider_accounts via rules:2525-2526 + hasOnly allowlist rules:2455-2479
- firestore.rules:1092-1131 credential_transfers — payload constrained to v1.x.x.x ciphertext regex, client get denied; credentialTransfer.ts:4 'end-to-end opaque to the server'
- functions/src/secrets.ts:238-250 retrieveCredential() + quota.ts:94,127,133 — server DOES reconstruct plaintext in memory for quota/validation (envelope, not E2E); ADC scopes cloudkms+cloud-platform at secrets.ts:39

**✅ SAFE wording (defensible to publish):**

> Provider API credentials submitted to the backend are not written to Firestore in plaintext. On every connect path the Cloud Function envelope-encrypts the credential (AES-256-GCM under a per-credential DEK, with the DEK wrapped by Cloud KMS) and stores the resulting blob as a Cloud Secret Manager version; Firestore retains only the Secret Manager version name (in a server-only, rules-locked collection) plus non-secret metadata such as a redacted label and credential kind. Firestore security rules additionally reject any client document containing common secret field names. Note this is server-side envelope encryption, not end-to-end: the backend (and anyone holding KMS-decrypt + Secret-Manager-access IAM) can reconstruct the plaintext in memory when refreshing quota, and the local macOS daemon necessarily handles provider credentials in plaintext on the user's own machine.

**⛔ UNSAFE wording (do NOT publish):**

> Your provider credentials are never stored or seen in plaintext — they are end-to-end encrypted and even we (the server/cloud) cannot read them. (FALSE: the Cloud Function decrypts via KMS to reconstruct plaintext for quota refresh, so the server can read them; and the local Mac daemon holds them in plaintext. The protection is at-rest envelope encryption against Firestore exposure, not E2E secrecy from the operator.)

**Open gaps / what would raise confidence:**
- Deployed IAM unverified: who/what service accounts hold roles/cloudkms.cryptoKeyDecrypter on the KMS key and secretmanager.secretAccessor on these secrets is not in code; the server's ability to decrypt is by design but blast radius depends on live IAM bindings (UNKNOWN without GCP config).
- KMS key configuration (rotation, key ring, protection level/HSM) and whether KMS_KEY_NAME is actually set in the deployed env are runtime config, not provable from code.
- Historical/legacy data not audited: cannot prove from current code that no plaintext credential was ever written to Firestore by an older deployment before this Secret Manager design; would need a Firestore data scan to confirm no residual plaintext docs exist.
- macOS daemon local plaintext handling (config store / SQLite, 'plaintext vault fallback' per TECH_DEBT_AUDIT_2026-06-11.md) is device-local and out of C10's Firestore scope but is the place plaintext genuinely lives; its scrubbing/keychain migration correctness was not deep-verified here.
- Secret Manager IDs embed the raw uid and provider (secrets.ts:163-169); not a plaintext-credential leak, but metadata about which providers a user connected is visible to anyone with Secret Manager list access.

---

### C11 — Object-level authz: no cross-user access
**Claim as tested:** C11: Object-level authorization holds: one user cannot reach another user's data — messages, devices, attachments, pairings, agent runs.
**Status:** 🟡 Partially defensible  **Confidence:** Medium  **Category:** Authentication/Authorization

**Refutation attempt (what the verifier tried to break, and what held / broke):**

> I tried to find a cross-user reach across both enforcement layers (Firestore/Storage rules and Cloud Functions Admin SDK) and could not break the core claim, but found bounded caveats.
>
> (1) Rules-layer sweep: `rg "allow (read|get|list)" firestore.rules` minus owner-gated lines returns ZERO ungated reads — every read allow is gated by `ownsUserNamespace(userId)` (firestore.rules:52-54, `request.auth.uid == userId`), `if false`, `isOperator()`, `sharedArtifactOwnerRead()` (1067-1071, checks `resource.data.ownerUserID == request.auth.uid`), or `isSignedIn()` for only 4 PUBLIC non-user docs (1138/1143 model benchmarks, 3065/4208 budget envelopes). No `if true`, no recursive default-allow `{document=**}` over user data, no auth-before-authz gap in rules.
>
> (2) Per-category spot checks all owner-scoped: conversations (1279), mobile_assistant_chats (1334), chat_threads (1286), devices (2369), media_attachment_manifests (3127), computer_use_sessions/actions (2995/3022), hermes_relay_requests + chunks (2559/2564), iroh_pairing controllers (2770), escrow_devices, relay_sender_keys (2783) — all `allow read: if ownsUserNamespace(userId)`.
>
> (3) Callable IDOR hunt: dominant pattern is `const uid = request.auth?.uid` (server-derived, not client data). `assertOwnership` (auth.ts:22-31) throws permission-denied on `uid !== expectedUid`. The few client-supplied uid params are all re-checked: computerUseOpenTimestamps.ts:465 passes `parsed.uid` into enforceHighRiskComputerUseCallable -> assertOwnership (appCheckAttestation.ts:142); credentialTransfer.ts:58 `data.ownerUid !== uid` reject; quota.ts:91 `data.uid !== uid` reject.
>
> (4) Cross-tenant relay (the real risk surface): hermesGateway resolveGatewayGrant (hermesGateway.ts:810-865) derives uid ONLY from the server-side SHA-256 token index, then re-validates client status/tokenHash/expiry/PoP/scope/entitlement; the message-send sink writes to `users/${grant.uid}/...` (1118-1162), never a client-supplied destination uid. The device-poll HTTP endpoint reads uid from the server-written session doc after a deviceSecretHash proof (hermesGateway.ts:999,1011), not from the attacker.
>
> (5) Signal prekey directory (a deliberately cross-readable surface) is actually clamped to same-user multi-device: signalPrekeyDirectory.ts:293 rejects `peerUid !== ownerUid`.
>
> Residual breaks found: Storage avatars are cross-user readable (storage.rules:18 `allow read: if request.auth != null` on `avatars/{userId}/profile.jpg`) — any authenticated user can read any user's profile JPEG. Also, object authz at the rules layer is real regardless of App Check, but the rules header (firestore.rules:20-23) notes App Check is NOT enforced by rules and must be enabled in console.

**Evidence (file:line):**
- firestore.rules:52-54 ownsUserNamespace(userId): isSignedIn() && request.auth.uid == userId — the universal owner gate used by every user-data read
- firestore.rules:1279 conversations / 1334 mobile_assistant_chats / 2369 devices / 3127 media_attachment_manifests / 2995 computer_use_sessions / 2559 hermes_relay_requests — all 'allow read: if ownsUserNamespace(userId)'
- firestore.rules:1067-1071 sharedArtifactOwnerRead(): workspace-keyed path still gated on resource.data.ownerUserID == request.auth.uid (no cross-user read despite shared path)
- functions/src/auth.ts:22-31 assertOwnership throws permission-denied when request.auth.uid !== expectedUid
- functions/src/appCheckAttestation.ts:139-144 enforceHighRiskComputerUseCallable -> assertOwnership, so computerUseOpenTimestamps client-supplied parsed.uid (computerUseOpenTimestamps.ts:465) must equal token uid
- functions/src/callables/hermesGateway.ts:810-864 resolveGatewayGrant binds uid via server-side token index + tokenHash/status/expiry/PoP/scope/entitlement re-checks; writes target grant.uid (1118,1147,1152)
- functions/src/callables/credentialTransfer.ts:58 rejects data.ownerUid !== uid; functions/src/quota.ts:91 rejects data.uid !== uid
- functions/src/callables/signalPrekeyDirectory.ts:292-296 same-user multi-device scope: peerUid must equal ownerUid
- firestore.rules read-allow sweep returns zero reads NOT gated by ownsUserNamespace/false/isOperator/isSignedIn/sharedArtifactOwnerRead; the 4 isSignedIn reads (1138,1143,3065,4208) are public non-user metadata only
- storage.rules:18 avatars/{userId}/profile.jpg 'allow read: if request.auth != null' — CROSS-USER readable profile photos (low sensitivity)
- firestore.rules:1086-1088 provider_account_secret_refs and 4226-4252 google_play_token_claims/cli_link_sessions/hermes_gateway_* root indexes all 'allow read,write: if false' (server-only)
- firestore-rules-tests/computer-use.test.js:189 + rr12-relay-and-root.test.js:143-201 assert cross-user/anonymous reads fail (object-isolation regression coverage)

**✅ SAFE wording (defensible to publish):**

> At the Firestore-rules layer, every private user-data collection (messages, devices, attachments, pairings, agent runs) is read-gated to the owning account (request.auth.uid == path userId), with no fail-open or default-allow; Cloud Functions consistently derive the user from the authenticated token and re-check ownership before Admin-SDK access, and the cross-device relay binds each token to a single account. Object-level isolation of private data is well-enforced. Known exceptions: profile-photo JPEGs are readable by any signed-in user, certain public/operator metadata is shared by design, and full assurance assumes App Check is enabled in the console and that the (Admin-SDK) Cloud Functions not exhaustively re-audited contain no IDOR.

**⛔ UNSAFE wording (do NOT publish):**

> No user can ever access any of another user's data — total cross-user isolation is cryptographically guaranteed end-to-end across all collections and all endpoints.

**Open gaps / what would raise confidence:**
- Cloud Functions run with Admin SDK which bypasses all Firestore rules; I verified the main cross-tenant surfaces (hermes gateway, signal directory, computer-use, credential transfer, the auth/ownership helpers) but did not line-by-line audit all ~40 callable files, so an IDOR in an unread callable cannot be fully excluded
- App Check enforcement is a deployed-console setting, not in code (firestore.rules:20-23); object authz holds regardless, but non-app clients reaching the ruleset is a deployed-config question
- isOperator() (token claim burnbarOperator) grants cross-user read of ops/* metrics and rollups by design — not end-user data, but is a privileged cross-tenant read whose claim issuance I did not trace
- Whether the avatar cross-read (storage.rules:18) is intended product behavior or an oversight needs a product decision; profile JPEGs of arbitrary users are enumerable by any authenticated user
- Signed-URL issuance for session_logs/media (referenced in storage.rules comments) lives in Cloud Functions; I confirmed the entitlement-gated pattern exists but did not verify every signed-URL path scopes the object key to the caller uid
- Admin-SDK relay/message-injection correctness ultimately depends on PoP key verification and token-index integrity; I read the control flow but did not test PoP signature verification logic for bypass

---

### C12 — Old messages/pairing codes cannot be replayed
**Claim as tested:** C12: Old messages and old pairing codes cannot be replayed as new (freshness/replay protection).
**Status:** 🟡 Partially defensible  **Confidence:** High  **Category:** Replay/Freshness

**Refutation attempt (what the verifier tried to break, and what held / broke):**

> I traced every replay-relevant path. TRANSPORT (Hermes relay) is strong: HermesRelayReplayCache.recordFresh (OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/HermesRelayAuthenticatedRequest.swift:123-141) enforces BOTH a strictly-increasing per-sender counter (sender.counter > state.maxCounter) AND per-requestID dedup with a 24h TTL, throwing .senderReplay on replay; counter+requestID+operation are bound into both the key AAD and payload AAD (lines 230-268) so they cannot be stripped without breaking AEAD decryption. Gateway PoP nonces are single-use via a Firestore create-if-absent transaction throwing pop_nonce_replay (functions/src/callables/hermesGateway.ts:758-771) with a +-5min timestamp skew window (line 716). HIGH-RISK callables use a true one-time nonce: consumeHighRiskNonceForUid (functions/src/appCheckAttestation.ts:179-207) atomically checks existence + consumedAt + expiresAtMillis then marks consumed. PAIRING: server publish enforces requireFreshPublicationMillis (functions/src/callables/computerUseSecurity.ts:1844 + 330-336) behind a high-risk nonce + trusted escrow device. WHERE IT BREAKS: (1) RR-8 at-rest replay/rollback is NOT fixed. The at-rest SignalBinding (packages/signal-envelope-contracts/src/index.ts:30-40) binds only location identity (uid/scope/collection/docId/field/slotId/mode/formatVersion) with NO revision/sequence/timestamp/freshness; SignalAtRestSealer.openPayload (OpenBurnBarCore/Sources/OpenBurnBarSignalCore/SignalAtRestSealer.swift:203-258) verifies only path/binding equality. So a compromised server or stolen session can re-serve an OLD valid at-rest envelope at the SAME path and it decrypts cleanly = content rollback (internal package T-TR-2/RR-8). No client read-site compares a monotonic revision. (2) The iroh pairing RECORD itself (IrohRelayPairing.swift:133-168) is verified only by a 3-minute upper-bound age (ageSeconds > maximumAge) with NO one-time-use / replay cache and NO future-date lower bound, so within the 3-min window a captured signed pairing record can be re-presented. (3) Overclaim: comment at computerUseSecurity.ts:1329 says requireHighRiskNonce defaults FALSE, but config.ts:92-95 defaults it to looksProd (TRUE in prod) — code is safer than the comment but the comment is stale and misleading.

**Evidence (file:line):**
- OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/HermesRelayAuthenticatedRequest.swift:123-141 HermesRelayReplayCache.recordFresh — strictly increasing counter + per-requestID dedup (24h TTL), throws .senderReplay
- OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/HermesRelayAuthenticatedRequest.swift:230-268 counter/requestID/operation bound into key AAD and payload AAD (HermesRelayCrypto.authenticatedKeyAAD / authenticatedRequestAAD)
- functions/src/callables/hermesGateway.ts:758-771 PoP nonce single-use via create-if-absent transaction, throws pop_nonce_replay
- functions/src/callables/hermesGateway.ts:716 PoP timestamp +-GATEWAY_POP_CLOCK_SKEW_MS (5min, line 181) else expired_pop_timestamp
- functions/src/appCheckAttestation.ts:179-207 consumeHighRiskNonceForUid atomically checks existence+consumedAt+expiresAtMillis, marks consumed (true one-time-use + TTL)
- functions/src/appCheckAttestation.ts:234-253 enforceHighRiskComputerUseCallableWithNonce — supplied-but-invalid nonce ALWAYS fails closed; fail-open only when App Check off or staged flag off AND no nonce supplied
- functions/src/callables/computerUseSecurity.ts:1334-1344 bootstrap self-approval requires fresh single-use nonce when App Check enforced
- functions/src/callables/computerUseSecurity.ts:330-336 + 1844 requireFreshPublicationMillis on iroh pairing publish (MAX_TRUST_ROOT_PUBLICATION_SKEW_MILLIS)
- OpenBurnBarCore/Sources/OpenBurnBarIrohRelay/IrohRelayPairing.swift:133-168 pairing verify = signature + 3-min age cap ONLY; no replay cache / one-time-use / future-date guard
- packages/signal-envelope-contracts/src/index.ts:30-40 + 85-95 SignalBinding has NO revision/sequence/timestamp — at-rest AAD binds location only (RR-8 unfixed)
- OpenBurnBarCore/Sources/OpenBurnBarSignalCore/SignalAtRestSealer.swift:203-258 openPayload verifies path/binding equality only — old envelope at same path decrypts (T-TR-2 rollback)
- functions/src/config.ts:92-95 requireHighRiskNonce defaults to looksProd (TRUE in prod), contradicting stale comment at computerUseSecurity.ts:1329 that says FALSE

**✅ SAFE wording (defensible to publish):**

> Live, in-transit traffic has solid replay/freshness protection: each Hermes relay request carries a strictly increasing per-sender counter plus a unique request ID that are cryptographically bound into the message, so a captured live message cannot be replayed as new; gateway and high-risk actions additionally use single-use server-tracked nonces with short expiries. Pairing publications are accepted only within a tight freshness window. However, encrypted data stored at rest is bound to its storage LOCATION but not to a version/time, so a malicious or compromised server (or a stolen session) could re-serve an older valid encrypted record at the same path and roll content back to a stale state. Old live messages and stale pairing publications cannot be replayed as new; old at-rest records can be re-served as current within the same location.

**⛔ UNSAFE wording (do NOT publish):**

> Nothing old can ever be replayed — all messages, pairings, and stored data have full freshness/replay protection and old state can never be served as current.

**Open gaps / what would raise confidence:**
- Whether REQUIRE_HIGH_RISK_NONCE / ENFORCE_APP_CHECK are actually TRUE in the deployed prod project (env/Remote Config) — code defaults TRUE in prod but operators can opt out (config.ts:98-106 only warns). UNKNOWN without deployed config.
- Whether Firestore TTL policies actually delete pop_nonces and high_risk_nonces docs on schedule (expireAt fields are set, but TTL enforcement is a deployed Firestore setting not visible in code).
- Whether any at-rest consumer enforces a server updateTime / monotonic revision check at a higher layer not seen here (none found at SignalAtRestSealer or the CloudVaultCrypto.ln read sites).
- Pop nonce doc expireAt is now+5min while timestamp window allows -5min; whether a nonce can be evicted before a late replay arrives at the window edge (needs runtime/TTL timing evidence).
- Android (Kotlin) IrohPairingFreshness mirror not read — assumed to match the 3-min policy per the cross-platform contract test.

---

### C13 — Logs/crash/push contain no plaintext bodies/secrets
**Claim as tested:** C13: "Logs, crash reports, and push notifications do not contain plaintext message bodies or secrets.
**Status:** 🟡 Partially defensible  **Confidence:** Medium  **Category:** Confidentiality

**Refutation attempt (what the verifier tried to break, and what held / broke):**

> I tried to find a path where a message body or secret reaches logs, crash reports, or push payloads on current code.
>
> PUSH NOTIFICATIONS: The agent-reply push body is hardcoded. createEventFromThreadWrite sets preview: GENERIC_PREVIEW ("OpenBurnBar has a new agent reply.") at agentNotifications.ts:310, and buildFcmMessage uses event.preview for both the FCM data field and the iOS notification.body (agentNotifications.ts:234, 257). latestAssistantReply extracts the reply text (agentNotifications.ts:137) only to decide whether a NEW reply exists; that text is never written into the event or preview. So message bodies do not reach the push. CAVEAT: VoIP push carries caller-controlled displayName into caller_name/caller_initial (callables/voipPush.ts:71-72) — that is a call display name, not a message body or secret, but it is user-controlled free text in the push payload.
>
> SERVER LOGS: logging.ts scrubs recursively — UID truncation (lines 75-77), sensitive-key redaction (isSensitiveLogKey lines 32-45), and SCRUB_PATTERNS for emails/IPs/known-prefix tokens(sk-/AIza/ya29./eyJ)/16-digit cards (lines 16-29). GAP: the regex set does NOT catch arbitrary plaintext message bodies — only known secret shapes. logCallableFailure logs error: String(error) (logging.ts:163-170); if a thrown Error.message embeds user content it is only scrubbed for those known patterns, not for free-form body text. Gateway logs are metadata-only (callables/hermesGateway.ts: message_sent logs client_id/message_id, plaintext_filename_deprecated logs client_id only).
>
> CRASH REPORTS (server): sentry.ts removed request-body capture — integrations is only extraErrorDataIntegration (line 41), sendDefaultPii:false (line 42), and sanitizeSentryEvent deletes request.data/cookies/env/query_string and redacts body/payload/data keys (lines 82-141). requestDataIntegration is confirmed absent. captureException only receives the error plus structured context (callable name, trace_id, uid hash) at logging.ts:188-192. Same Error.message residual risk applies.
>
> CRASH REPORTS (client): AppLogger.sanitizeMetadata redacts keys message/content/body/prompt/chatbody/token/etc. and path/url patterns, and OSLog values use .private(mask:.hash) (AppLogger.swift:45-103, 185). No direct SentrySDK.capture/addBreadcrumb calls exist outside AppLogger (grep returned none), so all manual breadcrumbs are scrubbed. GAPS: (a) client Sentry init blocks (AgentLensApp.swift:1176-1186, AppDelegate.swift:60-70, daemon Main:270-278) set NO beforeSend, NO beforeBreadcrumb, NO maxBreadcrumbs — they rely entirely on the SDK defaults plus AppLogger scrubbing; automatic SDK breadcrumbs/events bypass sanitizeMetadata. (b) silentFailure writes String(describing: error) under the key "error", which is NOT in sensitiveKeys (AppLogger.swift:45-53, 149) — error descriptions are only pattern-checked and truncated at ~500 chars, so an error string embedding user content could leak.
>
> RELAY: services/hermes-realtime-relay/src/logging.ts has NO scrubber (raw JSON.stringify of fields), but all call sites pass only metadata (uid hash, byte length, runtime, role) and frames are relayed as opaque serializeFrame blobs, never logged (relay.ts:95-146). hosted-mcp logging.ts uses key-based redact() covering body/snippet/query/ciphertext (redaction.ts).
>
> Net: the common/expected paths do not put message bodies or secrets into the three sinks, but the guarantee is enforced by key/pattern allow-listing, not by structural impossibility, and a few residual free-form error-string paths exist.

**Evidence (file:line):**
- functions/src/agentNotifications.ts:310 — preview: GENERIC_PREVIEW (hardcoded body, message text never used)
- functions/src/agentNotifications.ts:234,257 — buildFcmMessage uses event.preview for data.preview and notification.body
- functions/src/agentNotifications.ts:137 — latestAssistantReply reads reply text only for change detection; not stored in event/preview
- functions/src/callables/voipPush.ts:71-72 — caller_name/caller_initial = caller-controlled displayName in FCM push (display name, not body)
- functions/src/logging.ts:16-29,75-81 — SCRUB_PATTERNS + isSensitiveLogKey + UID truncation; catches known secret shapes only, not arbitrary bodies
- functions/src/logging.ts:163-170,188-192 — error: String(error) logged and passed to captureException (free-form Error.message residual risk)
- functions/src/sentry.ts:41-42 — integrations only extraErrorDataIntegration, sendDefaultPii:false; requestDataIntegration absent
- functions/src/sentry.ts:82-141 — sanitizeSentryEvent deletes request.data/cookies/env/query_string and redacts body/payload/data keys
- AgentLens/Services/AppLogger.swift:45-103,185 — sanitizeMetadata redacts message/content/body/prompt + path/token patterns; OSLog .private(mask:.hash)
- AgentLens/App/AgentLensApp.swift:1176-1186 / OpenBurnBarMobile/App/AppDelegate.swift:60-70 / daemon Main:270-278 — client SentrySDK.start sets NO beforeSend/beforeBreadcrumb/maxBreadcrumbs
- AgentLens/Services/AppLogger.swift:149 — silentFailure stores String(describing: error) under un-redacted key 'error'
- services/hermes-realtime-relay/src/logging.ts:11-22 — relay logger has no scrubber (raw JSON.stringify), but call sites pass metadata only; relay.ts:95-146 relays opaque frames, never logs payloads

**✅ SAFE wording (defensible to publish):**

> On current code, agent-reply push notifications carry a fixed generic body ("OpenBurnBar has a new agent reply.") with no message text, and server logs, server crash reports (Sentry, with request-body capture removed and key/pattern scrubbing), client crash-report breadcrumbs (key-based redaction), and the hosted-MCP relay are designed to exclude plaintext message bodies and known-shaped secrets. Redaction is enforced by key-name and value-pattern allow-listing rather than by structural impossibility, so the protection is strong on expected paths but not an absolute guarantee: free-form error strings (e.g. a thrown Error.message, or client silentFailure's "error" field) and client crash events emitted by the Sentry SDK without a beforeSend hook are not run through the scrubbers and could in principle carry user-derived text. VoIP pushes also include a caller-controlled display name (not a message body or secret).

**⛔ UNSAFE wording (do NOT publish):**

> Logs, crash reports, and push notifications never contain any plaintext message bodies or secrets.

**Open gaps / what would raise confidence:**
- Runtime evidence needed: confirm thrown Error.message strings in production functions do not embed user message content (only static code review done here)
- Client Sentry SDK default behavior: confirm Sentry Cocoa with no beforeSend does not attach view hierarchy/screenshots/HTTP bodies under the linked SDK version (defaults appear safe but version-dependent)
- No beforeSend/maxBreadcrumbs on any of the 3 client Sentry inits — automatic SDK breadcrumbs/events bypass AppLogger.sanitizeMetadata; verify they carry no bodies in practice
- silentFailure 'error' key is not in AppLogger.sensitiveKeys — assess whether any error type's description can embed prompt/message content
- Relay logging.ts has no scrubber by design; confirm no future call site passes frame contents into log fields
- Whether SENTRY_DSN is actually set in production (sentry disabled when unset) — affects whether server crash reports exist at all; needs deployed config

---

### C14 — BurnBar does NOT claim production Signal E2EE
**Claim as tested:** C14: "BurnBar does NOT currently claim production Signal/libsignal end-to-end encryption (the non-claim is honestly gated, fail-open-to-legacy).
**Status:** ✅ Defensible  **Confidence:** High  **Category:** Non-claim discipline

**Refutation attempt (what the verifier tried to break, and what held / broke):**

> I tried to find a place where BurnBar either (a) actually activates a Signal/libsignal lane in production, or (b) claims it does in user-facing copy, or (c) silently flips a lever, or (d) has a downgrade/fail-open hole that lets the server read plaintext under cover of a "Signal" claim. All four failed.
>
> (a) Activation: registry packages/data-domains/registry.json has NO domain carrying the signal scheme. The only sealingScheme present is "cloudvault-aesgcm-v2" on pensieve (registry.json:97); the prepared activation domain conversations_chat (line 31-49) declares signalSealedCollections (line 39) but has NO sealingScheme field at all, so the gate is not flipped. The Swift gate MobileCloudVaultSignalPayloads.swift:109-120 (signalSealingIsEnabled) requires BOTH domain.sealingScheme == "signal-hpke-identity-seal-v1" (CloudVaultCrypto.swift constant) AND a Remote Config flag signal_at_rest_<domainID>_enabled that defaults false — so it returns false everywhere today. The gateway transport production set is empty: hermesGateway.ts:152 HERMES_GATEWAY_PRODUCTION_SIGNAL_ENVELOPE_VERSIONS = new Set<number>().
>
> (b) Claims: website/src/data/crypto-claims.generated.ts:62 and :72 render every Signal lane as "wired in today, not yet activated in production"; line 22 LIBSIGNAL_ROLLOUT_STATUS = "wired in, not activated in production"; CRYPTO_NOT_CLAIMS line 97 explicitly "We don't claim any Signal-library lane is live in production." trust.astro:146 and security.astro:143 interpolate that status. SECURITY.md:54 and :87-95 say production activation is blocked.
>
> (c) Silent flip: scripts/ci/verify-signal-activation-parity.sh asserts empty gateway set, no signal sealingScheme, and no committed Remote Config flips a Signal flag ON; it is wired into CI as job "signal-activation-parity" (security-pr.yml:191-204). The website generator FAILS the build the moment third_party/libsignal/runtime-readiness.json status != "not_ready" (generate-crypto-claims.mjs:76-82); that manifest currently reads "status": "not_ready". No committed config sets OPENBURNBAR_GATEWAY_SIGNAL_REQUIRED=true (only the const name exists, hermesGateway.ts:153).
>
> (d) Fail-open hole: the producer DOES fail open to legacy (MobileChatHistoryStore.swift:691-711 logs and writes legacy-only on any Signal seal error), but the legacy floor is itself AES-GCM E2E-vault-key sealed (sealPayload at :659), so no plaintext is exposed. The read path is NOT a blind fail-open: forged/stripped sender-auth and binding-mismatch fail CLOSED (lines 901-913), only unknown-sender legacy-fallback is lenient (lines 914-919) and that still needs the vault key an attacker lacks. So the fail-open does not let the server read plaintext or forge an accepted Signal envelope.
>
> No break found that contradicts C14.

**Evidence (file:line):**
- SECURITY.md:54 — 'Signal/libsignal claims: production activation remains blocked... Signal paths are wired/readiness-gated, not marketed as live production coverage.'
- SECURITY.md:89-95 — 'wired but NOT activated in production'; legacy AES-GCM is the floor; 'producers fail OPEN to legacy if a Signal seal cannot be produced, so confidentiality never regresses.'
- packages/data-domains/registry.json:97 — only sealingScheme present is 'cloudvault-aesgcm-v2' (pensieve); no domain carries 'signal-hpke-identity-seal-v1'.
- packages/data-domains/registry.json:31-49 — conversations_chat declares signalSealedCollections (line 39) but has NO sealingScheme field, so the activation switch is OFF.
- OpenBurnBarMobile/Services/MobileCloudVaultSignalPayloads.swift:109-120 — signalSealingIsEnabled requires registry signal scheme AND RemoteConfig flag signal_at_rest_<domainID>_enabled (defaults false) → returns false today.
- OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/CloudVaultCrypto.swift — signalAtRestEncryption constant = 'signal-hpke-identity-seal-v1' (the string absent from registry).
- functions/src/hermesGateway.ts:152 — HERMES_GATEWAY_PRODUCTION_SIGNAL_ENVELOPE_VERSIONS = new Set<number>() (empty → transport fail-closed); :174-178 env-gated SIGNAL_REQUIRED mode, default off; :153 env const name only, never set true in committed config.
- OpenBurnBarMobile/Services/MobileChatHistoryStore.swift:691-711 — producer fail-open: on any Signal seal error logs and writes legacy AES-GCM only; legacy sealedPayload sealed at :659.
- OpenBurnBarMobile/Services/MobileChatHistoryStore.swift:901-919 — read path fails CLOSED on forged sender-auth / binding mismatch (downgrade defense); only unknown-sender falls back to legacy (which still needs the E2EE vault key).
- scripts/ci/verify-signal-activation-parity.sh:23-83 — asserts empty gateway set, no signal sealingScheme on any domain, and no committed Remote Config flips a Signal flag ON; wired into CI at .github/workflows/security-pr.yml:191-204 (job 'signal-activation-parity').
- website/src/data/crypto-claims.generated.ts:22,62,72,97 — LIBSIGNAL_ROLLOUT_STATUS='wired in, not activated in production'; Signal lanes' publicLine says 'not yet activated in production'; CRYPTO_NOT_CLAIMS: 'We don't claim any Signal-library lane is live in production.'
- website/scripts/generate-crypto-claims.mjs:76-82 + third_party/libsignal/runtime-readiness.json ('status':'not_ready') — generator FAILS the build if readiness flips off not_ready, so the non-claim copy cannot outlive the rollout.

**✅ SAFE wording (defensible to publish):**

> BurnBar does not claim, in any user-facing copy or shipped configuration, that Signal/libsignal end-to-end encryption is live in production. The Signal/libsignal at-rest and device-to-device lanes are wired in but deactivated: no data domain carries the Signal sealing scheme, the runtime kill-switch defaults off, the gateway's production Signal-envelope set is empty, and the website explicitly states 'wired in, not activated in production' and 'We don't claim any Signal-library lane is live in production.' The non-claim is machine-enforced by a CI parity job and a fail-closed website generator that breaks the build if any lever activates. The encrypted floor today is legacy AES-GCM sealing under the E2EE vault key; Signal producers fail open to that legacy floor without exposing plaintext, and the read path fails closed against forged-sender / downgrade attacks.

**⛔ UNSAFE wording (do NOT publish):**

> BurnBar uses Signal Protocol / libsignal end-to-end encryption to protect your data. (FALSE as a production claim — every Signal lane is wired but deactivated; do not imply libsignal E2E is the live at-rest or device-to-device path. Also avoid implying the 'fail-open' means data could be sent unencrypted — the floor is AES-GCM E2EE, not plaintext.)

**Open gaps / what would raise confidence:**
- Runtime values of the Remote Config flags signal_at_rest_<domainID>_enabled are not verifiable from source; code defaults are fail-closed false, but a deployed console flip cannot be confirmed without Remote Config access (would still require the registry scheme too, which is absent).
- Deployed value of OPENBURNBAR_GATEWAY_SIGNAL_REQUIRED is not verifiable from source; no committed config sets it true, but the running Functions environment could in principle set it (would enable Signal-envelope transport, not at-rest).
- I verified the Apple/Swift producer and gate paths and the website; I did not exhaustively re-verify the Android/Kotlin producer state, which SECURITY.md:101-126 itself flags as parity-REMAINING (Android RC bootstrap and sign/verify) — consistent with 'not activated' rather than a contradiction.
- The live gateway lane IS marketed as a 'homegrown Double Ratchet, forward-secret' gateway (crypto-claims.generated.ts:49-50); this is a separate live claim and not a Signal-Protocol production claim, but a reader should not conflate the two when relying on C14.
- firestore.rules and functions/src/signalAtRestWrite.ts enforcement of direct signalEnvelope writes was referenced by the generator's wiring proofs but not independently read here; relevant to the 'wired in' integrity story, not to the 'not claimed in production' verdict.

---

## Non-Claims — what BurnBar explicitly does NOT guarantee

These are deliberate boundaries. Stating them is a security control (it prevents users from over-trusting the system) and they must appear in any user-facing security page.

- **Not a universal end-to-end-encrypted product.** Only specific sealed sub-flows are E2E. The cloud sees rich **metadata** by design: user/device/client/destination IDs, timestamps, sizes, counters, statuses, sequence, model/provider/cost facets, search token/semantic hashes, push tokens, routing.
- **No protection of plaintext on a compromised endpoint or local agent runtime.** Phones, Macs, Android devices, and local agents necessarily see plaintext before sealing / after opening. Endpoint compromise is intentionally outside the cryptographic boundary.
- **No forward secrecy / post-compromise security** beyond the ephemeral relay leg. The relay scheme self-documents *no static-leg PFS and no KCI protection*; the gateway ratchet has no one-time prekeys/PQXDH.
- **Provider credentials are backend-decryptable**, not zero-knowledge. Secret Manager + KMS protect against direct Firestore compromise; a service account with the right IAM/KMS can decrypt. IAM/KMS is the real boundary.
- **No production Signal / libsignal end-to-end encryption.** The Signal at-rest lane is flag-OFF and fails open to the legacy AES-256-GCM seal; the live libsignal session lane has no production callers. Do not market "Signal Protocol", Double Ratchet, PFS/PCS, or post-quantum.
- **Revocation does not claw back already-cached plaintext.** A device that cached a vault key before revocation can read pre-revocation content until rotation completes; rotation is client-driven and best-effort.
- **No anonymity, no full metadata privacy, no screenshot/shoulder-surf protection** across the whole app, and **no protection against a fully-compromised paired device**.
- **Model providers see everything routed to them.** "The assistant cannot read your messages" is false by construction for the gateway/model lane.

## Banned phrasings (enforced by the repo's own `verify-signal-honesty-copy.sh` / license-posture gates)
"zero-knowledge" (unqualified) · "server learns nothing" / "server searches without reading it" · "Signal-quality privacy" for the whole product · "semantic memory is private from us" · "revocation immediately makes old data safe" · "encrypted database" (while SQLCipher codec is absent / legacy plaintext unmigrated) · unconditional "end-to-end encrypted" / "no one in the middle, including us" / "API keys never leave the device" / "never appears anywhere you didn't put it".
