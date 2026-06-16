# Threat Register

## THREAT-001: Kill Switch Disarm via Unauthenticated Watchdog Socket
- **Category:** Availability / Safety Control Bypass
- **Framework:** STRIDE (Tampering), NIST CSF (Protect)
- **Component:** Kill-switch watchdog (`PrivilegedInputKillSwitchWatchdogMain.swift`)
- **Asset:** ASSET-009 (Privileged Input Kill Switch)
- **Threat actor:** Compromised endpoint (root)
- **Preconditions:** Attacker has root on the Mac
- **Attack path:** Root process connects to `/var/run/openburnbar-killswitch-watch.sock` (0600 root), sends `{"action":"clear"}`, kill switch flag removed, HID dispatch no longer halted
- **Impact:** Safety control disarmed; if combined with another HID dispatch path, agent actions could continue after panic
- **Likelihood:** Low (requires root + separate HID compromise)
- **Severity:** High
- **Existing controls:** File permissions 0600 root; three other independent panic paths still active
- **Missing controls:** Peer authentication on watchdog socket
- **Residual risk:** Medium (one of multiple safety layers weakened)
- **Detection:** Watchdog stderr log on socket accept
- **Test case:** `TEST-THREAT-001`: Connect to watchdog socket as root, send clear, verify flag removed. Then add auth and verify rejection.
- **Evidence:** `PrivilegedInputKillSwitchWatchdogMain.swift:60-93`
- **Finding:** FINDING-001

## THREAT-002: Computer Use Grant Without Phone Proof
- **Category:** Authorization Bypass / Privilege Escalation
- **Framework:** STRIDE (Elevation of Privilege), OWASP ASVS
- **Component:** Daemon privileged input dispatch
- **Asset:** ASSET-008 (Capability Tokens)
- **Threat actor:** Compromised first-party signed process
- **Preconditions:** Attacker has code execution inside a first-party signed process that passes the peer codesig gate
- **Attack path:** Compromised process forwards fabricated computer-use grant to daemon; `DaemonLocalAuthProofVerifier` is nil, so `enforceLocalAuthProof` returns nil (no-op); daemon dispatches HID without phone-proof re-verification
- **Impact:** Unauthorized HID input if a signed process is compromised
- **Likelihood:** Low (requires compromising a signed process)
- **Severity:** Medium
- **Existing controls:** Peer codesig gate, capability token binding, kill switch
- **Missing controls:** `DaemonLocalAuthProofVerifier` wired and active in production
- **Evidence:** `OpenBurnBarDaemonMain.swift:69`, `BurnBarDaemonServer+RPCComputerUse.swift:129-131`
- **Finding:** FINDING-002

## THREAT-003: Phone Trust Mode Elevation
- **Category:** Authorization Bypass
- **Framework:** STRIDE (Elevation of Privilege)
- **Component:** Phone-side Computer Use UI
- **Asset:** Computer Use trust state
- **Threat actor:** Compromised/stolen phone
- **Preconditions:** Attacker has access to the paired phone
- **Attack path:** Open `PhoneControlOptionSheet`, tap "Trusted" mode, `downgradeTrustMode(mode)` calls `state.setTrustMode(.trusted)` without direction validation
- **Impact:** Session elevated to Trusted mode from phone (should be Mac-only)
- **Likelihood:** Medium (requires phone access)
- **Severity:** Medium-High
- **Existing controls:** Capability gate still enforces scope rules; Trusted mode doesn't mean unchecked
- **Missing controls:** UI should filter to downgrade-only modes
- **Evidence:** `PhoneControlOptionSheet.swift` (ForEach allCases without filter)
- **Finding:** FINDING-003

## THREAT-004: CloudVault Ciphertext Relocation (chat_threads, cli_sessions)
- **Category:** Confidentiality / Integrity
- **Framework:** STRIDE (Information Disclosure)
- **Component:** Firestore rules for chat_threads and cli_sessions
- **Asset:** ASSET-002 (Session Content)
- **Threat actor:** Authenticated user
- **Preconditions:** User can write to their own collections
- **Attack path:** Copy sealed payload from chat_threads to a different doc/collection; without path-bound AAD, the same ciphertext opens under a different context (mismatched integrity binding)
- **Impact:** Ciphertext relocation attack (limited: same-user, same-vault-key)
- **Likelihood:** Low (same-user boundary)
- **Severity:** Medium
- **Existing controls:** `validSealedPayloadForUser` still verifies vault key + sealed payload structure
- **Missing controls:** Path-bound AAD on `chat_threads` and `cli_sessions`
- **Evidence:** `firestore.rules:ownerWritableChatThread -> validSealedPayloadForUser` (global AAD, not path-bound)
- **Finding:** FINDING-008

## THREAT-005: Cross-Tenant Data Access via Callable
- **Category:** Authorization Bypass / BOLA
- **Framework:** OWASP API1, STRIDE (Information Disclosure)
- **Component:** All Cloud Functions callables
- **Asset:** All user data
- **Threat actor:** Authenticated malicious user
- **Preconditions:** Valid Firebase Auth token
- **Attack path:** Call any callable with another user's uid as parameter
- **Impact:** Cross-tenant data exposure
- **Likelihood:** Very Low (assertOwnership + Firestore rules + 21 BOLA test files)
- **Severity:** N/A (mitigated)
- **Existing controls:** `assertOwnership` on every callable; Firestore `ownsUserNamespace`; BOLA test suite with victim seeding
- **Evidence:** `auth.ts:assertOwnership`, `firestore.rules`, `functions/src/__tests__/bola/`

## THREAT-006: iroh First-Contact MITM
- **Category:** Man-in-the-Middle
- **Framework:** STRIDE (Spoofing)
- **Component:** iroh relay pairing
- **Asset:** Device communication channel
- **Threat actor:** Relay operator / network attacker
- **Preconditions:** First-time device pairing through compromised relay
- **Attack path:** Attacker substitutes relay public key during first contact; without safety-number compare, user has no out-of-band verification
- **Impact:** MITM on device communication
- **Likelihood:** Medium (relay is untrusted by design)
- **Severity:** Medium
- **Existing controls:** Key-change pinning after first contact; Ed25519 identity; server-source fetch (Android)
- **Missing controls:** Safety-number confirmation default-on
- **Evidence:** `IrohRelayPairing.swift`, `IrohPairingHostKeyPinStore.kt`
- **Finding:** FINDING-005

## THREAT-007: Prompt Injection via Indexed Content
- **Category:** AI/Agentic (OWASP LLM01)
- **Framework:** OWASP Top 10 for LLM Applications
- **Component:** Local index oracle
- **Asset:** Oracle response integrity
- **Threat actor:** Malicious document/session in local index
- **Preconditions:** Malicious content indexed in local search
- **Attack path:** Poisoned content contains injection instructions; oracle retrieves and includes in prompt
- **Impact:** Oracle response manipulation
- **Likelihood:** Low (requires local index poisoning; same-user boundary)
- **Severity:** Low
- **Existing controls:** Snippets framed as "untrusted evidence" (M-015 fix); instruction-looking lines redacted
- **Residual:** Denylist is trivially bypassable; framing change is the real protection
- **Evidence:** `ChatSessionController.swift`

## THREAT-008: Provider Credential Exposure via Hosted Quota
- **Category:** Credential Theft
- **Framework:** STRIDE (Information Disclosure)
- **Component:** Provider credential storage
- **Asset:** ASSET-003 (Provider API Credentials)
- **Threat actor:** Cloud service compromise
- **Preconditions:** GCP KMS or Secret Manager compromise
- **Attack path:** Attacker accesses Secret Manager, decrypts credentials with KMS key
- **Impact:** Provider API key theft, financial exposure
- **Likelihood:** Very Low (requires GCP compromise)
- **Severity:** High (if precondition met)
- **Existing controls:** KMS encryption, callable-gated access, Secret Manager versioning
- **Evidence:** `functions/src/secrets.ts`, `callables/providerAccounts.ts`

## THREAT-009: Supply Chain Compromise
- **Category:** Supply Chain
- **Framework:** NIST SSDF, SLSA
- **Component:** CI/CD pipeline
- **Asset:** Production deployment
- **Threat actor:** Malicious dependency, compromised maintainer
- **Preconditions:** Dependency compromise + CI executes malicious code
- **Attack path:** Compromised npm package executes in CI, exfiltrates secrets or modifies build
- **Impact:** Malicious production code
- **Likelihood:** Low
- **Severity:** Critical (if precondition met)
- **Existing controls:** SHA-pinned Actions, lockfile integrity, triple scanning, WIF (no long-lived keys), SBOM+SLSA+cosign attestations, live feed verification
- **Evidence:** `.github/workflows/`, `verify-github-action-pins.mjs`, `generate-sbom.py`

## THREAT-010: Privacy Leakage via Push Metadata
- **Category:** Privacy (LINDDUN: Detecting, Linking)
- **Framework:** LINDDUN
- **Component:** Push notification payloads
- **Asset:** User communication patterns
- **Threat actor:** Apple/Google (push providers)
- **Preconditions:** Push notifications sent
- **Attack path:** Push provider observes routing IDs and correlates user activity patterns
- **Impact:** Communication pattern analysis
- **Likelihood:** Medium (metadata is inherent to push)
- **Severity:** Low (accepted by design)
- **Existing controls:** Ephemeral correlation IDs (fresh UUID per push), generic "Incoming call" label, CI-enforced I5 invariant banning PII fields
- **Residual:** Stable routing IDs remain visible (FINDING-010, accepted)
- **Evidence:** `voipPush.ts:buildVoipApnsPayload`, `check-privacy-invariants.mjs`

## THREAT-011 through THREAT-018

| ID | Title | Severity | Status |
|----|-------|----------|--------|
| THREAT-011 | Account deletion leaves orphaned Storage blobs | Low | FINDING-013 |
| THREAT-012 | pop_nonces grows unbounded if TTL fails | Low | FINDING-015 |
| THREAT-013 | Extension Sentry lacks recursive scrubber | Low | FINDING-011 |
| THREAT-014 | DNS rebinding bypasses SSRF guard (future risk) | Low | FINDING-009 |
| THREAT-015 | Stolen App Check attestation valid for 30 days | Medium | FINDING-007 |
| THREAT-016 | CLI executable hijack from user-writable dirs | Medium | FINDING-006 |
| THREAT-017 | Firestore App Check not rule-enforced | Low | Documented limitation |
| THREAT-018 | Solo operator merge without review | Medium | FINDING-017, documented policy |
