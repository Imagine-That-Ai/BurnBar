# OpenBurnBar pre-launch security remediation — 2026-06-09

Companion to the pre-launch assessment. This records what was **fixed, tested,
and committed** in this pass, what is **owned by the concurrent control-plane
trust-root work**, and implementation-ready **designs** for the items that are
entangled with that work or with the bytecode-only runtime.

All work here is on branch `security/control-plane-trust-root` (shared tree),
committed by explicit file path so it never sweeps up the other agent's
in-flight changes. The agent-sandbox work is on branch
`security/agent-sandbox-hardening` in the `~/.hermes/hermes-agent` fork worktree.

---

## ✅ Fixed + tested + committed (this pass)

| ID | Title | Where | Verification | Commit |
|----|-------|-------|--------------|--------|
| **C-4** | Agent command-guard: gate secret reads/exfil, fail-closed tirith, smart-mode escalation, opt-in env hardening | `~/.hermes/hermes-agent` `tools/approval.py`, `tools/tirith_security.py`, `tools/environments/local.py` | 40 new tests + 191 existing approval/guard tests pass | `35bbc2c61` (fork) |
| **C-5** | Pin + hash the on-host agent runtime for auditability | `third_party/hermes-agent/manifest.json`, `scripts/ci/verify-vendored-agent-source.sh`, docs | verifier passes against pinned source; warns C-4 pin pending | `ce7c9a5e7` |
| **H-6** | Mark dead Rust remote-control authorizer non-shipping | `crates/burnbar-remote/SECURITY.md`, `…/burnbar-remote-security/src/lib.rs` | `cargo check` passes | `ce0a7a9f2` |
| **H-7** | Android: scope cleartext (force-TLS Firebase/Google) | `android/app/src/main/AndroidManifest.xml`, `res/xml/network_security_config.xml` | XML valid; SDK 35 | `a1073fb08` |
| **H-8** | Android: disable backup + device-transfer of key material | `AndroidManifest.xml`, `res/xml/data_extraction_rules.xml` | XML valid | `a1073fb08` |
| **M-5** | Non-replayable recovery confirmation commitment | `functions/src/callables/recovery.ts` | 25 tests (incl. replay-of-stored-value rejected) | `00dac4a6a` |
| **M-6** | CI-verify libsignal fork delta is build-only (never crypto-core) | `third_party/libsignal/manifest.json`, `scripts/ci/verify-libsignal-submodule-delta.sh`, `release.yml` | guard passes (delta = swift/Package.swift only) | `ae9153743` |
| **M-7** | Opt-in subprocess-env secret stripping | `~/.hermes/.../local.py` | covered by C-4 tests | `35bbc2c61` (fork) |
| **M-9** | Fix the broken privileged-peer code-sign requirement | `OpenBurnBarDaemon/.../OpenBurnBarSigningIdentity.swift`, `PrivilegedPeerAuthenticator.swift` | 6 `swift test` (requirement now compiles; was -67052) | `01e55d3ae` |
| **L-3** | Fail closed if production runs with App Check disabled | `functions/src/config.ts` | 4 tests | `cba61a7f4` |
| **L-4** | Refuse to publish a Homebrew cask with placeholder sha256 | `scripts/update-homebrew.sh` | `bash -n` + guards | `0c458732c` |
| **C-2** | Client-verifiable escrow trust chain before CloudVault key wrap | `CloudVaultTrustedDeviceChainVerifier.swift`, mobile/Android verifiers, `computerUseSecurity.ts` fingerprint backstop | `approveEscrowDeviceTrustHandler.test.ts`, `escrowDeviceTrustFingerprint.test.ts`, `CloudVaultDeviceTrustChainTests.swift`, `CloudVaultDeviceTrustChainTest.kt` | main @ 2026-06-13 |
| **C-3** | Revocation rotates + re-wraps the CloudVault key | `cloudVaultRotation.ts`, `ComputerUseSecurityCallableClient.swift`, `CloudVaultRotationRewrapWorker.swift`, Android rotation path | `cloudVaultRotationNonRevokerSurvivor.test.ts`, `cloudVaultRotationResilience.test.ts`, `CloudVaultRotationPickupTests.swift`, `AndroidCloudVaultRevocationRotationTest.kt` | main @ 2026-06-13 |
| **H-4** | Harden + audit Cloudflare tunnel auth (code path) | `CursorConnectorManager.swift` (loopback broker, session token, fail-closed probe), C-5 gateway pin | `verify-vendored-agent-source.sh`; residual quick-tunnel risk accepted as AR-006 | main @ 2026-06-13 |

### Notes on the bigger-than-scoped fixes

- **M-9 was a latent functionality+security bug.** The privileged UNIX-socket
  designated requirement never compiled (`info[ApplicationFlags] & ApplicationFlags
  HardenedRuntime` is invalid CSRL → `SecRequirementCreateWithString` returns
  `errSecCSReqInvalid`), so `defaultCodeSignatureValidation` always threw and the
  gate rejected *every* peer. And `identifier "com.openburnbar.*"` is a literal,
  not a wildcard (verified: it fails to satisfy for `com.openburnbar.daemon`). Now
  the requirement is valid (Apple anchor + Team ID + exact peer identifiers) and
  hardened-runtime + library-validation are enforced programmatically via
  `SecCodeCopySigningInformation`.
- **C-4 was less broken than the original audit (built from stale bytecode)
  implied** — the live guard already covered `rm -rf`, `curl|sh`, etc. The real,
  closed gaps were secret-file **reads** (`cat ~/.ssh/id_rsa`, `security
  dump-keychain`) and **exfil uploads** (`curl --data @file`, `scp`), tirith's
  fail-**open** default, and the injectable smart-guardian auto-approving those
  categories. A blanket `sandbox-exec` deny was deliberately **rejected** (it
  breaks `ssh`/`git`/keychain helpers — the precise guard is the better tool; use
  the Docker backend for true isolation). See
  `~/.hermes/hermes-agent/docs/security/AGENT_COMMAND_GUARD_HARDENING.md`.

---

## ✅ Verified already-addressed (no change needed)

- **H-1 (libsignal claim oversold).** The website crypto claims are already
  honest and CI-enforced: `website/src/data/crypto-claims.generated.ts` says
  libsignal is `"wired in, not activated in production"`, labels the gateway lane
  a `"homegrown Double Ratchet"`, and states iOS never links libsignal (an
  enforced invariant). The "no one in the middle, includes us" Floo claim becomes
  fully accurate once **C-1** (other agent) lands.
- **L-6 (committed Firebase web key).** Accepted-by-design and correctly
  documented in `apps/console/lib/firebaseClient.ts` — Firebase web API keys are
  **public client identifiers, not secrets** (Google's own guidance); security
  comes from Firestore rules + App Check (hardened in L-3). No exposure.

---

## ➡️ Owned by the concurrent control-plane trust-root work (do not duplicate)

The other agent's "Permanent Remote-Control Trust Boundary Remediation" covers
these; their footprint (`HermesService`, `HermesRelayAuthenticatedRequest`,
`PhoneControlAuthorityPublisher`/`Validator`, iroh handlers, Android relay,
`firestore.rules` pairing/grant sections, `computerUseSecurity.ts` +575 lines,
deep-link entry, gateway rate-limit) directly implements:

- **C-1** authenticated+pinned relay requests (HPKE Auth v3, sender binding,
  replay/downgrade defense) — the cardinal fix.
- **H-2** safety-number / Signal-identity enforcement (their "Signal identity
  gate": remote dispatch requires a verified, non-TOFU identity).
- **H-3 / H-5 / M-1 / M-2 / M-3 / M-4 / L-1** — phone-control authority + signed
  approvals (H-3 deny-region adjacent), escrow device verification (H-5/M-4),
  iroh/media auth (M-1), mirror consent (M-2), deep-link authority (M-3), gateway
  rate-limit (L-1). Coordinate so these land in their trust-root, not in parallel.

---

## ✅ Implemented after this doc (ledger: `docs/governance/PHASE1_SECURITY_REGISTER.md`)

C-2, C-3, and H-4 shipped on `main` with the proof commands listed in the Phase 1
register. The design notes below are kept for audit history.

## 📐 Implementation-ready designs (historical — implemented 2026-06-13)

### C-2 — Stop malicious-server escrow trusted-device injection (CloudVault key)

**Root cause.** `MobileCloudVaultKeyAccess.swift` wraps the vault key to *every*
device the server marks `escrow_devices.trustState == "trusted"`, trusting a
server-writable field + server-supplied `publicKeyData`; the fingerprint backstop
(`computerUseSecurity.ts` `ESCROW_DEVICE_FINGERPRINT_ENFORCEMENT_ENABLED`) is off.
A malicious Admin-SDK write of a `trusted` device with a server key harvests the
vault key.

**SOTA fix — client-verifiable signed trust chain (don't trust a server field).**
1. **Approver signature.** When an existing trusted device approves a new device,
   it signs the new device's escrow/identity public key (Ed25519) with its own
   device key. Store `approverDeviceId` + `approverSignature` on the
   `escrow_devices`/`escrow_public_keys` doc (server records, never mints).
2. **On-device pinned root.** Each client pins the **first** trusted device's
   identity key (the bootstrap root, surfaced as a safety number — see H-5) in the
   Keychain on first run.
3. **Verify before wrap.** In `keyForWriting`, before wrapping the vault key to a
   device, verify `approverSignature` chains (transitively) to the pinned root and
   that each hop's approver was itself trusted. Refuse to wrap to any device whose
   chain doesn't verify — even if the server says `trusted`. An Admin-SDK-injected
   device has no valid approver signature from a real user device, so it never
   receives a wrapper.
4. **Enable the backstop.** Turn on `ESCROW_DEVICE_FINGERPRINT_ENFORCEMENT_ENABLED`
   server-side (defense in depth).
5. **Parity** in Android `CloudVaultCrypto.kt` / escrow code.
Files: `OpenBurnBarMobile/Services/MobileCloudVaultKeyAccess.swift` (clean/mine),
`CloudVaultCrypto.swift`, `functions/src/callables/computerUseSecurity.ts`
(other agent's hot file — coordinate), `firestore.rules` escrow sections.
Tests: chain verifies for a real approver; an injected `trusted` device with a
server key is refused; a revoked approver breaks the chain.

### C-3 — Device revocation must rotate + re-wrap the CloudVault key

**Root cause.** `revokeEscrowDeviceTrust` flips `trustState:"revoked"` but never
rotates the key (`CloudVaultCrypto.currentKeyVersion = 1` hardcoded; rules forbid
changing `vaultKeyID`) nor invalidates the revoked device's
`cloud_vault_key_wrappers`. The revoked device decrypts forever.

**SOTA fix — client-driven rotation via a dedicated server callable (avoids the
contested files).**
1. New callable `rotateCloudVaultKey` (NEW file, e.g.
   `functions/src/callables/cloudVaultRotation.ts`, wired in `index.ts`) — runs
   under the Admin SDK so it can atomically bump `vaultKeyID` and replace wrappers
   **without** relaxing `firestore.rules` (client-immutability stays).
2. Client (surviving trusted device) generates a new vault key
   (`CloudVaultCrypto.generateVaultKey`, version N+1), re-wraps it to every
   surviving **chain-verified** trusted device (C-2), and submits the new wrappers
   + new `vaultKeyID` to the callable.
3. Callable transaction: verify caller is a trusted device, bump
   `cloud_vault_state.vaultKeyID` (monotonic, downgrade-protected), write the new
   wrappers, **delete/`status:"revoked"`** the revoked device's wrappers.
4. Trigger on revoke: `revokeEscrowDeviceTrust` enqueues/notifies the client to
   rotate (or the client rotates immediately after a successful revoke call).
5. **Re-encrypt content** under the new key (staged; lexical/at-rest envelopes
   carry `keyVersion`).
6. Parity in Android.
Honest limitation to document: plaintext already synced to a rogue device
*before* revocation cannot be clawed back; rotation stops all *future* and
*re-fetched* access.
Files: `CloudVaultCrypto.swift` (clean), `MobileCloudVaultKeyAccess.swift`
(clean), new `cloudVaultRotation.ts`, `signalDirectoryRuntime.ts` (clean),
Android `CloudVaultCrypto.kt`. Tests: revoke → rotate → revoked wrapper gone +
`vaultKeyID` bumped + survivors re-wrapped; downgrade rejected.

### H-4 — Harden / make auditable the Cloudflare tunnel auth

**Root cause.** `CursorConnectorManager.swift` exposes the local OpenAI-compatible
router on a public `*.trycloudflare.com` URL; the Bearer enforcement lives in the
bytecode-only gateway (so it can't be audited — see C-5).
**Fix.** (1) Make the router's Bearer enforcement auditable by publishing the
router source via the C-5 pin. (2) Strengthen the token: ≥256-bit, per-session,
rotated; the client already probes the endpoint unauthenticated and must reject
it if a 200 comes back without auth — keep that fail-closed. (3) Prefer a
Cloudflare Access policy or a named tunnel with an auth gate over a bare quick
tunnel. (4) Bind the router to loopback only. Depends on C-5 (router source).
Files: `AgentLens/Services/CursorConnector/CursorConnectorManager.swift`,
the gateway router (pinned via C-5).

---

## 🟡 Product decisions (no code change without a call)

- **L-2 — avatars readable by any authenticated user.** `storage.rules` allows
  `read: if request.auth != null` for `avatars/{userId}/profile.jpg` (the only
  cross-tenant read). If avatars must be private, scope read to the owner and
  serve other users' avatars via a signed URL from a Cloud Function (as session
  logs already do); if profile photos are intentionally shared in team/collab
  contexts, document it as accepted. `ProfileAvatarService.swift` /
  `UserAvatarView.swift` show how they're read — confirm before changing, since
  owner-scoping would break direct cross-user `AsyncImage` display.
- **L-5 — `.vsix` not signed/published in CI.** Add a signed
  `vsce package` + marketplace publish step with a scoped PAT, or document the
  out-of-band signing path.

---

## Pre-beta checklist (blocking)

1. **C-1** authenticated+pinned relay (other agent) — the cardinal privacy fix.
2. ~~**C-2 / C-3**~~ — **closed 2026-06-13** (see Phase 1 register).
3. ~~**C-4 → C-5 pin**~~ — **closed 2026-06-13** (`pendingHardening.blocking: false`,
   `verify-vendored-agent-source.sh` blocking in ops readiness).
4. ~~**H-4** tunnel auth (code path)~~ — **closed 2026-06-13**; quick-tunnel
   residual accepted as AR-006.
5. Remove the local `~/.hermes/config.yaml` `tirith_fail_open: true` override now
   that the product default is fail-closed.
6. Land **H-2/H-3/H-5/M-1–M-4/L-1** via the trust-root work.

## Verification summary

C-4: 40 + 191 tests · M-5: 25 · L-3: 4 · M-9: 6 (`swift test`) · H-6: `cargo
check` · M-6 + C-5: guards executed & pass · H-7/H-8: XML + SDK validated · L-4:
`bash -n` + guards. No regressions attributable to these changes; the only `tsc`
errors in `functions/` are 12 pre-existing type-mock issues in the untouched
`knowledgeRepoMatchToken.test.ts`.

---

## Cross-lane status notes — 2026-06-09 invisible-perf sweep

Recorded by the concurrent performance/quality sweep that validated on this
shared tree (the sweep itself is perf-scoped; see `CHANGELOG.md` and
`docs/architecture/macos-performance.md` §7–13). Two items touch this lane:

- **Forward-fix to this lane's CloudVault rotation/re-wrap work (C-2/C-3
  implementation).** Commit `87d2a5230` made `CloudVaultAADContext.init`
  throwing; `48af34db4` repaired the Mac caller but missed the mobile twin,
  leaving `OpenBurnBarMobile/Services/MobileCloudVaultRotationRewrapWorker.swift`
  (lines 211 and 351) failing to compile and blocking the iOS test lane. The
  perf-validation lane applied this lane's own committed `try?`-guard pattern
  from `48af34db4` verbatim at both call sites (uncommitted working-tree edit;
  no behaviour change beyond restoring compile). Fold into the next
  security-lane commit.
- **Adjacent hardening landed by the sweep (not part of this taxonomy).** The
  public unauthenticated `latestRouterRundown` HTTP endpoint is now cost-DoS
  bounded: 64-entry in-memory response cache (60 s mutable / 24 h immutable /
  60 s negative TTLs), zero-Firestore-read 404s for implausible dates, and
  `maxInstances: 10` as the hard invocation-spend cap
  (`functions/src/routerRundown.ts`, 7 regression tests in
  `routerRundownEndpoint.test.ts`). Firestore-transaction rate limiting was
  deliberately not used (it would cost more per request than it caps).
