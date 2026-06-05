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
deployed until every gate below is cleared** (these were confirmed by an adversarial review):

1. **Sender authentication (BLOCKER).** The at-rest envelope is sealed with RFC 9180 HPKE
   **Base mode** (recipient public key only) and carries no sender field, while Signal-first
   readers accept it without cross-checking the secret-keyed legacy payload. Because identity
   public keys are server-readable, a malicious/compromised server could forge a readable,
   trusted envelope (e.g. for `approval_policies`, `cli_agent_mission_requests`). Fix before
   any flip: seal in HPKE **Auth mode** keyed by the writing device's identity private key and
   verify the asserted sender against the user's *pinned* trusted-device set (the relay path
   already uses Auth mode), or as interim hardening require byte-agreement with the legacy
   `sealedPayload` on read.
2. **Per-collection coverage.** The gate is domain-keyed but producers are per-collection.
   `signalSealedCollections` in the registry records the EXACT collections that emit an
   envelope (today: `conversations`, `chat_threads`, `mobile_assistant_chats`,
   `cli_agent_mission_requests`); the rest of `conversations_chat` stay legacy AES-GCM (still
   end-to-end). The scheme codename is internal/non-websited, so this is not a user-facing
   claim, but do not advertise whole-domain Signal coverage. Pensieve is intentionally NOT in
   the activation diff — its daemon/iOS/MCP ingest paths do not yet emit envelopes.
3. **No staged rollout / kill switch.** Activation is registry/compile-baked with no Remote
   Config, per-cohort, or percentage lever. Add a server-served flag AND-ed with the registry
   scheme before fleet activation so a flip can be canaried and instantly reverted without an
   app release.
4. **Publish-readiness.** Activation should be gated on every trusted escrow device having a
   published `signal_identity_public_keys/{deviceId}_{keyVersion}` doc; otherwise envelopes
   degrade to legacy-only for users with an un-upgraded peer (the producer fail-open prevents
   write loss, but coverage is incomplete until readiness is 100% for the cohort).
5. **Cross-language KAT + libsignal pin.** Pin `Vendor/libsignal` to a verified official
   0.94.4 build and add a Swift↔Android sealed-vector known-answer test before relying on
   cross-device opens.
6. **Revocation rewrap.** Revoking a device's trust flips its sessions to `revoked` but does
   NOT re-seal existing at-rest documents (rewrap is planning-only). A revoked device retains
   read access to previously-sealed content — identical to the legacy path. Do not claim a
   revoke evicts a device from past content until a rewrap executor ships.
