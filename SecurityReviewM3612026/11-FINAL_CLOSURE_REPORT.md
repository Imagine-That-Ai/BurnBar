# BurnBar Security Swarm Final Closure Report

**Date:** 2026-06-01  
**Reviewer:** Codex final pass, after specialist swarm review and local remediation  
**Scope:** BurnBar / OpenBurnBar / BurnBar Cloud / BurnBar Cloud Pro surfaces visible in this workspace: cloud functions, Hermes Gateway, Iroh relay/pairing, desktop control, mobile clients, Android Hermes relay key storage, CI/supply-chain posture, docs/claims, and publishable-tree hygiene.

## Executive Verdict

**Launch readiness:** **Ready with conditions for controlled beta; hold broad public / enterprise launch.**

This codebase is not a soft prototype. It has serious security foundations: local-first state, App Check patterns, signed grants, Iroh E2EE, capability-token architecture, tamper-evident audit work, and strong engineering discipline. But the product category is inherently high-risk: remote control, cross-device agent messaging, attachments, runtime state, AI tool-calling, and cloud delivery all meet at sensitive trust boundaries.

The final pass closed multiple high-risk implementation gaps, but several product-launch blockers remain around signed attachment lifecycle, resource-exhaustion controls, step-up device trust, CI credential modernization, public secret/publishable-tree hygiene, and live cloud posture proof.

**Overall grade:** **B- for controlled beta**, **not ready for public enterprise security claims**.

## What Was Verified

Local evidence and commands:

- `npm --prefix functions run build` — **PASS**
- `npm --prefix functions run test:unit -- --run src/__tests__/hermesGateway.test.ts src/__tests__/publicRateLimit.test.ts src/__tests__/logging.test.ts` — **PASS**, 45 tests
- `npm --prefix extensions/openburnbar run build` — **PASS**
- full functions and extension unit suites after Vitest upgrade — **PASS**
- `cargo test frame_length_guard --quiet` in `crates/openburnbar-iroh` — **PASS**, 2 tests
- `./gradlew :app:compileDebugKotlin --no-daemon` in `android` — **PASS**
- `swift test --package-path OpenBurnBarCore --filter AgentCapabilityGrantTests/test_customDangerousCapabilitySetRequiresLocalAuthentication` — **PASS**, 1 test
- `bash scripts/ci/verify-resilience-wiring.sh` — **PASS**
- `bash scripts/ci/verify-ops-readiness.sh` — **PASS**
- `bash scripts/supply-chain-audit.sh` — **PASS** for npm audit; OSV scanner was not installed and was skipped
- publishable-tree Gitleaks scan — **FAIL**, 54 redacted hits; many are test vectors, but tracked `.asc/`, `artifacts/`, and release/download blobs need cleanup
- TruffleHog verified-only scan — **PASS**, 0 verified secrets

One attempted `xcodebuild` app-bundle test selected zero tests because the regression lives in `OpenBurnBarCore` SwiftPM tests; the correct SwiftPM test above passed. A broader app test wrapper stalled in an unrelated existing parity test and was stopped.

## Fixes Applied During Final Pass

1. **Remote control local-auth hardening**
   - Custom dangerous desktop-control capability sets now require local authentication based on actual selected capabilities and trust mode.
   - Added regression coverage in `OpenBurnBarCore/Tests/OpenBurnBarComputerUseCoreTests/AgentCapabilityGrantTests.swift`.

2. **Privileged HID leaf hardening**
   - `PrivilegedInputDispatchHandler` now validates capability tokens before input dispatch.
   - `OpenBurnBarVirtualHIDBridgeMain` forwards capability tokens through the legacy socket path.

3. **Iroh allowlist poisoning fix**
   - Removed broad `users/{uid}/devices[*].irohPeerNodeId` trust from inbound Mac allowlisting.
   - Connection-scoped controller allowlists are now the trust source.

4. **Iroh native frame-size guard**
   - Rust native `send_frame` / `recv_frame` enforce the 512 KiB cap before send/allocation.
   - Added frame-length guard tests.

5. **Hermes Gateway and device-code hardening**
   - Hermes default scopes no longer include `hermes.gateway.manage`.
   - Gateway and public device-code paths use safer IP extraction instead of blindly trusting `x-forwarded-for`.
   - CLI Link user code generation now uses cryptographic randomness.
   - Device secret hashes are validated and compared with timing-safe hex comparison.

6. **Attachment and logging mitigations**
   - Hermes signed upload init rejects active content types such as HTML, JavaScript, XHTML/XML, and SVG.
   - Cloud logging now redacts sensitive key names such as token, secret, cookie, password, privateKey, authorization, bearer, apiKey, and accessToken even when the value shape is unknown.

7. **Android Hermes relay secret storage**
   - Android relay EC/Iroh private material is migrated from plaintext base64 SharedPreferences into Android Keystore AES-GCM wrapping.
   - Legacy plaintext is read once, wrapped, then removed.

8. **Dependency hygiene**
   - Functions and extension Vitest / coverage dependencies were upgraded to remove npm audit findings.

## Remaining Blockers

**P0 before broad public launch**

1. **Signed attachment lifecycle is not complete.** The active-content block is useful, but the durable solution still needs finalize/verify metadata, size/hash enforcement, expiry cleanup, malware/content scanning policy, and server-side object ownership checks.
2. **Remote control needs launch-grade UX proof.** The code direction is much safer, but public launch needs unambiguous observe/control indicators, instant stop controls, scoped approvals, and an auditable confirmation model for high-impact agent actions.
3. **Device trust still needs step-up policy.** Pairing and grant approval should require recent-login/passkey/biometric/trusted-device proof for high-impact capabilities.
4. **Publishable-tree hygiene is not acceptable yet.** Gitleaks still flags 54 redacted hits and the repo has tracked artifacts/download material that should not be in a clean public security posture.
5. **Cloud deployment credentials need modernization.** Static `FIREBASE_TOKEN` / `GCP_SA_KEY` style deploy paths should move to GitHub OIDC / workload identity with least privilege.

**P1 within 7 days**

- Encrypted search/index fanout needs write amplification budgets and abuse tests.
- Remote MCP initialize/tools-list paths need active-client and entitlement enforcement parity.
- Iroh Android/prod pairing directory write paths need stricter verify-only behavior where intended.
- Datagram/media decoder paths need malformed/negative-length fuzz coverage.
- App Check enforcement, IAM, backups, WAF/rate limits, Cloud Logging redaction, and DR restore must be verified against live staging/prod configuration.
- Add OSV scanner / OpenSSF Scorecard / SBOM/provenance checks to CI for all artifact lanes.

## SOTA Baseline Used

Primary/current baselines checked:

- NIST SSDF SP 800-218: https://csrc.nist.gov/pubs/sp/800/218/final
- OWASP ASVS: https://owasp.org/www-project-application-security-verification-standard/
- OWASP API Security Top 10 2023: https://owasp.org/API-Security/editions/2023/en/0x00-header/
- OWASP GenAI / LLM Top 10: https://genai.owasp.org/llm-top-10/
- OWASP SCVS: https://scvs.owasp.org/
- CISA Secure by Design: https://www.cisa.gov/resources-tools/resources/secure-by-design
- CISA KEV catalog: https://www.cisa.gov/known-exploited-vulnerabilities-catalog
- SLSA v1.2: https://slsa.dev/spec/v1.2/
- OpenSSF Scorecard: https://scorecard.dev/
- OAuth 2.0 Device Authorization Grant, RFC 8628: https://www.rfc-editor.org/rfc/rfc8628
- OAuth 2.0 Security Best Current Practice, RFC 9700: https://www.rfc-editor.org/rfc/rfc9700
- Iroh relay, ticket, browser, and identity docs: https://www.iroh.computer/docs/concepts/relay-servers, https://www.iroh.computer/docs/concepts/tickets, https://www.iroh.computer/docs/platforms/browser

## Final Recommendation

**Do not market this as broadly launch-ready yet.** It is strong enough for a controlled beta with remote-control features gated, honest claims, and active monitoring. It is not yet ready for a public claim that BurnBar Cloud Pro is enterprise-secure.

The correct next engineering move is not more abstract planning. Close the remaining P0s, rerun the same verification suite plus a staging cloud posture check, then publish a clean security page and vulnerability disclosure policy before wider launch.
