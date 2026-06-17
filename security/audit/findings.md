>>>>>>> REPLACE
# Findings

## Legend

- **Status:** open / fixed / partially fixed / accepted risk / needs evidence / needs decision
- **Severity:** Critical / High / Medium / Low / Informational
- **Evidence confidence:** high / medium / low

---

## FINDING-001 — Local SQLite database is plaintext by default

| Field | Value |
|---|---|
| **Severity** | Critical |
| **Category** | Cryptography / Privacy |
| **Component** | AgentLens, OpenBurnBarDaemon, local SQLite |
| **Affected asset** | ASSET-001 (local SQLite) |
| **Status** | open |
| **First seen** | 2026-06-16 |
| **Related threats** | THREAT-001, THREAT-010 |
| **Related claims** | CLAIM-003, CLAIM-004 |

**Description:** The canonical local store (`~/Library/Application Support/OpenBurnBar/OpenBurnBar.sqlite`) is a standard SQLite file opened via GRDB. The SQLCipher-at-rest path is designed but the codec is not vendored, so shipped builds use plaintext on disk.

**Evidence:**
- `docs/THREAT_MODEL.md:128-131`: "The local DB is plaintext on disk today, protected by macOS file permissions."
- `docs/THREAT_MODEL.md:131`: "This codec is not yet vendored, so the encrypted path is not active in shipped builds — do not state or imply that the local database is encrypted at rest."
- `AgentLens/Services/DatabaseEncryptionService.swift` (design only; not active)

**Impact:** Any same-user process or anyone with filesystem access can read the user's full usage history, chat transcripts, session logs, and provider account metadata.

**Existing controls:** macOS file permissions (owner-only); Keychain for secrets.

**Missing controls:** Active SQLCipher linking and `PRAGMA key` enforcement in shipped builds.

**Recommendation:** Either (a) vendor and activate SQLCipher end-to-end with Keychain-backed keys and migration, or (b) remove any marketing/copy that implies local encryption.

**Acceptance criteria:**
- Release build links SQLCipher.
- `DatabaseEncryptionService` activates encryption and fails closed if the library is missing.
- Regression test verifies `PRAGMA cipher_version` and rejects plaintext fallback when encryption is requested.

**Suggested tests:**
- Build Release .app and run `otool -L` to confirm SQLCipher linkage.
- Unit test: open encrypted DB, verify `PRAGMA cipher_version`, attempt plaintext fallback fails.

**Owner suggestion:** Core platform team.

---

## FINDING-002 — macOS app and daemon run unsandboxed with full home-directory access

| Field | Value |
|---|---|
| **Severity** | Critical |
| **Category** | Local privilege / Sandboxing |
| **Component** | AgentLens, OpenBurnBarDaemon |
| **Affected asset** | All local assets |
| **Status** | accepted risk (documented) |
| **First seen** | 2026-06-16 |
| **Related threats** | THREAT-002 |

**Description:** The app intentionally runs without macOS App Sandbox (`com.apple.security.app-sandbox = false`) and the daemon is unsandboxed. This is required to read agent logs across the home directory and manage the daemon.

**Evidence:**
- `README.md:477-487` explains the sandbox decision and its implications.
- `docs/THREAT_MODEL.md:113-127`: "If the app is compromised, the attacker has full access to the user's home directory."

**Impact:** A compromised app or daemon has full access to the user's home directory, local DB, and any secret the user can access.

**Existing controls:** Secrets in Keychain, code signing + notarization as a secondary boundary.

**Missing controls:** Sandboxing is infeasible by design. Defense relies on code quality and gatekeeping high-risk actions.

**Recommendation:** Keep this as an explicit non-claim. Add runtime integrity checks (e.g., verify code signature of daemon binary). Consider Hardened Runtime + Library Validation for the daemon.

**Acceptance criteria:**
- Security claims clearly state the app is unsandboxed and what that means.
- Daemon binary code-signature verified before app connects.

**Owner suggestion:** macOS platform team.

---

## FINDING-003 — Computer Use high-impact actions lack complete adversarial test coverage

| Field | Value |
|---|---|
| **Severity** | High |
| **Category** | AI / Agentic / Authorization |
| **Component** | Computer Use subsystem |
| **Affected asset** | ASSET-013 (audit chain), user Mac |
| **Status** | open |
| **First seen** | 2026-06-16 |
| **Related threats** | THREAT-005 |
| **Related claims** | CLAIM-008 |

**Description:** Computer Use provides 13 tool kinds spanning browser automation, Mac input injection, and Accessibility inspection. While Manual/Step/Trusted modes and scope rules exist, adversarial coverage (scope bypass, deny-region bypass, trust-mode downgrade, kill-switch latency) is not complete.

**Evidence:**
- `docs/HERMES_COMPUTER_USE.md:125-156` describes trust modes and scope rules.
- `docs/HERMES_COMPUTER_USE.md:315-325` describes capability gate.
- No comprehensive adversarial test matrix found in `AgentLensTests/Active/` for all 13 tools.

**Impact:** A bug or poisoning attack could allow unauthorized input injection, screen capture, or cross-app data access.

**Existing controls:** Manual default, scope rules with deny precedence, built-in denies, four kill switches, audit chain.

**Missing controls:** Adversarial regression tests covering every tool kind, scope bypass attempts, and kill-switch latency.

**Recommendation:** Add a security test target with parameterized abuse cases for each tool kind and trust mode.

**Acceptance criteria:**
- Test matrix covers all 13 `BurnBarToolKind` cases.
- Tests verify deny-region, secure-focus, scope-rule precedence, and kill-switch reaction.

**Owner suggestion:** Computer Use team.

---

## FINDING-004 — Prompt and RAG injection defenses are partial

| Field | Value |
|---|---|
| **Severity** | High |
| **Category** | AI / Agentic / Input validation |
| **Component** | Chat, ContextBuilder, CLIArgumentBuilder, parsers, Computer Use tool results |
| **Affected asset** | ASSET-001, user actions |
| **Status** | open |
| **First seen** | 2026-06-16 |
| **Related threats** | THREAT-004, THREAT-007 |
| **Related claims** | — |

**Description:** Untrusted content from agent logs, webpages, and tool results is retrieved into LLM prompts. Prior review added untrusted-content framing in some paths, but coverage is not uniform across all 17 parsers, `ContextBuilder`, `ChatSessionController`, and Computer Use tool-result paths.

**Evidence:**
- `docs/security/LLM_GENAI_AGENT_THREAT_MODEL.md:140-151` documents prompt injection vectors.
- `docs/security/LLM_GENAI_AGENT_THREAT_MODEL.md:323-334` describes implemented hardening.
- `docs/security/LLM_GENAI_AGENT_THREAT_MODEL.md:256`: "No retrieval-time trust scoring or provenance tagging."

**Impact:** Indirect prompt injection can override instructions, causing data exfiltration, unauthorized actions, or cost abuse.

**Existing controls:** Some `LLMSafeContent` wrappers; grounding instructions; model allowlist stub.

**Missing controls:** Uniform provenance wrapper on all retrieved/tool-result content; adversarial regression tests.

**Recommendation:**
1. Wrap all evidence, focus transcripts, Computer Use extracts, and AX results with `<UNTRUSTED_CONTENT>` + warning.
2. Add prompt-injection regression tests using the six payloads from `docs/security/LLM_GENAI_AGENT_THREAT_MODEL.md:152-179`.

**Acceptance criteria:**
- All parser outputs pass through a provenance wrapper before indexing or prompt use.
- `AgentLensTests/Active/CLIBridgeTests.swift` or new security suite asserts wrappers present.

**Owner suggestion:** AI/agent team.

---

## FINDING-005 — App Check enforcement for Firestore is documented but not verifiable from code

| Field | Value |
|---|---|
| **Severity** | High |
| **Category** | Cloud / Authorization |
| **Component** | Firebase Firestore, Cloud Functions |
| **Affected asset** | ASSET-005/006 |
| **Status** | open |
| **First seen** | 2026-06-16 |
| **Related threats** | THREAT-003 |
| **Related claims** | CLAIM-006 |

**Description:** Firestore security relies on owner-scoped rules, but rules alone cannot block non-app clients. App Check must be enforced in the Firebase console. The repo documents this requirement but cannot verify production console state.

**Evidence:**
- `firestore.rules:20-23`: comment stating App Check must be enforced in console.
- `functions/src/auth.ts:53-61`: `assertAppCheck` is config-driven and skipped when `enforceAppCheck` is false.
- `docs/FIREBASE_APP_CHECK_ENFORCEMENT.md` (referenced, not read in detail).

**Impact:** If App Check is not enforced, an attacker with a valid Firebase Auth token can access any user's owner-scoped data from a non-app client.

**Existing controls:** `assertAppCheck`, `enforceAuthAndAppCheck`, App Check SDK initialization.

**Missing controls:** Runtime probe in CI/staging that verifies console enforcement; attestation max-age policy (prior audit M-031).

**Recommendation:** Add a CI/staging test that attempts Firestore access without a valid App Check token and assert it fails.

**Acceptance criteria:**
- Production console App Check enforcement verified.
- Attestation max-age documented and enforced.

**Owner suggestion:** Cloud/platform ops.

---

## FINDING-006 — Cloud sync leaks routing/count metadata to Firestore

| Field | Value |
|---|---|
| **Severity** | Medium |
| **Category** | Privacy |
| **Component** | CloudSync, Firestore |
| **Affected asset** | ASSET-005/006 |
| **Status** | accepted risk (documented) |
| **First seen** | 2026-06-16 |
| **Related threats** | THREAT-010 |
| **Related claims** | CLAIM-004, CLAIM-005 |

**Description:** While private content is sealed, Firestore still receives provider/runtime identifiers, status, timestamps, device IDs, token counts, costs, opaque document IDs, and sealed-envelope metadata.

**Evidence:**
- `README.md:414`: "Firestore can still see routing/count metadata such as provider/runtime identifiers, status, timestamps, device ids, token counts, cost estimates, opaque document ids, and sealed-envelope metadata."
- `docs/THREAT_MODEL.md:145`: same statement.

**Impact:** Usage patterns, device graphs, and approximate spend are visible to Firebase/Google.

**Existing controls:** User opt-in; disable sync anytime.

**Missing controls:** Differential privacy / aggregation before upload.

**Recommendation:** Keep as documented non-claim; ensure trust copy does not overstate privacy.

**Acceptance criteria:**
- Marketing/site copy reviewed against `docs/security/CONFIDENTIALITY_POLICY.md`.

**Owner suggestion:** Product/legal.

---

## FINDING-007 — Daemon RPC relies on single auth token and same-user UNIX socket

| Field | Value |
|---|---|
| **Severity** | Medium |
| **Category** | Local authorization |
| **Component** | OpenBurnBarDaemon |
| **Affected asset** | ASSET-010, local state |
| **Status** | accepted risk (documented) |
| **First seen** | 2026-06-16 |
| **Related threats** | THREAT-006 |

**Description:** The daemon listens on a UNIX socket at `~/Library/Application Support/OpenBurnBar/openburnbar-daemon.sock` and requires an auth token passed via launchd environment. Any process running as the same user that can read the plist can connect.

**Evidence:**
- `docs/THREAT_MODEL.md:48-76` describes daemon threat surface and residual risk.

**Impact:** Same-user malware can invoke daemon RPC methods, including reading local state and triggering tools within granted capabilities.

**Existing controls:** Filesystem ACL (0o600 socket), auth token, input size cap, typed Codable methods.

**Missing controls:** Per-client capability isolation; second-factor for high-risk RPC.

**Recommendation:** Document as accepted same-user risk. Consider per-client tokens with capability scopes if feasible.

**Acceptance criteria:**
- Threat model clearly states same-user trust assumption.

**Owner suggestion:** Daemon team.

---

## FINDING-008 — Local MCP server exposes raw search snippets without human gate

| Field | Value |
|---|---|
| **Severity** | Medium |
| **Category** | AI / Agentic / Information disclosure |
| **Component** | `tools/openburnbar-mcp/server.py` |
| **Affected asset** | ASSET-001 |
| **Status** | open |
| **First seen** | 2026-06-16 |
| **Related threats** | THREAT-007 |

**Description:** The local stdio MCP server exposes semantic search over the user's SQLite DB to external agents (Cursor/Claude Desktop). Results are raw snippets that can be poisoned or leak sensitive context; no human approval gate exists.

**Evidence:**
- `docs/security/LLM_GENAI_AGENT_THREAT_MODEL.md:240-241`: "Local MCP (openburnbar-mcp): Semantic search over chunks, usage ledger, resume, burnbar DB queries — None (stdio to Cursor/Claude Desktop etc.)."

**Impact:** Poisoned or sensitive snippets fed into an external agent can cause harmful actions or disclosures.

**Existing controls:** External agent workspace trust.

**Missing controls:** Provenance wrapper on MCP results; UI/audit surface showing what the MCP read.

**Recommendation:** Wrap MCP search results with `<UNTRUSTED_CONTENT>` and add an audit log visible to the user.

**Acceptance criteria:**
- `tools/openburnbar-mcp/server.py` returns wrapped snippets.
- UI shows recent MCP queries.

**Owner suggestion:** MCP/integrations team.

---

## FINDING-009 — Cursor connector Cloudflare quick tunnel exposes local gateway on public URL

| Field | Value |
|---|---|
| **Severity** | Medium |
| **Category** | Network exposure |
| **Component** | Cursor connector / routed gateway |
| **Affected asset** | ASSET-003 |
| **Status** | open |
| **First seen** | 2026-06-16 |
| **Related threats** | THREAT-008 |

**Description:** Because Cursor blocks localhost for BYOK endpoints, OpenBurnBar optionally creates a Cloudflare quick tunnel exposing the local OpenAI-compatible gateway on a public HTTPS URL. Only a short-lived session token is exposed; provider keys stay in Keychain.

**Evidence:**
- `docs/THREAT_MODEL.md:154-160`.
- `README.md:245-248`.

**Impact:** Any public URL increases scan/probe/DoS risk. Misconfiguration or token leak could allow unauthorized model access.

**Existing controls:** Short-lived token; provider keys in Keychain.

**Missing controls:** Origin validation, strict token lifetime, automatic tunnel teardown on inactivity.

**Recommendation:** Add telemetry/alerts for tunnel creation; document risk; enforce token rotation every N minutes.

**Acceptance criteria:**
- Tunnel URL has bounded lifetime.
- Unauthorized requests logged and rate-limited.

**Owner suggestion:** Routing/connector team.

---

## FINDING-010 — CI compromise could ship malicious signed release artifacts

| Field | Value |
|---|---|
| **Severity** | Medium |
| **Category** | Supply chain |
| **Component** | `.github/workflows/release.yml` |
| **Affected asset** | ASSET-016/017 |
| **Status** | open |
| **First seen** | 2026-06-16 |
| **Related threats** | THREAT-009 |

**Description:** The release workflow has access to Apple signing certificates, notary keys, Sparkle private key, and Android keystore. A compromised runner or malicious workflow change could produce signed, notarized malware.

**Evidence:**
- `.github/workflows/release.yml:57-59` secret availability checks.
- `.github/workflows/release.yml:388-540` signing and notarization steps.

**Impact:** Users install backdoored app via the legitimate update channel.

**Existing controls:** Environment gate, pinned actions, cleanup steps, cosign attestations.

**Missing controls:** Reproducible builds, dual-control for release signing, automated canary verification.

**Recommendation:** Add a post-release canary job that installs the DMG on a clean runner and verifies signature + known-good behavior.

**Acceptance criteria:**
- Release environment requires manual approval.
- Cosign/signature verification instructions are public.

**Owner suggestion:** Release engineering / security.

---

## FINDING-011 — Signal prekey directory allows direct client writes

| Field | Value |
|---|---|
| **Severity** | Medium |
| **Category** | Authorization / Cryptography |
| **Component** | Firestore rules / Signal prekey directory |
| **Affected asset** | ASSET-008 |
| **Status** | open |
| **First seen** | 2026-06-16 |
| **Related threats** | THREAT-011 |

**Description:** Firestore rules still permit direct client writes to the Signal prekey directory, creating a race condition with the preferred server-mediated `claimSignalPrekeyBundle` callable.

**Evidence:**
- `functions/src/callables/signalPrekeyDirectory.ts` header comment (per auth subagent review).
- `firestore.rules` signal prekey rules (not exhaustively read in this pass).

**Impact:** A malicious client could squat or overwrite prekeys, disrupting E2EE bootstrap.

**Existing controls:** Server path preferred; callable solves race.

**Missing controls:** Rules should deny direct writes or require server-only semantics.

**Recommendation:** Tighten Firestore rules to make prekey directory server-only or require a server-issued token.

**Acceptance criteria:**
- Client direct prekey write fails in rules tests.

**Owner suggestion:** Crypto/cloud team.

---

## FINDING-012 — Some management/revocation callables stop at `enforceAuthAndAppCheck` rather than high-risk owner-action guard

| Field | Value |
|---|---|
| **Severity** | Medium |
| **Category** | Authorization |
| **Component** | Cloud Functions |
| **Affected asset** | ASSET-005/006 |
| **Status** | open |
| **First seen** | 2026-06-16 |
| **Related threats** | THREAT-012 |

**Description:** High-risk operations use `requireHighRiskNonce` + device proof, but some management/revocation callables use only `enforceAuthAndAppCheck`, leaving them exposed to replay or stolen-token abuse.

**Evidence:**
- Auth subagent review noted this gap.
- `functions/src/callables/computerUseSecurity.ts` and related callables.

**Impact:** Stolen session token could be used for account-level management operations.

**Existing controls:** App Check, ownership assertion.

**Missing controls:** High-risk nonce + device proof on all destructive/management callables.

**Recommendation:** Audit all callables in `functions/src/index.ts`; apply high-risk guard to any operation that changes trust state, deletes data, or issues tokens.

**Acceptance criteria:**
- Endpoint authorization matrix updated and tested.

**Owner suggestion:** Cloud security team.

---

## FINDING-013 — Remote Unlock helper binary not bundled in shipping builds

| Field | Value |
|---|---|
| **Severity** | High |
| **Category** | Safety / Deployment |
| **Component** | Computer Use / Remote Unlock |
| **Affected asset** | ASSET-013 |
| **Status** | open (needs verification) |
| **First seen** | Prior audit M-001 |
| **Related threats** | THREAT-013 |

**Description:** Per the prior audit handoff, `OpenBurnBarPrivilegedInputKillSwitchWatchdog` is not bundled in `project.yml`, causing Remote Unlock setup to throw `bridgeBinaryMissing` on a clean Mac.

**Evidence:**
- `security-audit/HANDOFF_REMAINING_RISKS_2026-06-14.md`: M-001 details.
- `project.yml` (not exhaustively verified in this pass).

**Impact:** A safety-critical feature is broken on clean installs; users cannot use Remote Unlock or the kill switch may not halt privileged input.

**Existing controls:** Source code exists; SPM executable target defined in `OpenBurnBarDaemon/Package.swift`.

**Missing controls:** XcodeGen `project.yml` copy phase for the helper.

**Recommendation:** Add the watchdog helper to `project.yml` copy phase; verify on clean Mac.

**Acceptance criteria:**
- Clean-Mac install succeeds; panic-halt and Remote Unlock reject replay.

**Owner suggestion:** macOS platform team.

---

## FINDING-014 — session_logs Firestore rule uses denylist instead of allowlist

| Field | Value |
|---|---|
| **Severity** | High |
| **Category** | Authorization / Privacy |
| **Component** | `firestore.rules` |
| **Affected asset** | ASSET-006 |
| **Status** | open (needs verification) |
| **First seen** | Prior audit M-005 |
| **Related threats** | THREAT-014 |

**Description:** Per prior audit handoff, the `session_logs` manifest rule was switched from a `hasOnly` allowlist to an incomplete ~20-name denylist, allowing a Pro owner to write arbitrary off-list plaintext fields.

**Evidence:**
- `security-audit/HANDOFF_REMAINING_RISKS_2026-06-14.md`: M-001 details.
- `firestore.rules` (allowlist helper exists around L357-399 but not wired in, per handoff).

**Impact:** Private session content can be written to Firestore in plaintext, contradicting privacy claims.

**Existing controls:** Denylist catches known secret field names.

**Missing controls:** `hasOnly` allowlist must be the first conjunct.

**Recommendation:** Wire `validSessionLogManifestKeys()` into `validSessionLogManifestCore` and extend rules tests.

**Acceptance criteria:**
- `firestore-rules-tests/session-log-backup.test.js` asserts off-allowlist fields fail.

**Owner suggestion:** Cloud security team.

---

## FINDING-015 — CloudVault path-bound AAD not applied to all sealed surfaces

| Field | Value |
|---|---|
| **Severity** | High |
| **Category** | Cryptography / Authorization |
| **Component** | Cloud sync / Cloud Vault |
| **Affected asset** | ASSET-006 |
| **Status** | open (needs verification) |
| **First seen** | Prior audit M-007 |
| **Related threats** | THREAT-015 |

**Description:** Path-bound AAD is enforced only for `usage`/`budgetRules`. Other sealed surfaces (`conversations`, `mobile_assistant_chats`) use global AAD, allowing same-account ciphertext relocation across documents.

**Evidence:**
- `security-audit/HANDOFF_REMAINING_RISKS_2026-06-14.md`: M-007 details.
- Writers for `chat_threads`, `cli_sessions`, and `media_attachment_manifests` still use global/no AAD.

**Impact:** Authenticated user or cloud operator can move sealed ciphertext from one document to another, potentially causing confusion/deputy or data disclosure.

**Existing controls:** Some writers already emit path-bound AAD.

**Missing controls:** Rules enforcing path-bound AAD on all current writers; migration for legacy global-AAD surfaces.

**Recommendation:** Apply `validPathBoundSealedPayloadForUser` to `conversations` and `mobile_assistant_chats` now; migrate `chat_threads`/`cli_sessions` writers to path-bound AAD before tightening rules.

**Acceptance criteria:**
- Rules tests assert relocated ciphertext fails and correct AAD succeeds.

**Owner suggestion:** Crypto/cloud team.

---

## FINDING-016 — agentNotifications sweeper logs full UID path

| Field | Value |
|---|---|
| **Severity** | Medium |
| **Category** | Privacy / Logging |
| **Component** | `functions/src/agentNotifications.ts` |
| **Affected asset** | ASSET-005 |
| **Status** | open (needs verification) |
| **First seen** | Prior audit M-023 |
| **Related threats** | THREAT-016 |

**Description:** The sweeper catch block logs `doc.ref.path`, which contains the full 28-char UID. The `logging.ts` scrubber does not redact UIDs inside path-shaped string values.

**Evidence:**
- `security-audit/HANDOFF_REMAINING_RISKS_2026-06-14.md`: M-023 details.

**Impact:** Cloud logs contain full Firebase UIDs, a privacy/regulatory issue.

**Existing controls:** Other sweepers already log bare `document_id`.

**Missing controls:** agentNotifications sweeper uses same pattern.

**Recommendation:** Change to `logError` with `document_id: doc.id` only.

**Acceptance criteria:**
- Test asserts emitted record contains no `users/<uid>/` literal.

**Owner suggestion:** Functions team.

---

## FINDING-017 — Phone-control authority allowlist allows cross-pairing hijack

| Field | Value |
|---|---|
| **Severity** | Medium |
| **Category** | Authorization / Device trust |
| **Component** | `functions/src/callables/computerUseSecurity.ts` |
| **Affected asset** | ASSET-009, ASSET-013 |
| **Status** | open (needs verification) |
| **First seen** | Prior audit M-037 |
| **Related threats** | THREAT-017 |

**Description:** `publishIrohPairingRecord` materializes `authorizedControllerDeviceIds` as every trusted phone, allowing phone B to control a Mac session associated with phone A.

**Evidence:**
- `security-audit/HANDOFF_REMAINING_RISKS_2026-06-14.md`: M-037 details.

**Impact:** Any trusted phone can send control intents to any paired Mac session.

**Existing controls:** Trusted-device escrow.

**Missing controls:** Per-pairing controller allowlist with TOFU + revocation scrubbing.

**Recommendation:** Make `publishPhoneControlAuthority` a single-transaction TOFU claim; revoke scrubs allowlists.

**Acceptance criteria:**
- Test: phone B cannot hijack phone A's pairing.

**Owner suggestion:** iroh/Computer Use team.

---

## FINDING-018 — Capability token not bound to HID presenter

| Field | Value |
|---|---|
| **Severity** | Medium |
| **Category** | Authorization / Computer Use |
| **Component** | Remote Unlock / Virtual HID Bridge |
| **Affected asset** | ASSET-013 |
| **Status** | open (needs verification) |
| **First seen** | Prior audit M-028 |
| **Related threats** | THREAT-018 |

**Description:** The capability-token verifier supports `boundEscrowDeviceId`/`requiredAttestationHashBlake3`, but the HID consumer never supplies them, so a token could be replayed by a different presenting device.

**Evidence:**
- `security-audit/HANDOFF_REMAINING_RISKS_2026-06-14.md`: M-028 details.

**Impact:** A compromised device could replay a capability token to perform remote unlock/input on the Mac.

**Existing controls:** Token signature and expiry.

**Missing controls:** Thread presenting identity from `MacRemoteUnlockReadinessService` through `PrivilegedInputDispatchEnvelope` to verifier.

**Recommendation:** Add presenting device identity to dispatch envelope and verifier request.

**Acceptance criteria:**
- Test: A-bound token presented by B-device rejects; A→A accepts.

**Owner suggestion:** Computer Use security team.

---

## FINDING-019 — Android iroh host-key provider may accept cached untrusted key

| Field | Value |
|---|---|
| **Severity** | Medium |
| **Category** | Cryptography / Network |
| **Component** | Android iroh transport |
| **Affected asset** | ASSET-009 |
| **Status** | open (needs verification) |
| **First seen** | Prior audit M-006 |
| **Related threats** | THREAT-019 |

**Description:** Per prior audit, Android `FirestoreIrohPairingPublicKeyProvider.fetchPublicKey` used `Source.DEFAULT`, potentially returning a cached key when offline. Key pin store used plaintext `MODE_PRIVATE`.

**Evidence:**
- `security-audit/HANDOFF_REMAINING_RISKS_2026-06-14.md`: M-006 details.

**Impact:** Man-in-the-middle or relay compromise could substitute a host key.

**Existing controls:** Key-change pinning added per prior audit; needs verification in current tree.

**Missing controls:** Verified `Source.SERVER` fetch; Keystore-backed encrypted pin store.

**Recommendation:** Force server fetch, store pin in `EncryptedSharedPreferences`, run Android unit tests.

**Acceptance criteria:**
- `HermesIrohRelayTransportTest.kt` rejects key-change end-to-end.

**Owner suggestion:** Android team.

---

## FINDING-020 — CloudVault first-vault / survivor quorum strategy unresolved

| Field | Value |
|---|---|
| **Severity** | Medium |
| **Category** | Cryptography / Key management |
| **Component** | Cloud Vault |
| **Affected asset** | ASSET-004 |
| **Status** | needs decision |
| **First seen** | Prior audit M-008 |
| **Related threats** | THREAT-020 |

**Description:** It is unclear whether first-vault creation must be server-mediated and whether rotation requires a survivor quorum. This affects recoverability and insider resistance.

**Evidence:**
- `security-audit/HANDOFF_REMAINING_RISKS_2026-06-14.md`: M-008 details.

**Impact:** Wrong policy can lead to unrecoverable data or unauthorized key rotation.

**Recommendation:** Make explicit product decision and document in `docs/THREAT_MODEL.md`.

**Acceptance criteria:**
- Documented first-vault policy and rotation quorum.

**Owner suggestion:** Security architect / product.

---

## FINDING-021 — First-contact iroh safety-number UX is a product-decision gate

| Field | Value |
|---|---|
| **Severity** | Medium |
| **Category** | Device trust / Usability |
| **Component** | iroh pairing |
| **Affected asset** | ASSET-009 |
| **Status** | needs decision |
| **First seen** | Prior audit M-018 |
| **Related threats** | THREAT-021 |

**Description:** Whether first-contact iroh pairing must display a safety-number comparison before establishing trust is unresolved.

**Evidence:**
- `security-audit/HANDOFF_REMAINING_RISKS_2026-06-14.md`: M-018 details.

**Impact:** Without safety numbers, a relay/network attacker could perform first-contact MitM.

**Recommendation:** Decide default-on vs. optional, implement, and test.

**Owner suggestion:** Product / iroh team.

---

## FINDING-022 — Client telemetry scrubbers not verified in shipped artifacts

| Field | Value |
|---|---|
| **Severity** | Medium |
| **Category** | Privacy / Logging |
| Component | macOS/iOS/Android Sentry |
| **Affected asset** | ASSET-015 |
| **Status** | open (needs verification) |
| **First seen** | Prior audit M-014 |
| **Related threats** | THREAT-022 |

**Description:** Source scrubbers exist (`MobileSentryScrubber.swift`, `ClientTelemetrySanitizer`), but it is unknown whether they are enabled in the built artifacts and whether Sentry project settings disable default PII.

**Evidence:**
- `security-audit/HANDOFF_REMAINING_RISKS_2026-06-14.md`: M-014 details.

**Impact:** Crash reports may contain UIDs, emails, paths, or local filesystem details.

**Recommendation:** Build release artifact, send synthetic event, verify redaction.

**Acceptance criteria:**
- Synthetic Sentry event has no UID/email/path.
- Sentry project PII settings documented.

**Owner suggestion:** Platform / privacy team.

---

## Summary Table

| ID | Title | Severity | Status | Score Impact |
|---|---|---|---|---|
| FINDING-001 | Local SQLite plaintext | Critical | open | Catastrophic cap |
| FINDING-002 | Unsandboxed app/daemon | Critical | accepted risk | Catastrophic cap |
| FINDING-003 | Computer Use adversarial tests missing | High | open | Major claim cap |
| FINDING-004 | Prompt/RAG injection partial | High | open | Major claim cap |
| FINDING-005 | App Check enforcement unverified | High | open | Major claim cap |
| FINDING-006 | Cloud sync metadata server-readable | Medium | accepted | — |
| FINDING-007 | Daemon RPC same-user token | Medium | accepted | — |
| FINDING-008 | Local MCP raw snippets | Medium | open | — |
| FINDING-009 | Cursor tunnel public URL | Medium | open | — |
| FINDING-010 | CI release compromise | Medium | open | — |
| FINDING-011 | Signal prekey direct writes | Medium | open | — |
| FINDING-012 | Management callable guard gap | Medium | open | — |
| FINDING-013 | Remote Unlock helper not bundled | High | open | Critical cap |
| FINDING-014 | session_logs rule fail-open | High | open | Critical cap |
| FINDING-015 | CloudVault AAD partial | High | open | Critical cap |
| FINDING-016 | agentNotifications UID leak | Medium | open | — |
| FINDING-017 | Phone-control cross-pairing | Medium | open | — |
| FINDING-018 | Capability token HID binding | Medium | open | — |
| FINDING-019 | Android iroh cached key | Medium | open | — |
| FINDING-020 | CloudVault quorum decision | Medium | needs decision | — |
| FINDING-021 | iroh safety-number decision | Medium | needs decision | — |
| FINDING-022 | Telemetry scrubber verification | Medium | open | — |
