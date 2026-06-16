# BurnBar Security Audit Closure Plan - 2026-06-16

## Executive Verdict

The four audit artifacts agree on the core shape: BurnBar has strong security primitives, but the release posture is only defensible when production wiring, deployment enforcement, and user-facing claims are verified with executable checks. The score spread is mostly evidence policy, not disagreement about the riskiest gaps:

- GLM 5.2: 71/100. Emphasizes watchdog peer auth, dormant daemon local-auth verifier, and phone trust-mode downgrade invariants.
- Opus 4.8 1M: 73/100. Emphasizes encrypted collaboration artifacts, Mac Sentry scrubber tests, production setting proof, and claim hygiene.
- Kimi: 59/100. Applies a stricter cap for plaintext local database, App Check production proof, adversarial Computer Use tests, prompt/RAG injection, and daemon capability isolation.
- Codex GPT-5: 59/100. Applies a stricter cap for production daemon proof wiring, public URL/SSRF validation, App Check enforcement proof, durable deletion audit, and overbroad Signal/E2EE language.

My verification conclusion: the app is not "security done" until every high-impact runtime control has both implementation and a repeatable release verifier. The highest-confidence immediate remediations are now implemented in this workspace for daemon local-auth proof wiring and URL/SSRF validation. Production deployment gates and broader privacy/encryption work remain the next release blockers.

## 2026 Standards Basis

This plan uses current public guidance checked on 2026-06-16:

- OWASP ASVS 5.0.0 for web/API verification requirements: https://github.com/OWASP/ASVS
- OWASP MASVS / MASTG for mobile app security and privacy outcomes: https://mas.owasp.org/MASVS/
- Firebase App Check callable replay protection for low-volume security-critical callables: https://firebase.google.com/docs/app-check/cloud-functions
- OWASP SSRF Prevention Cheat Sheet and Top 10 SSRF guidance for strict scheme/host/IP validation, redirect discipline, and DNS rebinding resistance: https://cheatsheetseries.owasp.org/cheatsheets/Server_Side_Request_Forgery_Prevention_Cheat_Sheet.html
- OWASP Top 10 for LLM Applications 2025 for prompt injection, excessive agency, sensitive disclosure, and supply-chain controls: https://owasp.org/www-project-top-10-for-large-language-model-applications/
- GitHub Actions secure use guidance for least-privilege tokens, pinned actions, OIDC, and injection-resistant workflows: https://docs.github.com/en/actions/reference/security/secure-use
- SLSA provenance guidance for traceable, tamper-resistant release artifacts: https://slsa.dev/spec/v1.0/levels

## Claims Verified Or Corrected

### Now Defensible In This Workspace

- Public URL validation rejects userinfo, non-HTTP(S) schemes, parser-normalized loopback bypasses, and localhost lookalikes.
- SSRF normalization covers decimal, hex, octal, and short-form IPv4 before private/link-local/reserved range decisions.
- Daemon Computer Use local-auth proof is no longer dormant in production wiring; the daemon resolves pinned phone keys independently and records verified sessions without replaying single-use proofs per invocation.
- Phone key pinning has a daemon RPC path, a Keychain-backed production store, an in-memory test store, and end-to-end provisioning/proof tests.
- Xcode project generation now includes the new daemon key pin store in the macOS app build target.

### Still Not Safe To Claim Without More Proof

- "Everything is end-to-end encrypted." Collaboration/shared artifacts and local databases need exact scope language until every class of stored artifact is sealed and migration-tested.
- "Signal encryption" as a blanket claim. Only use this when the exact Signal-backed path is named and verified.
- "App Check enforced in production." Code configuration is not enough; release needs an automated verifier against deployed Firebase resources.
- "Production deletion is fully durable." Deletion must have durable intent/completion audit and reconciliation for partial failures.
- "Supply chain is SLSA-grade." Existing signing/SBOM/cosign work is strong, but release artifacts need a verifier that checks provenance and expected builder identity before publication claims.

## Remediation Plan

### P0 - Release Blockers

1. Production daemon local-auth proof gate
   - Status: implemented here.
   - Done means: production daemon creates `DaemonLocalAuthProofVerifier.production(...)`; verifier is enforced when privileged peer auth is enforced; phone public keys are pinned in Keychain; invokes require a previously proof-verified session.
   - Verification: daemon local-auth suite passes under SwiftPM and app target compiles/tests under Xcode.

2. Public URL and SSRF hardening
   - Status: implemented here.
   - Done means: `boundedHttpsURL` and `ssrfGuard` reject obfuscated loopback/private destinations, userinfo, unsafe schemes, and localhost lookalikes. Provider fetchers must still pin post-DNS IPs and disable redirects where outbound requests are executed.
   - Verification: unit tests cover decimal/hex/octal/short IPv4 and URL parser confusion cases.

3. Production Firebase App Check verifier
   - Status: pending.
   - Done means: release fails unless deployed callable/storage/firestore enforcement state matches the expected matrix; low-volume security-critical callables use `consumeAppCheckToken` where replay risk justifies the quota/performance cost.

4. Durable account deletion audit
   - Status: pending.
   - Done means: deletion writes durable intent, per-resource completion, idempotency key, and reconciliation status before returning success. Storage orphan cleanup must be observable.

5. Computer Use adversarial harness
   - Status: partially covered, pending expansion.
   - Done means: hostile tool output, malicious logs/RAG snippets, prompt-injection payloads, UI replay, stale grants, and trust-mode elevation attempts cannot trigger high-impact actions without fresh approval and local-auth proof where required.

### P1 - High-Value Hardening

6. Collaboration artifact encryption
   - Seal every shared/team artifact before Firestore write, migrate legacy plaintext safely, and keep backward-readable fallback only as a measured migration path.

7. Local database encryption claim closure
   - Either make SQLCipher key persistence fail closed everywhere or narrow claims. Add tests for Keychain failure, DB creation refusal, and recovery guidance.

8. Production ops truth verifier
   - Add one release command that verifies branch protection, required checks, App Check enforcement, alert routing, Sentry DSN, deletion retention, workflow permissions, and deployed function revisions.

9. Supply-chain provenance
   - Move deploys to OIDC/WIF-only, keep least-privilege workflow permissions, pin third-party actions, and verify SLSA provenance/Sigstore identity for release artifacts.

10. Security-claim lint
    - Block overbroad marketing/security language in docs and release notes unless it maps to evidence in `security-claims.md`.

### P2 - Completeness And Regression Resistance

11. Mac privacy scrubber tests for Sentry and local logs.
12. Extension notification privacy tests for thread IDs and device IDs.
13. Storage deletion reconciliation tests for partial Firebase Admin failures.
14. Android parity tests for iroh key caching and diff/authority coverage.
15. CODEOWNERS or explicit security reviewer routing for daemon, functions, workflows, Firebase rules, and crypto surfaces.

## Evidence From This Pass

- `functions/src/ssrfGuard.ts`
- `functions/src/callables/shared/validators.ts`
- `functions/src/__tests__/ssrfGuard.test.ts`
- `functions/src/__tests__/validators.test.ts`
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/DaemonPhoneKeyPinStore.swift`
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/DaemonLocalAuthProofVerifier.swift`
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemonExecutable/OpenBurnBarDaemonMain.swift`
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarDaemonServer.swift`
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/RPC/BurnBarDaemonServer+RPCComputerUse.swift`
- `OpenBurnBarCore/Sources/OpenBurnBarCore/Contracts/BurnBarRPCContracts.swift`
- `OpenBurnBarCore/Sources/OpenBurnBarCore/Contracts/BurnBarComputerUseContracts.swift`
- `OpenBurnBarCore/Sources/OpenBurnBarComputerUseCore/AgentCapabilityGrant.swift`
- `AgentLens/Services/ComputerUse/AgentCapabilityGrantStore.swift`
- `AgentLens/Services/ComputerUse/AgentCapabilityGrantQueueListener.swift`
- `AgentLens/Services/OpenBurnBarDaemon/OpenBurnBarDaemonSocketClient.swift`
- `AgentLens/Services/OpenBurnBarDaemon/OpenBurnBarDaemonManager+ComputerUse.swift`
- `AgentLens/Services/CLIBridge/OpenAICompatibleChatGatewayClient.swift`
- `OpenBurnBarDaemon/Tests/OpenBurnBarDaemonTests/BurnBarDaemonComputerUseLocalAuthProofWiringTests.swift`
- `OpenBurnBar.xcodeproj/project.pbxproj`

## Verification Commands

Passed:

```bash
cd functions && npm run test:unit -- --run src/__tests__/validators.test.ts src/__tests__/ssrfGuard.test.ts
swift test --package-path OpenBurnBarDaemon --filter BurnBarDaemonComputerUseLocalAuthProofWiringTests
xcodegen generate --spec project.yml
```

In progress at time this document was written:

```bash
./scripts/test-openburnbar-app.sh -only-testing:OpenBurnBarTests/AgentCapabilityGrantQueueListenerMattersTests
```

Known unrelated blocker from concurrent function work:

```bash
cd functions && npm run build
```

This currently fails in shared-workspace TypeScript unrelated to the URL/SSRF tests, including existing `functions/src/accountDeletion.ts` diagnostics and concurrent untracked notification privacy test work. Do not treat that as evidence against the targeted SSRF fix.

## Final Release Gate

Ship only after all P0 items are either implemented with passing tests or the release is explicitly scoped so the unimplemented control is unreachable. For a broad public release, the expected bar is:

- all P0 tests pass locally and in CI,
- production verifier passes against live Firebase/GitHub/Sentry/deploy state,
- docs avoid claims broader than evidence,
- release artifacts have signed provenance,
- rollback and alerting paths are tested.
