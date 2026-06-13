> **CONFIDENTIAL — BurnBar security package.** Independently code-verified at HEAD `5416ef780`. Share with Cure53 out-of-band; do not publish. Generated — see `_evidence/` for raw findings.

# Abuse Cases (Phase 7)

This document is the adversary's view of BurnBar / OpenBurnBar. Where the threat register (`threat-register.md`), the per-claim verdicts (`_evidence/_claims.json`), and the framework lenses (`agentic-ai-threat-model.md`, `privacy-threat-model.md`, `cloud-and-ops-threat-model.md`) decompose the system control-by-control, this file recomposes it **attacker-by-attacker**: for each realistic threat actor and each high-value misuse goal, it walks the kill-chain, draws the attack tree, names the assets at stake, cites the controls that stand in the way (with `file:line` pulled from `_evidence/`), states the gaps the attacker exploits, and prescribes the tests and mitigations.

> **Diagram convention:** the attack trees below are intentionally rendered as ASCII for legibility and diff-stability — they are not Mermaid. Every other diagram-bearing file in this package uses Mermaid; this file deliberately does not.

Every abuse case ties to **canonical threat IDs** (`T-*`), **components** (C1–C16), **trust boundaries** (B1–B9, B2-iroh) and **claim verdicts** (C1–C14) from `_evidence/_INDEX.md`. **CODE is source of truth**; where a control is "register-claimed, not re-verified here" or depends on deployed config, it is flagged. Conservative posture throughout: a protection is stated as a guarantee only where code enforces it, otherwise as "not currently guaranteed".

## Threat actors (canonical, referenced throughout)

| Actor | Capability | Trust posture | Primary boundaries crossed |
|---|---|---|---|
| **A-RELAY** Cloud relay / n0 relay data-plane (C7) | Sees ciphertext + IP/NodeId/size/timing metadata; can drop/delay/reorder; cannot decrypt | Untrusted (B2, B5, B2-iroh) | B2, B5, B2-iroh |
| **A-CLOUD** Compromised Firebase backend / rogue admin (C8) | Admin-SDK Firestore/Storage read+write (bypasses rules); writes trust-root docs; serves arbitrary key bytes; KMS-decrypt for provider creds | Untrusted for content; trusted for availability/ordering/authz-metadata | B2, B3, B5, B7, B2-iroh |
| **A-NET** On-path network adversary | Drop/blackhole/inject at IP layer; cannot break QUIC/TLS1.3 or HPKE | Untrusted | B2-iroh, B2 |
| **A-EXT** External account-takeover attacker | Holds a victim's Firebase credential or a stolen Gateway bearer; no pinned signing key, no device | Untrusted | B2, B5 |
| **A-MOBILE** Attacker on a compromised iOS/Android device (C4/C5) | App-context code on unlocked device; root/forensic on lost device | Endpoint compromise (B4) | B3, B4 |
| **A-DESK** Attacker on a compromised Mac (C1/C2) | Same-uid code execution; first-party code-sign or injection into signed app | Endpoint compromise (B1) | B1, B6 |
| **A-CONTENT** Untrusted content author (web/doc/email/repo/log) (C16-adjacent) | Plants text that reaches model context via tool output, RAG, oracle, or CLI ingest | Untrusted (B6) | B6 |
| **A-PEER** Malicious paired/queued peer or write-capable namespace actor | Writes to victim's own namespace (compromised session) or is an admitted controller | Semi-trusted post-admission | B3, B4, B5 |
| **A-SUPPLY** Supply-chain adversary (C15) | Moves a mutable action tag, lands a malicious dep, or coerces the sole CODEOWNER | Untrusted upstream | B8 |
| **A-MODEL** Model provider / AI service (C16) | Sees all plaintext routed to it; returns attacker-influenceable output | Untrusted third party by design | B6, B9 |
| **A-AGENT** Rogue / hijacked agent runtime (C10) | A model the runtime obeys, steered by injection, acting within granted scope | Trusted endpoint that can be subverted | B6 |

---

## AC-1 — Cloud Relay Compromise

**Actor:** A-RELAY (n0 relay / hosted relay data-plane, C7) and the iroh transport (C6). **Boundaries:** B5 (Gateway↔Agent), B2 (Device↔Cloud), B2-iroh. **Claims:** C1, C8, C12. **Threats:** T-TRN-03, T-TRN-04, T-TRN-06, T-CRY-01, T-CRY-03.

### Narrative
The relay is a blind store-and-forward / packet-mux node. The design intent (`_INDEX.md` B5, B7) is that it sees only ciphertext and routing metadata. This abuse case asks the seven adversary questions a relay operator would ask: can it **read**, **alter**, **replay**, **drop**, **impersonate**, harvest **metadata**, or **target** a specific user? The answer is "no read / no alter / no replay / no impersonate" but **yes drop, yes rich metadata, yes target**, plus a cheap **downgrade** that moves traffic onto the more-observable cloud path.

### Attack tree
```
GOAL: Relay subverts a phone⇄Mac / phone⇄agent exchange
├─ READ payload bytes ............................... BLOCKED
│   └─ iroh QUIC/TLS1.3 hop encryption (lib.rs:302-310) +
│       app-layer HPKE E2E seal (IrohRelayRequestHandler.swift:303,959)
│       → relay holds no recipient private key (C1 Defensible)
├─ ALTER payload in flight ......................... BLOCKED
│   └─ HPKE-Auth AEAD tag, AAD binds uid|conn|requestID|op|counter|keyID
│       (HermesRelayAuthenticatedRequest.swift:230-246); QUIC integrity
├─ REPLAY a captured frame ......................... BLOCKED (live) / window (at-rest)
│   ├─ live: monotonic counter + requestID 24h dedup (…:123-141) ⇒ senderReplay
│   └─ CAVEAT C12: at-rest re-serve of old valid envelope (no revision) — A-CLOUD, not relay
├─ DROP / blackhole frames ......................... ACHIEVABLE
│   └─ forces silent iroh→Firestore downgrade for all ops except
│       .chatCompletions (HermesCompositeRelayTransport.swift:64,108) [T-TRN-03]
├─ IMPERSONATE a paired device ..................... BLOCKED for relay data-plane
│   └─ would need pinned sender private key / Admin-SDK trust-root write (A-CLOUD path → AC-2)
├─ METADATA harvest ................................ ACHIEVABLE [T-TRN-04]
│   └─ NodeIds (never rotated), relay URL, direct IPs, sizes, timing in plaintext Firestore
│       (FirestoreIrohPairingDirectory.swift:42-81; audit …:441-447)
├─ DOWNGRADE crypto v3→v2 ......................... CONDITIONAL [T-CRY-01]
│   └─ if relay can write client record supportsRelayEnvelopeVersions=[2]
│       (HermesGatewayAPI.swift:1229-1230) — needs write to owner namespace
└─ TARGET a specific user / DoS ................... ACHIEVABLE [T-TRN-06]
    └─ connection flood reaches accept_one pre-allowlist (lib.rs:450), no rate cap
```

### Impacted assets
- **Availability** of the P2P control channel and CLI streams (drop/downgrade).
- **Metadata confidentiality / unlinkability**: persistent NodeIds, home relay region, LAN/WAN IPs, presence and usage timing (LINDDUN Linkability/Identifiability).
- **Crypto strength margin** (v3→v2 downgrade) — cryptanalytic margin only, no plaintext break.
- *Not* payload confidentiality or integrity (protected by the independent E2E layer).

### Current controls (file:line)
- E2E payload seal independent of transport — `IrohRelayRequestHandler.swift:303,959`; relay holds no private key (claim C1 **Defensible**).
- QUIC TLS1.3 + NodeId = Ed25519 pubkey, cryptographically bound on connect — `crates/openburnbar-iroh/src/lib.rs:302-310,430,481`.
- Live replay defeated by counter+requestID — `HermesRelayAuthenticatedRequest.swift:123-141,230-268`.
- Selected-model chat **hard-fails** rather than silently downgrading — `HermesCompositeRelayTransport.swift:119-121,126-132`; every fallback audited `:134-148`.
- iOS dials NodeId+relayURL only, suppresses published direct IPs — `HermesIrohRelayTransport.swift:449-453`.
- Frame cap 512 KiB both directions — `lib.rs:47,109,172,203`.

### Gaps
- **Silent automatic downgrade** for control-plane + CLI streams; no in-code fallback-rate alarm (T-TRN-03).
- **Raw persistent NodeIds + relay URL + direct IPs** stored plaintext in Firestore pairing/audit docs; NodeIds never rotate (T-TRN-04).
- **No connection-rate limit / concurrent-handshake cap** in the Rust crate; allowlist rejection is post-handshake (T-TRN-06).
- **No crypto version floor**: once v3 is negotiated nothing refuses a later v2 (T-CRY-01); `_emit_version_or_refuse` unmerged (CURE53 T-GW-5).

### Recommended tests
1. Blackhole all iroh UDP for a session; assert non-chat ops silently fall back to Firestore and that a fallback-rate alarm fires (currently expected to be absent).
2. Confirm `.chatCompletions` hard-fails (no reroute) when iroh is dropped.
3. Replay a captured live HPKE-Auth frame; assert `senderReplay`.
4. Flood `accept_one` with non-allowlisted dials; measure CPU/Firestore-read amplification (expect no cap).
5. As a namespace-writer, set `supportsRelayEnvelopeVersions=[2]`; assert the phone still seals v2 (downgrade) and capture whether any floor refuses it.
6. Read `iroh_pairing*`/audit docs as a metadata-only observer; enumerate NodeId↔IP↔timing correlation.

### Recommended mitigations
- Emit a client-side and server-side **fallback-rate alarm**; treat sustained iroh→Firestore fallback as an integrity event, not a silent degrade (closes T-TRN-03 observability gap).
- Add a **per-source connection-rate / concurrent-handshake cap** in `crates/openburnbar-iroh` before `accept_one` (T-TRN-06).
- **Rotate NodeIds** periodically and minimize raw IP/relay-URL persistence in Firestore (T-TRN-04, LINDDUN).
- Land `_emit_version_or_refuse` — a **monotonic crypto-version floor** that refuses v2 once v3 is registered (T-CRY-01).

---

## AC-2 — Malicious Cloud Administrator

**Actor:** A-CLOUD (rogue Firebase admin / Firebase-project takeover, C8). **Boundaries:** B2, B3, B5, B7, B2-iroh. **Claims:** C1, C2, C5, C8, C9, C11, C12, C13. **Threats:** T-TRN-01 (Critical), T-PTR-03, T-TRN-02, T-CVS-01, T-CVS-02, T-AZ-03, T-AZ-05, T-AZ-06.

This is the highest-leverage actor in the package: the Admin SDK **bypasses Firestore rules** (B2 caveat), and the relay-receive trust resolver and the iOS iroh host-key provider both read their trust anchors **from Firestore without local re-verification**. The honest-but-curious cloud model holds for *reading content*; it fails for *substituting trust roots*.

### Attack tree
```
GOAL: Malicious cloud admin reads or hijacks a victim
├─ READ message/vault bodies ....................... BLOCKED (current writes)
│   └─ ciphertext-only; no server decrypt primitive (C1/C2); BUT:
│       ├─ legacy plaintext schema-1 docs server-readable (C1 caveat, C2 caveat)
│       └─ metadata always plaintext (T-AZ-03): IDs/timestamps/sizes/deviceIds
├─ MITM the iroh control channel ................... ACHIEVABLE [T-TRN-01 CRITICAL]
│   └─ write users/{uid}/iroh_pairing_keys/host = attacker key + signed record
│       at attacker NodeId; iOS TOFUs whatever Firestore returns
│       (FirestoreIrohPairingPublicKeyProvider.swift:27-47, in-memory only, never pinned)
│       → phone dials attacker QUIC endpoint (HermesIrohRelayTransport.swift:385)
│       └─ payload confidentiality SURVIVES via independent E2E seal (defense-in-depth)
├─ IMPERSONATE a paired device to the agent ........ ACHIEVABLE (admin-SDK) [C8 Partial]
│   └─ forge relay_sender_keys + flip escrow_devices.trustState (admin-SDK,
│       bypasses rules:2782-2784); relay opener trusts cloud trustState directly
│       (HermesRelaySenderTrustResolver.swift:59-104) — NOT re-verified by the
│       CloudVaultTrustedDeviceChainVerifier the other subsystems use
├─ ADMIT attacker controller / lock out owner ...... ACHIEVABLE [T-TRN-02]
│   └─ inject controllers/{attackerNodeId} (admin-SDK) → Mac accept set; delete = DoS
├─ FORGE pairing record / substitute trust root .... ACHIEVABLE [C9 Partial]
│   └─ server is sole writer of host key + records, never verifies the Ed25519 sig
│       on publish (computerUseSecurity.ts:1755-1772) → iOS TOFU-trusts it
├─ STRIP signal envelope → force legacy decode ..... ACHIEVABLE (latent) [T-CVS-01/02]
│   └─ delete signalEnvelope field → reader fallthrough to unauthenticated legacy
├─ ROLL BACK at-rest content ....................... ACHIEVABLE [C12 Partial]
│   └─ re-serve old valid at-rest envelope at same path (no revision/seq binding)
└─ RECONSTRUCT provider creds ...................... ACHIEVABLE (by design) [C10]
    └─ KMS-decrypt + Secret-Manager-access IAM → plaintext in memory (envelope, not E2E)
```

### Impacted assets
Trusted-device graph integrity; iroh control-channel routing; relay sender-authentication; provider API credentials (server-decryptable); legacy plaintext bodies; **all cloud-visible metadata** (the cloud's by-design view). Payload bodies of *current* writes remain sealed.

### Current controls (file:line)
- No server-side decrypt primitive for current Gateway/vault bodies — claim C1 **Defensible**, C2 **Partial** (`hermesGateway.ts:188-190`, `CloudVaultCrypto.swift:438-466`).
- Trust-root docs are rules-locked `if false` (admin-SDK only) — `firestore.rules:2665,2677,2774,2784`; XEdDSA trust-chain verified server-side and **client-re-verified from key bytes** for vault/sync/computer-use paths — `CloudVaultTrustedDeviceChainVerifier.swift:151-199`.
- Bootstrap self-approval hard-requires a fresh single-use nonce — `computerUseSecurity.ts:1334`.
- Provider creds envelope-encrypted (KMS-wrapped DEK) into Secret Manager; Firestore holds only the version name — claim C10 **Defensible** (`secrets.ts:98-122`).
- E2E relay seal means even a successful iroh MITM cannot read payloads (T-TRN-01 residual).

### Gaps
- **T-TRN-01 (Critical):** iOS host-pairing key is **in-memory TOFU, never pinned/persisted** — asymmetric vs the Keychain-pinned Mac→phone controller key.
- **C8 break:** the **relay-receive path** trusts cloud-written `relay_sender_keys` + `trustState` **without** invoking the local trust-chain verifier (`HermesRelaySenderTrustResolver.swift:59-104`).
- Server **never verifies the pairing-record signature on publish** (C9) and is the sole writer of the trust root.
- Legacy plaintext bodies and **at-rest rollback** remain server-reachable (C1/C2/C12 caveats); App Check console enforcement **UNKNOWN from repo** (T-AZ-06).

### Recommended tests
1. As admin-SDK, swap `iroh_pairing_keys/host` to an attacker key on a cold-start iOS session; confirm the phone dials the attacker NodeId (T-TRN-01).
2. As admin-SDK, write a forged `relay_sender_keys` doc + flip `trustState`; confirm the relay opener accepts attacker-sealed v3 frames (C8 break) — and that the trust-chain verifier is **not** consulted on this path.
3. Inject `controllers/{attackerNodeId}`; confirm Mac admits it at transport layer (T-TRN-02).
4. Delete a victim's `signalEnvelope` field; confirm reader falls through to unauthenticated legacy (T-CVS-01).
5. Re-serve a stale at-rest envelope at the same path; confirm it decrypts (C12 rollback).
6. Enumerate which service accounts hold `cloudkms.cryptoKeyDecrypter` + `secretmanager.secretAccessor` (deployed-IAM open question).

### Recommended mitigations
- **Pin the iOS host pairing key** in Keychain with a safety-code / out-of-band confirmation; refuse silent cold-start key substitution (closes T-TRN-01, the package's #1 finding).
- **Wire `CloudVaultTrustedDeviceChainVerifier` into `FirestoreHermesRelaySenderTrustResolver`** so the relay path stops trusting the cloud's `trustState` flag (closes C8 break).
- Add a **monotonic revision/sequence binding** to the at-rest `SignalBinding` (closes C12 rollback / RR-8).
- Remove the **legacy plaintext read fallback** floor once backfill converges; add a **per-doc Signal-required pin** so envelope-strip is distinguishable (T-CVS-01/02).
- Confirm and document **App Check console enforcement** and least-privilege IAM split between relay data-plane and control-plane service accounts (T-AZ-06; the relay-vs-control credential separation directly bounds the C8 break — see `_claims.json` C8 gap).

---

## AC-3 — External Account Takeover

**Actor:** A-EXT (attacker with a stolen Firebase credential or stolen Gateway bearer, but no pinned signing key and no enrolled device). **Boundaries:** B2, B5. **Claims:** C4 (Defensible), C8, C11, C12. **Threats:** T-GW-01, T-AZ-05, T-AZ-06, T-PTR-04.

### Narrative
A-EXT phishes a Firebase ID token or steals a Gateway bearer token (e.g. from a log, a proxy, or a compromised non-pinned client). The question is whether holding *a* credential lets them act. For the **bearer surface** the answer is firmly **no** — proof-of-possession of the pairing-pinned Ed25519 key is mandatory and the key is server-immutable. For the **Firebase-auth surface** the answer is **bounded**: object-authz holds at the rules layer, but App Check is a console toggle and a captured-but-valid device-approval flow could enroll a device the human never confirmed.

### Attack tree
```
GOAL: A-EXT acts as the victim
├─ Replay stolen Gateway bearer alone .............. BLOCKED [C4 Defensible]
│   └─ every active route also requires Ed25519 PoP over the pinned key
│       (hermesGateway.ts:845, 693-757); missing key ⇒ 401 legacy_pop_required
├─ Rewrite the pinned signing key to attacker's .... BLOCKED
│   └─ hermes_gateway_clients write:if false (rules:2580-2582); token_index read,write:if false
├─ Direct Firestore/Storage SDK with stolen ID tok . CONDITIONAL [T-AZ-06]
│   └─ rules require request.auth but App Check is a CONSOLE toggle absent from repo
│       → if App Check OFF, a non-app client can hit the ruleset
├─ Cross-user read via IDOR ........................ BLOCKED at rules / bounded at callables
│   └─ ownsUserNamespace gate everywhere (rules:52-54); see AC-10
├─ Enroll an attacker device via captured approval .. CONDITIONAL [T-PTR-04]
│   └─ approve-time OOB safety-code compare defaults OFF
│       (EscrowDeviceSafetyCode.swift:202) → human never visually confirms
└─ Read cross-tenant avatars ....................... ACHIEVABLE (low) [T-AZ-01]
    └─ avatars/{userId}/profile.jpg allow read: if auth != null (storage.rules:18)
```

### Impacted assets
The victim's account session, device-enrollment graph, and (if App Check is off) direct datastore reachability. Profile photos (low sensitivity, enumerable).

### Current controls (file:line)
- Mandatory per-request PoP on every active Gateway route; auth-before-authz ordering — `hermesGateway.ts:845-857,693-757` (claim C4 **Defensible**, High confidence).
- Signing-key pin is server-only and immutable to token holders — `firestore.rules:2580-2582`, `:4250-4251`; rotation refuses to strip PoP — `hermesGateway.ts:2217-2222`.
- Universal owner gate on every private read — `firestore.rules:52-54`; callables derive uid from token and `assertOwnership` — `auth.ts:22-31`.
- Callables fail-closed in prod without App Check — `config.ts:78-84`.

### Gaps
- **App Check console enforcement UNKNOWN from repo** (T-AZ-06): a stolen ID token reaching the SDK datapath directly is a deployed-config question.
- **Approve-time safety-code compare defaults OFF** (T-PTR-04): a captured-but-valid approval admits a device with no human OOB confirmation.
- **Cross-tenant avatar read** (T-AZ-01) and the `users/{uid}` root-doc allowlist gap (`_INDEX.md` T-AZ).

### Recommended tests
1. Replay a stolen bearer with no PoP header → expect 401; replay with a forged PoP → expect `bad_pop_signature`.
2. With App Check disabled in a test project, hit Firestore directly with a stolen ID token and a non-app client; observe reachability (T-AZ-06).
3. Capture a device-approval flow and replay it with the safety-code gate at default; confirm a device enrolls without human OOB confirmation (T-PTR-04).
4. Enumerate `avatars/*/profile.jpg` as an arbitrary authenticated user (T-AZ-01).

### Recommended mitigations
- **Confirm and enforce App Check** in the console for all SDK datapaths; capture the deployed state as evidence (resolves T-AZ-06, the dominant external-ATO uncertainty).
- **Default the approve-time OOB safety-code compare ON** (T-PTR-04).
- Scope avatar reads to the owner or accept the risk explicitly in product copy (T-AZ-01).

---

## AC-4 — Pairing Attack

**Actor:** A-CLOUD / A-RELAY / A-PEER at first or cold pairing. **Boundaries:** B3 (Device↔Device), B2-iroh. **Claims:** C8, C9, C12. **Threats:** T-TRN-01 (Critical), T-PTR-03 (High), T-TRN-05, T-PTR-04, T-PTR-05, T-TOOL-06, T-CRY-02.

### Narrative
Pairing establishes the trust roots that every later control inherits. BurnBar's pairing is **TOFU relayed through the untrusted cloud**: there is no user-verified safety number at first contact for the Gateway/vault key exchange, and the iOS iroh host key is never persistently pinned. An attacker who controls the cloud at the moment of (first or cold) pairing — or who replays a still-fresh record — can poison the trust root that the rest of the system treats as authoritative. The Mac→phone controller direction *is* Keychain-pinned and safety-code-gated (asymmetric, in the user's favor on that leg).

### Attack tree
```
GOAL: Poison or hijack a pairing trust root
├─ Cloud substitutes iOS host pairing key .......... ACHIEVABLE [T-TRN-01 CRITICAL]
│   └─ in-memory TOFU, never Keychain-pinned (FirestoreIrohPairingPublicKeyProvider.swift:27-47)
├─ Cloud forges a signed pairing record ............ ACHIEVABLE [C9 Partial]
│   └─ server never verifies Ed25519 sig on publish (computerUseSecurity.ts:1755-1772)
├─ Replay a still-fresh pairing record ............. WINDOW (~3 min) [T-TRN-05]
│   └─ verify() enforces only publishedAtMillis age ≤180s vs local clock; no nonce/counter
│       (IrohRelayPairing.swift:133-168, freshness :69-75)
├─ Cross-tenant pairing spoof (another user) ....... BLOCKED [C9]
│   └─ canonical payload binds uid; records under users/{uid}/...; rules create:if false
├─ Controller-key first-pairing poison ............. CONDITIONAL [T-PTR-05]
│   └─ first controller key pinned unconfirmed; only if enforcement flag force-OFF
│       (ControllerKeyPinStore.swift:199-212, override :94)
├─ Queued-grant authority key pre-seed ............. CONDITIONAL [T-TOOL-06]
│   └─ agent_grant_authorities/{deviceId} cloud doc TOFU before first pin
├─ Pi-agent relay request forgery (no sender auth) .. ACHIEVABLE in-namespace [T-CRY-02]
│   └─ v1 wrap binds no sender (PiAgentCloudRelayHostService.swift:336-340)
└─ Approve a device the human never confirmed ...... CONDITIONAL [T-PTR-04]
    └─ approve-time safety-code compare default OFF (EscrowDeviceSafetyCode.swift:202)
```

### Impacted assets
The iroh control-channel routing identity, the Gateway relay sender-key pin, the controller-key pin, the queued-grant authority key, and the escrow trust graph — i.e. **every downstream authority decision** that trusts a pairing-time root.

### Current controls (file:line)
- iOS verifies the Mac's Ed25519-signed pairing record + 3-min freshness before dialing, fail-closed — `IrohRelayPairing.swift:133-168`, `HermesIrohRelayTransport.swift:385`.
- Trust-root docs server-owned, client direct-write denied — `firestore.rules:2665,2677,2774,2784`.
- Trust elevation needs a **distinct trusted native approver's** server-verified XEdDSA sig, client-re-verified from key bytes — `computerUseSecurity.ts:1263-1290,1396,1411`; `CloudVaultTrustedDeviceChainVerifier.swift:151-199`.
- Server fingerprint→key-bytes binding enforced fail-closed — `computerUseSecurity.ts:270,1248`.
- Mac→phone controller key Keychain-pinned, mismatch always refused, safety-code gate default ON — `ControllerKeyPinStore.swift:96,198`, `PhoneControlAuthorityValidator.swift:202-225`.
- F1 controller pin rejects a queued-grant authority key differing from the operator-pinned key — `AgentCapabilityGrantQueueListener.swift:81`.

### Gaps
- **No TOFU/safety-code pinning of the iOS host pairing key** (T-TRN-01/T-PTR-03) — the asymmetry vs the Mac-side pin is the core defect.
- **No per-record nonce/monotonic counter** on the pairing record; freshness relies on the client clock (T-TRN-05).
- **Approve-time OOB safety-code compare defaults OFF** (T-PTR-04); the enforcement flags can be UserDefaults/MDM-overridden (T-PTR-05).
- Pi-agent relay lane has **no sender authentication** (T-CRY-02).

### Recommended tests
1. Cold-start the iOS app and serve a swapped `host` key from a test backend; assert the phone dials the attacker (T-TRN-01).
2. Capture a signed pairing record and replay it within 180s at a reassigned NodeId; assert it is honored (T-TRN-05).
3. Force-disable `ControllerKeyPinEnforcementFlag` via UserDefaults and present a relay-supplied controller key on first contact (T-PTR-05).
4. Pre-seed `agent_grant_authorities/{deviceId}` before first pin, then submit a forged signed grant (T-TOOL-06).
5. Mint a Pi-agent relay request from a namespace-writer with only the recipient's public key (T-CRY-02).

### Recommended mitigations
- **Keychain-pin the iOS host pairing key** + surface a **user-verified safety number / QR at first pairing** (closes T-TRN-01/T-PTR-03/C9 TOFU root; this is the single highest-value pairing fix).
- Add a **per-record nonce + monotonic counter + session-challenge binding** to pairing records (T-TRN-05/C12).
- **Default the approve-time safety-code compare ON** and resist override (T-PTR-04/05).
- Add **sender authentication** to the Pi-agent relay request lane (T-CRY-02).

---

## AC-5 — Compromised Mobile Device

**Actor:** A-MOBILE (app-context code on an unlocked iOS/Android device, or root/forensic on a lost device, C4/C5). **Boundaries:** B4, B3. **Claims:** C2, C5, C7, C13. **Threats:** T-CVS-03 (High), T-AND-01, T-AND-02, T-AND-04, T-AND-05, T-AND-06, T-ATT-02, T-PTR-01.

### Narrative
The endpoint is **intentionally in scope for plaintext** (`_INDEX.md` §8). The phone holds identity/vault private keys and decrypted content. The abuse case quantifies what an attacker who reaches app context (malware, jailbreak/root, or a lost-but-unlocked device) gets, and what remains protected.

### Attack tree
```
GOAL: Exfiltrate from a compromised phone
├─ Extract vault/identity/relay private keys ....... ACHIEVABLE on unlocked/rooted [T-CVS-03 / T-AND-01]
│   ├─ iOS: WhenUnlockedThisDeviceOnly, no biometric/SecAccessControl on signing key
│   └─ Android: AndroidKeyStore wrap w/o user-auth/StrongBox; raw blobs in SharedPreferences
│       → forge sender-auth + decrypt ALL at-rest (no PFS to bound blast radius)
├─ Read plaintext received media .................. ACHIEVABLE (iOS) [T-ATT-02]
│   └─ iOS receive omits seal-at-rest + quarantine + capability gate (handleAdvertise:135-208)
├─ Retain decryption past revocation .............. WINDOW [T-PTR-01 / C5 Partial]
│   └─ cached vault key keeps decrypting until a survivor Mac completes rotation;
│       no claw-back; revoked device keeps its Firebase session
├─ MITM via cleartext HTTP (Android) .............. CONDITIONAL [T-AND-02]
│   └─ base-config permits HTTP to non-deny-listed hosts on hostile network
├─ Harvest from crash/observability pipeline ...... LOW [T-AND-06 / C13 Partial]
│   └─ Sentry/Crashlytics no reviewed beforeSend PII scrub
└─ Read Remote-Unlock saved credential ............ BLOCKED (Keystore auth) [T-AND-05]
    └─ setUserAuthenticationRequired(true) forces fresh auth on decrypt
```

### Impacted assets
The full at-rest corpus reachable from the device (conversations, sessions, memory, vault key), sender-authentication forgery capability, received media, and the cached-key window of pre-revocation content.

### Current controls (file:line)
- Device-only Keychain accessibility blocks iCloud/backup exfil; Android Keystore-wrapped non-exportable key, `allowBackup=false`, `FLAG_SECURE` — T-CVS-03 / T-AND-01 mitigations (`_threats.tsv`).
- Revoke severs grants/controllers/sessions immediately and queues rotation — `computerUseSecurity.ts:1456-1591`; survivor rotation re-keys so the revoked device cannot derive new material (C5 **Partial**).
- Remote-Unlock credential gated by `setUserAuthenticationRequired(true)` — T-AND-05.
- Push bodies are generic; logs/crash key-redacted — claim C13 **Partial** (`agentNotifications.ts:310`, `AppLogger.swift:45-103`).

### Gaps
- **Keys extractable on a compromised unlocked endpoint** — no hardware-bound non-extractable signing, no per-use auth, **no PFS** to bound blast radius (T-CVS-03, the headline mobile gap).
- **iOS received media stored plaintext** with no seal/quarantine/gate (T-ATT-02).
- **No claw-back** of pre-revocation cached keys; rotation is client-driven and Mac-dependent (T-PTR-01/02, C5).
- **Android cleartext HTTP** to non-deny-listed hosts (T-AND-02); crash pipeline PII scrub unreviewed (T-AND-06).

### Recommended tests
1. On a jailbroken iOS / rooted Android device, dump SharedPreferences/Keychain and attempt to unwrap the vault key and forge a `senderAuth` (T-CVS-03/T-AND-01).
2. Receive a Mercury transfer on iOS; inspect the Caches inbox for plaintext + missing FileProtection (T-ATT-02).
3. Revoke a phone, keep it offline, and confirm it still decrypts pre-revocation synced content until a Mac survivor rotates (T-PTR-01).
4. On a hostile Wi-Fi, drive an Android SDK/image-loader/relay host not in the deny list over HTTP (T-AND-02).

### Recommended mitigations
- Move signing/identity keys to **hardware-bound, non-extractable, per-use-auth** storage (Secure Enclave with `.biometryCurrentSet`; Android StrongBox + user-auth) and add **forward secrecy** to bound endpoint-compromise blast radius (T-CVS-03/T-AND-01).
- Apply **seal-at-rest + quarantine + capability gate + FileProtection.complete** to the iOS Mercury receive path (T-ATT-02).
- Add **server-driven or push-forced rotation** so the cached-key window does not depend on a Mac foregrounding; consider invalidating the revoked device's Firebase session (T-PTR-01/02).
- Tighten the Android `network_security_config` to LAN-only / deny cleartext broadly; add a reviewed Sentry `beforeSend` scrubber (T-AND-02/06).

---

## AC-6 — Compromised Desktop

**Actor:** A-DESK (same-uid code execution on the Mac; first-party code-sign or injection into the signed app, C1/C2). **Boundaries:** B1, B6. **Claims:** C2, C6, C7, C10, C13. **Threats:** T-DMN-01..T-DMN-08, T-CVS-03, T-TOOL-02/03.

### Narrative
The Mac is the canonical store and runs the agent runtimes that necessarily see plaintext. B1 documents that **all same-uid processes are equally trusted**, the app and daemon are **unsandboxed** in Developer-ID builds, and the daemon treats a **valid first-party code signature as authorization** with no capability attenuation. This abuse case is the blast-radius analysis of a single same-uid / signed-app compromise.

### Attack tree
```
GOAL: Full local agency from a same-uid / signed-app foothold
├─ Drive full daemon RPC (run/config/creds) + HID .. ACHIEVABLE [T-DMN-01 High]
│   └─ code inside/injected into signed app passes DR gate; no per-op attenuation
├─ Operate with no OS sandbox boundary ............. ACHIEVABLE [T-DMN-02 High]
│   └─ App Sandbox=false on Dev-ID app + daemon (OpenBurnBar.entitlements:24-26)
├─ Bypass phone single-use local-auth proof ........ ACHIEVABLE if app compromised [T-DMN-04]
│   └─ daemon does NOT re-verify the proof; trusts app to have stepped up
├─ Swap the daemon binary (TOCTOU) ................. WINDOW [T-DMN-03]
│   └─ user-writable path; launchd re-execs without re-verifying signature
├─ Disable peer code-sig gate via env var .......... CONDITIONAL [T-DMN-05]
│   └─ OPENBURNBAR_DAEMON_DISABLE_PEER_CODESIG=1 drops main-socket gate
├─ Extract vault/identity keys ..................... ACHIEVABLE [T-CVS-03]
│   └─ unlocked endpoint reads raw key bytes (no per-use auth, no PFS)
└─ Injection → RCE under YOLO/trusted .............. ACHIEVABLE [T-TOOL-02 Critical]
    └─ runShellUnrestricted /bin/zsh unsandboxed (see AC-8)
```

### Impacted assets
The entire local domain: local SQLite store, vault/identity/relay keys, provider credentials (plaintext on-device), HID input authority, and the agent runtimes — i.e. **everything**. Endpoint compromise defeats confidentiality by design (`_INDEX.md` §8).

### Current controls (file:line)
- Main + HID socket peer auth via Designated Requirement (Apple anchor + Team ID + exact identifier), hardened-runtime + library-validation enforced programmatically — `PrivilegedSocketTrust.swift:69-71,190-198`; gate runs before any RPC — `OpenBurnBarDaemonServer.swift:580-595`.
- Constant-time bearer token, secrets via launchd env not argv, rotated per reinstall — `OpenBurnBarDaemonServer.swift:365-383`, `OpenBurnBarDaemonManager+Lifecycle.swift:220-232,313-322`.
- Socket-dir squat defense (0700, uid-owned, real dir) — `PrivilegedInputExecutionSocketServer.swift:84-109`.
- HPKE credential envelopes bind request context, recipient re-derives info pre-decrypt — `RemoteUnlockCredentialEnvelopeCrypto.swift:95-106`.
- Single-use local-auth proof bound to canonical op hash (app/relay layer) — `PhoneControlAuthorityValidator.swift:432-454,475-548`.

### Gaps
- **Code-sign identity == authorization; no per-RPC capability attenuation; no OS sandbox** (T-DMN-01/02) — one signed-app RCE = full local agency + credential access.
- **Daemon does not re-verify the phone proof** (T-DMN-04) — proof binding only as strong as app integrity.
- **User-writable daemon binary / launchd no re-verify** (T-DMN-03); **prod env escape hatch** disables the peer gate (T-DMN-05).
- Vault/identity keys **extractable** on unlocked endpoint (T-CVS-03).

### Recommended tests
1. Inject a dylib into a signed-but-vulnerable first-party app (or run signed code) and exercise full main-socket RPC; confirm no per-op attenuation (T-DMN-01).
2. Swap the on-disk daemon binary between the app's `validateStaticCode` and launchd exec (T-DMN-03).
3. Set `OPENBURNBAR_DAEMON_DISABLE_PEER_CODESIG=1` in the daemon launch env; confirm the main-socket gate drops to `.disabled` (T-DMN-05).
4. With the app compromised, dispatch a high-risk grant and confirm the daemon does not re-verify the single-use proof (T-DMN-04).

### Recommended mitigations
- Add **per-RPC capability attenuation** at the daemon (least authority per signed peer) and a **runtime seatbelt sandbox** with entitlement minimization (T-DMN-01/02).
- Have the **daemon independently verify the phone single-use proof** (give it the phone verifying key) so step-up survives app compromise (T-DMN-04).
- Install the daemon to a **root-owned/SIP-protected location** or verify signature at every launchd exec; **remove the production env escape hatch** (T-DMN-03/05).
- Hardware-bind signing keys with per-use auth (T-CVS-03, shared with AC-5).

---

## AC-7 — Malicious Document / Webpage / Email (untrusted content into agent context)

**Actor:** A-CONTENT (author of any text the agent ingests: web page, document, email, repo file, third-party agent log). **Boundary:** B6 (User↔Agent / model output). **Claims:** C6 (Partial), C13. **Threats:** T-AI-01 (High), T-AI-02 (High), T-AI-03, T-AI-04, T-AI-06, T-TOOL-05.

### Narrative
This is the **indirect prompt-injection** abuse case — RR-15 is only *partly* closed at HEAD. Untrusted content reaches model context through several lanes; some are wrapped in `<UNTRUSTED_CONTENT>` (defense-in-depth, advisory, **not isolation**), and several are **not wrapped at all**. The model can be steered to call further tools, including shell under YOLO (chains into AC-8). Wrapping is explicitly rated "defense-in-depth, not isolation" by the repo's own matrix.

### Attack tree
```
GOAL: A-CONTENT steers the agent via injected instructions
├─ CU tool result outside 2-tool allowlist ......... UNWRAPPED [T-AI-01 High]
│   └─ read_file/run_terminal/browser_screenshot result appended verbatim as role:tool
│       (OpenAICompatibleChatGatewayClient.swift:1165-1169); only browser_extract +
│       mac_inspect_accessibility wrapped (:529)
├─ Oracle "authoritative findings" .................. UNWRAPPED + framed-trusted [T-AI-02 High]
│   └─ indexed snippet placed in oracle msg, injected as "authoritative local search
│       results" (ChatSessionController.swift:1609-1614); only 4 UI strings stripped (:2411)
├─ Memory/RAG poisoning via parsed agent logs ....... DURABLE [T-AI-03]
│   └─ third-party content → coding-agent CLI log → parsed w/o provenance → RAG corpus
├─ Browser SSRF via redirect / JS-nav / DNS rebind .. ACHIEVABLE [T-AI-04]
│   └─ no post-navigation host re-check (PlaywrightDriver goto); metadata exfil into context
├─ CLI lane ingests repo/web/tool content untagged .. UNWRAPPED [T-TOOL-05 High]
│   └─ combinedPrompt wraps only the chat user message (:248); files/tool output untagged
└─ Secret exfil into provider prompt ................ ACHIEVABLE [T-AI-06]
    └─ keys/tokens wrapped-but-transmitted verbatim to provider; no content redaction
```

### Impacted assets
The integrity of the agent's instruction-following (it can be made to act for the attacker within granted scope), the confidentiality of internal/cloud-metadata endpoints (SSRF), the RAG corpus (durable poisoning), and any secrets present in context (exfil to provider).

### Current controls (file:line)
- Untrusted wrapper with delimiter-breakout defang + provenance + "never treat as instructions" — `ContextBuilder.swift:11,38`; RAG snippets wrapped per-chunk `:146`; focus transcript wrapped — `ChatSessionController.swift:132-144`.
- CU `browser_extract` + `mac_inspect_accessibility` results wrapped — `OpenAICompatibleChatGatewayClient.swift:529-534`.
- Browser SSRF deny on initial `goto` (loopback/metadata/file:///RFC1918, octal/hex encodings) — `OpenBurnBarBrowserTargetPolicy.swift:52` at `ComputerUseRunCoordinator.swift:785`.
- In Manual mode, every high-impact action fails closed pending human approval (claim C6 **Partial** — strong in default posture).
- Tool-call budget cap bounds runaway loops — `OpenAICompatibleChatGatewayClient.swift:1154`.

### Gaps
- **CU tool-result wrapping is a 2-tool allowlist, not default-deny** (T-AI-01); file/shell/screenshot/clipboard output forwarded raw.
- **Oracle path bypasses the wrapper entirely** and is framed "authoritative" (T-AI-02).
- **No per-navigation/redirect/DNS-rebind re-validation** in the browser (T-AI-04).
- **CLI lane untags** repo/tool/web content (T-TOOL-05); **no content-level secret redaction** before providers (T-AI-06).

### Recommended tests
1. Plant injection in a file, read it via a non-allowlisted CU tool, and confirm the result is forwarded unwrapped and steers a subsequent tool call (T-AI-01).
2. Seed a malicious agent log on disk, trigger the oracle path, and confirm the snippet is injected as "authoritative" unwrapped (T-AI-02).
3. `goto` a public host that 302/JS-redirects to `169.254.169.254`; confirm the body returns into context (T-AI-04).
4. In the CLI lane, place an injection in a workspace file under a write/shell grant; confirm the CLI agent obeys it (T-TOOL-05).
5. Put an API key in context and confirm it is transmitted verbatim to the provider (T-AI-06).

### Recommended mitigations
- Make CU tool-result wrapping **default-deny (wrap ALL content-returning tools)** (T-AI-01).
- **Remove the "authoritative" framing** and wrap the oracle path with `wrapUntrusted` (T-AI-02).
- Add **post-navigation host re-validation + resolved-IP (post-DNS) enforcement** to the browser driver (T-AI-04).
- **Tag untrusted content in the CLI lane**, or interpose where possible (T-TOOL-05).
- Add **content-level secret redaction** and assert **zero-retention/no-train** on provider calls (T-AI-06).

---

## AC-8 — Tool Execution Attack

**Actor:** A-AGENT steered by A-CONTENT (injection-to-action) or a malicious local operator. **Boundary:** B6. **Claims:** C6 (Partial), C7 (Partial). **Threats:** T-TOOL-01..T-TOOL-10, T-AI-07 (High).

### Narrative
Two execution lanes exist (`08-agent-runtime-tools.md` §"Two execution lanes"). The **in-app broker** has a deterministic capability gate, per-action approval (unless trusted), and a workspace-confined `sandbox-exec` shell — **strong**. The **external CLI lane** delegates *all* runtime enforcement to the third-party CLI's flags; after spawn OpenBurnBar has **no in-process gate, no per-action approval, no revoke-kill**. The worst case is **YOLO**: `--dangerously-skip-permissions` + `runShellUnrestricted` runs `/bin/zsh` unsandboxed at full user privilege — injection-to-RCE the moment the user opts into trusted/YOLO.

### Attack tree
```
GOAL: Execute attacker-chosen actions via the tool layer
├─ YOLO injection → unsandboxed RCE ................ CRITICAL [T-TOOL-02 / T-AI-07]
│   └─ runShellUnrestricted /bin/zsh, no approval, no sandbox
│       (OpenAICompatibleChatGatewayClient.swift:367); no per-N-action re-auth (TODO :381)
├─ CLI lane acts within flag-granted authority ..... HIGH [T-TOOL-01]
│   └─ no in-process gate after spawn (CLIArgumentBuilder.swift:47-103)
├─ Revoke does not kill in-flight CLI run .......... HIGH [T-TOOL-03]
│   └─ revokeDesktopControl flips store state only; Process runs to completion
├─ Trusted-mode auto-dispatch (no approval) ........ HIGH [C6 caveat]
│   └─ .trusted + scope allow ⇒ .trustedScope dispatched w/o sheet
│       (ComputerUseCapabilityGate.swift:362; RunCoordinator.swift:262-269)
├─ Workspace preset → autonomous shell ............. MEDIUM [T-TOOL-07]
│   └─ codex --sandbox workspace-write, droid --auto medium (CLIArgumentBuilder.swift:89-126)
├─ SE-P256 controller skips explicit proof ......... PARTIAL [C7 / T-DMN-04]
│   └─ requiresProof=false for SE keys (PhoneControlAuthorityValidator.swift:493-503)
├─ Sandbox read-leak / path-deny evasion ........... LOW [T-TOOL-10 / T-TOOL-08]
└─ Local grant bypasses signed apply() ............. LOW [T-TOOL-09]
```

### Impacted assets
Full local execution authority (under YOLO), workspace integrity, the kill-switch guarantee (revoke≠kill), and the single-use-proof invariant (SE-P256 exemption).

### Current controls (file:line)
- Deterministic fail-closed capability gate, "harshest denial wins", kill-switch first, deny-region beats all — `ComputerUseCapabilityGate.swift:226,233,335`.
- Per-action approval for privileged broker tools (non-trusted), fails closed with no approver — `OpenAICompatibleChatGatewayClient.swift:155-164`.
- Workspace-confined `sandbox-exec` shell, network-denied, secret-store reads denied — `:344-357,662,702`.
- Grant time/thread/runtime/device-scoped, non-sticky, 30-min default expiry — `AgentCapabilityGrant.swift:308-322,374`.
- Single-use local-auth proof bound to canonical op hash (ed25519 path), replay-guarded at cloud + Mac — claim C7 **Partial** (`computerUseSecurity.ts:911-922,2268-2291`, `PhoneControlAuthorityValidator.swift:540-547`).
- YOLO unrestricted shell blocked in MAS build — `AgentCapabilityGrantStore.swift:166-172`.
- Audit-before-action fail-closed — `ComputerUseSessionCoordinator.swift:871-902`.

### Gaps
- **YOLO = injection-to-RCE**, no per-N-action re-auth (T-TOOL-02/T-AI-07, Critical).
- **No in-process gate / no revoke-kill for the CLI lane** (T-TOOL-01/03).
- **Trusted-mode auto-dispatch** has no high-impact-class carve-out (C6 caveat).
- **SE-P256 controllers skip the explicit single-use proof** (C7 caveat / T-DMN-04 divergence).
- CLI `--dangerously-skip-permissions` flags are **not** `#if DISTRIBUTION_MAS`-guarded (only the `.shellUnrestricted` broker capability is).

### Recommended tests
1. Enable trusted/YOLO, inject an instruction to run a shell command, confirm unsandboxed execution and that only a SHA-256 hash is logged (T-TOOL-02/T-AI-07).
2. Start a long YOLO CLI run, revoke the grant, confirm the subprocess keeps running to completion (T-TOOL-03).
3. In trusted mode with a scope allow rule, confirm a high-impact action dispatches with no approval sheet (C6).
4. Use an SE-P256 controller for a high-risk grant; confirm no explicit single-use proof is required on-device (C7).
5. In a MAS build, confirm CLI `--dangerously-skip-permissions` still emits (T-TOOL-02 caveat).

### Recommended mitigations
- Add **per-N-action re-auth** for YOLO/unrestricted shell (close the acknowledged TODO at `:381`) and require **re-approval on new domain / large tool output** even in Trusted/Step (the threat-model-prescribed but unimplemented control).
- Add an **in-process policy gate + mid-run revoke-kill** for the CLI lane (`grantStillActive` re-check; terminate the subprocess on revoke) (T-TOOL-01/03).
- Force **high-impact action classes to re-approve regardless of trust mode** (C6).
- Either require the **explicit single-use proof for SE-P256** too, or have the **daemon re-verify** the proof so the cloud/Mac divergence cannot be exploited (C7/T-DMN-04).
- Guard CLI dangerous flags under `#if DISTRIBUTION_MAS` (T-TOOL-02).

---

## AC-9 — Attachment Attack

**Actor:** A-PEER (malicious Mercury peer) / A-CONTENT (crafted attachment). **Boundaries:** B7, B5. **Claims:** C3 (Partial). **Threats:** T-ATT-01 (High), T-ATT-02..T-ATT-08.

### Narrative
Two attachment subsystems exist (`12-attachments.md`): **hosted-gateway** (GCS signed URLs, sealed-only, with a finalize size==declared + sha256 gate) and **Mercury peer-to-peer** (iroh content-addressed blobs). The hosted path is hardened; **Mercury is where the abuse lives** — the receiver trusts the advertised `manifest.size`, the iroh blob fetch has no streaming ceiling, and metadata (filename/mime/size) is unauthenticated and, on the wire manifest, plaintext.

### Attack tree
```
GOAL: Abuse the attachment pipeline
├─ Decompression/oversize disk-fill DoS ............ HIGH [T-ATT-01]
│   └─ advertise size=1KB (passes daily cap, MacFileTransferService.swift:391-395)
│       but BlobTicket commits multi-GB; fetch_blob downloads full blob, no streaming cap,
│       never compares bytes_total(284) to manifest.size (blobs.rs:258-282)
├─ iOS plaintext media at rest .................... MEDIUM [T-ATT-02]
│   └─ handleAdvertise records URL only; no seal/quarantine/gate/FileProtection
├─ Wire-manifest metadata leak to relay ........... MEDIUM [T-ATT-03]
│   └─ plaintext filename/mime/size in advertise frame; depends on frame E2EE elsewhere
├─ Spoofed file identity (no MAC on metadata) ..... MEDIUM [T-ATT-04]
│   └─ filename/mime not bound to bytes; .jpg name on executable payload
├─ Seal-at-rest fail-open (no session key) ........ LOW/MED [T-ATT-06]
│   └─ nil sealKey ⇒ plaintext blob persists in Caches
├─ Content-type confusion on preview .............. LOW [T-ATT-05]
└─ Download URL renders inline (no disposition) ... LOW [T-ATT-08]
```

### Impacted assets
Receiver disk/quota availability (Mercury DoS), confidentiality of received media at rest (iOS), filename/size metadata to the relay, and content-type integrity (spoofed identity).

### Current controls (file:line)
- Hosted path: sealed-only writes, fileName-free object path, finalize **size==declared + sha256** gate, 10-min signed URLs — `hermesGateway.ts:1439-1444,1470-1472,1567-1586`; claim C3 **Partial**.
- Mercury blobs content-addressed; export verifies BLAKE3 — `crates/openburnbar-iroh/src/blobs.rs:276-282`; inbox name = blobHash (no traversal) — `MediaFileTransferService.swift:162-169`.
- Mac receive: capability gate before fetch, seal-at-rest under media session key (AAD-bound), quarantine xattr — `MacFileTransferService.swift:391-407,420-543,555-576`.
- Firestore at-rest manifest seals filename — `MediaAttachmentManifestStore.swift`.

### Gaps
- **No streaming size ceiling on `fetch_blob` and no post-fetch `bytes_total == manifest.size` reject** — the GCS finalize check has no Mercury equivalent (T-ATT-01).
- **iOS receive omits seal/quarantine/gate/FileProtection** (T-ATT-02).
- **Wire manifest metadata unsealed at this layer and not MAC-bound to the blob** (T-ATT-03/04).
- **Seal-at-rest is fail-open** on missing session key (T-ATT-06).

### Recommended tests
1. Advertise a tiny `manifest.size` but commit a multi-GB blob; confirm the receiver downloads the full blob to Caches before any reject (T-ATT-01).
2. Receive media on iOS; confirm plaintext in Caches with no FileProtection (T-ATT-02).
3. Advertise a `.jpg` filename on executable bytes; confirm the displayed type is not bound to content (T-ATT-04).
4. Force `frameSealKeyProvider` to nil and confirm plaintext is retained (T-ATT-06).

### Recommended mitigations
- Add a **streaming byte ceiling + post-fetch `bytes_total == manifest.size` assertion** to the Mercury iroh path (mirror the GCS finalize gate) — closes T-ATT-01.
- Bring **iOS receive to parity**: capability gate + seal-at-rest + quarantine + `FileProtectionType.complete` + `isExcludedFromBackup` (T-ATT-02).
- **MAC-bind or seal the wire manifest metadata** to the blob hash (T-ATT-03/04).
- Make seal-at-rest **fail-closed** on missing session key (T-ATT-06).

---

## AC-10 — Object Authorization Attack (IDOR / BOLA)

**Actor:** A-EXT / A-PEER (authenticated user reaching another tenant's objects). **Boundaries:** B2, B7. **Claims:** C11 (Partial). **Threats:** T-AZ-01..T-AZ-08, T-GW-05.

### Narrative
Object-level isolation of private data is **well-enforced at the rules layer** (claim C11 **Partial**, Med confidence): every private read is gated by `ownsUserNamespace`, callables derive uid from the token and `assertOwnership`, and the cross-device relay binds each token to a single account. The residual abuse surface is (a) the **Admin-SDK callable layer** (rules bypass; ~100 handlers not exhaustively audited), (b) **cross-tenant avatars**, (c) the **App Check console toggle**, and (d) a latent **shared-artifact write** with no workspace↔uid binding.

### Attack tree
```
GOAL: Reach another tenant's objects
├─ Cross-tenant read at rules layer ............... BLOCKED [C11]
│   └─ ownsUserNamespace on every private read (rules:52-54); zero ungated reads
├─ IDOR in an Admin-SDK callable .................. RESIDUAL [T-AZ-05]
│   └─ one handler deriving uid from body w/o assertOwnership = cross-tenant; ~100 not all audited
├─ Cross-tenant avatar read ....................... ACHIEVABLE (low) [T-AZ-01]
│   └─ avatars/{userId}/profile.jpg allow read: if auth != null (storage.rules:18/19)
├─ Shared-artifact write into another workspace ... LATENT [T-AZ-02]
│   └─ sharedArtifactOwnerWrite never binds workspaceId to a uid (rules:1073-1080)
├─ App Check not enforced → non-app SDK client .... CONDITIONAL [T-AZ-06]
├─ Same-tenant other-client event surfacing ....... LOW [T-GW-05]
│   └─ targetClientId filtered in app code, not Firestore where-clause
├─ Plaintext secret in non-denylisted field ...... DEPENDS-ON-CLIENT [T-AZ-04]
└─ Operator custom-claim breadth .................. SCOPED [T-AZ-07]
    └─ burnbarOperator reads ops telemetry across tenants (not user content)
```

### Impacted assets
Cross-tenant private data (blocked at rules; residual at callables), profile photos (enumerable), workspace namespace integrity (latent write), and ops telemetry (operator claim).

### Current controls (file:line)
- Universal owner gate, zero ungated reads — `firestore.rules:52-54`; per-category owner-scoped reads — `:1279,1334,2369,3127,2995,2559`.
- Callables derive uid from token + `assertOwnership` — `auth.ts:22-31`; client-supplied uids re-checked — `credentialTransfer.ts:58`, `quota.ts:91`, `computerUseOpenTimestamps.ts:465`.
- Gateway binds uid via server-side token index, writes only `users/{grant.uid}/...` — `hermesGateway.ts:810-864,1118-1162`.
- Server-only index collections `read,write: if false` — `firestore.rules:1086-1088,4226-4252`.
- Rules-test coverage asserts cross-user/anonymous reads fail — `firestore-rules-tests/computer-use.test.js:189`, `rr12-relay-and-root.test.js:143-201`.

### Gaps
- **Admin-SDK bypasses rules**; ~40–100 callables not line-by-line audited — a single uid-from-body handler is a cross-tenant IDOR (T-AZ-05).
- **Cross-tenant avatar read** (T-AZ-01); **shared-artifact write** never binds workspace↔uid with zero rules-test coverage (T-AZ-02).
- **App Check enforcement UNKNOWN from repo** (T-AZ-06); plaintext-secret denylist is exact-top-level-names only (T-AZ-04).

### Recommended tests
1. Enumerate every `onCall`/`onRequest` handler that reads a uid/ownerId from the request body and confirm each calls `assertOwnership` (T-AZ-05).
2. Read another user's `avatars/{userId}/profile.jpg` as an arbitrary authenticated user (T-AZ-01).
3. Write a `sharedArtifactOwnerWrite` doc with `ownerUserID=self` under another tenant's workspace path (T-AZ-02).
4. With App Check off, hit Firestore directly with a non-app client (T-AZ-06).

### Recommended mitigations
- **Structurally enforce ownership** (a shared middleware that derives uid from token and forbids body-supplied uids) across all callables; complete the 100-handler audit (T-AZ-05).
- Scope **avatar reads to the owner** (T-AZ-01); **bind `workspaceId` to a uid** in the shared-artifact rule and add rules-test coverage (T-AZ-02).
- **Confirm App Check enforcement** in the console (T-AZ-06).

---

## AC-11 — Supply Chain Compromise

**Actor:** A-SUPPLY (upstream action owner / tag-mover, malicious dep author, or coercion of the sole CODEOWNER). **Boundary:** B8 (Repo/CI↔artifacts). **Claims:** (supply-chain lens). **Threats:** T-SC-01..T-SC-10.

### Narrative
The release lane is **strong** (SHA-pinned core actions, v*-tag-gated deploys, fail-closed secret validation, codesign+notarize+staple, Sparkle Ed25519 with post-publish live-feed verify, cosign attestations). The abuse surface is at the **edges**: a handful of **mutable action tags**, a **provenance "ecosystem-deny" step that silently no-ops** (false assurance), a **single CODEOWNER** (no separation of duties), and **unscanned Cargo/SwiftPM/Gradle locks**.

### Attack tree
```
GOAL: Inject malicious code/artifact via the pipeline
├─ Repoint a mutable action tag .................... HIGH [T-SC-01]
│   └─ @stable/@v2/@v4/@v0.x → malicious commit runs in CI with repo token
│       (fast-feedback.yml:478; codeql.yml:129; security-pr.yml:199; nightly-e2e.yml:110,142)
├─ Ship a vuln/yanked dep past provenance deny ..... HIGH [T-SC-02]
│   └─ cargo-deny/osv-scanner not installed → script no-ops (run-ecosystem-deny-checks.sh:10-34)
├─ Coerce/compromise the sole CODEOWNER ............ HIGH [T-SC-03]
│   └─ @Ajnunezg self-reviews workflow/firestore.rules/release; owns its own .github/workflows
├─ Land vuln crate/SwiftPM/Gradle dep .............. MEDIUM [T-SC-04]
│   └─ no OSV/grype over Cargo.lock / Package.resolved / Gradle locks
├─ Tamper xcframework (if ever committed) .......... LOW [T-SC-05]
├─ Publish unsigned checksums ...................... LOW/MED [T-SC-06]
│   └─ GPG signing best-effort, not in strict-secret gate
├─ Attest SBOM ≠ as-shipped bytes .................. MEDIUM [T-SC-08]
├─ predeploy npm build runs w/ deploy creds ........ LOW [T-SC-07]
└─ Agentic droid exec --skip-permissions in CI ..... LOW [T-SC-10]
```

### Impacted assets
The integrity of every released artifact (DMG/AAR/Functions), CI secrets and deploy credentials, and the provenance/SBOM assurance story.

### Current controls (file:line)
- Core actions SHA-pinned; least-priv top-level permissions on 30/32 workflows — `deploy-production.yml:37,72,207,3-5`.
- Prod deploy gated to `v*` tags + `environment: production`; release gated to `push: tags: v*` — `deploy-production.yml:7-10,56-59`, `release.yml:8-12`.
- Fail-closed strict release-secret validation; codesign+hardened-runtime+notarize+staple — `release.yml:139-170,415-448,500-531`.
- Sparkle Ed25519 + **post-publish live-feed verify** (fails release if DMG sig ≠ pinned key) — `release.yml:179-191,1167-1271`.
- Android AAR rebuild-parity gate — `build-iroh-android-aar.yml:110-119`; cargo-audit on shipping crates — `rust-sast.yml:42-98`; gitleaks + dependency-review + OSV (npm) — `security-pr.yml:63-79,90-98,199-209`.

### Gaps
- **Mutable action tags** in several workflows; no Dependabot/Renovate for actions (T-SC-01).
- **Provenance ecosystem-deny silently no-ops** cargo-deny/osv-scanner — false assurance (T-SC-02).
- **Single CODEOWNER** — no separation of duties; branch-protection unverifiable from repo (T-SC-03).
- **Cargo/SwiftPM/Gradle locks not OSV-scanned** (T-SC-04); **GPG checksums optional** (T-SC-06); **SBOM attests source, not shipped bytes** (T-SC-08).

### Recommended tests
1. Repoint a test fork's `@stable`/`@vN` action to a benign marker commit and confirm it executes in CI with the repo token (T-SC-01).
2. Introduce a known-vulnerable/yanked crate and confirm the provenance deny step passes anyway (T-SC-02).
3. Attempt a self-approved merge of a `.github/workflows` change (T-SC-03).
4. Export `gh api repos/{o}/{r}/rulesets` + `branches/main/protection` to resolve required-review enforcement (open question).

### Recommended mitigations
- **SHA-pin all actions** and add Dependabot/Renovate to keep pins current (T-SC-01).
- **Actually install + run `cargo deny check` and `osv-scanner`** on the provenance runner (or remove the misleading step) (T-SC-02).
- Add a **second reviewer / CODEOWNER** and enforce required reviews + signed commits via branch-protection rulesets (T-SC-03).
- Add **OSV/grype over Cargo.lock, Package.resolved, and Gradle locks** (T-SC-04); make **GPG checksum signing required** (T-SC-06); attest the **as-shipped artifact bytes** (T-SC-08).

---

## AC-12 — Model Provider / AI Service Compromise

**Actor:** A-MODEL (the model provider or a compromised AI service, C16). **Boundaries:** B6, B9 (BurnBar↔providers). **Claims:** C10 (Defensible, BYOK note), C6, C13. **Threats:** T-AI-05, T-AI-06, plus the providers-see-plaintext non-claim.

### Narrative
B9 and `_INDEX.md` §8 are explicit: **model providers see everything routed to them** — this is by design, not a bug. The abuse case has two sides: (a) **confidentiality** — what leaks to a curious/compromised provider, and (b) **integrity** — the provider returns attacker-influenceable output that BurnBar must treat as untrusted (improper output handling). Provider creds are backend-decryptable (IAM/KMS is the boundary, not zero-knowledge); BYOK keys do **not** transit BurnBar servers on the gateway lane (verified).

### Attack tree
```
GOAL: A-MODEL leaks data or steers BurnBar via its output
├─ Receive raw prompts incl. secrets ............... ACHIEVABLE (by design) [T-AI-06]
│   └─ keys/tokens wrapped-but-transmitted verbatim; no zero-retention/no-train header
├─ Retain / train on routed content ................ UNKNOWN (deployment) [T-AI-06 gap]
│   └─ retention policy not asserted in code
├─ Return malicious JSON → missions/recommendations . LOW/MED [T-AI-05]
│   └─ insightsHostedAnswer output rendered as missionCandidates (insightsHostedAnswer.ts:301-308)
├─ Steer agent via tool-call output ................ HIGH (chains AC-7/AC-8) [T-AI-01/07]
│   └─ model output is untrusted; authority only from signed grants + typed approvals (B6)
└─ Read BYOK provider keys in transit .............. BLOCKED on gateway lane [C10]
    └─ BYOK keys do not transit BurnBar servers (gateway lane verified)
```

### Impacted assets
Confidentiality of any plaintext routed to the provider (transcripts, RAG snippets, file reads, secrets), and the integrity of model-authored action proposals.

### Current controls (file:line)
- Hosted analyst (insights) sends **digest only**, no raw transcripts/keys; strict JSON envelope, no tools — `insightsHostedAnswer.ts:241-273,330` (claim per `09` **Defensible** for that path).
- Model output is untrusted; authority flows only from signed grants + typed-action approvals (B6) — the capability gate and approval pipeline (AC-8 controls).
- BYOK provider creds envelope-encrypted, do not transit on the gateway lane — claim C10 **Defensible**.
- `CLILaunchRedactor` redacts secrets for **log display** — `CLIProfileStreamFailoverRunner.swift:260`.

### Gaps
- **No content-level secret redaction on the prompt payload path**; the chat path sends raw secrets to the provider (T-AI-06).
- **No zero-retention / no-train header asserted in code**; provider retention is deployment-dependent and UNKNOWN (T-AI-06 gap).
- **No semantic safety validation** of model-recommended missions/actions (T-AI-05).

### Recommended tests
1. Place a secret in a focus transcript / file read and capture the provider request; confirm it is transmitted verbatim (T-AI-06).
2. Inspect outbound provider calls for any zero-retention / no-train assertion (expect none) (T-AI-06).
3. Return crafted `missionCandidate` JSON and observe it rendered as a recommendation (T-AI-05).

### Recommended mitigations
- Add a **prompt-payload secret redactor** (reuse/extend `CLILaunchRedactor`) before any provider call (T-AI-06).
- **Assert zero-retention / no-train** headers/flags on provider calls and document deployed provider retention posture (T-AI-06).
- **Semantically validate** model-authored mission/action proposals before surfacing them (T-AI-05).
- Keep stating the honest non-claim: **providers see everything routed to them** (`_INDEX.md` §8).

---

## AC-13 — Rogue Agent

**Actor:** A-AGENT (an agent runtime that has gone rogue — via injection (AC-7), a malicious model, or a compromised vendored runtime, C10). **Boundary:** B6. **Claims:** C6, C7. **Threats:** T-TOOL-01/03/04, T-AI-01/02/03/07, T-TOOL-06.

### Narrative
This case treats the agent itself as the adversary — whether steered by injection, served by a malicious model, or running compromised vendored code (`~/.hermes/hermes-agent`, **source not fully in-repo**, C10). It asks: once an agent is rogue, what can it do, and what stops it? The answer hinges on **mode** (Manual = strong fail-closed gating; Trusted/YOLO = arbitrary local agency) and on the **kill-switch** (which is **compiled out of the MAS build** and **does not terminate in-flight CLI runs**).

### Attack tree
```
GOAL: A rogue agent maximizes impact
├─ Self-escalate authority ......................... BLOCKED [C6/C7]
│   └─ cannot set trust mode (per-session, never agent-set, ComputerUseSessionMetadata.swift:44-47);
│       cannot mint its own grants (signed grants + typed approvals only, B6)
├─ Act within granted scope (Trusted) ............. ACHIEVABLE [C6 caveat]
│   └─ trustedScope auto-dispatch, no per-action approval (RunCoordinator.swift:262-269)
├─ Injection → unsandboxed shell (YOLO) ........... CRITICAL [T-AI-07/T-TOOL-02]
├─ Survive revocation mid-run (CLI) ............... HIGH [T-TOOL-03]
│   └─ revoke ≠ kill; subprocess runs to completion
├─ Evade the kill-switch (MAS) .................... HIGH [T-TOOL-04]
│   └─ panic coordinator #if !DISTRIBUTION_MAS — hotkey/lock-screen kill absent
├─ Poison its own future context (memory) ......... DURABLE [T-AI-02/03]
│   └─ emit attacker text into CLI log → RAG corpus → retrieved later as authoritative
└─ Exceed runaway loop budget .................... BOUNDED [maxToolCalls :1154]
```

### Impacted assets
The kill-switch / loss-of-control guarantee, the bound on agent authority (held by grants/approvals), the durability of the RAG corpus, and — under Trusted/YOLO — the entire local domain.

### Current controls (file:line)
- Agent cannot self-escalate: trust mode is per-session, never sticky, never agent-settable; entering Trusted requires local auth — `ComputerUseSessionMetadata.swift:44-58`, `AgentCapabilityGrant.swift:35-50`.
- Authority only from signed grants + typed approvals; deny-region beats agent+mac+phone — `ComputerUseCapabilityGate.swift:335`.
- Independent panic/kill paths (hotkey/lock/remote-config) — `ComputerUsePanicHaltCoordinator.swift:29-67,112,54`; AsyncStream cancellation kills the process on stream teardown.
- Remote grant intake Ed25519/pinned-controller verified; tool-call budget cap — `AgentCapabilityGrantQueueListener.swift:81-90`, `OpenAICompatibleChatGatewayClient.swift:1154`.
- Audit-before-action fail-closed — `ComputerUseSessionCoordinator.swift:871-902`.

### Gaps
- **Kill-switch compiled out of MAS build**; physical-hotkey + lock-screen kill absent (T-TOOL-04).
- **Revoke does not terminate in-flight CLI subprocess** (T-TOOL-03).
- **Trusted-mode auto-dispatch** within scope, no per-action approval (C6); **injection→RCE under YOLO** (T-AI-07).
- **Durable memory poisoning** with no provenance trust tier / quarantine (T-AI-02/03); **vendored runtime source not fully in-repo** (C10 trust assumption).

### Recommended tests
1. In a MAS build, start an in-flight agent and confirm the only kill path is quitting the app (T-TOOL-04).
2. Revoke a running CLI grant and confirm the subprocess continues (T-TOOL-03).
3. Confirm an agent cannot set its own trust mode or mint a grant via any callable/grant path (C6/C7).
4. Have an agent write attacker text into its CLI log and confirm it is later retrieved as "authoritative" (T-AI-02/03).

### Recommended mitigations
- Provide an **in-MAS kill path** for in-flight agents (remote-config kill is reachable, but add a user-facing one) (T-TOOL-04).
- Make **revoke terminate the CLI subprocess** and re-check `grantStillActive` mid-run (T-TOOL-03).
- Force **high-impact re-approval in Trusted mode** and add **per-N-action re-auth under YOLO** (C6/T-AI-07).
- Add a **provenance trust tier + poisoned-chunk quarantine** to the RAG corpus, and **wrap the oracle path** (T-AI-02/03).
- **Bring the vendored agent runtime source in-repo** (or attest it) to close the C10 trust gap.

---

## Cross-cutting framework mapping

Each abuse case maps to the named lenses (`_INDEX.md` §9). Mapping, not name-dropping:

| Abuse case | STRIDE | LINDDUN | OWASP LLM/Agentic | MITRE ATLAS | ASVS / API / MASVS | NIST CSF / ZT / SSDF | SLSA / SCVS |
|---|---|---|---|---|---|---|---|
| AC-1 Cloud Relay | Tampering, DoS, Info-disc | Linkability, Identifiability | — | AML.T0048 (downgrade) | API4 (rate) | Protect, Detect | — |
| AC-2 Malicious Admin | Spoofing, Tampering, Info-disc | Non-repudiation, Disclosure | LLM03 (supply/trust) | AML.T0051 | API2/API5; ASVS V2/V4 | Protect, ZT (verify-explicitly) | — |
| AC-3 External ATO | Spoofing, Elevation | — | — | — | API2 BrokenAuth; ASVS V2 | ZT, Protect | — |
| AC-4 Pairing | Spoofing, Tampering | Non-repudiation, Detectability | — | — | ASVS V2/V9 | ZT (no implicit trust) | — |
| AC-5 Mobile | Info-disc, Spoofing | Disclosure | — | — | MASVS-STORAGE/CRYPTO/NETWORK | Protect, Recover | — |
| AC-6 Desktop | Elevation, Tampering | Disclosure | — | — | ASVS V1/V14 | Protect, Respond | — |
| AC-7 Untrusted content | Tampering, Spoofing | Disclosure | LLM01, LLM02, LLM08; Agentic indirect-injection | AML.T0051, AML.T0070 | API (SSRF) | Protect, Detect | — |
| AC-8 Tool Execution | Elevation, Tampering | — | LLM01→LLM06 Excessive Agency; Agentic Tool-Misuse | AML.T0053 | ASVS V1 | Protect, Respond | — |
| AC-9 Attachment | Tampering, DoS, Info-disc | Disclosure | — | — | CWE-409/770/400/312; MASVS-STORAGE | Protect | — |
| AC-10 Object Authz | Info-disc, Elevation | Linkability | — | — | API1 BOLA, API3 BOPLA, API5 BFLA; ASVS V4 | ZT, Protect | — |
| AC-11 Supply Chain | Tampering, Elevation, Repudiation | — | LLM03 | — | — | SSDF PW/PO/PS/RV | SLSA build-L, SCVS V2 |
| AC-12 Model Provider | Info-disc, Tampering | Disclosure, Unawareness | LLM02, LLM05, LLM06 | AML.T0051 | — | Identify, Protect | — |
| AC-13 Rogue Agent | Elevation, Tampering | — | LLM01, LLM06, LLM08; Agentic loss-of-control | AML.T0070 | — | Respond, Recover | — |

## Severity roll-up (per `_INDEX.md` §10)

| Abuse case | Worst-case canonical threat | Severity |
|---|---|---|
| AC-2 Malicious Admin | T-TRN-01 | **Critical** |
| AC-4 Pairing | T-TRN-01 / T-PTR-03 | **Critical / High** |
| AC-8 Tool Execution | T-TOOL-02 / T-AI-07 | **Critical / High** |
| AC-6 Desktop | T-DMN-01 / T-DMN-02 | **High** |
| AC-7 Untrusted content | T-AI-01 / T-AI-02 | **High** |
| AC-9 Attachment | T-ATT-01 | **High** |
| AC-11 Supply Chain | T-SC-01 / T-SC-02 / T-SC-03 | **High** |
| AC-13 Rogue Agent | T-TOOL-03 / T-TOOL-04 | **High** |
| AC-1 Cloud Relay | T-TRN-03 / T-TRN-02 | **High** |
| AC-5 Mobile | T-CVS-03 | **High** |
| AC-10 Object Authz | T-AZ-05 (residual) | **Medium** |
| AC-3 External ATO | T-AZ-06 (conditional) | **Medium** |
| AC-12 Model Provider | T-AI-06 (by-design + retention UNKNOWN) | **Medium** |

> The two reads that dominate this package: a **compromised cloud** (AC-2/AC-4) can MITM the iroh control channel and impersonate paired devices because trust roots are cloud-fetched and not locally pinned/re-verified (T-TRN-01 Critical, C8 break); and a **user who opts into Trusted/YOLO** (AC-8/AC-13) converts indirect prompt injection (AC-7) into unsandboxed local RCE (T-TOOL-02 Critical). Payload confidentiality and object-authz isolation hold with material caveats; the headline gaps are trust-root pinning, kill-switch coverage, and untrusted-content isolation.
