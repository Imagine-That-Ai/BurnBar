# Findings

All findings are new in this `codex-gpt-5` FULL_BASELINE namespace because no prior model-specific state existed.

| ID | Severity | Status | Title |
|---|---|---|---|
| FINDING-001 | High | open | Daemon local-auth proof verifier is not wired in the production executable |
| FINDING-002 | Medium | open | Daemon browser Computer Use uses synthetic entitlement and kill-switch context |
| FINDING-003 | Medium | open | Stripe redirect URL validation accepts unsafe non-HTTPS localhost-substring hosts |
| FINDING-004 | Medium | open | Firestore App Check enforcement is deployment-state dependent and not repo-verifiable |
| FINDING-005 | Medium | open | Public HTTP endpoints lack explicit product-layer rate limiting evidence |
| FINDING-006 | Medium | open | Data deletion audit logging is best-effort |
| FINDING-007 | Low | open | Production deploy still supports long-lived secret fallback paths |
| FINDING-008 | Low | open | SQLCipher key creation can continue after Keychain persistence failure |
| FINDING-009 | Low | open | Signal and E2EE privacy claims require narrower wording |

## FINDING-001: Daemon local-auth proof verifier is not wired in the production executable

Severity: High

Affected component: OpenBurnBarDaemon

Evidence: `OpenBurnBarDaemonMain.swift:54-86` wires `localAuthProofVerifier` to nil. `RPCComputerUse.swift:111-132` treats a nil verifier as no-op. `DaemonLocalAuthProofVerifier.swift:6-18,68-74,100-160` implements the intended verifier. `BurnBarDaemonComputerUseLocalAuthProofWiringTests.swift:90-242` proves both enforced and unenforced behavior.

Attack path: a compromised admitted local process or stolen daemon token requests Computer Use without independent phone/device proof.

Impact: high-impact local action under weaker authorization.

Recommendation: instantiate the verifier in production with persistent pin and replay stores, and fail closed when unavailable.

Acceptance criteria: production daemon path rejects missing, stale, replayed, wrong-device, wrong-intent, and unsigned proofs.

Regression test: production-configuration daemon test.

Score impact: -12.

## FINDING-002: Daemon browser Computer Use uses synthetic entitlement and kill-switch context

Severity: Medium

Evidence: `ComputerUseService.swift:108-149` builds context with `killSwitch: false`; `ComputerUseService.swift:285-310` returns synthetic active browser entitlement; `ComputerUseCapabilityGate.swift:232-246` enforces those fields when supplied.

Recommendation: source daemon context from live entitlement and Remote Config.

Score impact: -5.

## FINDING-003: Stripe redirect URL validation accepts unsafe non-HTTPS localhost-substring hosts

Severity: Medium

Evidence: `validators.ts:344-356`; `stripe.ts:229-254,314-341`.

Recommendation: exact loopback detection, HTTPS-only non-loopback, optional production origin allowlist.

Score impact: -4.

## FINDING-004: Firestore App Check enforcement is deployment-state dependent and not repo-verifiable

Severity: Medium

Evidence: `firestore.rules:20-23`; `appCheckAttestation.ts:1-8`; `config.ts:384-399`.

Recommendation: add release verifier that queries production App Check enforcement state.

Score impact: -5.

## FINDING-005: Public HTTP endpoints lack explicit product-layer rate limiting evidence

Severity: Medium

Evidence: public endpoint catalog; `routerRundown.ts:205-220`; hosted MCP has rate limits in `rateLimits.ts:5-36` but not every public Function endpoint.

Recommendation: add public endpoint rate-limit middleware or edge verifier inventory.

Score impact: -3.

## FINDING-006: Data deletion audit logging is best-effort

Severity: Medium

Evidence: `dataDeletion.ts:105-113`; `auditLog.ts:171-184`; `dataExport.ts:606-660`.

Recommendation: required pre-delete audit intent plus completion, or fail closed on audit failure.

Score impact: -3.

## FINDING-007: Production deploy still supports long-lived secret fallback paths

Severity: Low

Evidence: `deploy-production.yml:3-6,109-119,193-201`.

Recommendation: move production deploy to WIF/OIDC only and block fallback secret references.

Score impact: -3.

## FINDING-008: SQLCipher key creation can continue after Keychain persistence failure

Severity: Low

Evidence: `DatabaseEncryptionService.swift:95-117`.

Recommendation: fail closed when Keychain persistence fails for a newly generated key.

Score impact: -2.

## FINDING-009: Signal and E2EE privacy claims require narrower wording

Severity: Low

Evidence: `CloudVaultCrypto.swift:202-223` says Signal envelopes are additive/flag-off; `CloudVaultCrypto.swift:31-82,470-486` supports AES-GCM AAD.

Recommendation: claim AES-GCM Cloud Vault today; claim Signal only for enabled tested flows.

Score impact: -2.

