# Security Claims Matrix

## Defensible Claims

### CLAIM-001: Session content is end-to-end encrypted
- **Status:** Defensible
- **Evidence:** `CloudVaultCrypto.swift` uses AES-256-GCM with path-bound AAD (`OpenBurnBar-CloudVault-aad-v2|uid|collection|docID|field|schemaVersion|field`); vault key in Keychain `WhenUnlockedThisDeviceOnly`, never uploaded; Firestore rules enforce `validPathBoundSealedPayloadForUser` on `conversations` and `mobile_assistant_chats`; `validSessionLogManifestCore` requires sealed payloads with path-bound AAD on session_logs
- **Tests:** CloudVault AAD rules tests, `signalAtRestWrite.test.ts`, `firestore-rules-tests/` session-log-backup suite
- **Confidence:** High
- **Safe wording:** "Session content is encrypted on-device with AES-256-GCM before cloud upload. The server cannot decrypt session content."
- **Unsafe wording:** "Zero-knowledge encryption" (search hashes reveal metadata patterns to server)

### CLAIM-002: Object-level authorization is enforced on every callable
- **Status:** Defensible
- **Evidence:** `auth.ts:assertOwnership(request, expectedUid)` called on every callable that accesses user data; 21 BOLA test files covering 60+ endpoints with runtime cross-user proofs; `bolaCoverage.test.ts` validates matrix covers ALL exports from `index.ts`; `endpointAuthorizationMatrix` CI-enforced with `bolaCoverage` entries
- **Tests:** `functions/src/__tests__/bola/*.bola.test.ts`, `bolaCoverage.test.ts`, `endpointAuthorizationMatrix.test.ts`
- **Confidence:** High
- **Safe wording:** "Every callable endpoint verifies caller ownership of the requested resource, with CI-enforced BOLA test coverage."

### CLAIM-003: Computer Use audit chain is tamper-evident
- **Status:** Defensible
- **Evidence:** `ComputerUseAuditChain.swift` — SHA-256 content-addressed chain, each entry links to `parentEntryHashHex`; canonical-JSON (sorted keys, millisecond dates); `validateRequiringSignedHead()` fails closed with `.headAnchorMissing`; `ComputerUseAuditHeadFinalizer` signs terminal head with Ed25519
- **Tests:** ComputerUseAuditChain validation tests
- **Confidence:** High

### CLAIM-004: Three+ independent panic-kill paths exist
- **Status:** Defensible (with caveat)
- **Evidence:** `ComputerUsePanicHaltCoordinator.install()` wires: (1) global hotkey, (2) NSWorkspace auth gate, (3) Remote Config kill switch, (4) AX revocation polling (5s), (5) phone panic gesture. All converge on `PrivilegedInputKillSwitch.activate()`.
- **Caveat:** Kill-switch watchdog socket (used for crash recovery) has no peer auth — root can disarm (FINDING-001). This weakens the "cannot be disarmed" property but does NOT remove the other paths.
- **Safe wording:** "Multiple independent panic-halt paths (hotkey, auth gate, remote kill switch, phone gesture) all reach the privileged input boundary."
- **Unsafe wording:** "The kill switch cannot be disarmed by any local process" (FINDING-001 contradicts)

### CLAIM-005: No secrets are committed to the repository
- **Status:** Defensible
- **Evidence:** `.gitleaks.toml` + `.secrets.baseline` + `detect-private-key` pre-commit; triple scanning at release (gitleaks + detect-secrets + trufflehog `--only-verified`); `functions/.env.burnbar.production` verified line-by-line — contains only public product IDs, URLs, flags; `scan-internal-content.mjs` blocks internal-only content; `check-no-committed-evidence.sh` CI gate
- **Confidence:** High

### CLAIM-006: Supply chain uses SHA-pinned GitHub Actions with SBOM and SLSA
- **Status:** Defensible
- **Evidence:** `verify-github-action-pins.mjs` CI-enforced (rejects non-40-hex-SHA); all 39 workflows verified; SBOM via `generate-sbom.py` (SPDX 2.3, 4 ecosystems); SLSA via `cosign attest`; OpenVEX sidecar; live feed verification gate (`release.yml:1230-1294`) verifies DMG sha256 + Ed25519 signature post-publish
- **Confidence:** High

### CLAIM-007: High-risk callables require nonce + device proof
- **Status:** Defensible
- **Evidence:** `appCheckAttestation.ts:enforceHighRiskComputerUseCallableWithNonce()` requires fresh single-use nonce (2-min TTL in `high_risk_action_nonces`) + attestation binding (custom claim `obb_app_check.appId` must match live `request.app.appId`)
- **Tests:** `highRiskOwnerAction.test.ts`, `appCheckAttestation.test.ts`
- **Confidence:** High

### CLAIM-008: Daemon database is encrypted at rest
- **Status:** Defensible
- **Evidence:** SQLCipher with fail-closed `cipher_version` self-check; key in Keychain `WhenUnlockedThisDeviceOnly`
- **Tests:** `BurnBarDaemonDatabaseCipherTests`
- **Confidence:** High

### CLAIM-009: Daemon socket is 3-layer authenticated
- **Status:** Defensible
- **Evidence:** `OpenBurnBarDaemonServer.swift` — (1) filesystem `chmod 0600`, (2) bearer token via `constantTimeTokensEqual`, (3) peer code-signature validation via `BurnBarDaemonPeerAuthenticator`; self-codesig verification at startup; env stripping for child processes
- **Confidence:** High

## Partially Defensible Claims

### CLAIM-010: CloudVault key rotation is secure
- **Status:** Partially defensible
- **Evidence:** Server-enforced monotonic generation, client-driven zero-access rotation, survivor wrapper rewrap, session-log Storage blob resealing, hosted search index rekeying
- **Gaps:** First-vault creation not server-mediated; no survivor quorum (FINDING-004)
- **Safe wording:** "Vault key rotation is client-driven with server-enforced monotonic ordering."
- **Unsafe wording:** "Revoked devices immediately lose access" (cached plaintext not clawable back)

### CLAIM-011: iroh communication is secure
- **Status:** Partially defensible
- **Evidence:** App-level encryption over iroh QUIC; Ed25519 device identity; key-change pinning on all platforms; Firestore server-source fetch (Android)
- **Gaps:** First-contact safety-number not default-on (FINDING-005); relay observes traffic patterns
- **Safe wording:** "iroh traffic is encrypted and devices verify key continuity after first contact."
- **Unsafe wording:** "End-to-end encrypted with perfect forward secrecy"

### CLAIM-012: App Check is enforced
- **Status:** Partially defensible
- **Evidence:** `assertAppCheck()` on callables; `enforceAppCheck: true` in production env; attestation binding for high-risk ops
- **Gaps:** Att max-age 30 days (FINDING-007); Firestore rules do not use `request.app` (console-only)
- **Safe wording:** "Cloud Functions enforce App Check for callable endpoints."
- **Unsafe wording:** "App Check protects all data access"

## Not Defensible Claims

### CLAIM-013: "Signal encryption is live in production"
- **Status:** Not defensible
- **Evidence:** Signal HPKE at-rest dual-write is wired but NOT activated; `signalSealingIsEnabled` requires registry scheme + Remote Config flag (default OFF); Android parity incomplete
- **Safe wording:** "Signal-based at-rest encryption is implemented and staged for activation."
- **Unsafe wording:** Any claim of live Signal encryption

### CLAIM-014: "The phone can only downgrade trust mode"
- **Status:** Not defensible
- **Evidence:** `PhoneControlOptionSheet.swift` presents `ComputerUseTrustMode.allCases` (all three modes) without filtering; `downgradeTrustMode()` calls `state.setTrustMode(mode)` without direction validation
- **Resolution:** Filter to modes <= current mode

### CLAIM-015: "The kill switch cannot be disarmed by a local process"
- **Status:** Not defensible
- **Evidence:** Kill-switch watchdog socket (`/var/run/openburnbar-killswitch-watch.sock`) has no peer auth; any root process can send `{"action":"clear"}`
- **Resolution:** Add `PrivilegedPeerAuthenticator` to watchdog socket handler

## Unknown Claims

### CLAIM-016: "Production Firestore rules match this checkout"
- **Status:** Unknown
- **Resolution:** Run `check-firestore-deploy-drift.mjs` against production

### CLAIM-017: "TTL policies are materialized in production"
- **Status:** Unknown
- **Resolution:** Run `verify-firestore-ttl-state.mjs` on next deploy
