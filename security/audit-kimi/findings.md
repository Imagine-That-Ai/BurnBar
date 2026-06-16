# Findings

## Legend

| Severity | Score Weight | Meaning |
|---|---|---|
| Critical | 0 | Unacceptable risk; ship-blocking without explicit acceptance |
| High | -4 | Significant risk; must fix or formally accept before release |
| Medium | -2 | Moderate risk; should fix in upcoming sprint |
| Low | -1 | Minor risk; track and fix opportunistically |
| Informational | 0 | Documentation/observation |

## FINDING-001 — Local SQLite Database is Plaintext by Default

- **Severity:** Critical
- **Status:** Open
- **CWE:** CWE-312 (Cleartext Storage of Sensitive Information)
- **Area:** Local database / cryptography
- **Evidence:** `AgentLens/Services/DatabaseEncryptionService.swift` exists but the GRDB-SQLCipher codec is not enabled; `docs/THREAT_MODEL.md` admits SQLCipher is not yet vendored.
- **Impact:** Any process running as the same user, any Time Machine/iCloud backup, or any attacker with filesystem access can read all agent logs, provider tokens, and usage data.
- **Acceptance Criteria:**
  1. `PRAGMA cipher_version` returns a version in Release builds.
  2. `DatabaseEncryptionService` derives a unique key per install and stores it in the keychain.
  3. Migration path documented for existing plaintext databases.
- **Related Threats:** THREAT-001, THREAT-005
- **Related Prior Audit:** M-001 (contextual)

## FINDING-002 — App and Daemon Run Unsandboxed

- **Severity:** Critical (accepted design risk)
- **Status:** Risk Accepted
- **CWE:** CWE-250 (Execution with Unnecessary Privileges)
- **Area:** macOS app / daemon
- **Evidence:** README and `docs/THREAT_MODEL.md` explicitly state the app requires full home-directory access and cannot be sandboxed.
- **Impact:** A compromised app or daemon has full access to the user's home directory, keychain, and can perform arbitrary actions as the user.
- **Acceptance Criteria:**
  1. Documented as accepted risk with compensating controls (code signing, notarization, approval gates, kill switches).
  2. Daemon RPC enforces least privilege per method.
- **Related Threats:** THREAT-001, THREAT-006
- **Related Prior Audit:** —

## FINDING-003 — Computer Use Adversarial Test Coverage Incomplete

- **Severity:** High
- **Status:** Open
- **CWE:** CWE-693 (Protection Mechanism Failure)
- **Area:** Computer Use / agent tools
- **Evidence:** `AgentLens/Services/ComputerUse/` has approval UI and kill switches, but `AgentLensTests/Active/` lacks adversarial tests for UI bypass, scope escalation, and per-tool-kind abuse.
- **Impact:** An attacker or malicious prompt could bypass approval, escalate scope, or trick the user into approving harmful actions.
- **Acceptance Criteria:**
  1. Tests for all 13 tool kinds under adversarial input.
  2. Tests for "Trusted" → "Step" downgrade and panic kill.
  3. Tests for cross-origin/cross-app injection in browser tool.
- **Related Threats:** THREAT-008, THREAT-009, THREAT-010
- **Related Prior Audit:** M-001, M-028

## FINDING-004 — Prompt / RAG Injection Defenses Partial

- **Severity:** High
- **Status:** Open
- **CWE:** CWE-74 (Improper Neutralization of Special Elements), CWE-917 (Expression Language Injection)
- **Area:** AI/RAG/chat
- **Evidence:** `docs/security/LLM_GENAI_AGENT_THREAT_MODEL.md` documents the threat; delimiter wrappers exist in some parsers but not all paths (`ContextBuilder.swift`, `ChatSessionController.swift`, Computer Use tool results).
- **Impact:** Malicious agent log content can manipulate LLM output, leak data, or trigger unauthorized tool calls.
- **Acceptance Criteria:**
  1. Uniform untrusted-content wrapper applied at every ingestion → prompt boundary.
  2. Provenance metadata attached to RAG snippets.
  3. Adversarial test corpus committed and run in CI.
- **Related Threats:** THREAT-004, THREAT-007
- **Related Prior Audit:** M-016

## FINDING-005 — App Check Production Enforcement Unverifiable

- **Severity:** High
- **Status:** Open
- **CWE:** CWE-306 (Missing Authentication for Critical Function)
- **Area:** Cloud sync / Firebase
- **Evidence:** `functions/src/auth.ts` has `assertAppCheck` but the helper's rejection behavior depends on Firebase console configuration. Firestore rules do not contain `request.app != null` checks.
- **Impact:** If App Check is disabled or misconfigured, any client with a stolen Firebase Auth token can read/write owner-scoped Firestore data via REST.
- **Acceptance Criteria:**
  1. Production console audit confirms App Check enforcement for Firestore.
  2. Add a repo-level assertion test that fails if rules drift.
  3. Add runtime probe using a non-attested token.
- **Related Threats:** THREAT-002, THREAT-003
- **Related Prior Audit:** M-005

## FINDING-006 — Cloud Sync Metadata Leaks Provider/Cost/Device Info

- **Severity:** Medium
- **Status:** Accepted / Document
- **CWE:** CWE-359 (Exposure of Private Information)
- **Area:** Cloud sync / privacy
- **Evidence:** Firestore documents under `users/{uid}/usage/`, `usage_rollups/`, `quota_snapshots/` contain provider IDs, costs, timestamps, device IDs, and opaque hashes.
- **Impact:** BurnBar/Firebase can profile user behavior; legal/competitive risk if marketing claims "we can't see anything."
- **Acceptance Criteria:**
  1. Privacy policy accurately describes visible metadata.
  2. Consider encrypting or hashing provider IDs and costs with a user key.
- **Related Threats:** THREAT-002
- **Related Prior Audit:** —

## FINDING-007 — Daemon RPC Lacks Per-Method Capability Isolation

- **Severity:** Medium
- **Status:** Open
- **CWE:** CWE-285 (Improper Authorization)
- **Area:** Local daemon
- **Evidence:** Daemon uses a single auth token; no documented authorization matrix.
- **Impact:** Any client with the token can call any method, including Computer Use tool dispatch.
- **Acceptance Criteria:**
  1. Document RPC method authorization matrix.
  2. Add per-method capability checks.
  3. Consider per-client ephemeral tokens.
- **Related Threats:** THREAT-006
- **Related Prior Audit:** —

## FINDING-008 — Local MCP Server Exposes Raw Search Snippets

- **Severity:** Medium
- **Status:** Open
- **CWE:** CWE-200 (Exposure of Sensitive Information to an Unauthorized Actor)
- **Area:** Local MCP / AI tools
- **Evidence:** `tools/openburnbar-mcp/server.py` returns semantic-search snippets without human gate.
- **Impact:** An external AI agent with MCP access can exfiltrate sensitive user context.
- **Acceptance Criteria:**
  1. Add user approval before returning snippets.
  2. Scope returned snippets to an explicit query intent.
  3. Add audit log of MCP tool calls.
- **Related Threats:** THREAT-004, THREAT-007
- **Related Prior Audit:** M-016

## FINDING-009 — Cursor Connector Uses Public Cloudflare Quick Tunnel

- **Severity:** Medium
- **Status:** Open
- **CWE:** CWE-668 (Exposure of Resource to Wrong Sphere)
- **Area:** Extensions / Cursor integration
- **Evidence:** `extensions/openburnbar/src/cursor/CursorConnector.ts` (or adjacent) uses a Cloudflare quick tunnel for localhost exposure.
- **Impact:** Public URL increases attack surface; token exposure could allow remote access to local daemon.
- **Acceptance Criteria:**
  1. Document when/why tunnel is used.
  2. Bind tunnel to a cryptographically random token with short TTL.
  3. Add UI indicator and one-click revocation.
- **Related Threats:** THREAT-006
- **Related Prior Audit:** —

## FINDING-010 — CI/CD Has Broad Secrets and Can Ship Malicious Release

- **Severity:** Medium
- **Status:** Risk Accepted
- **CWE:** CWE-345 (Insufficient Verification of Data Authenticity)
- **Area:** Supply chain
- **Evidence:** `.github/workflows/release.yml` signs and notarizes using GitHub secrets. Compromise of a maintainer account or workflow can ship malicious binaries.
- **Impact:** Users install trojanized update; worst-case full user compromise.
- **Acceptance Criteria:**
  1. Require two-person rule for release workflow.
  2. Use OIDC to fetch short-lived signing certs where possible.
  3. Publish reproducible-build instructions and verification.
- **Related Threats:** THREAT-011
- **Related Prior Audit:** M-040

## FINDING-011 — Firestore Rules Drift Risk

- **Severity:** Medium
- **Status:** Open
- **CWE:** CWE-284 (Improper Access Control)
- **Area:** Cloud infrastructure
- **Evidence:** Rules live in `firestore.rules`; deployment is manual/semi-automated. No CI test fails on rule drift.
- **Impact:** Production rules may diverge from repo, weakening tenant isolation.
- **Acceptance Criteria:**
  1. Add CI step that parses and compares deployed rules to repo.
  2. Add property-based tests for rule paths.
- **Related Threats:** THREAT-002, THREAT-003
- **Related Prior Audit:** M-005

## FINDING-012 — Rate Limiting Missing from Callable Surface

- **Severity:** Medium
- **Status:** Open
- **CWE:** CWE-770 (Allocation of Resources Without Limits)
- **Area:** Cloud Functions
- **Evidence:** No global rate-limit middleware; only resilience helpers for Stripe/Firestore.
- **Impact:** Abuse, enumeration, or cost attacks.
- **Acceptance Criteria:**
  1. Add per-UID rate limiting for expensive callables.
  2. Add App Check + IP-based anomaly alerting.
- **Related Threats:** THREAT-011, THREAT-012
- **Related Prior Audit:** M-017

## FINDING-013 — Data Deletion Cascade Incomplete

- **Severity:** Medium
- **Status:** Open
- **CWE:** CWE-212 (Improper Cross-boundary Removal of Data)
- **Area:** Privacy / data governance
- **Evidence:** `functions/src/callables/dataDeletion.ts` exists; prior audit M-013 noted incomplete cascade.
- **Impact:** User data may remain in Firestore/Storage/backup after deletion request.
- **Acceptance Criteria:**
  1. End-to-end test proving deletion of all user documents and Storage blobs.
  2. Verify local deletion path.
- **Related Threats:** THREAT-013
- **Related Prior Audit:** M-013

## FINDING-014 — Android iroh Secret Key Caching

- **Severity:** Medium
- **Status:** Open
- **CWE:** CWE-312 (Cleartext Storage of Sensitive Information)
- **Area:** Android / crypto
- **Evidence:** Prior audit M-006 noted iroh secret key may be cached in shared preferences.
- **Impact:** Key extraction from rooted or backup-exposed devices.
- **Acceptance Criteria:**
  1. Store iroh secret key in Android Keystore.
  2. Add migration from shared prefs.
- **Related Threats:** THREAT-014
- **Related Prior Audit:** M-006

## FINDING-015 — Cloud Vault AAD Partial

- **Severity:** Medium
- **Status:** Open
- **CWE:** CWE-345 (Insufficient Verification of Data Authenticity)
- **Area:** Cloud sync / crypto
- **Evidence:** Prior audit M-007 noted AAD coverage is incomplete across envelope variants.
- **Impact:** Possible substitution or malleability of sealed payloads.
- **Acceptance Criteria:**
  1. Audit every `seal`/`open` call site for AAD binding to sender, recipient, and scope.
  2. Add tests that reject tampered AAD.
- **Related Threats:** THREAT-002
- **Related Prior Audit:** M-007

## FINDING-016 — session_logs Callable/Rule Validation Gaps

- **Severity:** Medium
- **Status:** Open
- **CWE:** CWE-20 (Improper Input Validation)
- **Area:** Cloud Functions / Firestore
- **Evidence:** Prior audit M-018 noted validation gaps in `session_logs` write path.
- **Impact:** Malformed or oversized logs could break sync or leak across documents.
- **Acceptance Criteria:**
  1. Strict schema validation for `session_logs` writes.
  2. Size/depth limits enforced.
- **Related Threats:** THREAT-003
- **Related Prior Audit:** M-018

## FINDING-017 — Log Parser Memory Exhaustion / Zip Bomb

- **Severity:** Medium
- **Status:** Open
- **CWE:** CWE-400 (Uncontrolled Resource Consumption)
- **Area:** Log parsing
- **Evidence:** Parsers load entire files; no size/depth caps visible.
- **Impact:** DoS via malicious log file.
- **Acceptance Criteria:**
  1. Max file size per parser.
  2. Max nested depth for JSON/XML.
  3. Streaming parse where possible.
- **Related Threats:** THREAT-015
- **Related Prior Audit:** M-019

## FINDING-018 — Exported Data May Contain More Than Expected

- **Severity:** Low
- **Status:** Open
- **CWE:** CWE-359 (Exposure of Private Information)
- **Area:** Privacy
- **Evidence:** Prior audit M-014 noted `dataExport` could include derived or cached fields.
- **Impact:** User receives more data than expected; regulatory concern.
- **Acceptance Criteria:**
  1. Audit `dataExport` fields against privacy policy.
- **Related Threats:** THREAT-013
- **Related Prior Audit:** M-014

## FINDING-019 — Push Notification Payload May Leak UID

- **Severity:** Low
- **Status:** Open
- **CWE:** CWE-200 (Exposure of Sensitive Information)
- **Area:** Notifications
- **Evidence:** Prior audit M-023 noted `agentNotifications.ts` leaked UIDs.
- **Impact:** FCM payload could deanonymize user or link devices.
- **Acceptance Criteria:**
  1. Notification body contains no UIDs, names, or provider IDs.
- **Related Threats:** THREAT-002
- **Related Prior Audit:** M-023

## FINDING-020 — Phone HID Capability Token Binding Weak

- **Severity:** Medium
- **Status:** Open
- **CWE:** CWE-639 (Authorization Bypass Through User-Controlled Key)
- **Area:** Computer Use / phone control
- **Evidence:** Prior audit M-028 noted HID actions need stronger capability-token binding to device/session.
- **Impact:** Cross-pairing or stolen token could allow unauthorized remote input.
- **Acceptance Criteria:**
  1. Bind each HID capability grant to a specific session/device key.
  2. Verify token before every action.
- **Related Threats:** THREAT-009
- **Related Prior Audit:** M-028

## FINDING-021 — Free-Form Crash Context Could Leak Content

- **Severity:** Low
- **Status:** Open
- **CWE:** CWE-532 (Insertion of Sensitive Information into Log File)
- **Area:** Observability / privacy
- **Evidence:** Sentry/Crashlytics scrubbers exist but cannot catch all free-form error messages thrown from deep code paths.
- **Impact:** Agent log fragments or paths may appear in crash reports.
- **Acceptance Criteria:**
  1. Audit all `throw` sites for user content.
  2. Add before-send hook tests with synthetic sensitive data.
- **Related Threats:** THREAT-013
- **Related Prior Audit:** —

## FINDING-022 — Local Daemon Auth Token Rotation Undefined

- **Severity:** Low
- **Status:** Open
- **CWE:** CWE-798 (Use of Hard-coded Credentials)
- **Area:** Local daemon
- **Evidence:** Single auth token stored in defaults/keychain; no documented rotation on reinstall/update.
- **Impact:** Long-lived secret; compromise of one client can persist.
- **Acceptance Criteria:**
  1. Document rotation policy.
  2. Rotate on major updates or on demand.
- **Related Threats:** THREAT-006
- **Related Prior Audit:** —
