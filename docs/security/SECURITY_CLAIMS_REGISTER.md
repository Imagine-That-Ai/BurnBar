# Security Claims Register

This register is the claim boundary for public copy, release notes, app-store copy, and reviewer packets. If product language conflicts with this file, this file wins until code and live evidence prove otherwise.

**Remediation status legend**
- **CLOSED (verified)** — fixed in code AND proven by a gate this environment ran (TS/JS vitest, node --test, shell, YAML lint, Firestore emulator, or a SwiftPM `swift test` / Android `gradlew testDebugUnitTest`).
- **CLOSED (build-gated)** — fixed in code, matched to an existing-correct sibling pattern, with tests added; final compile proven only by the team's full Xcode app-target / device CI (cannot `xcodebuild`/sign here). Adversarially reviewed.
- **MITIGATED** — the exploitable lock-up is removed, but full activation depends on a native client handler or operator step named below.
- **ACCEPTED RESIDUAL** — deliberately not closed; named with its caveat so no copy claims it done.
- **OPERATOR-ONLY** — code/CI is done; the remaining step is live console/portal/device state that cannot be set from the repo.

---

## Cure53 residual-risk remediation (this cycle)

| RR | Risk | Status | Gate / evidence |
|---|---|---|---|
| RR-1 | Local DB plaintext at rest (SQLCipher inert) | **PARTIAL — honest-degrade CLOSED, real encryption OPERATOR-ONLY** | App degrades to *disclosed* plaintext (persistent banner, never silent/brick); daemon now keys its DB + runs a plaintext→encrypted migration **gated on codec presence** (`BurnBarDaemonDatabaseCipher`, `swift test` PASS). Real encryption still needs the SQLCipher codec vendored (see Tracked Residuals). |
| RR-2 | Plaintext provider-credential continuity file | **CLOSED (verified)** | `OpenBurnBarProviderExecutor` scrubs the file on init and no longer reads/writes it; Keychain-only. |
| RR-3 | Daemon binary swap / no pre-exec sig check | **CLOSED (build-gated)** | Main daemon socket validates each peer's audit-token code signature (designated requirement) before honoring RPCs, fail-closed (`BurnBarDaemonPeerAuthenticator`, default `enforced:true`); app re-validates the on-disk binary before each launch. `swift test` 15/0-fail; adversarially CONFIRMED_CLOSED. |
| RR-4 | No PITR/backups; NXDOMAIN alerting | **PARTIAL — gate CLOSED, live state OPERATOR-ONLY** | `verify-firestore-disaster-recovery.sh` fails closed on missing PITR/delete-protection/backup-schedule; `ops-alerts-gate.mjs` now fails unless every required channel is enabled AND (email/sms) `verificationStatus===VERIFIED` with placeholder targets rejected (`node --test` 10/10). Enabling the live GCP state + repointing the alert domain is operator-only. |
| RR-5 | Revocation never rotates vault key | **MITIGATED (build-gated)** | Server `listPendingCloudVaultRotationRequirements` + `detectStalePendingCloudVaultRotations` (vitest PASS) let any surviving trusted device complete rotation; Mac + Android clients drive rotate+rewrap on revoke and pick up pending rotations on launch (adversarially CONFIRMED_CLOSED on Android). Requires the native wake-to-rotate handler to run; server side verified + `firestore.indexes.json` COLLECTION_GROUP index added. |
| RR-6 | Mac→phone escrow export was a stub | **CLOSED (build-gated)** | `MacEscrowCredentialProducer` writes real ECIES `escrow_envelopes` byte-identical to the iOS import path; adversarially CONFIRMED_CLOSED (seal↔import round-trip). |
| RR-7 | Android parity (sender-auth, wire-approval, attestation, unlock cred) | **CLOSED (build-gated)** | Android now produces+verifies XEdDSA at-rest sender-auth fail-closed; over-the-wire approval ingest + signed send wired with Swift↔Kotlin `respondedAt` KAT parity; attestation made enforcing; unlock cred OS-auth-bound. `gradlew testDebugUnitTest` PASS; adversarially CONFIRMED_CLOSED. |
| RR-8 | At-rest large/recall payloads no path AAD | **CLOSED (verified)** | Pensieve chunks now seal+open path-bound (`CloudVaultAADContext`); writer/reader wire serialization carries `schemaVersion`+`aad` (the activation exposed a drop bug — fixed + regression test). `swift test` 11/11 incl. a wire round-trip KAT proving the fields are load-bearing. Freshness/replay still accepted (below). |
| RR-9 | Kill switches / budget / F7 fail open | **CLOSED (build-gated + verified)** | RC kill switches fail closed (prior); media budget RC-failure clamps to hard-cap (vitest PASS); cold-start/transient budget resolves conservative; F7 negotiation refuses audio/camera/file lanes when sealing is expected-but-unavailable (screen-video still degrades). |
| RR-10 | Sentry would capture request bodies | **CLOSED (verified)** | `requestDataIntegration` removed, `sendDefaultPii:false`, recursive scrub in `beforeSend`; vitest PASS, CI-wired. |
| RR-11 | Hosted-MCP live adversarial proofs ran nowhere | **CLOSED (verified)** | Deterministic in-process suite (cross-tenant, revoked-client, non-entitled, rate-cap, at-rest-sealed) over real auth/cursor/resource code paths; `npm test` 61/61 + `prove-hosted-mcp-live.mjs --local` 7/7; wired as the blocking `security-pr` gate. |
| RR-12 | Rules soft-spots + suite ran in zero CI | **CLOSED (verified)** | Key-wrapper owner-delete denied; `users/{uid}` root allowlist; Pi relay sender-auth added; **escrow-device identity-field introduction hole closed** (was a real, never-CI'd permissiveness bug). `firestore-rules-tests` now CI-gated (`test:ci`: computer-use 16/16, media-budget, rr12-relay-and-root 7/7). |
| RR-13 | Symmetric MCP token mints any uid | **CLOSED (verified)** | `assertProductionTokenPosture()` fails closed at boot unless Ed25519 verification configured + legacy HMAC disabled; shim plaintext fallback needs explicit opt-in. config.test.ts PASS, CI-wired. |
| RR-14 | iOS chat at-rest / no privacy overlay | **CLOSED (build-gated) + OPERATOR-ONLY entitlement** | Chat JSON written `.completeFileProtection` + backup-excluded; default-data-protection entitlement added; Mac-mirror screens carry a privacy overlay on `.inactive`/`.background` + `UIScreen.isCaptured`. The entitlement must be enabled on the App ID / provisioning profiles (portal). |
| RR-15 | Injection feedback loop + browser SSRF | **CLOSED (verified)** | DNS-rebind resolve-and-block (fail-closed) at the route chokepoint; focus transcript + CU tool results provenance-wrapped; both CI-wired (`test-playwright-bridge-guard.mjs`, security tests). |
| RR-16 | Supply chain (AAR parity, curl\|sh, SAST) | **CLOSED (verified)** | iroh AAR rebuild-parity (`git diff --exit-code`); remote-shell installers removed + verifier; Kotlin in CodeQL; Rust `cargo audit` SAST (`rust-sast.yml`). |
| RR-17 | Governance / branch protection | **PARTIAL — verifier CLOSED, live state OPERATOR-ONLY** | `verify-github-governance.sh` fails closed on missing main/release/production protection; security gates also fire on push to main (direct-push backstop). Enabling branch/environment protection + making the verifier a required check is operator-only. |
| RR-18 | Media files plaintext / teardown / gate | **PARTIAL (build-gated)** | Quarantine xattr + safe names; per-peer mid-stream teardown wired on allowlist refresh; inbound file-transfer capability gate injected. Received-file at-rest *sealing* is wired but inert (no per-connection key store) — see Tracked Residuals. |
| RR-19 | Pensieve vector geometry | **ACCEPTED RESIDUAL** | Caveats present; honesty-copy gate bans "zero-knowledge semantic search". |
| RR-20 | §9.2 / App.E claim drift | **CLOSED (verified)** | Website/wiki over-claims conditioned down; `THREAT_MODEL.md` SQLCipher prose corrected; App.E stale docs refreshed; honesty-copy gate extended (`--self-test` 5 MUST-FAIL / 6 MUST-PASS PASS). |

---

## Current Accurate Claims

| Surface | Allowed claim | Required caveat / proof |
|---|---|---|
| Local macOS database | The app fails loud (persistent banner), never silent, when at-rest encryption is requested but the SQLCipher codec is absent; the daemon keys the shared DB + migrates plaintext once the codec is present. | The DB is still **plaintext on disk today** (codec not yet vendored). Never say "encrypted database" until the codec lands and `cipher_version` is non-empty in a release build. |
| Cloud Vault sealed payloads | High-risk and recall writers (chats, CLI mirrors, conversations, **Pensieve knowledge chunks**) bind AES-GCM payloads to uid+collection+doc+field; the reader rebuilds that AAD from the path, so same-account transplant fails. | Legacy global-AAD rows remain readable for migration. Same-path stale-document replay by a malicious storage service is not cryptographically eliminated without a monotonic revision/read-state protocol. |
| Signal at-rest envelopes | Path-bound and sender-authenticated where enabled, on **iOS, macOS, and Android** (XEdDSA sender-auth verified fail-closed vs the pinned trusted-device set). | Lane stays flag-OFF in production. Do not call this whole-product "Signal-quality privacy"; metadata, search indexes, and legacy fallback surfaces remain outside that claim. |
| Pensieve / semantic search | Content bodies/snippets sealed; token/semantic indexes keyed/opaque. | Cloaked vectors preserve similarity geometry. Do not claim "zero-knowledge semantic search" or "semantic memory is private from us." |
| Hosted Remote MCP | Production refuses to boot unless asymmetric Ed25519 verification is configured and legacy HMAC disabled; cross-tenant/revocation/entitlement/cap/at-rest isolation is proven on every PR by an in-process adversarial suite. | HMAC tokens are a legacy transition path only; plaintext env/file token sources require explicit insecure opt-in. |
| Sentry | Functions Sentry init scrubs request bodies, cookies, query strings, secret-like headers, breadcrumbs, contexts, extras; `requestDataIntegration` removed; `sendDefaultPii:false`. | Pattern scrubbers are not a license to log secrets. New logging fields still need review. |
| Remote Config kill switches | Computer Use and media kill switches default killed/closed when RC is absent or fetch fails; media budget clamps to hard-cap on RC failure. | Operators must explicitly publish remote false values to open these features. |
| Firestore disaster recovery | Production readiness requires live Admin API proof of PITR, delete protection, and ≥1 backup schedule. | Run `bash scripts/ops/verify-firestore-disaster-recovery.sh`; documentation-only evidence is not accepted. |
| Ops alerting | A required alert channel counts only if enabled AND (email/sms) `verificationStatus===VERIFIED`, with placeholder/unresolvable targets rejected. | Run the ops-alerts gate; an NXDOMAIN/unverified channel no longer reads green. |
| GitHub governance | Production readiness requires live GitHub API proof of main branch protection + release/production environment protection. | Run `bash scripts/ops/verify-github-governance.sh`. A live run still reports the production environment lacks protection rules — close that before claiming governance is enforced; the verifier is not yet a PR-required check. |
| Computer Use browser tool | Blocks navigation to loopback/link-local/private/cloud-metadata targets incl. hosts that *resolve* to those addresses (DNS-rebinding), fail-closed. | Enforced by `node scripts/test-playwright-bridge-guard.mjs` (CI job `browser-target-policy`). Residual: a TTL rebind flipping AFTER the resolver check needs connection-IP pinning Playwright doesn't expose; daemon bearer is defense-in-depth. |
| Cloud Vault revocation | Revocation severs grants/controllers immediately and now schedules vault-key rotation any surviving trusted device (Mac or Android) completes; a server sweep nudges stale rotations. | Until a surviving device runs the rotation, a pre-revocation cached key still reads pre-revocation content. Do not say "revocation immediately makes old data safe." |
| Mac→phone credential escrow | Device-to-device transfer is ECIES ciphertext only and the Mac export producer is real (no longer a stub). | BYOK keys are stored in the OS Keychain and sent only to the providers you choose; BurnBar's servers never receive them in plaintext. |

---

## Tracked Residuals (open — gated, not yet closeable as claims)

| Residual | Why still open | Closure gate |
|---|---|---|
| RR-1 **real** local DB encryption | The SPM `GRDB`/`CSQLite` target links stock `sqlite3` (no `SQLITE_HAS_CODEC`); daemon keying + migration are implemented but no-op until a real codec is linked. | Vendor a SQLCipher SPM target/XCFramework so `cipher_version` is non-empty in a release build; un-quarantine the codec-gated tests (`DAEMON_SQLCIPHER_PRESENT=1`). Until then: "plaintext on disk, protected by macOS file permissions; at-rest encryption pending." |
| RR-8 freshness/replay | At-rest envelopes have no monotonic revision/read-state, so a malicious storage service can replay an old valid same-path envelope. | Add a doc-id+revision/read-state binding (signalEnvelope sequence) to the AAD or a separate freshness channel. |
| RR-18 received-file at-rest sealing | The file-transfer seal-key provider returns nil — there is no per-(uid,connection) media-seal key store on the receive path, so received blobs stay quarantine-only plaintext in Caches. | Persist the opened media-seal session key per connection when a mirror request's `mediaSealKey` is opened, then have the provider look it up to seal received bytes. |
| RR-14 iOS data-protection entitlement | `com.apple.developer.default-data-protection` must be enabled on the App ID + provisioning profiles for the new per-write protection to take effect on signed builds. | Enable the Data Protection capability in the Apple Developer portal; regenerate profiles. |
| RR-4 / RR-17 live posture | PITR/backups/delete-protection ON, alert domain repointed, App Check `ENFORCED` (Firestore + Storage), GitHub main/release/production protection — all live console/portal state. | Run the fail-closed `scripts/ops/verify-*` verifiers with creds; make them required checks. |
| Pre-existing `session-log-backup` rules failures | 3 cases (Pro-entitlement manifest accept/refresh/overwrite) fail standalone on the base tree — unrelated to Cure53, previously masked by the umbrella `npm test` aborting in computer-use. | Triage the entitlement-rule vs test-seed mismatch; the RR-12 CI gate runs them non-blocking so they stay visible. |

---

## Banned Shortcuts

- "Zero-knowledge" unless the sentence immediately names the remaining metadata/index/vector leakage.
- "Server learns nothing" or "server searches without reading it."
- "Signal-quality privacy" for the whole product.
- "Semantic memory is private from us."
- "Revocation immediately makes old data safe."
- "Encrypted database" when SQLCipher is disabled or when a legacy plaintext database has not been migrated.
- Unconditional "end-to-end encrypted" / "no one in the middle, and that includes us" / "API keys never leave the device" / "never appears anywhere you didn't put it" — condition to the readiness-gated trust-page voice (enforced by `scripts/ci/verify-signal-honesty-copy.sh`).

## Review Rule

Any new claim about confidentiality, replay resistance, revocation, disaster recovery, governance, or production readiness must cite one of:

- a test or CI gate in this repository,
- a live verifier command under `scripts/ops/`,
- a signed release/provenance artifact,
- or an explicit accepted residual in this register.
