# Security Test Plan

## O.1 Existing Security Tests

### Cloud Functions (Vitest)
| Test File | Covers | Status |
|-----------|--------|--------|
| `bola/*.bola.test.ts` (21 files) | Cross-tenant authorization for all callables | CI-enforced |
| `bolaCoverage.test.ts` | Matrix completeness vs index.ts exports | CI-enforced |
| `endpointAuthorizationMatrix.test.ts` | Every endpoint has auth fields | CI-enforced |
| `highRiskOwnerAction.test.ts` | Nonce + attestation proof | CI-enforced |
| `appCheckAttestation.test.ts` | App Check binding | CI-enforced |
| `loggingScrubber.test.ts` | Log PII redaction | CI-enforced |
| `sentry.test.ts` | Sentry event sanitization | CI-enforced |
| `voipPushMetadata.test.ts` | Push payload minimization | CI-enforced |
| `stripeWebhookOrdering.test.ts` | Webhook signature + idempotency | CI-enforced |
| `accountDeletion.test.ts` | GDPR erasure completeness | CI-enforced |
| `phoneControlPairingBinding.test.ts` | Phone controller cross-pairing | CI-enforced |
| `cloudVaultRotationResilience.test.ts` | Vault key rotation | CI-enforced |
| `computerUseSecurity.test.ts` | Computer Use callable security | CI-enforced |

### Firestore Rules
| Test Suite | Covers | Status |
|-----------|--------|--------|
| `firestore-rules-tests/session-log-backup.test.js` | Session log manifest allowlist + plaintext rejection | CI-enforced (test:ci) |
| `firestore-rules-tests/` (6 suites) | Full rules coverage including relay/root | CI-enforced |

### Swift (XCTest)
| Test | Covers |
|------|--------|
| `BurnBarDaemonDatabaseCipherTests` | SQLCipher fail-closed |
| `ComputerUsePanicHaltCoordinatorTests` | Panic-kill paths |
| `ComputerUseAuditChain` validation tests | Tamper-evident chain |
| `CapabilityTokenVerifierTests` | Token binding verification |
| `VirtualHIDBridgeCapabilityGateTests` | HID boundary gate |
| `ClientTelemetrySanitizerTests` | Telemetry PII scrubbing |
| `AppLoggerSanitizationTests` | AppLogger metadata redaction |
| `OpenBurnBarSwitcherShellTests` | Env var stripping |
| `PrivilegedInputKillSwitchTests` | Kill switch flag |

### Android (JUnit)
| Test | Covers |
|------|--------|
| `HermesIrohRelayTransportTest` | Key-change rejection |
| `IrohPairingHostKeyPinStoreTest` | Pin store security |
| `SentryPrivacyScrubberTest` | Sentry PII scrubbing |
| `IntelligenceBriefFormattingTest` | Shared formatters |

### CI Gates
| Gate | Purpose |
|------|---------|
| `verify-github-action-pins.mjs` | SHA-pinned Actions |
| `check-no-suppressions.sh` | No new lint suppressions |
| `check-privacy-invariants.mjs` | Privacy invariant enforcement (I1-I6) |
| `verify-resilience-wiring.sh` | No raw fetch in functions |
| `verify-callable-logging.sh` | onCallProduction enforcement |
| `scan-publishable-tree.sh` | Pre-release secret scanning |
| `check-no-committed-evidence.sh` | No committed evidence artifacts |

## O.2 Missing Tests

| Test ID | Threat Covered | Type | Acceptance Criteria | Priority | Location |
|---------|---------------|------|---------------------|----------|----------|
| TEST-001 | THREAT-001 (kill switch disarm) | Integration | Watchdog socket rejects unsigned peer | High | `OpenBurnBarDaemon/Tests/` |
| TEST-002 | THREAT-002 (grant without proof) | Unit | Daemon rejects computer-use RPC without valid phone proof when verifier is wired | High | `OpenBurnBarDaemon/Tests/` |
| TEST-003 | THREAT-003 (trust elevation) | Unit/UI | Phone UI only shows modes <= current | High | `OpenBurnBarMobileTests/` |
| TEST-004 | THREAT-004 (ciphertext relocation) | Rules | chat_threads ciphertext fails when relocated to different docID | Medium | `firestore-rules-tests/` |
| TEST-005 | Prompt injection systematic | Adversarial | Oracle ignores injection instructions in indexed content | Medium | `AgentLensTests/` |
| TEST-006 | SSRF DNS rebinding | Unit | Guard rejects hostname that resolves to private IP | Low | `functions/src/__tests__/` |
| TEST-007 | Account deletion Storage reconciliation | Integration | Orphaned blobs detected/retried after partial failure | Low | `functions/src/__tests__/` |

## O.3 Safe Local Checks (Recommended)

```bash
# Functions security tests
cd functions && npm run test:security

# Firestore rules tests
cd firestore-rules-tests && npm run test:ci

# Privacy invariants
node scripts/ci/check-privacy-invariants.mjs

# BOLA coverage
cd functions && npx vitest run src/__tests__/bolaCoverage.test.ts

# Secret scanning
gitleaks detect --config .gitleaks.toml .

# GitHub Actions pin verification
node scripts/ci/verify-github-action-pins.mjs

# Daemon tests
swift test --package-path OpenBurnBarDaemon

# Core tests (crypto, capability tokens)
swift test --package-path OpenBurnBarCore --filter CapabilityTokenVerifier
swift test --package-path OpenBurnBarCore --filter ComputerUseAuditChain
```
