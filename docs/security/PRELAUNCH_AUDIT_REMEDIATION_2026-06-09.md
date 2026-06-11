# Pre-launch audit remediation — status (2026-06-09)

This tracks the remediation of the pre-launch security assessment. Most findings
were fixed in this pass (see "Shipped" below). The remaining items are **protocol /
multi-client changes** that cannot be shipped from one side without breaking paired
clients or creating false assurance; each has a precise spec here and is gated
before beta.

## Shipped in this pass (code + tests where buildable)

| ID | Fix | Where |
|----|-----|-------|
| F1 | `openburnbar://link-cli` now requires an explicit confirmation **and** a device-owner (Touch ID / password) proof before the Cloud Vault key is read/copied; success shown only after the gated copy. | `AgentLens/App/AgentLensApp.swift` |
| F4 | MCP resume never executes a server-supplied executable: `argv[0]` must be a slash-free name on a fixed local allowlist (`claude`/`codex`/`cursor`/`windsurf`/`open`); else rejected with guidance to use `--print`. | `tools/openburnbar-mcp-remote/src/resume.ts` |
| F6 | Phone-control replay-counter store fails **closed** when the file exists but is unreadable (vs. silently resetting counters to 0). | `…/PhoneControlReplayCounterStore.swift`, `…/PhoneControlAuthorityValidator.swift` |
| F8 / L6 | Constant-time token comparison on the daemon control socket and HTTP gateway. (A code-signature peer pin is intentionally **not** added: the Cursor/VS Code extension is a legitimate unsigned Node client of that socket — see below.) | `…/ConstantTimeCompare.swift`, `OpenBurnBarDaemonServer.swift`, `OpenBurnBarHTTPGatewayServer.swift` |
| L1 | `REQUIRE_HIGH_RISK_NONCE` defaults **ON** in production (fail-closed), overridable only by explicit opt-out. | `functions/src/config.ts` |
| L3 | Per-`(uid, clientId)` rate limit on `enqueueHermesGatewayEvent`. | `functions/src/callables/{hermesGateway,publicRateLimit}.ts` |
| L4 | Device-start rate limit adds a second dimension keyed on the supplied device-secret hash. | `functions/src/callables/hermesGateway.ts` |
| L5 | SSRF guard (`assertOutboundFetchTarget`) blocks cloud-metadata + private/link-local hosts in `resilientFetch`; the one legitimate metadata fetch opts in explicitly. | `functions/src/ssrfGuard.ts`, `resilienceHelpers.ts`, `computerUseOpenTimestamps.ts` |
| F3 | `shell_run_unrestricted` writes a tamper-evident audit line (command hash, not plaintext) on every dispatch. | `…/OpenAICompatibleChatGatewayClient.swift` |
| F9 | `shell_run` seatbelt denylist expanded to cover OpenBurnBar's own on-disk state (encrypted DB, replay counters, audit chain, queued grants) plus more credential stores. | `…/OpenAICompatibleChatGatewayClient.swift` |
| F5 | `verify-vendored-agent-source.sh` now **fails closed** while `manifest.pendingHardening.blocking` is true, and is wired into the pre-beta `verify-ops-readiness.sh` gate. Ops-readiness cannot pass until the C-4 agent command-guard is merged + re-pinned. | `scripts/ci/verify-vendored-agent-source.sh`, `scripts/ci/verify-ops-readiness.sh` |
| L8a | Kill-switch (`PrivilegedInputKillSwitch.assertNotActive()`) re-checked at the `MacActionDispatcher.dispatch` input-synthesis chokepoint, closing the panic race. | `…/MacActionDispatcher.swift` |
| L8b | Audit-chain verifier gains a strict `requireExpectedHead` mode (`validateRequiringSignedHead`) that fails closed when the signed terminal head is absent. | `…/ComputerUseAuditChain.swift` |
| L9 | Consumed single-use local-auth proof IDs persist with TTL so "single-use" survives restarts. | `…/PhoneControlConsumedProofStore.swift`, `…/PhoneControlAuthorityValidator.swift` |
| Docs | Corrected stale SQLCipher recovery-file claims, the gateway-destinations writability claim, disclosed the post-revocation non-E2E token-TTL window, and added a precise media confidentiality model. | `docs/reviews/SECURITY_PRIVACY_REVIEW.md`, `docs/reviews/RELIABILITY_OPS_REVIEW.md`, `docs/HERMES_GATEWAY_PLATFORM.md`, `docs/PRIVACY.md`, `docs/HERMES_MEDIA_TRANSPORT.md` |
| L7 | Already mitigated (backend hosts hard-deny cleartext; app-layer `validatedBaseURL` scopes HTTP to localhost/RFC1918). Flipping base-config to deny would regress the LAN-direct feature; tracked below. | `android/.../network_security_config.xml` |

## Progress — 2026-06-09 (F2 / F7 / F10 / L2 cores + server landed, tested)

Branch `security/prelaunch-f2-f7-f10-l2`. Every change below is **backward
compatible and behind a default-off capability gate**, so paired clients never
break and the tree stays shippable while the device/mobile/vendor wiring lands.
Verified surfaces: **OpenBurnBarCore `swift test` (1437 pass / 3 skip)** and
**functions `vitest` (435 pass / 4 skip)**, plus `tsc --noEmit` clean.

| Finding | Shipped + tested this pass | Remaining (gated) |
|---|---|---|
| F2 | keyKind negotiation, Secure-Enclave P-256 verify/sign path, shared peerNodeId derivations, per-action step-up policy (18 core tests); server SE-P256 publish + atomic revoke + revocation receipt (5 vitest) | ~~Mac validator accept-both verify; iOS Secure Enclave + Android StrongBox keygen + biometric; Kotlin signer P-256 mirror; shorten TTL + per-session rebind~~ **all landed 2026-06-10 (below)**. **Physical biometric/SE device validation remains.** |
| F7 | per-frame media AEAD + capability gate (8 core tests); Kotlin mirror + frozen KATs; Mac→phone advertisement; **ACTIVATED Swift end-to-end 2026-06-10 (`4bce121a8`):** phone wraps a per-mirror key into the mirror request (sealKeyV3, viewerId-bound AAD), Mac opens via the pinned-sender trust path and seals every frame before chunking (cleartext `sealedFramePosition` rebuilds the AAD), phone opens after reassembly fail-closed — all behind default-off `computer_use_media_frame_aead_enabled`; **Android viewer activated 2026-06-10** (establish in `requestMirror` — the single funnel for all 4 mirror surfaces — + sealed-open in the live read loop, fail closed) | live two-device validation with the RC flags ramped |
| F10 | control-frame seal + capability gate (6 core tests); Kotlin mirror + frozen KATs; Mac advertises `control_seal_v1`; **ACTIVATED Swift end-to-end 2026-06-10 (`b5c78fee4`/`75d221ffa`/`15a51bcec`):** classify-time sealKeyV3 establishment (pinned-sender trust path), iOS seals every control payload into a streamClass-only shell at MercuryLiveSheet + InlineAgentMirror, Mac opens-or-drops fail-closed before dispatch — all behind default-off `computer_use_control_seal_enabled`; **iOS AgentWatch + remote-unlock senders sealed via a per-connection session registry; Android sender activated 2026-06-10** (Kotlin `ControlFrameSealSession` + establisher at the screen-share classify; inline mirror reuses the registry session) | live two-device validation with the RC flags ramped |
| L2 | gateway PoP v2 query binding, accept-both transition, per-client downgrade protection (5 vitest); **2026-06-10:** adapter PoP v2 signer on all 10 call sites + pairing key registration (13 unittest); fork commit `005cf0d86` + provenance pin bumped (hash verified) | **L2 COMPLETE.** The F5 gate still fails closed on the unrelated C-4 hardening (by design) |

### Adversarial self-review pass — 2026-06-10 (commit `1ac0693ec`)

A principal-reviewer pass over the default-ON flip (`02c12cb85`) found and fixed
three issues; all verified.

- **[security] Android API 26–29 could emit a non-biometric `se-p256` key.**
  `setUserAuthenticationParameters(0, AUTH_BIOMETRIC_STRONG)` (the API that
  excludes device-credential/PIN unlock) is API-30+ only; below it,
  `setUserAuthenticationRequired(true)` accepts a PIN. Since `minSdk = 26` and
  the Mac skips the explicit local-auth proof for `se-p256` (treating the
  signature as biometric step-up evidence), a PIN-gated key on API 26–29 would
  have satisfied a sensitive-action step-up without a biometric.
  `PhoneControlSecureEnclaveKeystore.mintIdentity` now refuses below API 30
  (and refuses to load any pre-existing alias), so those devices use the legacy
  Ed25519 key — which *forces* the explicit proof. The invariant
  "`se-p256` ⇒ biometric-strong-gated signature" is now globally true on both
  platforms (iOS uses `.biometryCurrentSet`, which already excludes passcode).
- **[availability] iOS `signingIdentity` threw on Secure-Enclave mint failure.**
  A `.biometryCurrentSet` key cannot be created on a passcode-only device with
  no enrolled biometric, so once the flag defaults ON, remote control would
  brick there. It now falls back to the legacy key (mirroring Android's
  `getOrNull()`); the security invariant holds because the legacy lane forces
  the explicit proof. Regression test asserts `signingIdentity` never throws.
- **[kill switch] the Android kill switch was inert.** Android never called
  `RemoteConfig.fetchAndActivate()`, so `getValue().source` stayed permanently
  `STATIC` and an operator-set `false` could never reach the device — the
  default-ON flags were un-disable-able remotely. `RemoteConfigBootstrap` now
  runs a one-time fetch (hourly minimum interval) at `Application.onCreate`.

### Progress — 2026-06-10 (wiring pass: F2 all-platform activation, L2 adapter)

Nine commits (`bd8be99cb..23c1424cf`). All default-off / both-peers-gated; legacy
wire bytes proven unchanged by tests on every surface. Verified: OpenBurnBarCore
`swift test` 1456+ green; AgentLens validator/receiver suites green via
xcodebuild; iOS `OpenBurnBarMobileUnitTests` 969+ cases green; Android
`:app:testDebugUnitTest` 742/742; functions vitest 443 + tsc clean; adapter
13/13 unittest.

| Lane | Landed |
|---|---|
| F2 Mac | Validator stores `PhoneControlVerifyingKey`; one key-kind-aware signature chokepoint (envelope `keyKind` must match the registered key — downgrade/escalation fail closed); SE-signed sensitive grants skip the explicit local-auth proof (the biometry-gated signature IS the step-up); `authorityMaxLifetime` 300→120 s; `deregisterAllPeers()` per session end/panic; provider + grant-queue listener parse `signingKeyKind` fail-closed. |
| F2 iOS | Keystore vends `PhoneControlAuthoritySigningKey`; SE-P256 mint (`.biometryCurrentSet`+`.privateKeyUsage`) behind default-off RC `computer_use_phone_control_secure_enclave_key`; all 8 sender paths + publishes carry `keyKind`; remote-unlock envelopes attach the cached attestation digest. |
| F2 Android | `PhoneControlSigningIdentity` + StrongBox/TEE Keystore mint (biometric-bound, fail-closed fallbacks) behind the same RC key (the app's first RC read); DER→r‖s converters; keyKind on app-side envelope/publish; frozen `android-se-…` vector. |
| F2 server | Queued agent grants verify SE-P256 authorities (`verifyPhoneControlAuthoritySignature`, key-kind-aware local-auth-proof verify) — closes the Ed25519-only queued-lane gap. |
| F7/F10 shared | Kotlin `MediaFrameAead`/`ControlFrameSeal` mirrors with Swift-emitted frozen fixtures (Swift seal → Kotlin open proven); Mac advertises `media_frame_aead_v1` + `control_seal_v1` + its streaming snapshot to phones. |
| L2 | Adapter signs every gateway request with PoP v2 (byte-locked canonical-query/stable-JSON/path mirrors incl. ICU key order); pairing registers the Ed25519 key + `popVersion: 2`; fork copy sha256-identical. |
| Tree fix | `CloudVaultRotationRewrapWorker` missing `try` (broken by 87d2a5230) — Mac app compiles again. |

### F2 — Hardware-bind the phone control signing key + per-action step-up
- **Now:** controller authority = possession of a software Ed25519 key + server
  controller record + iroh allowlist; after the first Mac approval, no per-intent
  re-auth.
- **Target:** generate/hold the phone control signing key in the Secure Enclave
  (iOS) / StrongBox-backed Keystore (Android) so it is non-exportable; require a
  biometric per signing for sensitive action classes (`shell`, `desktop_system_input`,
  unrestricted); shorten authority TTL + re-bind per session; make `revokePeer`
  clear the pin + allowlist atomically and surface a revocation receipt.
- **Shipped (core + server, tested):**
  - `PhoneControlSigningKeyKind` (`ed25519` | `se-p256`) on
    `HermesRealtimeRelayAuthorityEnvelope` — optional, absent ⇒ legacy ed25519;
    pre-F2 envelopes decode unchanged.
  - `PhoneControlVerifyingKey` — one algorithm-aware verify path (Ed25519 +
    P-256 raw/DER) used by the Mac validator and the cross-language KAT.
  - `PhoneControlPeerNodeIdDerivation` — the four canonical derivations
    (legacy iOS prefix-12, legacy Android sha256-24, SE iOS `ios-se-…`, SE
    Android `android-se-…`) in one place, byte-mirrored in the server.
  - `PhoneControlStepUpPolicy` — sensitive classes
    (`shell`/`shell_unrestricted`/`desktop_system_input`) require a fresh
    biometric step-up; an SE signature is self-proving (OS-enforced biometry),
    a legacy key must attach an explicit single-use local-auth proof.
  - Server: `publishPhoneControlAuthority` + `publishAgentGrantAuthority` accept
    `keyKind=se-p256` (x9.63 key, SE peerNodeId derivation), persist
    `signingKeyKind`, bump `schemaVersion` to 3. `revokeEscrowDeviceTrust`
    **atomically deletes the controller record(s) + the agent-grant authority**
    (closing the "revoked but still dialable" gap) and **emits a revocation
    receipt** (audit event + `receiptId` in the response).
- **Remaining (gated):** Mac `PhoneControlAuthorityValidator` must build a
  `PhoneControlVerifyingKey` from the record's `signingKeyKind` and verify
  se-p256 envelopes; iOS `PhoneControlSigningKeyStore` must mint a Secure
  Enclave key (`kSecAttrTokenIDSecureEnclave` + `.biometryCurrentSet` access
  control) and Android must use a StrongBox + `setUserAuthenticationRequired`
  Keystore key, both emitting `keyKind:"se-p256"`; Kotlin `PhoneControlSigner`
  P-256 mirror; shorten `authorityMaxLifetime` + re-run controller
  `controlClassify` registration per session. **Needs physical biometric/SE
  device testing.** No client emits se-p256 until this lands, so the foundation
  is dormant + backward-compatible today.

### F7 — Per-frame AEAD for media/screen (defense-in-depth beyond iroh transport)
- **Now:** media frames rely on iroh QUIC transport encryption between paired peers
  (confidential, but not a second app-layer seal like chat).
- **Target:** derive a media session key from the paired identities (HKDF over the
  pairing secret) and AEAD-seal each `MediaFrame`/`media.screen.video` payload, so a
  future non-iroh fallback can never carry plaintext and media matches the chat
  lane's depth. Requires `MediaFrame` v-bump + both peers advertising support
  (mirror the existing MediaFrame v2 capability gate).
- **Shipped (core, tested):** `OpenBurnBarMedia/MediaFrameAEAD` — `deriveSessionKey`
  (HKDF-SHA256 over the paired ECDH shared secret + per-session salt), `seal`/`open`
  (AES-256-GCM, `OBMFA1` envelope) with AAD binding `(streamClass, kind, gopID,
  frameIndex)` so a sealed frame cannot be replayed in another position or stream;
  `isSealedEnvelope` sniff; `MediaFrameAeadNegotiation` (`media_frame_aead_v1`,
  both-peers-required). 8 core tests.
- **Remaining (gated):** feed the key agreement from the pinned P-256 relay
  identities (the same identities the HPKE chat lane authenticates); **add the
  Mac→phone capability advertisement** (today the Mac never advertises
  `streamingCapabilities` back to phones — `MercuryRouter` heartbeat reply /
  `mediaMirrorAck`); seal before chunking in `MacFileTransferService`; open in
  iOS `MediaControlStreamCoordinator` + Android `MediaControlFrameDispatcher`;
  Kotlin `MediaFrameAEAD` mirror + a cross-language KAT.

### F10 — HPKE-wrap control iroh frames
- **Now:** `control.*` frames are dispatched directly on the iroh stream; mutating
  intents are still Ed25519-signed, but the control JSON itself isn't HPKE-wrapped
  like chat/CLI `request.start`.
- **Target:** open control streams only after the HPKE authenticated-request opener
  (reuse `HermesRelayAuthenticatedRequest`), or seal control JSON with the session
  key. Coordinated Swift + Kotlin change.
- **Shipped (core, tested):** `OpenBurnBarComputerUseCore/ControlFrameSeal` —
  `deriveSessionKey` (HKDF over the HPKE authenticated-request session key),
  `seal`/`open` (AES-256-GCM, `OBCFS1` envelope) with AAD binding
  `(peerNodeId, frameType)` so a sealed control frame can't be replayed across
  peers or re-typed; `ControlFrameSealNegotiation` (`control_seal_v1`). 6 core
  tests. (The signature lane already gives authenticity + replay protection;
  this adds the missing confidentiality.)
- **Remaining (gated):** thread the HPKE opener's per-request session `keyData`
  (already produced by `HermesRelayAuthenticatedRequestOpener.open`) to the
  control lane; seal in iOS/Android `PhoneControlSender`; open in
  `IrohRelayRequestHandler`'s `control.*` arm before `controlDispatcher`;
  advertise `control_seal_v1`; Kotlin `ControlFrameSeal` mirror.

### L2 — Fold the query string into the gateway PoP signed payload
- **Now:** the proof-of-possession signature covers `tokenHash | METHOD | path |
  bodyHash | nonce | timestamp`; GET query params are not integrity-protected
  (de-risked today by TLS + single-use nonce + uid-scoped E2EE responses).
- **Target:** add the raw query string to `gatewayPopSignablePayload` behind a **PoP
  v2** that both the external Hermes client and the server negotiate, accepting v1
  during a transition window. A unilateral server change would reject all current
  paired clients.
- **Shipped (server, tested):** `gatewayPopSignablePayloadV2` binds a canonical
  query string (`canonicalGatewayQueryString` — decoded params sorted by
  key/value, joined `k=v` with `&`, no percent-encoding variance). Version is
  negotiated per request via `x-openburnbar-pop-version`; the server verifies v1
  **or** v2 during the transition. The client doc carries a `popVersion`
  capability (captured at device/start + approve); once a client registers v2 a
  v1 downgrade is refused (`pop_v2_required`). 5 vitest cases incl. the proof
  that a tampered query is now caught (`bad_pop_signature`).
- **Shipped (adapter source, tested 2026-06-10):** the BurnBar platform adapter
  (`tools/hermes-platform-burnbar/adapter.py`, byte-identical copy synced to
  `~/.hermes/hermes-agent/plugins/platforms/burnbar/adapter.py`) now signs
  **every** gateway request with PoP v2: Ed25519 client signing key
  (Keychain-stored, minted + registered as `agentClientSigningPublicKeyBase64`
  with `popVersion: 2` at `device/start`), byte-locked mirrors of the server's
  `stableJSONString` (incl. ICU `localeCompare` key order), canonical query
  builder, `gatewayPath`, and payload lines; all 10 token-bearing call sites
  (`/events`, `/destinations`, `/state`, `/runtime`, `/approvals` GET+POST,
  `/messages`, `/typing`, `/attachments/init|finalize`) attach the headers. No
  key ⇒ falls back to bare Bearer (the pre-PoP wire, no new failure mode).
  13 unittest cases in `tools/hermes-platform-burnbar/test_adapter_pop.py`
  (run with `PYTHONPATH=~/.hermes/hermes-agent`), incl. the
  lowercase-before-uppercase ICU vector and a tampered-query negative.
- **Re-vendored (2026-06-10):** the signer is committed on the fork's pinned
  branch as `005cf0d86` and `third_party/hermes-agent/manifest.json` is bumped
  to it (`vendoredSourceTreeSha256` recomputed; `verify-vendored-agent-source.sh`
  hash-verifies at the new pin). `pendingHardening.blocking` stays true — the
  F5 gate keeps failing closed until the C-4 command-guard merges. **L2 is
  complete**; nothing L2-specific remains.

### Attestation default-on (remote-control F6) & full-key `peerNodeId` (remote-control F7)
- Flipping `computer_use_phone_control_attestation_required` to default-true requires
  every phone build to send `attestationHashBlake3` first (else control breaks);
  ramp via Remote Config once clients emit it.
- Widening the iOS `peerNodeId` from a 96-bit key prefix to the full key hash is an
  identity-format change that must land on the phone, the Mac validator, and the
  `requireDerivedPhoneControlPeerNodeId` server check together, and re-pairs
  existing controllers. (Severity is LOW/5; collision is impractical at 96 bits.)
- **Shipped (Android wire field, compiled + tests green):** the Kotlin
  `HermesRealtimeRelayAuthorityEnvelope` now carries `attestationHashBlake3` (and
  `keyKind`) as nullable fields — the field absence that would have denied **every
  Android controller** under strict attestation is closed at the wire level (the
  `:openburnbar-iroh-relay` module compiles and its unit tests pass with the new
  fields). The SE `peerNodeId` derivations are also already defined and tested in
  `PhoneControlPeerNodeIdDerivation` + the server (above), giving the full-key
  identity change a versioned home.
- **Landed 2026-06-10:** the Android attestation reader exists and produces a
  REAL digest (the server's `obb_app_check` claim is platform-agnostic and
  Android already binds Play-Integrity App Check): parses the ID-token claim,
  checks 30-day freshness, derives the identical
  `SHA-256("openburnbar.appcheck.v1|appId|boundAtMillis")`, and attaches it on
  every Android controller envelope (never enforcing — null on any failure,
  pre-F2 wire byte-identical). Android reads Remote Config since the F2 lane.
  iOS remote-unlock envelopes attach the cached digest. The attestation ramp
  can now include BOTH platforms.
- **Remaining (gated):** the full-key `peerNodeId` migration + Mac re-pair UX.
  Not launch-blocking while the RC flag stays default-off.

### F5 follow-through (out of this repo)
The C-4 agent command-guard and the server-side Telegram chat-ID allowlist live in
the pinned `NousResearch/hermes-agent` fork (vendored as bytecode). The ops-readiness
gate now blocks beta until that hardened runtime is merged, re-vendored, and
re-pinned (`third_party/hermes-agent/manifest.json` → `pendingHardening.blocking:false`).
