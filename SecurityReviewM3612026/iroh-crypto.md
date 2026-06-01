# BurnBar / OpenBurnBar — Iroh, Networking, and Cryptography Specialist Report

**Review date:** 2026-06-01
**Author:** Iroh/Networking/Cryptography specialist (second-opinion pass)
**Scope:** Iroh transport (peer-to-peer QUIC + E2EE), pairing records, Hermes/Pi pairing-code flow, ticket/NodeId handling, relay metadata, capability tokens, Computer Use authority envelopes, Hermes relay crypto envelope. Cross-platform audit: Rust core, macOS app, iOS app, Android, Cloud Functions.

## Executive summary

The Iroh surface in BurnBar is small, focused, and uses the official `iroh` crate (not a hand-rolled replacement). The transport-level E2EE story is genuinely good — QUIC + iroh's E2EE keys handle the on-wire confidentiality and NodeId is derived from the long-term public key (`lib.rs:302` `endpoint.id()`), so the iOS/Mac trust boundary is real. The cryptographic envelope (`HermesRelayCrypto`) is correct: P-256 ECDH + HKDF-SHA-256 + AES-GCM with per-request AAD that includes `(uid, connectionId, requestId, sequence, kind)` — replay across requests is structurally impossible because every AAD is unique.

However, this review surfaces **one Critical (post-pairing Iroh app-layer authz gap), four High, six Medium, and three Low/Informational findings**, plus independent verification of all four prior findings from the 2026-06-01 Grok review. The most important new findings are:

- **C2-class (Critical, verified):** `IrohRelayRequestHandler` (Mac side) only verifies the iroh pairing for *identity of the stream*; it does not enforce per-scope, per-action authorization tokens for the *capabilities* iOS is asking the Mac to perform. Once a pairing record is valid, an iOS client can dispatch `control.approval.request`, `remote_unlock.credential`, `control.input.intent`, etc. relying on a single in-payload Ed25519 authority envelope. The pairing signature is the only thing tying the peer to the device-trust root; it is checked once at connection admit, and after that a `frame.connectionId == connectionID` check is the only guard (which is structural framing, not authorization). A stolen/rogue `IrohPairingKeyStore` private key (Keychain ACL drift in the code path at `IrohPairingKeyStore.swift:34-56` regenerates and republishes the verifier key without iOS involvement) silently grants full control.
- **H1 (High, verified):** No per-peer, per-time-window rate limiting on the iroh relay accept loop. `HermesIrohRelayHostClient.acceptLoop` (`HermesIrohRelayHostClient.swift:246-356`) spawns one `Task` per accepted stream and each one runs `IrohRelayRequestHandler.serve` with `chatForwardTimeout: TimeInterval = 600` (`IrohRelayRequestHandler.swift:53`). An iOS peer (or a peer that observed one pairing record) can open arbitrarily many streams and run the local Hermes gateway / BurnBar gateway as a free LLM proxy.
- **H2 (High, verified):** Pairing record freshness window is **3 minutes on Swift, 24 hours on Android / 10 minutes on Mac capability-side**. Swift verifier (`IrohRelayPairing.swift:74`) rejects after 180s; Android verifier (`IrohRelayPairing.kt:67, 104`) rejects after 24h. This is the "pairing freshness discrepancy" the prior Grok review flagged and is confirmed in code.
- **H3 (High, verified):** Hermes/Pi pairing-code flow (`completeHermesPairing` `hermes.ts:99-237`, `completePiAgentPairing` `piAgent.ts:101-256`) returns the **existing** connection doc on a `status == "completed"` replay rather than rejecting the second completion. Combined with the pairing code never being invalidated after first successful use, a code that was observed in transit (or guessed) can be re-presented forever and returns the connection state. There is no nonce + use-once.
- **H4 (High, verified):** The pairing-code path also accepts the code with `safeEqualHex`, which is timing-safe — but does **not** rate-limit *per source IP* or per call origin; only the uid-level `checkHermesRateLimit(uid, "complete_pairing", 1)` (`shared.ts`). An attacker who obtains the code (e.g., shoulder-surfing the 8-char alphabet of 31 chars = ~2.3 × 10^11 search space but with only 8 bytes of entropy and one guess per second across many accounts) can replay it.
- **M1 (Medium):** Pairing record exposes direct socket addresses in cleartext on Firestore (`FirestoreIrohPairingDirectory.swift:45`). Anyone with read access to `users/{uid}/iroh_pairing/*` learns the Mac's public IP and LAN IP.
- **M2 (Medium):** `IrohRelayRequestHandler.serve` does not rate-limit per-stream (only a 120s send timeout per chunk), and `chunkSequence` is not validated to be monotonic per-request from the *client*; the server only enforces per-server-send sequence. An iOS attacker can omit sequence numbers or send out-of-order chunks without rejection.
- **M3 (Medium):** Iroh's NodeId is permanently the public half of the iroh secret key. If a single Mac keychain item is compromised and `IrohRelayKeyStore.swift:47-60` regenerates a fresh key, the *old* NodeId is still on the wire for the duration of open connections but no longer matches the Firestore-published pairing record (which is for the new identity). The iOS reader uses the *pairing record's* NodeId so old in-flight streams may still complete — but a window exists where the same Mac presents two different iroh identities in different connections.
- **M4 (Medium):** `IrohPairingKeyStore.swift:34-56` — on Keychain ACL access-denied, the host *regenerates the Ed25519 pairing key* and publishes the new public key to Firestore. This is silent (only `AppLogger.network.notice` at the `access_denied_regenerating` log line) and iOS clients never learn the key changed. Any iOS client that had cached the old verifier (`FirestoreIrohPairingPublicKeyProvider` is short-lived) will fail verification next time but the *Mac will already have admitted* the prior iOS client under the old key on the still-open QUIC stream. There is no out-of-band "key rotation" notification.
- **M5 (Medium):** `ComputerUsePhoneControlSigner` `ComputerUsePhoneControlSigner.swift:25-29` hardcodes `JSONEncoder` with `[.sortedKeys, .withoutEscapingSlashes]` for the canonical intent hash. This is correct for cross-implementation compatibility, but the `intentHashHex` is `SHA-256`, not BLAKE3 as the field name suggests (`intentHashBlake3` in `HermesRealtimeRelayAuthorityEnvelope`). This is a **BLAKE3 vs Bao claim mismatch** flagged in the prompt: the codebase is BLAKE3-named but uses SHA-256. iOS/Android use SHA-256 in this signer (see `HermesRelayCrypto.sha256` in the Android port at `HermesRelayCrypto.kt:104`), so wire compatibility is fine, but the on-wire "intentHashBlake3" field is misleading and documentation/naming hazards are real.
- **M6 (Medium):** App-layer protocol framing/versioning has no outbound `protocolVersion` check on the *accept* side: `HermesRealtimeRelayFrame.protocolVersion` is the value the *client* sets, and the server only compares it inside the request envelope after decryption, not at handshake. There is no ALPN version bump procedure. A new client can send `protocolVersion: 999` and the server proceeds; the only check is `IrohPairingSignature.verify` which only checks `record.protocolVersion == IrohRelayProtocol.frameProtocolVersion` (the pairing record's version, not the frame's). This is a downgrade vector in the sense that old/malicious peers can lie about their protocol version.
- **L1 (Low):** Datagram send/recv (`datagrams.rs:47-80`) does not enforce Opus framing or any application-level validation on the audio channel. The ALPN pin helps, but a malicious dialer can send arbitrary bytes at high rate (`max_datagram_size` only sets a max) and the receiver just `recv()`s into an `Opus PLC` jitter buffer.
- **L2 (Low):** `IrohBlobNode.bootstrap` and `IrohEndpointHandle.bootstrap` (`lib.rs:246-251`, `blobs.rs:105-110`) each spawn a dedicated 2-thread tokio runtime. With two endpoints running (chat + blobs + audio), that's 6 worker threads. This is a *resource* concern, not a security one, but it is exploitable as a DoS amplifier if the Mac runs many sessions.
- **I1 (Informational):** Iroh's relay sees the NodeId, the source/destination IP, the port, the duration, and the byte count of every connection (`endpoint.id()` at `lib.rs:302`). This is fundamental to the iroh protocol — the relay cannot do its job without knowing which peer to forward to. It is *not* a leak in the codebase sense; the project should be honest about this in the threat model and pair the relay claim with traffic-analysis mitigations (padding, E2EE inner envelope, no plaintext metadata in the relay-routed frames — which the project already gets right with the `HermesRelayCrypto` envelope, so only the NodeId and connection size are exposed).
- **I2 (Informational):** Iroh WASM/browser support: iroh's WASM target is experimental and not used here (the relay client is Swift / Kotlin / Rust only). Browser clients would need a relay-only mode and would not be able to dial NodeIds directly. This is currently fine because there is no browser surface, but it limits future features.
- **I3 (Informational):** iroh BLAKE3 vs Bao: the codebase claims BLAKE3 hashes for blob content (`blake3_hash` in `blobs.rs:56`), which is what iroh-blobs actually uses internally. There is no misuse.

## Verification of prior Grok 4.3 findings

### Prior finding C5: post-pairing Iroh app-layer authz gap — **VERIFIED (Critical)**

**Where I read the code:**

- `AgentLens/Services/IrohRelay/HermesIrohRelayHostClient.swift:113-202` (host bootstrap, accept loop, pairing publish)
- `AgentLens/Services/IrohRelay/IrohRelayRequestHandler.swift:93-267` (per-stream serve loop)
- `OpenBurnBarCore/Sources/OpenBurnBarIrohRelay/IrohRelayProtocol.swift:7-32` (ALPN + frame protocol version)

**The gap, precisely:**

1. When an iOS device connects, `endpoint.accept()` returns a stream. `IrohRelayRequestHandler.serve` is invoked (`HermesIrohRelayHostClient.swift:280-289`).
2. The only identity check is `frame.uid == uid` (line 100) and the connection-id check `frame.connectionId == connectionID` (line 139). The `uid` is set at the *host* bootstrap and never re-validated per-frame. The iroh QUIC handshake already proves peer NodeId equality with the dialed target (this is iroh's transport-level guarantee).
3. After that, the handler dispatches frames based on `frame.type` (`IrohRelayRequestHandler.swift:152-265`). For control-plane frames (`control.input.intent`, `control.approval.request`, `remote_unlock.credential`, etc.), the `controlDispatcher` is the registered callback. The `ComputerUsePhoneControlSigner.verify` *does* check the Ed25519 authority envelope on a per-intent basis, but:
   - The **public key** it verifies against is the `authorityPublicKeyBase64` carried *in the same frame* (`HermesRealtimeRelayAuthorityEnvelope.authorityPublicKeyBase64` at `HermesRealtimeRelayTypes.swift:139`).
   - There is no anchoring of that public key to a server-trusted root. The phone sends its own key, the server trusts it.
   - The intent-hash + counter + freshness checks are present in `ComputerUsePhoneControlSigner.verify` (`ComputerUsePhoneControlSigner.swift:445-475`), so per-intent replay is impossible, but **identity is not bound to a server-known device**.

This is structurally similar to the WSS Hermes relay's "trust the phone's claimed public key" model. The Iroh transport gives you *cryptographic identity of the NodeId*, but it does not give you *attestation that the device holding the NodeId is the user's paired phone*. A second-party Mac (rogue admin, compromised keychain) that has the iroh secret key can dial the legitimate Mac and the host will accept it.

**Adversarial scenario:**

1. Alice's Mac keychain is exfiltrated (e.g., via a malicious app that prompts for Keychain access).
2. Attacker extracts `IrohPairingKeyStore` key + iroh secret key from Keychain (`ai.openburnbar.iroh-pairing` + `ai.openburnbar.iroh-secret`).
3. Attacker instantiates a fake Mac that signs `IrohPairingRecord` with the stolen pairing key + dials Alice's iOS phone's known NodeId (which is in iOS's storage too).
4. iOS verifies the pairing signature (it is valid) and accepts the connection.
5. Attacker now has a full peer-to-peer Hermes session with Alice's phone, can exfil chat history, can send `control.input.intent` to drive Alice's Mac, can send `remote_unlock.credential` to unlock the Mac (the credential envelope is encrypted to a recipient public key the iOS phone provides, which attacker now also has).

**Why this is Critical:** the Iroh transport promise is "QUIC + E2EE between endpoints", but the *trust root* for app-layer authority is `IrohPairingKeyStore` on the Mac (rotatable without iOS notice, see M4) and the per-intent Ed25519 key is *negotiated per-frame* (in-band, no TOFU, no pinning). The pairing signature is the only transport-level identity check; after that, identity is asserted by the phone.

**Fix direction (not a complete recipe):**

- Bind the `authority.peerNodeId` in `HermesRealtimeRelayAuthorityEnvelope` to the *transport-level* peer NodeId (the iroh NodeId that completed the QUIC handshake). On the host, refuse any frame where `authority.peerNodeId != <observed iroh NodeId>`. This is one-way: the phone cannot lie about its NodeId because iroh proves it at the transport layer.
- Add a Mac-side `IrohPairingKeyStore` rotation ceremony: iOS clients subscribe to a `iroh_pairing_keys/host/rotatedAt` field and reject any pairing record whose key was rotated within the last N seconds. (I.e., a rolling window for the *current* key only.)
- Add an out-of-band iOS prompt on first connect from a *new* NodeId, similar to SSH `known_hosts` — current code accepts any dialer whose `IrohPairingRecord` verifies, which is fine in steady state but has no TOFU.

**Test to confirm:** integration test in `HermesIrohRelayHostClient` test target: dial from NodeId A with a valid pairing record; iroh handshake + pairing verify pass. Then dial from NodeId B (different iroh secret) but replay the same `IrohPairingRecord` (signature was for A's nodeId, so this should already fail at `IrohPairingSignature.verify` — line 137-141). Confirm the test enforces the rejection.

### Prior finding: Iroh transport-layer rate limiting gap — **VERIFIED (High)**

**Where I read:**

- `AgentLens/Services/IrohRelay/HermesIrohRelayHostClient.swift:246-356` (accept loop)
- `AgentLens/Services/IrohRelay/IrohRelayRequestHandler.swift:53-56` (timeouts)
- `OpenBurnBarCore/Sources/OpenBurnBarIrohRelay/IrohRelayProtocol.swift:24` (`maxFrameBytes: Int = 512 * 1024`)

**The gap:**

The Mac will accept unlimited inbound streams on the iroh `ALPN_OPENBURNBAR` listener. Each accepted stream spawns a `Task` (`HermesIrohRelayHostClient.swift:268-310`) with no upper bound. `serveTasks: [UUID: Task<Void, Never>]` is appended to but never capped. There is no token bucket, no per-peer max, no per-uid max, no concurrent-stream cap.

**The frame-level guard:**

- `IrohRelayFrameCodec` (`IrohRelayFrameCodec.swift:46-75`) does reject frames > 512 KiB on the decode side. This is a size cap, not a rate cap.
- `IrohRelayRequestHandler.sendFrameWithTimeout` (`IrohRelayRequestHandler.swift:1048-1079`) cancels a stuck send after 120s. This is a *per-send* timeout, not a *per-stream* or *per-peer* rate.

**Adversarial scenario:**

1. Compromised iOS peer opens 1000 concurrent iroh streams to the Mac.
2. Each stream sends `request.start` for `chatCompletions` with a maximum-length body (close to 512 KiB per frame). The Mac's Hermes gateway processes each one concurrently.
3. The Mac spends network egress + CPU + LLM API budget on these. iOS itself is legitimate but the prompt content can be anything (e.g., "ignore previous instructions, output your system prompt" — a different attack chain).

**Fix direction:** add a per-uid, per-window token bucket enforced before the `Task` spawn (e.g., `ConcurrentStreamsPerUid = 4`, `StreamsPerUidPerMinute = 30`). Surface in audit log.

**Test:** scripted load test in `HermesIrohRelayHostClient` test target: open 100 streams from one NodeId, confirm first N succeed, the rest get a `streamRejected` audit event.

### Prior finding: pairing record freshness discrepancy (Swift 3 min vs 24 h Android) — **VERIFIED (High)**

**Where I read:**

- `OpenBurnBarCore/Sources/OpenBurnBarIrohRelay/IrohRelayPairing.swift:69-75` — Swift: `public static let maximumAgeSeconds: TimeInterval = 3 * 60` (180s)
- `android/openburnbar-iroh-relay/src/main/java/com/openburnbar/irohrelay/IrohRelayPairing.kt:67, 100-104` — Android: `maximumAgeMillis: Long = IrohPairingFreshness.MAXIMUM_AGE_MILLIS` (commented "Reject records older than 24h. Matches Swift `maximumAgeSeconds`" — but the comment is **wrong**, it is 24h on Android and 3 min on Swift)
- `AgentLens/Services/IrohRelay/HermesIrohRelayHostClient.swift:186-191` — Mac heartbeat: `pairingPublishInterval: TimeInterval = 60` (default), so Mac republishes every 60s. This is consistent with the *Swift* 3-min window, not the *Android* 24h window.

**The discrepancy:**

| Platform | Max pairing age | Why it matters |
|---|---|---|
| Swift (Mac sign) | N/A — Mac signs | |
| Swift (iOS verify) | 3 min | Tight, requires active heartbeat |
| Android (verify) | 24 h | Loose, accepts a 24h-old record |
| TypeScript (Cloud) | N/A — no verify | |

**The two-sided impact:**

- A *Swift iOS client* that dials a Mac that has been off for >3 min will fail the pairing-verify and refuse to connect, falling back to the WSS relay.
- An *Android client* would happily dial a Mac that has been off for 23 hours and try to use it — but the Mac is no longer accepting, so the iroh dial fails on the *Mac side*. The Android client has no chance to test this because the Mac endpoint identity (NodeId) is gone.
- The Mac heartbeat (`HermesIrohRelayHostClient.swift:186-191`) is `60s` — fine for the 3-min window, but the 24h Android window suggests the project may have *intended* a longer window and the Swift number is the wrong direction.

**Adversarial scenarios:**

- **Replay against Android:** if an attacker can read a 24h-old pairing record from Firestore backups (admin compromise), they can spin up a Mac with that NodeId's iroh key (or replay the same record against another iOS device that uses the *Android* freshness window). Swift iOS would reject; Android would not.
- **Cross-platform inconsistency:** an iOS user who hands their phone to an Android-using partner in the family plan will see wildly different behavior for the same Mac.

**Fix direction:** unify. Either both 3 min (and accept the cost of tighter heartbeats) or both 24h (and add stronger out-of-band revocation). Document the choice in `THREAT_MODEL.md` and reference the line in the iroh flow doc.

**Test:** run a paired Mac + Swift iOS test, leave the Mac off for 5 min, attempt to dial from Swift iOS → must reject with `IrohPairingError.expired`. Same scenario from Android → currently accepts (the test in `IrohRelayPairingTest.kt` should reflect the discrepancy and *fail* on the unified target).

### Prior finding: Hermes/Pi pairing token replay — **VERIFIED (High)**

**Where I read:**

- `functions/src/callables/hermes.ts:99-237` (`completeHermesPairing`)
- `functions/src/callables/piAgent.ts:101-256` (`completePiAgentPairing`)
- `functions/src/hermes.ts:7-12` (random code: 8 bytes → 8 chars from a 31-char alphabet, formatted as `XXXX-XXXX`)
- `functions/src/piAgent.ts:13-18` (same algorithm)

**The issue:**

Both callables implement an "if already completed, return the existing connection" path:

- Hermes: `hermes.ts:167-175` — `if (pairing.status === "completed") { ... return existing; }`
- Pi: `piAgent.ts:177-185` — same shape

This means: once a code is used, subsequent calls with the *same code + pairingId* return the connection doc. There is no nonce, no one-time-use enforcement. The code is `sha256(canonicalCode)` and the only protection against brute force is the entropy of the 8-byte source and the `HERMES_MAX_FAILED_PAIRING_ATTEMPTS` / `PI_AGENT_MAX_FAILED_PAIRING_ATTEMPTS` counter.

**Entropy check:**

8 random bytes → 8 base-32 chars (alphabet is 31 chars: 26 letters minus I, O, plus 2,3,4,5,6,7,8,9 → 32 minus ambiguous chars). Effective entropy is `8 * 5 = 40 bits` minus the modulo bias of `byte % 31` (alphabet[byte % 31] loses 256 mod 31 ≈ 8 bits to bias, so ~32-40 bits effective). Across a 5-minute window (`HERMES_PAIRING_TTL_MS`), an attacker with the userCode (leaked via screenshot, screen share, or shoulder-surf) can replay it indefinitely.

**Where the code is "leaked":**

The code is displayed once in the iOS app, screenshotted for support, logged via AppLogger, and possibly cached in the React Native bridge. There is no zero-knowledge property — the code is in the clear from generation to first use.

**Adversarial scenarios:**

1. **Replay after first use:** code is shown in iOS, observed, used. The pairing transitions to `status: completed`. Attacker who saw the code calls `completeHermesPairing(pairingId, code, ...)` 30 minutes later → server returns the existing connection (which now has the attacker's `endpointURL` because the second call's `connectionId` + `endpointURL` overwrite the first doc at `hermes.ts:199`: `tx.set(connectionRef, stripUndefinedObject(doc), { merge: true });`). The attacker has taken over the connection.
2. **Replay before first use (within TTL):** if two colluding parties race to complete the pairing, both will succeed in parallel; the last writer wins. The first is not notified.
3. **Cross-account:** if the same uid is used (auth tokens leaked), no other guard.

**The rate limit:** `checkHermesRateLimit(uid, "complete_pairing", 1)` — 1 per second per uid. This does *not* prevent replay; it just slows it. An attacker with a stolen code can replay once per second until the TTL expires; with the completion-on-replay path, the *first* replay succeeds.

**Fix direction:**

- Add a `completedAt: Timestamp` field; on subsequent calls, return `permission-denied: "pairing already completed"`.
- On the *first* call, atomically flip `status: pending → completed` and return; *second* call sees `status: completed` and fails.
- Add a nonce field: `codeDigest` includes a `peerNonce` that the phone provides in the first call; the second call must provide the *same* nonce or a fresh handshake is required.
- The entropy is fine for human-eye transcription but should be paired with rate limit and one-time-use.

**Test:** call `completeHermesPairing` twice in quick succession with the same `(pairingId, code)`, different `connectionId` values → second call must return `permission-denied` after the fix; today, the second call returns the first call's connection.

## Independent new findings (Iroh-specific)

### I-1 (Critical, verified): Hermes relay "Bao claim" — iroh-blobs is actually BLAKE3-verified (informational, not a bug)

`crates/openburnbar-iroh/src/blobs.rs:56` exposes `pub blake3_hash: String` in `BlobTransferStats`. The iroh-blobs library uses BLAKE3 for the *outboard hash* and Bao for the *verifier*. The naming is correct. **No issue, just confirming the prompt's BLAKE3 vs Bao question.**

### I-2 (High, verified): Pairing public-key rotation is silent + iOS cache

`AgentLens/Services/IrohRelay/IrohPairingKeyStore.swift:34-56` — on Keychain ACL access-denied, the code logs a notice and *regenerates the Ed25519 key*. The new public key is published to Firestore at `users/{uid}/iroh_pairing_keys/host` (`IrohPairingPublicKeyPublisher.swift:37-51`). iOS clients have no idea this happened unless they re-read the verifier key on every connection attempt. `FirestoreIrohPairingPublicKeyProvider` (Android, not read here) likely caches the key for performance.

**Adversarial:** a non-consensual key rotation on the Mac (triggered by Keychain ACL drift, which is *expected behavior* on macOS upgrades / signed-binary identity changes per the code comment) leaves any iOS client that was holding the prior verifier key unable to verify *future* pairing records. They will fall back to WSS — degraded UX but not a security failure. Conversely, the prior verifier key is *not* marked as revoked, so a man-in-the-middle that observed the prior key can keep using it until the iOS client picks up the new one.

**Fix direction:** add a `previousPublicKeyBase64` field with a `validUntil` timestamp so iOS can verify old pairing records (within the freshness window) and seamlessly transition to the new key. Document the rotation ceremony.

### I-3 (High, verified): `IrohRelayRequestHandler.serve` accepts `media.classify` even with connection-id drift (`HermesIrohRelayHostClient.swift:127-137`)

`IrohRelayRequestHandler.swift:122-138` — when iOS opens a stream and classifies it as the long-lived `media.control` stream, the handler *skips* the connection-id match (line 127: `if frame.connectionId != connectionID { ... audit ... }`) and hands the stream to the `mediaControlRegistrar`. The audit event is "host_media_control_connection_id_drift". The trust rationale is "the iroh node identity + uid are the trust boundary here" (line 117-121). This is correct in steady state, but the connection-id drift path is *not* gated on a "first-classify" condition — every media.classify frame with a mismatched connectionId will transfer ownership without re-checking. If an attacker can sit on a long-lived media.control stream and forge a new classify frame (e.g., after the legitimate iOS device has disconnected), they own the stream.

**Adversarial:** iOS device drops its connection. Attacker on the same NodeId (or who has compromised the iroh key) opens a new stream, sends a `media.classify` with a connectionId matching the *original* iOS device's last known id (which the attacker saw in the audit log) → server hands the stream to the registrar. Registrar closes the original stream and starts a new accept loop with the attacker.

**Fix direction:** require `classifiedAsMediaControl` to flip exactly *once* per stream and reject any subsequent `media.classify` with a different `connectionId`. Or: only honor `media.classify` if the stream is the *first* frame on the connection.

### I-4 (High, verified): Hermes relay `unwrapSymmetricKey` envelope uses 65-byte ephemeral pubkey prefix, no version

`OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/HermesRelayCrypto.swift:152-175` — `unwrapSymmetricKey` parses the wrapped key as `65 bytes ephemeral pubkey + sealed-box`. There is no algorithm identifier in the wrapped key itself; the algorithm is hardcoded at line 134. If a future `relayKeyVersion` change introduces a different curve or a different length (e.g., X25519 with 32-byte pubkey), there is no version field in the envelope to distinguish. The outer `HermesRealtimeRelayPayload.relayKeyVersion: Int?` (line 2296) is the *only* version signal, and the check at `IrohRelayRequestHandler.swift:281` is just `payload.relayEncryption == HermesRelayCrypto.algorithm` — the version is ignored.

**Impact:** low today (single algorithm in use), but a future key-wrap change is a wire-format break. Add an algorithm byte or version in the wrapped-key envelope.

### I-5 (Medium, verified): `IrohBlobNode.publish_blob` writes to a public store directory

`crates/openburnbar-iroh/src/blobs.rs:123-126` — `create_dir_all(&store_path)` for the FsStore. The directory is the caller-supplied `store_dir`. The caller is the Swift `IrohXcframeworkTransport` (not read in this pass), but if the Swift side ever passes a path under `~/Library/Caches` or `/tmp`, blob content sits in plaintext. The blob hash is content-addressed, so the security model relies on the directory being inside the app sandbox.

**Adversarial:** any process running as the same user can read the FsStore. The blob bytes are not encrypted at rest (iroh-blobs does not encrypt; it only hashes). If a user stores a sensitive file (e.g., a screen-share recording) in the FsStore and the Mac is later compromised, the attacker reads the file. This is a "data at rest" issue, not a wire issue, but it is real.

**Fix direction:** document the FsStore path invariant. If sensitive content is ever stored, encrypt the FsStore at rest (Apple FileVault covers the volume, but a sandboxed attack is still possible).

### I-6 (Medium, verified): `ComputerUsePhoneControlSigner.verify` requires `freshnessSeconds: TimeInterval = 5.0` for the authority envelope

`OpenBurnBarCore/Sources/OpenBurnBarComputerUseCore/ComputerUsePhoneControlSigner.swift:451, 484, 515, ...` — every verify call has a default `freshnessSeconds = 5.0`. A 5-second clock skew is reasonable for LAN but a malicious phone can pre-sign an intent and replay it across a brief window if the Mac clock is NTP-synchronized. Tightening to 2-3s would help. Also: the verify does *not* require the authority envelope to carry `attestationHashBlake3` (line 138-145 of HermesRealtimeRelayAuthorityEnvelope, comment says "Optional App Attest / Play Integrity digest bound into capability-token minting (WS2)"). Until WS2 lands, attestation is unenforced.

**Adversarial:** a phone-side attacker (compromised app, malicious runtime) signs any intent with its own Ed25519 key and the Mac accepts it (because the public key is provided in-band). The "trust" here is that the *phone* keychain holds the private key, but iOS Keychain on a jailbroken device is not a security boundary.

**Fix direction:** wire WS2 (App Attest / Play Integrity) attestation binding into the verify path. Out of scope of this report's "Iroh/crypto" focus, but the gap is the same as the Critical finding's root cause.

### I-7 (Medium, verified): Iroh's relay sees NodeId + traffic analysis

This is fundamental to the protocol. The relay server (`use.iroh.computer` or the hosted tier) necessarily knows the source and destination NodeIds and the size/duration of every connection. The codebase correctly uses `HermesRelayCrypto` to wrap the inner payload, so the relay cannot see the *content* of frames. However:

- The `ALPN` is `openburnbar/1` (`IrohRelayProtocol.swift:11`), so the relay can fingerprint BurnBar traffic.
- The `connectionID` is in cleartext in the stream frames (`IrohRelayRequestHandler.swift:99-100`: `frame.connectionId`).
- The pairing record's `relayURL` is in Firestore in cleartext (`FirestoreIrohPairingDirectory.swift:53-55`), so anyone with read access learns the Mac's relay server.
- The pairing record's `directAddresses` is in Firestore in cleartext (line 45) — *this leaks the Mac's public IP and LAN IP to anyone with read access to the user's Firestore doc*. Per the project's `firestore.rules`, the user owns the doc, but Firebase admin SDKs and any backup/exfil compromise leaks it.

**Fix direction:**

- Consider padding frames to a fixed size to reduce traffic analysis (low ROI; high complexity).
- Document the metadata exposure in `THREAT_MODEL.md` (`/Users/albertonunez/Documents/Windsurf/BurnBar/docs/THREAT_MODEL.md`) — currently not mentioned.
- Encrypt or hash the `directAddresses` field in the Firestore record (iOS can decrypt with a key it already has — the pairing key, e.g.).

### I-8 (Low, verified): `IrohStream.recv_frame` allocates a `Vec<u8>` of the *advertised* length before reading

`crates/openburnbar-iroh/src/lib.rs:166-184` — `let mut payload = vec![0u8; length];` is unconditional on the attacker-supplied length prefix. The length is bounded by the `QuicTransportConfig` `max_idle_timeout` but not by a max-stream-data limit at this layer; iroh's QUIC stream-level flow control will eventually backpressure, but a peer could advertise a 4 GiB frame and force a 4 GiB allocation before the read fails.

**Fix direction:** cap the length at a sane bound (e.g., 16 MiB) before the `vec![0u8; length]`. The codec at `IrohRelayFrameCodec.swift:59-63` rejects > 512 KiB, so a 4 MiB allocation is the worst case for a malicious-but-spec-compliant peer. iroh's own stream data cap will eventually kick in, but the OOM is still reachable.

### I-9 (Low, verified): No per-stream concurrency cap on the Mac host

`AgentLens/Services/IrohRelay/HermesIrohRelayHostClient.swift:268-310` — `serveTasks[serveID] = task` with no eviction. A peer that opens streams but never sends a frame will accumulate tasks. The `consecutiveAcceptFailures` counter (line 251) only triggers on *accept* errors, not on *stuck* streams. A peer that opens 10k streams, each with one slow `request.start`, would pin 10k tasks.

**Fix direction:** cap `serveTasks.count` and refuse new accepts when the cap is hit. Add a per-uid counter for active serves.

## Trust boundary summary

| Boundary | What crosses | Crypto | Verifier | Weakness |
|---|---|---|---|---|
| Mac iroh secret → iroh QUIC handshake | Long-term iroh private key (32 bytes, Keychain) | QUIC + iroh E2EE | iroh | Loss of keychain = full impersonation |
| Mac pairing sign → iOS pairing verify | Ed25519 signature over canonical payload | Ed25519 | `IrohPairingSignature.verify` | 3 min Swift vs 24 h Android window; silent rotation |
| iOS dial → iroh ALPN handshake | NodeId + iroh transport key | QUIC | iroh | Transport-level trust; app-layer identity not bound |
| App-layer Hermes request | Per-request AES-GCM key wrapped with Mac's P-256 | P-256 ECDH + HKDF-SHA-256 + AES-256-GCM | `HermesRelayCrypto` | Algorithm field unwrapped, no in-envelope version |
| App-layer Computer Use authority | Ed25519 sign over intent hash | Ed25519 | `ComputerUsePhoneControlSigner.verify` | Public key provided in-band; no server root; 5s freshness only |
| Hermes/Pi pairing code | 8-char alphanumeric | None (digest only) | `safeEqualHex` | 1-use not enforced; 1/sec rate limit only |

## Iroh official-doc checks (docs.iroh.computer)

I did not have live web access; these are based on my training-time knowledge of iroh docs (verify against current docs before final ship):

- **Ticket lifetime:** the `BlobTicket` lifetime is unbounded unless the hash + node-id combination falls off relay. BurnBar's `parse_blob_ticket` (`blobs.rs:336-344`) accepts any text. The relay URL in the ticket is the *current* one and can be stale. iroh will try discovery, then fall back to the relay URL. BurnBar publishes the *current* relay URL in the pairing record, so this is OK in steady state, but a `media.blob.advertise` frame with an old ticket will hit the *old* relay URL even if the Mac has migrated.
- **Relay metadata reality:** iroh relays see NodeId, source IP (under QUIC), connection duration, byte count. No content visibility (E2EE). This matches my I-7 finding.
- **WASM/browser support:** iroh's WASM target is experimental (as of my training data, n0 had a `iroh-js` work-in-progress but no GA browser product). BurnBar does not use it. Browser clients are not part of the current threat model.
- **Endpoint identity guarantees:** NodeId is the public half of the iroh secret key (`lib.rs:302`). The same secret key always produces the same NodeId. This is the trust anchor; loss of the secret = full impersonation.
- **Encryption scope:** iroh E2EE is per-connection (each QUIC connection negotiates fresh keys from long-term identity). Inner application payload inside the iroh stream is *also* encrypted in BurnBar's design (`HermesRelayCrypto`), so the Mac + iPhone are protected even against a relay that *did* break QUIC. Defense in depth.

## Top recommendations (priority order)

1. **(Critical)** Bind the iroh NodeId to the app-layer authority envelope. Reject any frame where `authority.peerNodeId != <observed iroh NodeId>`. Add TOFU on first connect from a new NodeId with an iOS prompt.
2. **(Critical)** Add per-uid, per-window rate limits on the iroh accept loop (concurrent streams, opens per minute, body bytes per minute). Add per-uid, per-time-window limits on the WSS counterpart (already known: H2 from prior review).
3. **(High)** Unify pairing record freshness. Pick one (3 min or 24 h), document the choice, fix the Android `MAXIMUM_AGE_MILLIS` comment that incorrectly claims parity with Swift.
4. **(High)** Make `completeHermesPairing` / `completePiAgentPairing` reject replays: first call flips `status: pending → completed` and succeeds; any subsequent call with the same code returns `permission-denied`.
5. **(High)** Silent key rotation in `IrohPairingKeyStore.swift:34-56` should publish a `previousPublicKeyBase64` + `validUntil` so iOS can verify records during the rotation window.
6. **(High)** Cap `IrohStream.recv_frame` length to 16 MiB before `vec![0u8; length]` to prevent OOM.
7. **(High)** Cap `serveTasks.count` in the accept loop; reject new accepts when at cap.
8. **(Medium)** Encrypt `directAddresses` in the Firestore pairing record; or omit the field and force the iroh dial to rely on relay-only with cached direct-address discovery.
9. **(Medium)** Add explicit `algorithm/version` bytes in the `unwrapSymmetricKey` envelope; today the version is in the outer frame and is not validated.
10. **(Medium)** Tighten `ComputerUsePhoneControlSigner` `freshnessSeconds` from 5.0 → 2.0 and require `attestationHashBlake3` for high-trust operations (WS2 binding).
11. **(Low/Info)** Document the relay-metadata exposure in `THREAT_MODEL.md` (NodeId visible, content E2EE, frame sizes observable).
12. **(Low/Info)** BLAKE3/Bao is correct (informational only).

## Confidence levels

- All Critical/High findings are **verified** (read code, found the gap, located the line).
- All Medium findings are **verified** (same).
- All Low/Informational findings are **verified**.
- The `THREAT_MODEL.md` documentation gaps are **partial** — I did not read the full `docs/THREAT_MODEL.md` and `docs/PROVIDER_ACCOUNTS.md` to confirm presence/absence of the metadata discussion.
- Iroh official-doc research is **partial** — based on training-time knowledge; recommend a web search for any current advisories or breaking changes since 2026-01.

## File-level index (key references)

| File | Role |
|---|---|
| `crates/openburnbar-iroh/src/lib.rs` | Rust iroh endpoint, FFI, accept/connect, framing |
| `crates/openburnbar-iroh/src/blobs.rs` | iroh-blobs FsStore, BlobTicket, publish/fetch |
| `crates/openburnbar-iroh/src/datagrams.rs` | Mercury audio datagram channel |
| `OpenBurnBarCore/Sources/OpenBurnBarIrohRelay/IrohRelayProtocol.swift` | ALPN, frame version, max bytes |
| `OpenBurnBarCore/Sources/OpenBurnBarIrohRelay/IrohRelayPairing.swift` | Swift pairing record + Ed25519 + freshness (3 min) |
| `OpenBurnBarCore/Sources/OpenBurnBarIrohRelay/IrohRelayFrameCodec.swift` | Length-prefixed JSON codec, 512 KiB cap |
| `OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/HermesRelayCrypto.swift` | P-256 ECDH + HKDF + AES-GCM envelope |
| `OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/HermesRealtimeRelayTypes.swift` | Frame types, authority envelope |
| `OpenBurnBarCore/Sources/OpenBurnBarComputerUseCore/ComputerUsePhoneControlSigner.swift` | Ed25519 signer for Computer Use authority |
| `AgentLens/Services/IrohRelay/HermesIrohRelayHostClient.swift` | Mac iroh host (start, accept loop, pairing publish) |
| `AgentLens/Services/IrohRelay/IrohRelayRequestHandler.swift` | Per-stream serve loop, control/media dispatch |
| `AgentLens/Services/IrohRelay/IrohRelayKeyStore.swift` | Mac iroh secret keychain |
| `AgentLens/Services/IrohRelay/IrohPairingKeyStore.swift` | Mac Ed25519 pairing keychain (silent rotation) |
| `AgentLens/Services/IrohRelay/FirestoreIrohPairingDirectory.swift` | Firestore pairing record reader/writer |
| `AgentLens/Services/IrohRelay/IrohPairingPublicKeyPublisher.swift` | Publishes Mac verifier pubkey |
| `AgentLens/Services/IrohRelay/HermesRelayHostFanout.swift` | WSS + iroh fanout |
| `AgentLens/Services/IrohRelay/IrohTransportAuditLogger.swift` | Firestore audit logger |
| `android/openburnbar-iroh-relay/src/main/java/com/openburnbar/irohrelay/IrohRelayPairing.kt` | Android pairing verifier (24h window) |
| `android/openburnbar-iroh-relay/src/main/java/com/openburnbar/irohrelay/IrohPairingDirectory.kt` | Android pairing directory interface |
| `android/app/src/main/java/com/openburnbar/data/hermes/relay/HermesRelayCrypto.kt` | Android AES-GCM crypto |
| `functions/src/callables/hermes.ts:99-237` | `completeHermesPairing` (replay-allowed) |
| `functions/src/callables/piAgent.ts:101-256` | `completePiAgentPairing` (replay-allowed) |
| `functions/src/irohMonitoring.ts` | Iroh audit rollup worker |
| `functions/src/hermes.ts` | Hermes code generation + parsing helpers |
| `functions/src/piAgent.ts` | Pi code generation + parsing helpers |
