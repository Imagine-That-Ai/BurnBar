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
| Docs | Corrected stale SQLCipher recovery-file claims, the gateway-destinations writability claim, disclosed the post-revocation non-E2E token-TTL window, and added a precise media confidentiality model. | `SECURITY_PRIVACY_REVIEW.md`, `RELIABILITY_OPS_REVIEW.md`, `docs/HERMES_GATEWAY_PLATFORM.md`, `docs/PRIVACY.md`, `docs/HERMES_MEDIA_TRANSPORT.md` |
| L7 | Already mitigated (backend hosts hard-deny cleartext; app-layer `validatedBaseURL` scopes HTTP to localhost/RFC1918). Flipping base-config to deny would regress the LAN-direct feature; tracked below. | `android/.../network_security_config.xml` |

## Remaining — protocol / multi-client (gated before beta)

These require coordinated Swift + Kotlin + TypeScript changes with explicit version
negotiation, cross-language known-answer tests, and physical-device validation. They
are **not** safe to half-ship.

### F2 — Hardware-bind the phone control signing key + per-action step-up
- **Now:** controller authority = possession of a software Ed25519 key + server
  controller record + iroh allowlist; after the first Mac approval, no per-intent
  re-auth.
- **Target:** generate/hold the phone control signing key in the Secure Enclave
  (iOS) / StrongBox-backed Keystore (Android) so it is non-exportable; require a
  biometric per signing for sensitive action classes (`shell`, `desktop_system_input`,
  unrestricted); shorten authority TTL + re-bind per session; make `revokePeer`
  clear the pin + allowlist atomically and surface a revocation receipt.
- **Why staged:** changes the key-custody model and the signing UX on both mobile
  clients + the Mac validator; needs device biometric testing.

### F7 — Per-frame AEAD for media/screen (defense-in-depth beyond iroh transport)
- **Now:** media frames rely on iroh QUIC transport encryption between paired peers
  (confidential, but not a second app-layer seal like chat).
- **Target:** derive a media session key from the paired identities (HKDF over the
  pairing secret) and AEAD-seal each `MediaFrame`/`media.screen.video` payload, so a
  future non-iroh fallback can never carry plaintext and media matches the chat
  lane's depth. Requires `MediaFrame` v-bump + both peers advertising support
  (mirror the existing MediaFrame v2 capability gate).

### F10 — HPKE-wrap control iroh frames
- **Now:** `control.*` frames are dispatched directly on the iroh stream; mutating
  intents are still Ed25519-signed, but the control JSON itself isn't HPKE-wrapped
  like chat/CLI `request.start`.
- **Target:** open control streams only after the HPKE authenticated-request opener
  (reuse `HermesRelayAuthenticatedRequest`), or seal control JSON with the session
  key. Coordinated Swift + Kotlin change.

### L2 — Fold the query string into the gateway PoP signed payload
- **Now:** the proof-of-possession signature covers `tokenHash | METHOD | path |
  bodyHash | nonce | timestamp`; GET query params are not integrity-protected
  (de-risked today by TLS + single-use nonce + uid-scoped E2EE responses).
- **Target:** add the raw query string to `gatewayPopSignablePayload` behind a **PoP
  v2** that both the external Hermes client and the server negotiate, accepting v1
  during a transition window. A unilateral server change would reject all current
  paired clients.

### Attestation default-on (remote-control F6) & full-key `peerNodeId` (remote-control F7)
- Flipping `computer_use_phone_control_attestation_required` to default-true requires
  every phone build to send `attestationHashBlake3` first (else control breaks);
  ramp via Remote Config once clients emit it.
- Widening the iOS `peerNodeId` from a 96-bit key prefix to the full key hash is an
  identity-format change that must land on the phone, the Mac validator, and the
  `requireDerivedPhoneControlPeerNodeId` server check together, and re-pairs
  existing controllers. (Severity is LOW/5; collision is impractical at 96 bits.)

### F5 follow-through (out of this repo)
The C-4 agent command-guard and the server-side Telegram chat-ID allowlist live in
the pinned `NousResearch/hermes-agent` fork (vendored as bytecode). The ops-readiness
gate now blocks beta until that hardened runtime is merged, re-vendored, and
re-pinned (`third_party/hermes-agent/manifest.json` → `pendingHardening.blocking:false`).
