# Security Policy

## Supported Versions

OpenBurnBar supports the current `main` branch and the version declared in the repo metadata (`1.0.2` in this source release). Older commits may contain known issues and may not receive fixes.

## Reporting a Vulnerability

We take security bugs seriously. If you discover a security vulnerability, please report it responsibly.

**Please do not file a public GitHub issue for security vulnerabilities.**

Preferred private path:

1. Use GitHub's private vulnerability reporting or a draft security advisory if it is enabled for this repository. GitHub documents private vulnerability reporting as a public-repository feature, so confirm it immediately after visibility flips.
2. If private reporting is not available, contact the maintainer privately through the repository owner profile: https://github.com/Ajnunezg

### What to Include

A good vulnerability report should include:

- Type of vulnerability (e.g., injection, auth bypass, data exposure)
- Full paths of source file(s) related to the vulnerability
- Location of the affected source code (tag/branch/commit or direct path)
- Step-by-step instructions to reproduce the issue
- Proof-of-concept or exploit code (if possible)
- Impact assessment — how an attacker could exploit this

We do not promise formal SLA response times. Reports are handled on a best-effort basis.

## Security Best Practices for OpenBurnBar Users

- **Secrets**: Routed provider API keys, Hermes/OpenClaw bearer tokens, the controller Telegram bot token, and daemon-managed connector credentials use macOS Keychain with a device-local accessibility class.
- **Daemon auth tokens**: Socket and gateway auth tokens are passed to the daemon via launchd `EnvironmentVariables`, not CLI arguments, to prevent exposure via process listings (`ps aux`). The launchd plist is written with `0o600` permissions.
- **Encryption key recovery**: The SQLCipher key is stored only in the macOS Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. There is no automatic plaintext recovery file. If the Keychain entry is lost (for example during macOS migration, Keychain reset, or device loss), the encrypted database is unrecoverable unless the user previously exported an explicit passphrase-protected recovery bundle. Recovery bundles are created with `DatabaseEncryptionService.exportRecoveryBundle(password:)`, encrypted with PBKDF2-HMAC-SHA256 plus AES-GCM, and restored with `DatabaseEncryptionService.importRecoveryBundle(data:password:)`.
- **Local data**: Default storage is local SQLite. Cloud sync (Firebase) is opt-in.
- **Cloud sync scope**: When cloud sync is enabled, OpenBurnBar currently uploads usage rows and in-app OpenBurnBar chat threads for cross-device resume. The current source release also writes owner-scoped shared-artifact heads/revisions under `workspaces/workspace-{uid}/teams/team-default/artifacts/...`. Conversation metadata and full session-log backup remain separately gated by their own settings.
- **OAuth flows**: Firebase Auth handles Google and Apple sign-in. Verify redirect URIs match `com.openburnbar.app`.
- **Extension permissions**: The OpenBurnBar extension requests minimal capabilities. Review workspace trust settings in Cursor/VS Code.
- **Workspace tool boundaries**: Editor workspace tools are constrained to the opened workspace roots. In trusted workspaces, `apply_patch` and `run_terminal` still require explicit approval before execution.
- **Daemon socket**: The local daemon uses a UNIX domain socket. Ensure filesystem permissions restrict access to your user account only.
- **Cursor connector runtime**: The local connector bridge keeps provider API keys in Keychain and writes only Keychain lookup metadata plus a short-lived session token into OpenBurnBar's private support directory while the bridge is active.
- **Optional integrations**: Connector-plane, browser-tooling, and tunnel features expand the network surface area. Enable only the integrations you actually plan to use.

## Pre-Beta Security Gates

High-impact control paths are fail-closed:

- **Risky Agent Control grants**: `shell`, `workspace_write`, `desktop_*`, `desktop_system_input`, and `shell_unrestricted` grants require a single-use local-auth proof bound to the exact canonical operation hash. A normal account session can still request read-only/observe grants, but it cannot elevate to host-impacting control without hardware-backed local approval on a trusted device.
- **Hermes Gateway autonomous mode**: downgrades to supervised mode are normal authenticated account operations. Elevation to autonomous mode requires a trusted native escrow device, a high-risk callable nonce, a local-auth proof, and an audit event.
- **Hermes Gateway tokens**: gateway clients are pinned to an agent signing public key. Access tokens are short lived, and refresh/rotation requires proof-of-possession over nonce, timestamp, method, path, body hash, and token hash. Legacy bearer-only clients must rotate/re-pair.
- **Cloud Vault wrapping**: clients do not wrap new vault keys to a device merely because the server says it is trusted. A trusted local root pins its own Signal identity, and every additional device must carry a client-verifiable trust-chain signature over that device's escrow public key and Signal identity fingerprint before Mac, iOS, or Android will wrap future vault material to it.
- **Cloud Vault revocation**: revoking a device is not considered complete until a surviving trusted device rotates the vault key, verifies the survivor trust chains, rewraps survivor wrappers, removes revoked wrappers, re-seals document envelopes, re-seals session-log Storage blobs, and rekeys the hosted search index. The server coordinates the job but never receives vault keys or plaintext.
- **Signal/libsignal claims**: production activation remains blocked unless local gates, external crypto review, legal/store approval, and physical-device E2E evidence are all green. Until then, Signal paths are wired/readiness-gated, not marketed as live production coverage.

## Accepted Risks (deliberate design calls)

These are decisions, not oversights — recorded so external reviewers read them
as such (each has a trigger that would revisit it):

- **Single region (us-central1), single Redis** for the realtime relay and
  functions. Accepted while the user base is overwhelmingly US-based and
  pre-launch; revisit when sustained non-US traffic appears or relay p95
  cross-region latency becomes user-visible.
- **Single production Firebase project** (no staging environment). Tag-gated
  functions deploys, emulator-tested rules with a CI deploy + drift gate, and
  sub-minute revision rollback are the compensating controls; a staging
  project is the planned next step once a second operator exists.
- **Fake-SSE polling fallback** on some hosted surfaces instead of true
  server-sent streams. Bounded staleness traded for serverless simplicity.
- **Avatar images readable cross-tenant** (public-read avatars collection).
  Avatars are explicitly non-sensitive by policy; nothing else shares that
  rule shape.
- **Solo-operator process**: merge/control compensations are codified in
  [docs/SOLO_OPERATOR_POLICY.md](docs/SOLO_OPERATOR_POLICY.md).

## Known Limitations

- **Cost estimates**: Cost calculations use public pricing lists and do not reflect actual invoices. Do not use for financial reconciliation.
- **Parser heuristics**: Some provider log formats require estimation. The "Exact" vs "Estimated" column in the README indicates confidence level.
- **Factory exact quota**: OpenBurnBar no longer borrows session state from other local apps for Factory exact quota. Use explicit `FACTORY_COOKIE_HEADER` and/or `FACTORY_BEARER_TOKEN` overrides if you want the official API path.
- **Local settings**: Non-secret values such as gateway URLs, chat model overrides, and controller chat IDs still live in app preferences on the same Mac.
- **Third-party tunnels**: When using the Cursor connector with cloud tunnels, review tunnel provider privacy policies.

## Signal at-rest sealing — status and activation gates

The Signal HPKE at-rest dual-write (an additive `signalEnvelope` written alongside the
legacy AES-GCM `sealedPayload`) is **wired but NOT activated in production**. The activation
switch is the per-domain `sealingScheme` in `packages/data-domains/registry.json`; no
production domain carries `signal-hpke-identity-seal-v1` (enforced by
`scripts/ci/verify-signal-activation-parity.sh`). The legacy AES-GCM seal is the floor and
remains the only at-rest path until activation; producers fail **open** to legacy if a
Signal seal cannot be produced, so confidentiality never regresses.

A prepared activation diff exists for the `conversations_chat` domain only. **It MUST NOT be
deployed until every remaining gate below is cleared** (these were confirmed by an adversarial
review; ✅ items have since landed):

1. **Sender authentication — ✅ LANDED on Apple (Swift), Android parity REMAINING.** The
   at-rest envelope now carries a `senderAuth` block: the writing device signs the envelope
   (domain-separated over the HPKE info/binding + ciphertext + sorted wraps) with its identity
   PRIVATE key, and `OpenBurnBarSignalAtRest.openPayload` REQUIRES it and verifies the
   signature against the reader's PINNED trusted-device public key (never the wire field) —
   so a server holding only public keys cannot forge an accepted envelope (proven by
   `testServerForgedEnvelopeIsRejectedBySenderAuth`). Apple producers sign and readers verify
   (self-authored docs fully, cross-device falls back to legacy until the trusted-sender set
   is resolved on the read path). REMAINING before flip: (a) Android (Kotlin) must sign on
   write AND verify on read with the identical canonical signed-message + a Swift↔Android
   signature KAT; (b) wire cross-device trusted-sender resolution into the Apple readers.
2. **Per-collection coverage.** The gate is domain-keyed but producers are per-collection.
   `signalSealedCollections` in the registry records the EXACT collections that emit an
   envelope (today: `conversations`, `chat_threads`, `mobile_assistant_chats`,
   `cli_agent_mission_requests`); the rest of `conversations_chat` stay legacy AES-GCM (still
   end-to-end). The scheme codename is internal/non-websited, so this is not a user-facing
   claim, but do not advertise whole-domain Signal coverage. Pensieve is intentionally NOT in
   the activation diff — its daemon/iOS/MCP ingest paths do not yet emit envelopes.
3. **Staged rollout / kill switch — ✅ LANDED (Apple), Android RC bootstrap REMAINING.**
   `signalSealingIsEnabled` now requires BOTH the registry scheme AND a per-domain runtime
   flag `signal_at_rest_<domainID>_enabled` (default OFF), so a deployed-but-unramped flip is
   inert and activation is a console flip with staged % rollout + instant revert. iOS/Mac read
   it from Firebase Remote Config directly; Android reads it from an injected
   `signalAtRestActivationProvider` (fail-closed false) — wiring that provider to Firebase
   Remote Config (add `firebase-config`, bootstrap in `BurnBarApplication`) is the REMAINING
   one-line step before Android can be ramped.
4. **Publish-readiness — ✅ LANDED.** The `signalActivationReadiness` callable reports, per
   account, whether every trusted escrow device has a valid published Signal identity; the
   activation runbook ramps the kill switch only where readiness is 100% for the cohort. (The
   producer fail-open already prevents write loss when a peer is un-upgraded.)
5. **Cross-language KAT + libsignal pin.** The sender-auth signed message is now length-
   prefixed + NFC-normalized + byte-wise sorted, so it is byte-stable across languages by
   construction; still pin `Vendor/libsignal` to a verified official 0.94.4 build and add a
   Swift↔Android sealed-vector + sender-signature known-answer test before relying on
   cross-device opens. (An independent cross-model adversarial review confirmed the
   forgery hole is closed and fail-closed; the open items above are coverage/interop, not
   forgery vectors.)
6. **Revocation rewrap.** CloudVault rotation and client-side rewrap workers now exist, including
   session-log Storage blob resealing and hosted-search index rekeying. Product copy must still say
   revocation is complete only after the `cloud_vault_rotation_jobs/{jobId}` record reaches
   `complete`; a device that already cached plaintext before revocation cannot be clawed back.
